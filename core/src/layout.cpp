// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Profile -> Drawing: vista/sección, acotación en paralelo desde la cara de referencia, rayado, cajetín.
#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include "profile.hpp"
#include "font.hpp"
#include "stack.hpp"
#include "projsym.hpp"
#include "i18n.hpp"

namespace diedro {
namespace {
const double kEps = 1e-4;
const double kEdge = 0.3;     // mm: catetos menores = rotura de arista, no se acota
const double kMinFeat = 0.1;  // mm: detalle axial mínimo que se acota
const double kThick = 0.5, kThin = 0.25, kTxt = 3.5;

struct Loc { std::string lang = "es"; bool imperial = false; };
thread_local Loc gLoc;

std::string trimNum(double v, int dec) {
    char b[32];
    std::snprintf(b, sizeof b, "%.*f", dec, v);
    std::string s = b;
    while (s.back() == '0') s.pop_back();
    if (s.back() == '.') s.pop_back();
    if (s == "-0") s = "0";
    return s;
}
std::string decSep(std::string s) {
    if (decimalComma(gLoc.lang)) { auto i = s.find('.'); if (i != std::string::npos) s[i] = ','; }
    return s;
}
std::string fmtK(double v) { return trimNum(v, 2); }                                           // clave canónica (mm, punto)
std::string fmt(double v) { return decSep(gLoc.imperial ? trimNum(v / 25.4, 3) : trimNum(v, 2)); }  // longitud mostrada
std::string fnum(double v) { return decSep(trimNum(v, 2)); }                                   // magnitud sin unidad (ángulo, relación)
// ISO 129-1 6.2: una desviación nula se escribe «0» sin signo
std::string devTxt(double v) { return std::fabs(v) < 1e-9 ? "0" : (v > 0 ? "+" : "-") + fmt(std::fabs(v)); }
std::string T(const char* es) { return tr(es, gLoc.lang); }
std::string Tf(const char* es, std::initializer_list<std::string> a) {  // plantilla con {0}, {1}... (el orden de palabras cambia según el idioma)
    std::string s = T(es);
    int i = 0;
    for (auto& v : a) {
        std::string k = "{" + std::to_string(i++) + "}";
        for (size_t p; (p = s.find(k)) != std::string::npos;) s.replace(p, k.size(), v);
    }
    return s;
}
// nombres de rasgos no soportados (analyze.cpp los genera en español): se traduce la parte de texto, no las cifras
std::string unsupT(const std::string& k) {
    auto pre = [&](const char* p) { return k.rfind(p, 0) == 0; };
    if (pre("cilindro radial Ø")) { auto e = k.find(" ("); return T("cilindro radial") + " " + k.substr(16, e - 16) + " (" + T("taladro/resalte") + ")"; }
    if (pre("cilindro no coaxial Ø")) return T("cilindro no coaxial") + " " + k.substr(19);
    if (pre("superficie ")) return T("superficie") + " " + k.substr(11);
    return T(k.c_str());
}

bool near(double a, double b) { return std::fabs(a - b) < kEps; }

struct V2 { double x, y; };

// tangente (unitaria) del segmento en su extremo (end=0: inicio, 1: fin)
V2 tangentAt(const Seg& s, int end) {
    double z = end ? s.z1 : s.z0, r = end ? s.r1 : s.r0, dz, dr;
    if (s.kind == Seg::Plane) { dz = 0; dr = 1; }
    else if (s.kind == Seg::Line) { dz = s.z1 - s.z0; dr = s.r1 - s.r0; }
    else { dz = -(r - s.cr); dr = z - s.cz; }
    double n = std::hypot(dz, dr);
    return {dz / n, dr / n};
}

bool tangentJoin(const Seg& a, int ea, const Seg& b, int eb) {
    V2 t1 = tangentAt(a, ea), t2 = tangentAt(b, eb);
    return std::fabs(t1.x * t2.y - t1.y * t2.x) < std::sin(1.5 * M_PI / 180);
}

struct Pt { double z, r; };
Pt endPt(const Seg& s, int e) { return e ? Pt{s.z1, s.r1} : Pt{s.z0, s.r0}; }

// ¿es chaflán (cono a 45° pequeño)? / ¿es acuerdo (arco tangente a ambos vecinos)?
bool isChamfer(const Seg& s, double rmax) {
    if (s.kind != Seg::Line) return false;
    double dz = s.z1 - s.z0, dr = std::fabs(s.r1 - s.r0);
    return dz > kEps && dr > kEps && std::fabs(dz - dr) < 0.01 * std::max(dz, dr) && dz <= 0.25 * rmax;
}

struct Ctx {
    const Profile& p;
    std::vector<char> soft;          // chaflán / acuerdo: sus extremos no son puntos de cota
    std::vector<std::string> label;  // texto de la cota de chaflán/acuerdo
};

// vecinos: busca otro segmento que comparta el extremo e del segmento i
int neighbour(const Profile& p, int i, int e, int& eo) {
    Pt a = endPt(p.segs[i], e);
    for (int j = 0; j < (int)p.segs.size(); j++) {
        if (j == i) continue;
        for (int k = 0; k < 2; k++) {
            Pt b = endPt(p.segs[j], k);
            if (near(a.z, b.z) && near(a.r, b.r)) { eo = k; return j; }
        }
    }
    return -1;
}

void arcAngles(const Seg& s, double sign, double& a0, double& a1) {
    auto ang = [&](double z, double r) { return std::atan2(sign * r - sign * s.cr, z - s.cz) * 180 / M_PI; };
    double p0 = ang(s.z0, s.r0), p1 = ang(s.z1, s.r1), pm = ang(s.mz, s.mr);
    auto inside = [](double a, double b, double m) {  // m dentro del arco antihorario a->b
        auto n = [](double x) { while (x < 0) x += 360; while (x >= 360) x -= 360; return x; };
        return n(m - a) <= n(b - a);
    };
    if (inside(p0, p1, pm)) { a0 = p0; a1 = p1; } else { a0 = p1; a1 = p0; }
}

// Rayado: líneas a 45° (en hoja) dentro del polígono, rejilla global para que las dos mitades casen.
void hatch(Drawing& d, const std::vector<V2>& poly, double spacing) {
    { Poly h; for (auto& p : poly) h.pts.push_back({p.x, p.y}); h.hatch = spacing; h.hid = (int)d.polys.size(); if (h.pts.size() >= 3) d.polys.push_back(h); }
    const double c = std::sqrt(0.5);
    auto U = [&](V2 p) { return (p.x + p.y) * c; };
    auto W = [&](V2 p) { return (p.y - p.x) * c; };
    double wmin = 1e18, wmax = -1e18;
    for (auto& p : poly) { wmin = std::min(wmin, W(p)); wmax = std::max(wmax, W(p)); }
    for (double w = std::ceil(wmin / spacing) * spacing + 1e-7; w < wmax; w += spacing) {
        std::vector<double> us;
        for (size_t i = 0; i < poly.size(); i++) {
            V2 a = poly[i], b = poly[(i + 1) % poly.size()];
            double wa = W(a), wb = W(b);
            if ((wa <= w) == (wb <= w)) continue;
            us.push_back(U(a) + (w - wa) / (wb - wa) * (U(b) - U(a)));
        }
        std::sort(us.begin(), us.end());
        for (size_t i = 0; i + 1 < us.size(); i += 2) {
            double u0 = us[i], u1 = us[i + 1];
            d.lines.push_back({(u0 - w) * c, (u0 + w) * c, (u1 - w) * c, (u1 + w) * c, LineType::Continuous, kThin});
        }
    }
}

// Recorta un polígono con un semiplano f(p) <= 0 (Sutherland-Hodgman)
template <class F> std::vector<V2> clipPoly(const std::vector<V2>& in, F f) {
    std::vector<V2> out;
    for (size_t i = 0; i < in.size(); i++) {
        V2 a = in[i], b = in[(i + 1) % in.size()];
        double fa = f(a), fb = f(b);
        if (fa <= 0) out.push_back(a);
        if ((fa < 0 && fb > 0) || (fa > 0 && fb < 0)) { double t = fa / (fa - fb); out.push_back({a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)}); }
    }
    return out;
}

// Polígonos (mitad superior) del material a partir de los segmentos + cierres por el eje.
std::vector<std::vector<Pt>> materialLoops(const Profile& p, double polyHy = 0, std::vector<std::pair<Pt, Pt>>* walls = nullptr) {
    struct E { Pt a, b; int seg; };  // seg=-1: cierre por el eje
    std::vector<E> es;
    for (int i = 0; i < (int)p.segs.size(); i++) es.push_back({endPt(p.segs[i], 0), endPt(p.segs[i], 1), i});
    std::vector<double> axis;
    for (auto& s : p.segs)
        for (int e = 0; e < 2; e++) { Pt q = endPt(s, e); if (near(q.r, 0)) axis.push_back(q.z); }
    std::sort(axis.begin(), axis.end());
    for (size_t i = 0; i + 1 < axis.size(); i += 2) es.push_back({{axis[i], 0}, {axis[i + 1], 0}, -1});
    {   // extremos sin pareja (rasgos que no son de revolución, p. ej. el hexágono interior de un tornillo): se unen por pares cercanos con un tramo recto para poder rayar
        std::vector<Pt> open;
        double rm = 0;
        for (auto& e : es) {
            rm = std::max({rm, e.a.r, e.b.r});
            for (const Pt& q : {e.a, e.b}) {
                int c = 0;
                for (auto& f : es) c += (near(f.a.z, q.z) && near(f.a.r, q.r)) + (near(f.b.z, q.z) && near(f.b.r, q.r));
                if (c == 1) open.push_back(q);
            }
        }
        std::vector<char> done(open.size(), 0);
        std::vector<E> add;
        bool ok = open.size() >= 2 && open.size() <= 8 && open.size() % 2 == 0;
        if (polyHy > 0 && open.size() == 2 && !near(open[0].z, open[1].z) && polyHy > std::max(open[0].r, open[1].r)) {  // prisma exterior: el contorno cierra por la silueta de sus aristas
            Pt a{open[0].z, polyHy}, b{open[1].z, polyHy};
            es.push_back({open[0], a, -1}); es.push_back({a, b, -1}); es.push_back({b, open[1], -1});
            ok = false;
        }
        for (size_t i = 0; ok && i < open.size(); i++) {
            if (done[i]) continue;
            size_t bj = open.size();
            double bd = 1e18;
            for (size_t j = i + 1; j < open.size(); j++)
                if (!done[j] && std::hypot(open[i].z - open[j].z, open[i].r - open[j].r) < bd) { bd = std::hypot(open[i].z - open[j].z, open[i].r - open[j].r); bj = j; }
            if (bj == open.size() || bd > (p.hexes.empty() ? 0.6 * rm : 1e9)) { ok = false; break; }  // con hueco hexagonal el cierre es su pared (plano, no de revolución)
            done[i] = done[bj] = 1;
            add.push_back({open[i], open[bj], -1});
        }
        if (ok) for (auto& e : add) { es.push_back(e); if (walls && !p.hexes.empty()) walls->push_back({e.a, e.b}); }
    }
    std::vector<char> used(es.size(), 0);
    std::vector<std::vector<Pt>> loops;
    for (size_t s = 0; s < es.size(); s++) {
        if (used[s]) continue;
        std::vector<Pt> pts;
        Pt cur = es[s].a, start = cur;
        size_t k = s;
        for (int guard = 0; guard < 10000; guard++) {
            used[k] = 1;
            // puntos del borde k desde cur
            bool fwd = near(es[k].a.z, cur.z) && near(es[k].a.r, cur.r);
            Pt from = fwd ? es[k].a : es[k].b, to = fwd ? es[k].b : es[k].a;
            pts.push_back(from);
            if (es[k].seg >= 0 && p.segs[es[k].seg].kind == Seg::Arc) {
                const Seg& g = p.segs[es[k].seg];
                double a0, a1;
                arcAngles(g, 1, a0, a1);
                double span = a1 - a0;
                while (span <= 0) span += 360;
                int n = std::max(4, (int)std::ceil(span / 5));
                bool rev = !fwd ? true : false;
                // generar de a0 a a1 y ordenar según from->to
                std::vector<Pt> arc;
                for (int i = 1; i < n; i++) {
                    double a = (a0 + span * i / n) * M_PI / 180;
                    arc.push_back({g.cz + g.rad * std::cos(a), g.cr + g.rad * std::sin(a)});
                }
                Pt first = {g.z0, g.r0};
                bool startsAtA0 = std::hypot(first.z - g.cz - g.rad * std::cos(a0 * M_PI / 180), first.r - g.cr - g.rad * std::sin(a0 * M_PI / 180)) < 1e-3;
                bool forwardOrder = (startsAtA0 == fwd);
                (void)rev;
                if (!forwardOrder) std::reverse(arc.begin(), arc.end());
                for (auto& q : arc) pts.push_back(q);
            }
            cur = to;
            if (near(cur.z, start.z) && near(cur.r, start.r)) break;
            size_t nx = es.size();
            for (size_t j = 0; j < es.size(); j++) {
                if (used[j]) continue;
                if ((near(es[j].a.z, cur.z) && near(es[j].a.r, cur.r)) || (near(es[j].b.z, cur.z) && near(es[j].b.r, cur.r))) { nx = j; break; }
            }
            if (nx == es.size()) { pts.clear(); break; }  // perfil abierto: sin rayado
            k = nx;
        }
        if (pts.size() >= 3) loops.push_back(pts);
    }
    return loops;
}

struct Sheet { const char* name; double w, h; };
const Sheet kSheets[] = {{"A4", 297, 210}, {"A3", 420, 297}, {"A2", 594, 420}, {"A1", 841, 594}, {"A0", 1189, 841}};
const double kScales[] = {50, 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01};  // ISO 5455

std::string scaleText(double s) { return s >= 1 ? fnum(s) + ":1" : "1:" + fnum(1 / s); }

void line(Drawing& d, double x1, double y1, double x2, double y2, double w = kThin, LineType t = LineType::Continuous) {
    d.lines.push_back({x1, y1, x2, y2, t, w});
}
void arrow(Drawing& d, double x, double y, double dx, double dy) {  // punta en (x,y) mirando hacia (dx,dy)
    double n = std::hypot(dx, dy);
    dx /= n; dy /= n;
    const double L = 3.0, W = 0.8;   // ISO 129-1 5.4: flecha cerrada rellena de 30° incluidos (tan15°·3)
    Poly p;
    p.pts = {{x, y}, {x + dx * L - dy * W, y + dy * L + dx * W}, {x + dx * L + dy * W, y + dy * L - dx * W}};
    d.polys.push_back(p);
}
void mask(Drawing& d, double cx, double cy, double w, double h) {
    Poly p;
    p.pts = {{cx - w / 2, cy - h / 2}, {cx + w / 2, cy - h / 2}, {cx + w / 2, cy + h / 2}, {cx - w / 2, cy + h / 2}};
    p.white = true;
    d.polys.push_back(p);
}
}  // namespace

struct Opt {
    bool dense = false;
    double minS = 0;                   // escala mínima exigida (agrandar la hoja si hace falta)
    double wz0 = 0, wz1 = 0;           // ventana de detalle (wz1 > wz0): sus cotas van en la vista de detalle
    bool detail = false;               // dibuja solo la vista de detalle (sin marco ni cajetín) a la escala ds
    double ds = 0;
    const Drawing* det = nullptr;      // vista de detalle ya dibujada (se inserta arriba) y su caja
    double detX = 0, detY = 0, detW = 0, detH = 0;
    std::string detLabel;
};

Drawing layoutImpl(const Profile& p, const Meta& meta, const Opt& o) {
    gLoc.lang = meta.lang;
    gLoc.imperial = meta.imperial;
    Drawing d;
    d.warnings.clear();
    const bool win = o.wz1 > o.wz0;
    auto inWin = [&](double a, double b) { return win && a >= o.wz0 - kEps && b <= o.wz1 + kEps; };
    if (o.dense) d.warnings.push_back(T("Zona muy densa: algunas cotas se solapan; amplía con el zoom para leerlas."));
    const int n = (int)p.segs.size();
    std::vector<int> htag;  // taladros radiales concéntricos (mismo z y dirección) = un solo taladro escalonado: misma etiqueta
    for (size_t i = 0; i < p.rholes.size(); i++) {
        int t = (int)i + 1;
        for (size_t j = 0; j < i; j++)
            if (near(p.rholes[j].z, p.rholes[i].z) && std::fabs(p.rholes[j].ang - p.rholes[i].ang) < 1e-3) { t = htag[j]; break; }
        htag.push_back(t);
    }
    double rmax = 0;
    bool anyInner = false;
    for (auto& s : p.segs) {
        rmax = std::max({rmax, s.r0, s.r1});
        if (s.kind == Seg::Arc) rmax = std::max(rmax, s.mr);
        anyInner |= s.inner;
    }
    const double L = p.length;

    // ---- clasificación de segmentos blandos (chaflán / acuerdo)
    std::vector<char> soft(n, 0);
    int nEdge = 0;
    std::vector<std::string> lab(n);
    for (int i = 0; i < n; i++) {
        const Seg& s = p.segs[i];
        if (s.kind == Seg::Line && isChamfer(s, rmax)) {
            soft[i] = 1;
            double c = s.z1 - s.z0;
            lab[i] = fmt(c) + "×45°";
        } else if (s.kind == Seg::Line && std::fabs(s.r1 - s.r0) > kEps && s.z1 - s.z0 > kEps && s.z1 - s.z0 < kEdge && std::fabs(s.r1 - s.r0) < kEdge) {
            soft[i] = 2;  // rotura de arista (ISO 13715): ni se acota ni cuenta como punto de cota
            lab[i] = "~";
            nEdge++;
        } else if (s.kind == Seg::Line && (s.r0 < 0.025 || s.r1 < 0.025) && std::fabs(s.r1 - s.r0) > 0.05 && s.z1 - s.z0 > kEps) {
            soft[i] = 1;  // cono que acaba en punta (punta de broca): se acota su ángulo incluido
            lab[i] = fnum(std::round(2 * std::atan(std::fabs(s.r1 - s.r0) / (s.z1 - s.z0)) * 1800 / M_PI) / 10) + "°";
        } else if (s.kind == Seg::Arc) {
            int e0, e1, a = neighbour(p, i, 0, e0), b = neighbour(p, i, 1, e1);
            bool cap = near(s.r0, 0) || near(s.r1, 0);
            bool tang0 = a >= 0 && tangentJoin(s, 0, p.segs[a], e0), tang1 = b >= 0 && tangentJoin(s, 1, p.segs[b], e1);
            if (cap) { soft[i] = 1; lab[i] = "SR" + fmt(s.rad); }               // casquete esférico
            else if (tang0 && tang1) { soft[i] = 1; lab[i] = "R" + fmt(s.rad); }  // acuerdo
            else { soft[i] = 0; lab[i] = "R" + fmt(s.rad); }
        }
    }

    // ---- puntos de cota longitudinal (desde z=0), sin extremos de rasgos blandos
    std::vector<double> zs;
    auto addZ = [&](double z) {
        if (z < kMinFeat) return;  // pegado a la referencia z=0
        for (double q : zs) if (std::fabs(q - z) < kMinFeat) return;  // detalle < 0,1 mm: ni el taller ni la cota lo distinguen
        zs.push_back(z);
    };
    for (int i = 0; i < n; i++) {
        const Seg& s = p.segs[i];
        if (soft[i]) {
            if (s.kind == Seg::Arc && (near(s.r0, 0) || near(s.r1, 0))) addZ(s.z1 > s.z0 ? s.z1 : s.z0);
            else if (s.kind == Seg::Line && lab[i] != "~" && lab[i].find("×") == std::string::npos) addZ(s.r0 > s.r1 ? s.z0 : s.z1);  // punta cónica: profundidad hasta la base del cono
            continue;
        }
        addZ(s.z0); addZ(s.z1);
    }
    // el extremo blando que cae sobre un plano ya cuenta por el plano; el que cae en cilindro, no
    zs.erase(std::remove_if(zs.begin(), zs.end(), [&](double q) { return std::fabs(q - L) < kMinFeat; }), zs.end());
    addZ(L);
    // un extremo de segmento duro que solo toca segmentos blandos tangentes (p. ej. cilindro que empalma con acuerdo) no es cota
    std::vector<double> keep;
    for (double z : zs) {
        bool hard = near(z, L);
        for (int i = 0; i < n && !hard; i++) {
            const Seg& s = p.segs[i];
            if (s.kind == Seg::Plane && near(s.z0, z)) hard = true;
            if (soft[i] && s.kind == Seg::Line && lab[i] != "~" && lab[i].find("×") == std::string::npos && near(s.r0 > s.r1 ? s.z0 : s.z1, z)) hard = true;  // base de punta cónica
        }
        for (int i = 0; i < n && !hard; i++) {
            const Seg& s = p.segs[i];
            if (soft[i] || s.kind == Seg::Plane) continue;
            for (int e = 0; e < 2 && !hard; e++) {
                Pt q = endPt(s, e);
                if (!near(q.z, z)) continue;
                int eo, j = neighbour(p, i, e, eo);
                if (j < 0 && s.inner) continue;  // extremo suelto de un taladro sin plano ni vecino: no es un vértice medible
                if (j < 0 || !soft[j]) hard = true;  // junta dura con otro segmento duro
                else if (!tangentJoin(s, e, p.segs[j], eo) && p.segs[j].kind == Seg::Line) hard = false;
            }
        }
        if (hard) keep.push_back(z);
    }
    bool polyPre = p.cuts.size() >= 3;  // prisma regular: su arranque es el chaflán del hexágono, no una cota
    for (auto& c : p.cuts) polyPre &= !c.slot && near(c.h, p.cuts[0].h) && near(c.z0, p.cuts[0].z0) && near(c.z1, p.cuts[0].z1);
    for (auto& c : p.cuts) { if (polyPre) break; bool dup = false; for (double q : keep) dup |= near(q, c.z0); if (!dup && c.z0 > kEps) keep.push_back(c.z0); }
    for (auto& h : p.rholes) { bool dup = false; for (double q : keep) dup |= near(q, h.z); if (!dup && h.z > kEps) keep.push_back(h.z); }
    if (polyPre) {  // chaflanes y arandela del prisma regular: sus extremos (sin cara plana) no se acotan; quedan los escalones y la longitud total
        const double b = p.cuts[0].z1;
        double zEnd = L;
        for (auto& sg : p.segs) if (sg.kind == Seg::Plane && sg.z0 >= b - kEps && sg.z0 < zEnd) zEnd = sg.z0;
        auto plane = [&](double z) { for (auto& sg : p.segs) if (sg.kind == Seg::Plane && near(sg.z0, z)) return true; return false; };
        auto nearPlane = [&](double z) { if (z < 0.7 || z > L - 0.7) return true; for (auto& sg : p.segs) if (sg.kind == Seg::Plane && std::fabs(sg.z0 - z) < 0.7) return true; return false; };
        auto bound = [&](double z) { return (near(z, p.cuts[0].z0) || near(z, p.cuts[0].z1)) && !nearPlane(z); };  // arranque/fin del prisma lejos de cualquier escalón: es un hombro real
        keep.erase(std::remove_if(keep.begin(), keep.end(), [&](double z) { return z > kEps && z < L - kEps && z <= zEnd + kEps && !plane(z) && !bound(z); }), keep.end());
    }
    zs = keep;
    if (win) zs.erase(std::remove_if(zs.begin(), zs.end(), [&](double z) { return z > o.wz0 + kEps && z < o.wz1 - kEps; }), zs.end());
    std::sort(zs.begin(), zs.end());

    // gargantas: dos cotas consecutivas con un cilindro entre ellas más pequeño que ambos lados -> cota de ancho
    struct LenDim { double z0, z1; };
    std::vector<LenDim> widths, base;
    std::vector<char> consumed(zs.size(), 0);
    auto outerRAt = [&](double z) {  // radio exterior de un cilindro que cubre z
        double r = -1;
        for (auto& s : p.segs)
            if (s.kind == Seg::Line && !s.inner && near(s.r0, s.r1) && s.z0 - kEps <= z && z <= s.z1 + kEps) r = std::max(r, s.r0);
        return r;
    };
    for (size_t i = 0; i + 1 < zs.size(); i++) {
        double za = zs[i], zb = zs[i + 1], zm = 0.5 * (za + zb);
        double rm = -1;
        for (auto& s : p.segs)
            if (s.kind == Seg::Line && !s.inner && near(s.r0, s.r1) && s.z0 - kEps <= za && s.z1 + kEps >= zb) rm = s.r0;
        double rl = outerRAt(za - 1e-3), rr = outerRAt(zb + 1e-3);
        if (rm > 0 && rl > rm + kEps && rr > rm + kEps && !consumed[i] && za > kEps) {
            widths.push_back({za, zb});
            consumed[i + 1] = 1;
        }
        (void)zm;
    }
    // taladro ciego que abre por la cara derecha: su profundidad se acota desde la boca (z=L), no desde la referencia
    bool openR = false, openL = false;
    for (auto& s : p.segs) if (s.inner && s.kind != Seg::Plane) { openR |= near(s.z1, L); openL |= near(s.z0, 0); }
    auto innerOwned = [&](double z) {
        bool in = false;
        for (auto& s : p.segs) {
            if (s.kind == Seg::Plane || !(near(s.z0, z) || near(s.z1, z))) continue;
            if (!s.inner) return false;
            in = true;
        }
        return in;
    };
    for (size_t i = 0; i < zs.size(); i++)
        if (!consumed[i]) {
            if (openR && !openL && !near(zs[i], L) && innerOwned(zs[i])) base.push_back({zs[i], L});
            else base.push_back({0, zs[i]});
        }

    auto withTol = [&](const std::string& base, const std::string& key, double nominal = -1, bool dia = false) {
        auto it = meta.tols.find(key);
        if (it != meta.tols.end() && !it->second.empty()) {   // «+0.02/-0.01» del usuario: también apilada
            return stackTol(base, it->second, decSep);
        }
        for (auto& q : p.pmi)  // tolerancia declarada en el PMI del STEP (no se infiere nunca)
            if (nominal > 0 && q.diameter == dia && !q.radius && std::fabs(q.value - nominal) < 1e-3) {
                if (std::fabs(q.upper - q.lower) < 1e-9) return base + " ±" + fmt(q.upper);
                return base + kStk + devTxt(q.upper) + kStk + devTxt(q.lower);
            }
        return base;
    };
    // rosca: solo si el usuario la escribe en la cota (M12x1.75, G1/2, Tr20x4...); nunca se deduce de la geometría
    auto threadOf = [&](const std::string& key, double& pitch) {
        auto it = meta.tols.find(key);
        pitch = 0;
        if (it == meta.tols.end()) return std::string();
        std::string v = it->second;
        auto dig = [&](size_t i) { return i < v.size() && std::isdigit((unsigned char)v[i]); };
        bool th = (v.size() > 1 && v[0] == 'M' && dig(1)) || (v.size() > 1 && v[0] == 'G' && dig(1)) || (v.rfind("Tr", 0) == 0 && dig(2)) ||
                  (v.rfind("Rp", 0) == 0 && dig(2)) || (v.rfind("Rc", 0) == 0 && dig(2)) || v.rfind("NPT", 0) == 0 || v.rfind("UN", 0) == 0;
        if (!th) return std::string();
        size_t x = v.find_first_of("xX");
        if (x == std::string::npos) { size_t u = v.find("×"); if (u != std::string::npos) { pitch = std::atof(v.c_str() + u + 2); std::string r = v; r.replace(u, 2, "×"); return r; } return v; }
        if (v[0] == 'M') { std::string pv = v.substr(x + 1); for (auto& ch : pv) if (ch == ',') ch = '.'; pitch = std::atof(pv.c_str()); }
        std::string r = v; r.replace(x, 1, "×");
        return r;
    };
    // ---- taladros axiales no coaxiales: vista lateral desde el extremo libre + notas
    struct HG { std::vector<HoleStage> st; std::vector<V2> pos; char tag; };
    std::vector<HG> groups;
    std::vector<std::string> notes;
    double evR = 0;
    bool fromRef = false;  // vista desde la cara de referencia (z=0) si allí abren más taladros
    {
        int nL = 0, n0 = 0;
        for (auto& st : p.sites) for (auto& h : st.st) { nL += h.z1 > L - kEps; n0 += h.z0 < kEps; }
        fromRef = n0 > nL;
    }
    const bool fromRefPre = fromRef;
    if (!p.sites.empty()) {
        // orientar: el primer taladro descentrado queda arriba (la orientación STEP es arbitraria)
        double phi = 0;
        for (auto& st : p.sites) if (std::hypot(st.x, st.y) > 1e-3) { phi = M_PI / 2 - std::atan2(st.y, st.x); break; }
        for (auto& st : p.sites) {
            V2 q{st.x * std::cos(phi) - st.y * std::sin(phi), st.x * std::sin(phi) + st.y * std::cos(phi)};
            auto stg = st.st;
            std::sort(stg.begin(), stg.end(), [](const HoleStage& a, const HoleStage& b) { return a.r != b.r ? a.r > b.r : a.z0 < b.z0; });
            for (size_t k = 1; k < stg.size();) {   // tramos del mismo Ø partidos en caras (rosca modelada, costuras): un solo tramo
                if (near(stg[k].r, stg[k - 1].r) && stg[k].z0 <= stg[k - 1].z1 + 0.5) { stg[k - 1].z1 = std::max(stg[k - 1].z1, stg[k].z1); stg[k - 1].blind = stg[k - 1].blind && stg[k].blind; stg.erase(stg.begin() + k); }
                else k++;
            }
            HG* g = nullptr;
            for (auto& h : groups) {
                if (h.st.size() != stg.size()) continue;
                bool same = true;
                for (size_t k = 0; k < stg.size(); k++) same &= near(h.st[k].r, stg[k].r) && near(h.st[k].z0, stg[k].z0) && near(h.st[k].z1, stg[k].z1);
                if (same) g = &h;
            }
            if (!g) { groups.push_back({stg, {}, (char)('A' + groups.size() % 26)}); g = &groups.back(); }
            if (fromRefPre) q.x = -q.x;
            g->pos.push_back(q);
        }
        for (auto& g : groups) {
            std::string t = std::string(1, g.tag) + ": " + (g.pos.size() > 1 ? std::to_string(g.pos.size()) + "× " : "");
            for (size_t k = 0; k < g.st.size(); k++) {
                const HoleStage& h = g.st[k];
                bool thru = !h.blind;
                if (k) t += "; ";
                t += "Ø" + fmt(2 * h.r) + (thru ? " " + T("pasante") : " " + (std::string("↧") + (fmt(h.z1 - h.z0))));
                d.dims.push_back({"hole", 2 * h.r, "Ø" + fmt(2 * h.r)});
            }
            double dist0 = std::hypot(g.pos[0].x, g.pos[0].y);
            bool circ = g.pos.size() >= 3 && dist0 > 1e-3;
            std::vector<double> ang;
            for (auto& q : g.pos) { circ &= near(std::hypot(q.x, q.y), dist0); ang.push_back(std::atan2(q.y, q.x)); }
            if (circ) {
                std::sort(ang.begin(), ang.end());
                double gap = 2 * M_PI / ang.size();
                for (size_t k = 0; k < ang.size(); k++) circ &= std::fabs(std::fmod(ang[(k + 1) % ang.size()] - ang[k] + 4 * M_PI, 2 * M_PI) - gap) < 0.01 || ang.size() == 1;
            }
            if (circ) { t += " " + Tf("equidistantes en Ø{0}", {fmt(2 * dist0)}); d.dims.push_back({"pcd", 2 * dist0, "Ø" + fmt(2 * dist0)}); }
            notes.push_back(t);
            if (!circ) {
                std::string ps = "   " + T("posición (x; y) desde el eje:");
                for (auto& q : g.pos) {
                    std::string one = " (" + fmt(q.x) + "; " + fmt(q.y) + ")";
                    if (textW(ps + one, kTxt) > 90) { notes.push_back(ps); ps = "   "; }
                    ps += one;
                    d.dims.push_back({"position", std::hypot(q.x, q.y), fmt(q.x) + ";" + fmt(q.y)});
                }
                notes.push_back(ps);
            }
        }
    }
    bool polyPrism = p.cuts.size() >= 3;  // prisma regular exterior (cabeza hexagonal, cuadrado)
    for (auto& c : p.cuts) polyPrism &= !c.slot && near(c.h, p.cuts[0].h) && near(c.z0, p.cuts[0].z0) && near(c.z1, p.cuts[0].z1);
    {
        const double a1 = !p.cuts.empty() ? p.cuts[0].ang : !p.rholes.empty() ? p.rholes[0].ang : 0;
        const std::string ref1 = !p.cuts.empty() ? "C1" : "H1";
        auto deg = [&](double a) { return std::fmod(a - a1 + 4 * M_PI, 2 * M_PI) * 180 / M_PI; };
        auto aligned = [&](double a) { double x = std::fmod(deg(a), 90); return x < 0.05 || 90 - x < 0.05; };
        if (p.threadExtD > 0) notes.push_back(Tf("rosca helicoidal exterior de Ø{0} (cresta) no modelada: acotar según su norma de rosca", {fmt(p.threadExtD)}));
        if (p.thread) notes.push_back(T("rosca helicoidal interior no modelada: acotar según su norma de rosca"));
        if (polyPrism) notes.push_back(Tf("prisma de {0} caras, {1} entre caras, longitud {2}", {std::to_string(p.cuts.size()), fmt(2 * p.cuts[0].h), fmt(p.cuts[0].z1 - p.cuts[0].z0)}));
        for (size_t i = 0; i < p.cuts.size() && !polyPrism; i++) {
            const Cut& c = p.cuts[i];
            double zm = 0.5 * (c.z0 + c.z1), R = outerRAt(zm);
            if (R < 0) R = rmax;
            std::string t = "C" + std::to_string(i + 1) + ": ";
            if (c.slot) t += Tf("chavetero/ranura, ancho {0}, {1} desde la cara opuesta", {fmt(c.w), fmt((c.rin > 0 ? c.rin : R) + c.h)});
            else t += Tf("plano a {0} del eje", {fmt(c.h)});
            t += ", " + Tf("longitud {0}", {fmt(c.z1 - c.z0)});
            if (i && !aligned(c.ang)) t += ", " + Tf("a {0}° de {1}", {fnum(deg(c.ang)), "C1"});
            notes.push_back(t);
        }
        for (size_t i = 0; i < p.rholes.size(); i++) {
            const RadHole& h = p.rholes[i];
            std::string t = "H" + std::to_string(htag[i]) + ": Ø" + fmt(2 * h.r) + " " + Tf("radial {0}, a {1} de la referencia", {h.through ? T("pasante") : (std::string("↧") + (fmt(h.depth))), fmt(h.z)});
            if ((i || !p.cuts.empty()) && !aligned(h.ang)) t += ", " + Tf("a {0}° de {1}", {fnum(deg(h.ang)), ref1});
            notes.push_back(t);
            d.dims.push_back({"hole", 2 * h.r, "Ø" + fmt(2 * h.r)});
        }
        for (auto& n : p.extraNotes) notes.push_back(n);
        for (auto& hx : p.hexes) notes.push_back(Tf("Hueco hexagonal {0} entre caras, prof. {1}", {fmt(hx.af), fmt(hx.z1 - hx.z0)}));
    }
    bool hasLeaders = false;
    for (int i = 0; i < n; i++) hasLeaders |= soft[i] == 1;
    // pieza achatada (arandela, disco): se añade la vista desde el extremo (círculos), como en los planos de arandelas; llena la hoja y aclara el contorno
    const bool discView = !o.detail && !o.det && !polyPrism && p.cuts.empty() && p.sites.empty() && p.rholes.empty() && p.hexes.empty() && L < 0.5 * 2 * rmax;
    const bool hasEnd = !p.sites.empty() || discView;
    const bool hasCuts = !p.cuts.empty(), hasFeat = hasCuts || !p.rholes.empty();
    const int nViews = (hasEnd ? 1 : 0) + (hasCuts ? 1 : 0);
    const double topRes = hasLeaders && hasFeat ? 28 : (hasLeaders || hasFeat) ? 16 : 6;
    const double dimW = hasCuts ? 34 : 0;
    // notas a la izquierda del cajetín (hueco de 87 mm en A4) si caben: no restan alto a las vistas
    bool notesBeside = !o.detail && notes.size() <= 7 && p.unsupported.empty() && d.warnings.empty();
    for (auto& nt : notes) notesBeside &= textW(nt, kTxt) <= 80;
    const double extraS = 4.5 * notes.size() + 3;  // modo franja: notas abajo a la izquierda, bajo las cotas
    const double extraY = notesBeside ? 0 : std::max(0.0, 4.5 * (notes.size() + p.unsupported.size() + d.warnings.size() + 1) + 3 - 9);

    // ---- hoja y escala
    // cotas desde la referencia: con 5 o más se pasa a cotas por coordenadas (ISO 129-1), una sola fila en vez de una pila
    struct Ord { double z; std::string t, shown; };
    std::vector<Ord> ords;
    int nStack = 0;
    for (auto& b : base) {
        if (near(b.z0, 0) && b.z1 > kEps) { std::string t = fmt(b.z1); ords.push_back({b.z1, t, withTol(t, fmtK(b.z1), b.z1)}); }
        else nStack++;
    }
    const bool useOrd = ords.size() >= 5;
    double ordStep = 0;
    for (auto& q : ords) ordStep = std::max(ordStep, textW(q.shown, kTxt) + 3);
    // nivel de cada cota por coordenadas: las que quedan a menos de 4,6 mm de la anterior bajan un escalón (texto a la izquierda de su línea)
    auto ordLevels = [&](double sc, std::vector<int>& lv) {
        lv.assign(ords.size() + 1, 0);  // [0] = origen
        int mx = 0;
        double prev = 0;
        for (size_t i = 0; i < ords.size(); i++) {
            lv[i + 1] = (sc * (ords[i].z - prev) < 4.6) ? lv[i] + 1 : 0;
            mx = std::max(mx, lv[i + 1]);
            prev = ords[i].z;
        }
        return mx + 1;
    };
    std::sort(ords.begin(), ords.end(), [](const Ord& a, const Ord& b) { return a.z < b.z; });
    // anchos (cotas entre dos aristas cercanas): cada una baja un nivel si su texto/flechas chocan con una anterior
    auto wLevels = [&](double sc, std::vector<int>& lv) {
        lv.assign(widths.size(), 0);
        std::vector<std::vector<std::pair<double, double>>> occ;
        int mx = 0;
        for (size_t i = 0; i < widths.size(); i++) {
            const double a = sc * widths[i].z0, b = sc * widths[i].z1, tw = textW(fmt(widths[i].z1 - widths[i].z0), kTxt) + 2;
            const bool fits = b - a >= tw + 6;
            const double lo = fits ? a : a - 5, hi = fits ? b : b + 5 + tw;
            int l = 0;
            for (;; l++) {
                if (l >= (int)occ.size()) occ.emplace_back();
                bool hit = false;
                for (auto& iv : occ[l]) if (lo < iv.second + 1 && hi > iv.first - 1) hit = true;
                if (!hit) break;
            }
            occ[l].push_back({lo, hi});
            lv[i] = l;
            mx = std::max(mx, l + 1);
        }
        return mx;
    };
    auto lenBlockH = [&](double sc) {
        std::vector<int> lv, wl;
        return (nStack + wLevels(sc, wl)) * 7 + (useOrd ? ordLevels(sc, lv) * ordStep + 4 : (int)ords.size() * 7);
    };
    const double titleH = o.detail ? 0 : 42, margL = o.detail ? 0 : 20, margO = o.detail ? 0 : 10;
    double reserveH = 0, reserveW = 0;  // detalle: encima de la vista principal o a su derecha
    double chosenS = 0;
    const Sheet* sh = &kSheets[0];
    bool forced = false, stripMode = false;
    for (auto& c : kSheets) forced |= meta.sheet == c.name;
    for (auto& cand : kSheets) {
        if (forced && meta.sheet != cand.name) continue;  // formato elegido por el usuario: solo ese
        double bestS = 0, bestH = 0, bestW = 0;
        bool bestStrip = false;
        for (int mode = 0; mode < (o.det ? 2 : 1); mode++) {
            const double rh = o.det && mode == 0 ? o.detH + 12 : 0, rw = o.det && mode == 1 ? o.detW + 12 : 0;
            double zw = cand.w - margL - margO - 30 - rw, zhB = cand.h - 2 * margO - titleH - topRes - 12 - extraY - rh;
            if (o.det && mode == 0 && o.detW > zw) continue;
            if (o.det && mode == 1 && o.detH + 20 > cand.h - 2 * margO - titleH - topRes - extraY) continue;
            double sBest = 0;
            for (double s : kScales) {
                if (o.det && s > 1) continue;  // con detalle la vista principal no se amplía
                if (s < o.minS) break;
                const double zh = zhB - lenBlockH(s);
                bool ok = s * L <= zw + (s > 1 ? 12 : 0) && s * 2 * rmax <= zh;   // holgura: 2:1 que se pasa por poco de la reserva de cotas
                if (ok && nViews) ok = s * L + 15 + 2 * rmax * s + dimW <= zw && nViews * (2 * rmax * s + 30) <= zh + 24;
                bool okS = false;  // vista principal en la franja izquierda a toda la altura (el cajetín solo ocupa la mitad derecha)
                if (!ok && notesBeside && !o.det) {
                    const double bx0 = cand.w - margO - std::min(180.0, cand.w - margL - margO), stripW = bx0 - 5 - (margL + 15);
                    const double zhS = cand.h - 2 * margO - topRes - 12 - extraS - lenBlockH(s);
                    okS = s * L + 25 <= stripW && s * 2 * rmax <= zhS;
                    if (okS && nViews) okS = nViews * (2 * rmax * s + 30) - 26 <= cand.h - 2 * margO - titleH - topRes && cand.w - margO - 15 - dimW - 2 * s * rmax >= bx0 + 3;
                }
                if (ok || okS) { sBest = s; bestStrip = !ok; break; }
            }
            if (sBest > bestS) { bestS = sBest; bestH = rh; bestW = rw; stripMode = bestStrip; }
        }
        sh = &cand;
        chosenS = bestS; reserveH = bestH; reserveW = bestW;
        if (bestS >= std::max(1.0, o.minS) || &cand == &kSheets[4] || forced) break;
    }
    const double keepS = chosenS;  // escala normalizada ya hallada pero ridícula (las notas se comen el alto): se busca una libre mayor
    if (forced && chosenS < 0.25 && !o.detail && o.minS == 0) {
        chosenS = 0;  // no cabe a escala normalizada: mayor escala libre que quepa
        const double zw = sh->w - margL - margO - 30 - reserveW, zhB = sh->h - 2 * margO - titleH - topRes - 12 - extraY - reserveH;
        for (int pass = 0; pass < 3 && chosenS == 0; pass++)  // pase 1: sin reservar sitio para cotas y notas; pase 2: ni vistas auxiliares (el plano quedará denso)
            for (double s = 0.5; s > std::max(0.005, keepS); s *= 0.97) {
                const double zh = zhB + (pass == 2 ? extraY : 0) - (pass ? 0 : lenBlockH(s));
                bool ok = s * L <= zw && s * 2 * rmax <= zh;
                if (ok && nViews && pass < 2) ok = s * L + 15 + 2 * rmax * s + dimW <= zw && nViews * (2 * rmax * s + 30) <= zh + 24;
                if (ok && (s >= 0.25 || pass == 2)) {
                    chosenS = s;
                    d.warnings.push_back(T(pass ? "El formato elegido es pequeño para esta pieza: el plano queda denso; elige un formato mayor o Automático." : "La pieza no cabe en el formato elegido a escala normalizada; se usa una escala no normalizada."));
                    break;
                }
            }
    }
    if (forced && chosenS == 0 && keepS > 0) chosenS = keepS;
    if (o.detail) { chosenS = o.ds; sh = &kSheets[0]; }
    else if (chosenS == 0) { chosenS = 0.01; d.warnings.push_back(T("La pieza no cabe en A0 a la escala mínima normalizada.")); }
    d.sheetW = sh->w; d.sheetH = sh->h; d.sheetName = sh->name; d.scale = chosenS;
    if (o.detail) {
        d.sheetW = chosenS * L + 30 + 50;
        d.sheetH = topRes + 2 * rmax * chosenS + lenBlockH(chosenS) + 12 + extraY + 14 + 4 + 10;
    }
    const double s = chosenS;

    // marco ISO 5457: margen izquierdo 20 (archivo), resto 10
    double fx0 = margL, fy0 = margO, fx1 = d.sheetW - margO, fy1 = d.sheetH - margO;
    if (!o.detail) { line(d, fx0, fy0, fx1, fy0, kThick); line(d, fx1, fy0, fx1, fy1, kThick); line(d, fx1, fy1, fx0, fy1, kThick); line(d, fx0, fy1, fx0, fy0, kThick); }

    // zona de vista
    double zoneX0 = fx0 + 15, zoneX1 = fx1 - 15 - reserveW;
    double zoneY0 = fy0 + titleH + lenBlockH(chosenS) + 14 + extraY, zoneY1 = fy1 - topRes - 4 - reserveH;
    double colW = nViews ? 15 + 2 * rmax * s + dimW : 0;
    double cx = 0.5 * (zoneX0 + zoneX1 - colW) - 0.5 * s * L, cy = 0.5 * (zoneY0 + zoneY1);
    if (nViews && !stripMode && s * L < 40) cx = zoneX1 - colW - s * L - 12 - dimW;   // vista principal corta: pegada a la columna de vistas; balanceViews centra el conjunto
    if (stripMode) {  // vista principal centrada en la franja izquierda (sobre las notas), a toda la altura
        const double bx0 = fx1 - std::min(180.0, fx1 - fx0);
        cx = 0.5 * (zoneX0 + bx0 - 5) - 0.5 * s * L;
        cy = 0.5 * (fy0 + lenBlockH(chosenS) + 14 + extraS + zoneY1);
    }
    auto X = [&](double z) { return cx + s * z; };
    auto Y = [&](double r) { return cy + s * r; };

    d.groups = {T("Vista"), T("Vista lateral"), T("Detalle")};
    const Pos pView = d.pos();
    // ---- contorno (ambas mitades)
    for (int i = 0; i < n; i++) {
        const Seg& g = p.segs[i];
        for (double sg : {1.0, -1.0}) {
            if (g.kind == Seg::Arc) {
                double a0, a1;
                arcAngles(g, sg, a0, a1);
                d.arcs.push_back({X(g.cz), Y(sg * g.cr), s * g.rad, a0, a1, LineType::Continuous, kThick});
            } else {
                line(d, X(g.z0), Y(sg * g.r0), X(g.z1), Y(sg * g.r1), g.brk ? kThin : kThick);
            }
        }
    }
    // uniones visibles entre superficies (círculo visto de canto) en vista exterior; en sección el contorno basta
    if (!anyInner) {
        for (int i = 0; i < n; i++) {
            const Seg& g = p.segs[i];
            if (g.kind == Seg::Plane) continue;
            for (int e = 0; e < 2; e++) {
                int eo, j = neighbour(p, i, e, eo);
                if (j < 0 || j < i || p.segs[j].kind == Seg::Plane) continue;
                Pt q = endPt(g, e);
                if (q.r < kEps || tangentJoin(g, e, p.segs[j], eo)) continue;
                line(d, X(q.z), Y(q.r), X(q.z), Y(-q.r), kThick);
            }
        }
    }
    // rayado en sección
    if (anyInner) {
        double hyP = 0;
        if (polyPrism) { const size_t n = p.cuts.size(); const double Rv = p.cuts[0].h / std::cos(M_PI / n); for (size_t k = 0; k < n; k++) hyP = std::max(hyP, std::fabs(Rv * std::sin(M_PI + M_PI / n + 2 * M_PI * k / n))); }
        std::vector<std::pair<Pt, Pt>> sockW;
        auto loops = materialLoops(p, hyP, &sockW);
        for (auto& w : sockW) for (double sg : {1.0, -1.0}) line(d, X(w.first.z), Y(sg * w.first.r), X(w.second.z), Y(sg * w.second.r), kThick);
        if (loops.empty()) d.warnings.push_back(T("Perfil abierto: no se pudo rayar la sección."));
        for (auto& lp : loops)
            for (double sg : {1.0, -1.0}) {
                std::vector<V2> poly;
                for (auto& q : lp) poly.push_back({X(q.z), Y(sg * q.r)});
                if (p.rootR > kEps) {   // dentado: en la sección axial los dientes no se rayan (el rayado llega al pie)
                    const double xa = X(p.rootZ0), xb = X(p.rootZ1), y0 = Y(0), rr = s * p.rootR;
                    hatch(d, clipPoly(poly, [&](V2 q) { return sg * (q.y - y0) - rr; }), 3.0);
                    hatch(d, clipPoly(poly, [&](V2 q) { return q.x - xa; }), 3.0);
                    hatch(d, clipPoly(poly, [&](V2 q) { return xb - q.x; }), 3.0);
                } else hatch(d, poly, 3.0);
            }
    }
    if (p.rootR > kEps && anyInner) for (double sg : {1.0, -1.0}) line(d, X(p.rootZ0), Y(sg * p.rootR), X(p.rootZ1), Y(sg * p.rootR), 0.25);   // pie del dentado en la sección (fino)
    // taladros axiales: líneas ocultas en la vista lateral
    for (auto& g : groups)
        for (auto& q : g.pos)
            for (auto& h : g.st)
                if (!anyInner)
                for (double sg : {1.0, -1.0}) line(d, X(h.z0), Y(q.y + sg * h.r), X(h.z1), Y(q.y + sg * h.r), 0.25, LineType::Hidden);
    // línea de eje (sobresale 3 mm de cada extremo)
    line(d, X(0) - 4, cy, X(L) + 4, cy, 0.18, LineType::Center);

    // ---- diámetros: una cota por radio distinto y lado (exterior/interior)
    struct DD { double r; bool inner; double zm; };
    std::vector<DD> done;
    std::vector<double> usedX;
    int outN = 0;
    auto addDia = [&](double r, bool inner, double za, double zb) {
        if (r < 0.025) return;
        for (auto& q : done) if (q.inner == inner && near(q.r, r)) return;
        double zm = 0.5 * (za + zb);
        std::string t = "Ø" + fmt(2 * r), tk = "Ø" + fmtK(2 * r);
        done.push_back({r, inner, zm});
        double x = X(zm);
        for (auto& h : p.rholes) {  // la cota no debe cruzar un taladro radial
            double hx = X(h.z), hr = X(h.z + h.r) - hx + 2.5;
            if (std::fabs(x - hx) < hr) {
                double xa = X(std::min(za, zb)), xb = X(std::max(za, zb));
                x = hx - hr - 1 >= xa ? hx - hr - 1 : hx + hr + 1 <= xb ? hx + hr + 1 : x;
            }
        }
        {  // dos cotas de Ø no deben solaparse en x (rótulo vertical de ~4 mm)
            double xa = X(std::min(za, zb)) + 2.5, xb = X(std::max(za, zb)) - 2.5, x0 = x;
            auto free = [&](double c) { for (double u : usedX) if (std::fabs(c - u) < 6) return false; return true; };
            for (int k = 1; !free(x) && k <= 8; k++)
                for (double c : {x0 + 6.5 * k, x0 - 6.5 * k}) if (c >= xa && c <= xb && free(c)) { x = c; break; }
            if (!free(x)) {  // sin hueco dentro de la pieza: cota exterior con líneas de referencia
                x = X(L) + 8 + 7 * outN++;
                double xe = X(std::max(za, zb));
                line(d, xe + 1, Y(r), x + 2, Y(r), 0.18); line(d, xe + 1, Y(-r), x + 2, Y(-r), 0.18);
            }
            usedX.push_back(x);
        }
        if (Y(r) - Y(-r) < 7) {   // cota corta (ISO 129-1 5.4): flechas por fuera apuntando hacia dentro, con tramo de línea a cada lado
            line(d, x, Y(r) + 6, x, Y(-r) - 6);
            arrow(d, x, Y(r), 0, 1); arrow(d, x, Y(-r), 0, -1);
        } else {
            line(d, x, Y(r), x, Y(-r));
            arrow(d, x, Y(r), 0, -1); arrow(d, x, Y(-r), 0, 1);
        }
        std::string shown = withTol(t, tk, 2 * r, true);
        double pitch;
        std::string th = threadOf(tk, pitch);
        if (!th.empty()) {
            shown = th;
            if (pitch > 0 && !inner)  // ISO 6410: línea fina al diámetro menor a lo largo de la rosca
                for (double sg : {1.0, -1.0}) line(d, X(za), Y(sg * (r - 0.6134 * pitch)), X(zb), Y(sg * (r - 0.6134 * pitch)), 0.18);
            else if (inner && th[0] == 'M') {  // rosca interior: el contorno es el Ø de núcleo; la línea fina va al nominal que escribe el usuario
                double rn = 0.5 * std::atof(th.c_str() + 1);
                if (rn > r + 0.05 && rn < 2 * r + 1)
                    for (double sg : {1.0, -1.0}) line(d, X(za), Y(sg * rn), X(zb), Y(sg * rn), 0.18);
            }
        }
        double tw = textW(shown, kTxt);
        mask(d, x - 1.9, cy, kTxt + 1, tw + 2);
        text(d, x - 0.6, cy - tw / 2, kTxt, shown, 90);
        d.dims.push_back({"diameter", 2 * r, t, tk});
    };
    for (int i = 0; i < n; i++) {
        const Seg& g = p.segs[i];
        if (g.kind == Seg::Plane || g.kind == Seg::Arc) continue;
        if (soft[i]) continue;
        if (polyPrism && !g.inner && g.z0 >= p.cuts[0].z0 - 0.7 && g.z1 <= p.cuts[0].z1 + 0.7) continue;  // chaflán/arandela del prisma: su Ø no se fabrica por separado
        if (g.inner && !p.hexes.empty() && std::fabs(2 * std::max(g.r0, g.r1) - 2 * p.hexes[0].af / std::sqrt(3.0)) < 1e-3) continue;  // pared del hueco hexagonal: se acota «entre caras»

        if (g.kind != Seg::Plane && inWin(g.z0, g.z1)) continue;
        if (near(g.r0, g.r1)) addDia(g.r0, g.inner, g.z0, g.z1);
        else {  // cono: diámetros de los extremos que no estén ya acotados por el vecino
            for (int e = 0; e < 2; e++) {
                Pt q = endPt(g, e);
                int eo, j = neighbour(p, i, e, eo);
                bool covered = j >= 0 && p.segs[j].kind == Seg::Line && near(p.segs[j].r0, p.segs[j].r1) && near(p.segs[j].r0, q.r);
                if (!covered) addDia(q.r, g.inner, q.z, q.z + (e ? -1 : 1) * 0.5 * (g.z1 - g.z0));
            }
        }
    }
    // diámetro de arcos duros / extremos de acuerdos que no estén acotados: no se añaden (se leen del contorno + radio)

    // ---- chaflanes y radios con directriz sobre el contorno superior
    int leaderIdx = 0;
    struct LBox { double x0, y0, x1, y1; };
    std::vector<std::array<double, 4>> leaderSegs;
    auto segBox = [](double ax, double ay, double bx, double by, const LBox& b) {  // ¿corta el segmento la caja? (Liang–Barsky)
        double t0 = 0, t1 = 1, dx = bx - ax, dy = by - ay;
        double pp[4] = {-dx, dx, -dy, dy}, qq[4] = {ax - b.x0, b.x1 - ax, ay - b.y0, b.y1 - ay};
        for (int i = 0; i < 4; i++) {
            if (std::fabs(pp[i]) < 1e-12) { if (qq[i] < 0) return false; continue; }
            double r = qq[i] / pp[i];
            if (pp[i] < 0) { if (r > t1) return false; t0 = std::max(t0, r); } else { if (r < t0) return false; t1 = std::min(t1, r); }
        }
        return t0 <= t1;
    };
    std::vector<LBox> leaderBoxes;  // rótulos de directriz ya colocados (evita solapes)
    // coloca el rótulo en la primera posición libre (filas y desplazamiento horizontal); false si no hay hueco
    auto placeLeader = [&](double px, double py, const std::string& label) {
        double tw = textW(label, kTxt) + 1, xmax = d.sheetW - 10 - 5;
        for (int k = 0; k < 24; k++) {
            double tx = px + 6 + 3 * (k / 2), ty = Y(rmax) + 5 + ((leaderIdx + k) % 2) * 6;
            if (tx + tw > xmax) break;
            LBox b{tx - 0.5, ty - 0.5, tx + tw + 0.5, ty + kTxt + 1.5};
            bool free = true;
            for (auto& o : leaderBoxes) free &= !(b.x0 < o.x1 && o.x0 < b.x1 && b.y0 < o.y1 && o.y0 < b.y1);
            for (auto& o : leaderBoxes) free &= !segBox(px, py, tx, ty, o);       // la directriz nueva no cruza rótulos ya puestos
            for (auto& q : leaderSegs) free &= !segBox(q[0], q[1], q[2], q[3], b);  // ni las anteriores cruzan este rótulo
            if (!free) continue;
            leaderBoxes.push_back(b);
            leaderSegs.push_back({px, py, tx, ty});
            leaderIdx++;
            line(d, px, py, tx, ty);
            line(d, tx, ty, tx + tw, ty);
            arrow(d, px, py, tx - px, ty - py);
            text(d, tx + 0.5, ty + 0.8, kTxt, label);
            return true;
        }
        return false;
    };
    std::map<std::string, int> labCount, labDrawn;
    for (int i = 0; i < n; i++) if (soft[i] == 1) labCount[lab[i]]++;
    for (int i = 0; i < n; i++) {
        if (soft[i] != 1) continue;
        const Seg& g = p.segs[i];
        if (inWin(g.z0, g.z1)) continue;
        double zm = g.kind == Seg::Arc ? g.mz : 0.5 * (g.z0 + g.z1), rm = g.kind == Seg::Arc ? g.mr : 0.5 * (g.r0 + g.r1);
        double px = X(zm), py = Y(rm);
        int cnt = labCount[lab[i]];
        if (cnt > 3) {  // rasgo repetido: una sola directriz con el nº de repeticiones
            if (!labDrawn[lab[i]]++) placeLeader(px, py, std::to_string(cnt) + "× " + lab[i]);
        } else placeLeader(px, py, lab[i]);
        double v = g.kind == Seg::Arc ? g.rad : g.z1 - g.z0;
        if (g.kind != Seg::Arc && lab[i].find("×") == std::string::npos) v = std::round(2 * std::atan(std::fabs(g.r1 - g.r0) / (g.z1 - g.z0)) * 1800 / M_PI) / 10;
        d.dims.push_back({g.kind == Seg::Arc ? "radius" : lab[i].find("×") == std::string::npos ? "angle" : "chamfer", v, lab[i]});
    }

    if (nEdge) d.warnings.push_back(Tf("{0} roturas de arista menores de 0,3 mm sin acotar (ISO 13715)", {std::to_string(nEdge)}));

    // garganta en V (dos conos exteriores que se encuentran en el fondo): ángulo incluido; no en roscas modeladas (muchos conos)
    int nCones = 0;
    for (int i = 0; i < n; i++) nCones += p.segs[i].kind == Seg::Line && !near(p.segs[i].r0, p.segs[i].r1) && !soft[i];
    for (int i = 0; i < n && nCones <= 6; i++)
        for (int j = i + 1; j < n; j++) {
            const Seg &a = p.segs[i], &b = p.segs[j];
            if (a.kind != Seg::Line || b.kind != Seg::Line || a.inner || b.inner || soft[i] || soft[j] || near(a.r0, a.r1) || near(b.r0, b.r1)) continue;
            for (int ea = 0; ea < 2; ea++)
                for (int eb = 0; eb < 2; eb++) {
                    Pt qa = endPt(a, ea), qb = endPt(b, eb), oa = endPt(a, 1 - ea), ob = endPt(b, 1 - eb);
                    if (!near(qa.z, qb.z) || !near(qa.r, qb.r) || oa.r <= qa.r + kEps || ob.r <= qb.r + kEps) continue;
                    double ha = std::atan(std::fabs(oa.z - qa.z) / (oa.r - qa.r)), hb = std::atan(std::fabs(ob.z - qb.z) / (ob.r - qb.r));
                    std::string t = fnum(std::round((ha + hb) * 1800 / M_PI) / 10) + "°";
                    if (win && qa.z > o.wz0 + kEps && qa.z < o.wz1 - kEps) continue;
                    placeLeader(X(qa.z), Y(qa.r), t);
                    d.dims.push_back({"angle", std::round((ha + hb) * 1800 / M_PI) / 10, t});
                }
        }

    // ---- cotas longitudinales (anchos de garganta en el nivel 0; bases en niveles siguientes)
    auto zExt = [&](double z) {  // extremo inferior visible de la silueta en z
        double r = 0;
        for (auto& g : p.segs) {
            if (g.inner) continue;
            double a = g.z0, b = g.z1;
            if (g.kind == Seg::Plane) { if (near(a, z)) r = std::max(r, std::max(g.r0, g.r1)); continue; }
            if (a - kEps <= z && z <= b + kEps) {
                double rr = g.kind == Seg::Arc ? (near(z, a) ? g.r0 : near(z, b) ? g.r1 : std::max(g.r0, g.r1)) : (g.r0 + (g.r1 - g.r0) * (b > a ? (z - a) / (b - a) : 0));
                r = std::max(r, rr);
            }
        }
        return r;
    };
    std::vector<double> extX;  // posiciones x de todas las líneas de referencia de las cotas longitudinales
    for (auto& w : widths) { extX.push_back(X(w.z0)); extX.push_back(X(w.z1)); }
    for (auto& b : base) { extX.push_back(X(b.z0)); extX.push_back(X(b.z1)); }
    std::vector<int> wlv;
    const int nWd = wLevels(s, wlv);
    const double ordBlock = useOrd ? [&] { std::vector<int> lv; return ordLevels(s, lv) * ordStep + 4; }() : 0.0;
    auto lenDim = [&](double za, double zb, int level) {
        double yd = Y(-rmax) - 8 - level * 7 - (useOrd && level >= nWd ? ordBlock : 0);
        double xa = X(za), xb = X(zb);
        for (double z : {za, zb}) {
            double ye = Y(-zExt(z)) - 1;
            line(d, X(z), ye, X(z), yd - 2);
        }
        line(d, xa, yd, xb, yd);
        std::string t = fmt(zb - za);
        bool inside = (xb - xa) >= 2 * 3.0 + 2;
        if (inside) { arrow(d, xa, yd, 1, 0); arrow(d, xb, yd, -1, 0); }
        else { arrow(d, xa, yd, -1, 0); arrow(d, xb, yd, 1, 0); line(d, xa - 4, yd, xa, yd); line(d, xb, yd, xb + 4, yd); }
        std::string shown = withTol(t, fmtK(zb - za), zb - za);
        double tw = textW(shown, kTxt);
        // el valor va centrado; si no cabe o lo cruza una línea de referencia, fuera de las flechas en el primer hueco sin líneas
        auto clear = [&](double tx) { for (double u : extX) if (u > tx - 0.4 && u < tx + tw + 0.4) return false; return true; };
        double tx = 0.5 * (xa + xb) - tw / 2;
        if (!(tw + 1 <= xb - xa && clear(tx))) {
            double cand[] = {xb + 4.5, xa - 4.5 - tw, xb + 8.5, xa - 8.5 - tw};
            for (double c : cand) if (clear(c)) { tx = c; break; }
            if (!clear(tx)) tx = xb + 4.5;
        }
        text(d, tx, yd + 1, kTxt, shown);
        d.dims.push_back({"length", zb - za, t, fmtK(zb - za)});
    };
    int lvl = 0;
    if (!widths.empty()) { for (size_t i = 0; i < widths.size(); i++) lenDim(widths[i].z0, widths[i].z1, wlv[i]); lvl = nWd; }
    if (useOrd) {
        std::vector<int> lv;
        ordLevels(s, lv);
        const double yTop = Y(-rmax) - 8 - nWd * 7;
        auto one = [&](double z, int k, const std::string& shown) {
            double yEnd = yTop - (k + 1) * ordStep + 2;
            line(d, X(z), Y(-zExt(z)) - 1, X(z), yEnd);
            text(d, X(z) - 0.6, yEnd, kTxt, shown, 90);
        };
        one(0, lv[0], "0");
        for (size_t i = 0; i < ords.size(); i++) {
            one(ords[i].z, lv[i + 1], ords[i].shown);
            d.dims.push_back({"length", ords[i].z, ords[i].t, fmtK(ords[i].z)});
        }
    }
    for (auto& b : base) { if (useOrd && near(b.z0, 0) && b.z1 > kEps) continue; lenDim(b.z0, b.z1, lvl++); }
    // las posiciones de garganta (z0 de cada ancho) también se cotan desde la referencia
    // (ya están en 'base' porque solo se consumió el segundo extremo)

    // ---- rasgos radiales en alzado: el primer rasgo mira al observador (a la izquierda de la vista lateral)
    const double a1f = hasCuts ? p.cuts[0].ang : !p.rholes.empty() ? p.rholes[0].ang : 0;
    const double phiF = M_PI - a1f;
    auto beta = [&](double a) { return a + phiF; };
    const double colX = zoneX1 - dimW - s * rmax;  // centro de las vistas de la columna derecha
    double colY = zoneY1 - s * rmax - 4;
    std::vector<size_t> hTags;  // índices en d.texts de las etiquetas H1, H2…: se desplazan si tocan otra cota
    for (size_t i = 0; i < p.rholes.size(); i++) {
        const RadHole& h = p.rholes[i];
        double b = beta(h.ang), cb = std::cos(b), sb = std::sin(b);
        double hx = X(h.z), rr = s * h.r;
        if (std::fabs(sb) < 0.02) {
            if (cb < 0) {
                d.arcs.push_back({hx, cy, rr, 0, 360, LineType::Continuous, kThick});
                line(d, hx - rr - 2, cy, hx + rr + 2, cy, 0.18, LineType::Center);
                line(d, hx, cy - rr - 2, hx, cy + rr + 2, 0.18, LineType::Center);
            } else {
                d.arcs.push_back({hx, cy, rr, 0, 360, LineType::Hidden, kThin});
            }
            if (htag[i] == (int)i + 1) { hTags.push_back(d.texts.size()); text(d, hx + rr + 1, cy + rr + 1, kTxt, "H" + std::to_string(i + 1)); }
        } else if (std::fabs(cb) < 0.02) {
            double sg = sb > 0 ? 1 : -1, R = outerRAt(h.z);
            if (R < 0) R = rmax;
            double yb = h.through ? Y(-sg * R) : Y(sg * (R - h.depth));
            for (double q : {-1.0, 1.0}) line(d, hx + q * rr, Y(sg * R), hx + q * rr, yb, kThin, LineType::Hidden);
            if (htag[i] == (int)i + 1) { hTags.push_back(d.texts.size()); text(d, hx + rr + 1, Y(sg * R) + sg * 2, kTxt, "H" + std::to_string(i + 1)); }
        }
    }
    // prisma regular exterior (cabeza hexagonal, cuadrado): sus aristas son contorno visible; la silueta llega a la mayor proyección de los vértices
    if (polyPrism) {
        const size_t n = p.cuts.size();
        const double Rv = p.cuts[0].h / std::cos(M_PI / n), x0 = X(p.cuts[0].z0), x1 = X(p.cuts[0].z1);
        double hy = 0;
        std::vector<double> ys;
        for (size_t k = 0; k < n; k++) {
            double y = Rv * std::sin(beta(p.cuts[0].ang) + M_PI / n + 2 * M_PI * k / n);
            ys.push_back(y); hy = std::max(hy, std::fabs(y));
        }
        for (double y : ys) {
            bool dup = false;
            for (double o : ys) if (&o < &y && std::fabs(o - y) < 1e-3) dup = true;
            if (!dup) line(d, x0, Y(y), x1, Y(y), std::fabs(std::fabs(y) - hy) < 1e-3 ? kThick : kThin);
        }
        line(d, x0, Y(-hy), x0, Y(hy), kThick); line(d, x1, Y(-hy), x1, Y(hy), kThick);
        for (int e = 0; e < 2; e++) {  // resalte entre el cilindro y el prisma: la cara anular del cuerpo de revolución
            const double zc = e ? p.cuts[0].z1 : p.cuts[0].z0;
            double Ra = 0;
            for (auto& g : p.segs) if (!g.inner && g.kind == Seg::Line && near(e ? g.z0 : g.z1, zc)) Ra = std::max(Ra, e ? g.r0 : g.r1);
            if (Ra > hy + kEps) for (double sg : {1.0, -1.0}) line(d, X(zc), Y(sg * hy), X(zc), Y(sg * Ra), kThick);
        }
    }
    if (!polyPrism && hasCuts) {  // una cara extrema cortada por un plano o ranura ya no es de revolución: falta su línea de contorno
        for (double zc : {0.0, p.length}) {
            bool cutHere = false, planeSeg = false;
            for (auto& c : p.cuts) cutHere |= near(zc, 0.0) ? near(c.z0, 0.0) : near(c.z1, p.length);
            for (auto& g : p.segs) planeSeg |= !g.inner && g.kind == Seg::Plane && near(g.z0, zc);
            const double Re = outerRAt(zc + (zc < 0.5 * p.length ? 1e-3 : -1e-3));
            if (cutHere && !planeSeg && Re > 0) line(d, X(zc), Y(-Re), X(zc), Y(Re), kThick);
        }
    }
    for (size_t i = 0; i < p.cuts.size(); i++) {
        const Cut& c = p.cuts[i];
        double b = beta(c.ang), cb = std::cos(b), sb = std::sin(b);
        double x0 = X(c.z0), x1 = X(c.z1);
        if (polyPrism) {}
        else if (c.slot && cb < -0.98) {
            line(d, x0, Y(c.w / 2), x1, Y(c.w / 2), kThin); line(d, x0, Y(-c.w / 2), x1, Y(-c.w / 2), kThin);
            line(d, x0, Y(-c.w / 2), x0, Y(c.w / 2), kThin); line(d, x1, Y(-c.w / 2), x1, Y(c.w / 2), kThin);
            text(d, x0 + 1, Y(c.w / 2) + 1, kTxt, "C" + std::to_string(i + 1));
        } else if (std::fabs(sb) > 0.98) {
            double sg = sb > 0 ? 1 : -1, yf = Y(sg * c.h);
            line(d, x0, yf, x1, yf, kThin);
            text(d, x0 + 1, yf + sg * 1.5 - (sg < 0 ? 3 : 0), kTxt, "C" + std::to_string(i + 1));
        } else if (cb > 0.98) {
            double R = outerRAt(0.5 * (c.z0 + c.z1)); if (R < 0) R = rmax;
            double hw = c.slot ? c.w / 2 : std::sqrt(std::max(0.0, R * R - c.h * c.h));
            line(d, x0, Y(hw), x1, Y(hw), kThin, LineType::Hidden); line(d, x0, Y(-hw), x1, Y(-hw), kThin, LineType::Hidden);
        } else if (cb < -0.98) {
            double R = outerRAt(0.5 * (c.z0 + c.z1)); if (R < 0) R = rmax;
            double hw = std::sqrt(std::max(0.0, R * R - c.h * c.h));
            line(d, x0, Y(hw), x1, Y(hw), kThin); line(d, x0, Y(-hw), x1, Y(-hw), kThin);
            if (!c.slot) {  // el plano termina en una arista: línea fina entre sus bordes (donde no hay cara extrema)
                if (c.z0 > kEps) line(d, x0, Y(-hw), x0, Y(hw), kThin);
                if (c.z1 < p.length - kEps) line(d, x1, Y(-hw), x1, Y(hw), kThin);
            }
        }
        if (c.z1 - c.z0 < kMinFeat || polyPrism) break;  // rasgo de longitud nula (o prisma: su longitud ya está en la cadena de cotas): no hay cota que dar
        // cota de longitud del rasgo, sobre la vista
        double yd = Y(rmax) + 8;
        line(d, x0, Y(rmax) + 1, x0, yd + 2); line(d, x1, Y(rmax) + 1, x1, yd + 2); line(d, x0, yd, x1, yd);
        std::string t = fmt(c.z1 - c.z0);
        arrow(d, x0, yd, 1, 0); arrow(d, x1, yd, -1, 0);
        text(d, 0.5 * (x0 + x1) - textW(t, kTxt) / 2, yd + 1, kTxt, t);
        d.dims.push_back({"length", c.z1 - c.z0, t});
        break;  // una sola cota de longitud por encima; el resto va en las notas
    }
    // vista transversal (corte por la zona media del primer rasgo) con todos los rasgos que coinciden en z
    int viewIdx = 0;
    if (hasCuts) {
        const Cut& c0 = p.cuts[0];
        double zm = 0.5 * (c0.z0 + c0.z1);
        double R = outerRAt(zm); if (R < 0) R = rmax;
        if (polyPrism) R = p.cuts[0].h / std::cos(M_PI / p.cuts.size());  // el prisma regular manda: su circunradio, no el radio de revolución en ese punto
        double ex = colX, ey = colY, r = s * R;
        struct Iv { double a0, a1; };
        std::vector<Iv> ex_, exIn;
        double boreR_ = 0;
        auto P = [&](double th, double u, double v) { return V2{ex + std::cos(th) * u - std::sin(th) * v, ey + std::sin(th) * u + std::cos(th) * v}; };
        auto lineP = [&](double th, double u0, double v0, double u1, double v1) { V2 a = P(th, u0, v0), b = P(th, u1, v1); line(d, a.x, a.y, b.x, b.y, kThick); };
        for (size_t i = 0; i < p.cuts.size(); i++) {
            const Cut& c = p.cuts[i];
            if (!(c.z0 < zm && zm < c.z1)) continue;
            double th = beta(c.ang), hh = s * c.h;
            double halfW = c.slot ? s * c.w / 2 : s * std::sqrt(std::max(0.0, R * R - c.h * c.h));
            const bool inn = c.rin > 0;
            const double rr = inn ? s * c.rin : r;
            double aw = std::asin(std::min(1.0, halfW / rr));
            if (inn) { exIn.push_back({th - aw, th + aw}); boreR_ = rr; } else ex_.push_back({th - aw, th + aw});
            double xe = std::sqrt(std::max(0.0, rr * rr - halfW * halfW));
            if (c.slot) { lineP(th, xe, halfW, hh, halfW); lineP(th, xe, -halfW, hh, -halfW); }
            lineP(th, hh, -halfW, hh, halfW);
            std::string tag = "C" + std::to_string(i + 1);
            V2 tp = inn ? P(th, hh + 2, halfW + 3) : P(th, r + 3, c.slot ? halfW + 4 : 0);
            if (!polyPrism) text(d, tp.x - (std::cos(th) < -0.3 ? textW(tag, kTxt) : 0), tp.y - 1, kTxt, tag);
            double other = -1;  // plano opuesto: cota entre caras
            if (!c.slot) for (auto& o : p.cuts) if (&o != &c && !o.slot && near(o.z0, c.z0) && near(o.z1, c.z1) && std::fabs(std::fabs(std::remainder(o.ang - c.ang, 2 * M_PI)) - M_PI) < 1e-3) other = o.h;
            std::string td = fmt(other >= 0 ? c.h + other : (inn ? c.rin : R) + c.h);
            if (i == 0) {  // cota de profundidad (desde la cara opuesta) y, en chavetero, ancho
                double yd = inn ? ey - 0.5 * rr : ey - r - 7;
                V2 fl = P(th, hh, halfW);
                V2 fo = P(th, -r, 0);
                // cota paralela a la dirección del rasgo si está alineado con un eje; si no, solo nota
                if (std::fabs(std::sin(th)) < 1e-6) {
                    double xa = ex + (other >= 0 ? -std::cos(th) * s * other : std::cos(th) > 0 ? -rr : rr), xb = ex + std::cos(th) * hh;
                    line(d, xa, ey - (other >= 0 ? halfW : inn ? 0 : r), xa, yd - 2); line(d, xb, ey - halfW, xb, yd - 2); line(d, xa, yd, xb, yd);
                    bool lr = xa < xb;
                    arrow(d, xa, yd, lr ? 1 : -1, 0); arrow(d, xb, yd, lr ? -1 : 1, 0);
                    text(d, 0.5 * (xa + xb) - textW(td, kTxt) / 2, yd - kTxt - 1, kTxt, td);
                    d.dims.push_back({c.slot ? "slot_depth" : "flat_across", other >= 0 ? c.h + other : (inn ? c.rin : R) + c.h, td});
                    if (c.slot) {
                        std::string tb = fmt(c.w);
                        double xd = ex + (std::cos(th) > 0 ? (inn ? hh + 6 : r + 7) : (inn ? -hh - 6 : -r - 7));
                        double sgx = std::cos(th) > 0 ? 1 : -1;
                        line(d, ex + sgx * hh, ey + halfW, xd + sgx * 2, ey + halfW); line(d, ex + sgx * hh, ey - halfW, xd + sgx * 2, ey - halfW);
                        line(d, xd, ey - halfW, xd, ey + halfW);
                        arrow(d, xd, ey + halfW, 0, -1); arrow(d, xd, ey - halfW, 0, 1);
                        text(d, sgx > 0 ? xd + 1.5 : xd - textW(tb, kTxt) - 1.5, ey - kTxt / 2, kTxt, tb);
                        d.dims.push_back({"slot_width", c.w, tb});
                    }
                } else d.dims.push_back({c.slot ? "slot_depth" : "flat_across", other >= 0 ? c.h + other : R + c.h, td});
                (void)fl; (void)fo;
            }
        }
        // arcos del contorno entre las muescas
        {
            const double TWO = 2 * M_PI, deg = 180 / M_PI;
            std::vector<std::pair<double, double>> iv;
            for (auto& q : ex_) {
                double a0 = std::fmod(q.a0 + 4 * M_PI, TWO), a1 = a0 + (q.a1 - q.a0);
                if (a1 > TWO) { iv.push_back({a0, TWO}); iv.push_back({0, a1 - TWO}); } else iv.push_back({a0, a1});
            }
            std::sort(iv.begin(), iv.end());
            double cur = 0;
            auto arcTo = [&](double a, double b) { if (b - a > 1e-6) d.arcs.push_back({ex, ey, r, a * deg, b * deg, LineType::Continuous, kThick}); };
            for (auto& q : iv) { arcTo(cur, q.first); cur = std::max(cur, q.second); }
            arcTo(cur, TWO);
        }
        if (boreR_ > 0) {   // agujero con chavetero: circunferencia interrumpida en la ranura
            const double TWO = 2 * M_PI, deg = 180 / M_PI;
            std::vector<std::pair<double, double>> iv;
            for (auto& q : exIn) { double a0 = std::fmod(q.a0 + 4 * M_PI, TWO), a1 = a0 + (q.a1 - q.a0); if (a1 > TWO) { iv.push_back({a0, TWO}); iv.push_back({0, a1 - TWO}); } else iv.push_back({a0, a1}); }
            std::sort(iv.begin(), iv.end());
            double cur = 0;
            auto arcTo = [&](double a, double b) { if (b - a > 1e-6) d.arcs.push_back({ex, ey, boreR_, a * deg, b * deg, LineType::Continuous, kThick}); };
            for (auto& q : iv) { arcTo(cur, q.first); cur = std::max(cur, q.second); }
            arcTo(cur, TWO);
        }
        if (polyPrism) {  // cilindro de revolución contiguo, visto detrás del prisma
            double Ra = 0;
            for (auto& g : p.segs) if (!g.inner && g.kind == Seg::Line && (near(g.z1, p.cuts[0].z0) || near(g.z0, p.cuts[0].z1))) Ra = std::max(Ra, near(g.z1, p.cuts[0].z0) ? g.r1 : g.r0);
            if (Ra > R + kEps) d.arcs.push_back({ex, ey, s * Ra, 0, 360, LineType::Continuous, kThin});
        }
        if (polyPrism) {  // taladro pasante visto desde el extremo
            std::vector<double> bs;
            for (auto& g : p.segs) if (g.inner && g.kind == Seg::Line && g.r0 > kEps && near(g.r0, g.r1)) {
                bool dup = false; for (double q : bs) dup |= near(q, g.r0);
                if (!dup) { bs.push_back(g.r0); d.arcs.push_back({ex, ey, s * g.r0, 0, 360, LineType::Continuous, kThick}); }
            }
        }
        line(d, ex - r - 4, ey, ex + r + 4, ey, 0.18, LineType::Center);
        line(d, ex, ey - r - 4, ex, ey + r + 4, 0.18, LineType::Center);
        std::string vt = T("Vista transversal");
        text(d, ex - textW(vt, 2.2) / 2, ey + r + 5, 2.2, vt);
        viewIdx++;
    }

    d.tag(pView, 0);
    // ---- vista desde el extremo libre
    if (hasEnd) {
        const Pos pEnd = d.pos();
        double ex = colX, ey = colY - viewIdx * (2 * rmax * s + 30);
        auto circle = [&](double r, double w, LineType ty = LineType::Continuous) { d.arcs.push_back({ex, ey, r, 0, 360, ty, w}); };
        circle(s * rmax, kThick);
        std::vector<double> rs;
        for (auto& g : p.segs) if (!g.inner && g.kind == Seg::Line && g.r0 > kEps && near(g.r0, g.r1) && !near(g.r0, rmax)) {
            bool dup = false; for (double q : rs) dup |= near(q, g.r0);
            if (!dup) rs.push_back(g.r0);
        }
        for (double r : rs) circle(s * r, 0.25);
        if (p.rootR > kEps) circle(s * p.rootR, 0.25);   // círculo de pie (fino)
        if (p.faceTeeth > 0) for (int k = 0; k < 2 * p.faceTeeth; k++) {   // dentado frontal: aristas de cresta y de valle (visibles, ISO 128-20)
            const double an = p.faceAng0 + k * 3.14159265358979 / p.faceTeeth, c = std::cos(an), sn = std::sin(an);
            line(d, ex + s * p.faceRi * c, ey + s * p.faceRi * sn, ex + s * rmax * c, ey + s * rmax * sn, k % 2 ? 0.25 : 0.35);
        }
        if (discView) {  // taladro y escalones interiores vistos desde el extremo: el menor, a trazo grueso
            std::vector<double> ri;
            for (auto& g : p.segs) if (g.inner && g.kind == Seg::Line && g.r0 > kEps && near(g.r0, g.r1)) {
                bool dup = false; for (double q : ri) dup |= near(q, g.r0);
                if (!dup) ri.push_back(g.r0);
            }
            std::sort(ri.begin(), ri.end());
            for (size_t k = 0; k < ri.size(); k++) circle(s * ri[k], k == 0 ? kThick : 0.25);
        }
        line(d, ex - s * rmax - 4, ey, ex + s * rmax + 4, ey, 0.18, LineType::Center);
        line(d, ex, ey - s * rmax - 4, ex, ey + s * rmax + 4, 0.18, LineType::Center);
        for (auto& g : groups) {
            double dist = std::hypot(g.pos[0].x, g.pos[0].y);
            bool pcd = dist > 1e-3 && g.pos.size() >= 3;
            if (pcd) { bool eqd = true; for (auto& q : g.pos) eqd &= near(std::hypot(q.x, q.y), dist); if (eqd) circle(s * dist, 0.18, LineType::Center); }
            for (size_t i = 0; i < g.pos.size(); i++) {
                double hx = ex + s * g.pos[i].x, hy = ey + s * g.pos[i].y;
                for (auto& h : g.st) {
                    bool vis = fromRef ? h.z0 < kEps : h.z1 > L - kEps;
                    d.arcs.push_back({hx, hy, s * h.r, 0, 360, vis ? LineType::Continuous : LineType::Hidden, vis ? kThick : 0.25});
                }
                line(d, hx - 3, hy, hx + 3, hy, 0.18, LineType::Center); line(d, hx, hy - 3, hx, hy + 3, 0.18, LineType::Center);
                if (i == 0) text(d, hx + s * g.st[0].r + 1, hy + s * g.st[0].r + 1, kTxt, std::string(1, g.tag));
            }
        }
        std::string vt = fromRef ? T("Vista desde la cara de referencia") : T("Vista desde el extremo libre");
        text(d, ex - textW(vt, 2.2) / 2, ey + s * rmax + 5, 2.2, vt);
        d.tag(pEnd, 1);
    }

    // ---- marcador y vista de detalle (ISO 128-3 4.12): contorno de línea fina continua, letra y escala entre paréntesis en la vista principal y copia ampliada arriba
    if (win && o.det) {
        const Pos pMark = d.pos();
        const double yt = Y(rmax) + 2, yb = Y(-rmax) - 2, xa = X(o.wz0), xb = X(o.wz1);
        line(d, xa, yb, xb, yb, 0.18, LineType::Continuous); line(d, xb, yb, xb, yt, 0.18, LineType::Continuous);
        line(d, xb, yt, xa, yt, 0.18, LineType::Continuous); line(d, xa, yt, xa, yb, 0.18, LineType::Continuous);
        text(d, xa + 1, yt + 1, kTxt, "A");
        d.tag(pMark, 0);
        const Pos pDet = d.pos();
        const Drawing& e = *o.det;
        const double detX = reserveW > 0 ? fx1 - 15 - o.detW : zoneX0 + 0.5 * (zoneX1 - zoneX0 - o.detW), detY = reserveW > 0 ? 0.5 * (zoneY0 + zoneY1) - 0.5 * o.detH : zoneY1 + 8;
        for (auto l : e.lines) { l.x1 += detX; l.x2 += detX; l.y1 += detY; l.y2 += detY; d.lines.push_back(l); }
        for (auto a : e.arcs) { a.cx += detX; a.cy += detY; d.arcs.push_back(a); }
        for (auto t : e.texts) { t.x += detX; t.y += detY; d.texts.push_back(t); }
        for (auto q : e.polys) { for (auto& pt : q.pts) { pt.first += detX; pt.second += detY; } d.polys.push_back(q); }
        d.dims.insert(d.dims.end(), e.dims.begin(), e.dims.end());
        text(d, detX, detY + o.detH + 1, kTxt, "A (" + scaleText(o.ds) + ")  " + T("longitudes desde la sección de corte"));
        d.tag(pDet, 2);
    }

    // etiquetas de taladro: si tocan otra cota, probar posiciones vecinas
    for (size_t ti : hTags) {
        const double x0 = d.texts[ti].x, y0 = d.texts[ti].y;
        for (double r : {0.0, 3.0, 6.0, 9.0})
            for (int k = 0; k < 8 && !textClear(d, ti); k++) {
                const double a = k * M_PI / 4;
                d.texts[ti].x = x0 + r * std::cos(a); d.texts[ti].y = y0 + r * std::sin(a);
                if (r == 0) break;
            }
        if (!textClear(d, ti)) { d.texts[ti].x = x0; d.texts[ti].y = y0; }
    }

    // ---- notas de taladros y rasgos (arriba del cajetín, a la izquierda)
    if (o.detail) return d;

    // ---- rasgos no soportados: visibles
    double ny = fy0 + (notesBeside ? 0 : titleH) + 3;
    if (!polyPrism) {
        size_t nu = 0;
        for (auto& kv : p.unsupported) nu += kv.second;
        if ((p.totArea > 0 && (p.unsupArea > 0.25 * p.totArea || (nu >= 12 && p.unsupArea > 0.08 * p.totArea))) || p.rShape > 1.3 * rmax + 0.5) d.warnings.push_back(T("PIEZA NO TORNEADA: predominan rasgos que no son de revolución; este plano NO es válido para fabricar."));
    }
    for (auto& kv : p.unsupported) {
        if (polyPrism && (kv.first.rfind("cilindro no coaxial", 0) == 0 || kv.first.rfind("superficie", 0) == 0 || kv.first.rfind("plano parcial perpendicular", 0) == 0)) continue;  // redondeo de las aristas del prisma: ya descrito en la nota
        std::string w = T("NO ACOTADO (rasgo no de revolución):") + " " + unsupT(kv.first) + " ×" + std::to_string(kv.second);
        d.warnings.push_back(w);
    }
    for (auto& w : d.warnings) { text(d, fx0 + 3, ny, 3.0, w, 0, true); ny += 4.5; }
    for (auto it = notes.rbegin(); it != notes.rend(); ++it) { text(d, fx0 + 3, ny, kTxt, *it); ny += 4.5; }  // las notas van sobre los avisos (todos ya contados)

    // ---- cajetín ISO 7200 simplificado (abajo a la derecha)
    double bw = std::min(180.0, fx1 - fx0), bx0 = fx1 - bw, by1 = fy0 + 36;
    line(d, bx0, fy0, bx0, by1, kThick); line(d, bx0, by1, fx1, by1, kThick);
    line(d, bx0, fy0 + 24, fx1, fy0 + 24); line(d, bx0, fy0 + 12, fx1, fy0 + 12);
    double split1 = bx0 + bw * 0.62, split2 = bx0 + bw * 0.5, split3 = bx0 + bw * 0.75;
    line(d, split1, fy0 + 24, split1, by1);
    line(d, split2, fy0, split2, fy0 + 24); line(d, split3, fy0, split3, fy0 + 12);
    auto field = [&](double x, double y, const std::string& name, const std::string& v) {
        text(d, x + 1.5, y + 7.8, 2.2, name);
        if (v.empty()) text(d, x + 1.5, y + 2, kTxt, T("NO DEFINIDO"), 0, true); else text(d, x + 1.5, y + 2, kTxt, v);
    };
    field(bx0, fy0 + 24, T("Pieza"), meta.title);
    field(split1, fy0 + 24, T("N.° de plano"), meta.partNo);
    field(bx0, fy0 + 12, T("Material"), meta.material);
    field(split2, fy0 + 12, T("Tolerancia general"), meta.generalTolerance);
    text(d, bx0 + 1.5, fy0 + 7.8 - 12 + 12 - 0.0, 2.2, T("Escala"));
    text(d, bx0 + 1.5, fy0 + 2, kTxt, scaleText(s));
    text(d, split2 + 1.5, fy0 + 7.8, 2.2, T("Formato"));
    text(d, split2 + 1.5, fy0 + 2, kTxt, d.sheetName);
    text(d, split3 + 1.5, fy0 + 7.8 - 12 + 12, 2.2, T("Unidades"));
    text(d, split3 + 1.5, fy0 + 2, kTxt, gLoc.imperial ? "in" : "mm");
    projSymbol(d, fx1 - 25, fy0 + 2.5);
    text(d, bx0 + 1.5, by1 + 1.5, 2.2, "Diedro");
    thirdAngle(d, 0, -1, 1);
    return d;
}

// Recorta el perfil a la ventana [a,b] (extremos en cambios de segmento reales): sin segmentos partidos no hay cotas inventadas.
static Profile clipProfile(const Profile& p, double a, double b) {
    Profile q;
    q.length = b - a;
    q.pmi = p.pmi;
    std::vector<double> ra, rb;  // radios del material en cada borde de corte
    for (auto g : p.segs) {
        if (g.z1 < a - kEps || g.z0 > b + kEps) continue;
        if (g.z0 < a - kEps || g.z1 > b + kEps) {  // cruza el borde: solo un cilindro se puede cortar sin inventar ningún Ø
            if (g.kind != Seg::Line || !near(g.r0, g.r1)) continue;
            g.z0 = std::max(g.z0, a); g.z1 = std::min(g.z1, b);
        }
        if (g.kind == Seg::Plane && (near(g.z0, a) || near(g.z0, b))) continue;
        if (g.kind != Seg::Plane) {
            if (near(g.z0, a)) ra.push_back(g.r0); else if (near(g.z1, a)) ra.push_back(g.r1);
            if (near(g.z1, b)) rb.push_back(g.r1); else if (near(g.z0, b)) rb.push_back(g.r0);
        }
        g.z0 -= a; g.z1 -= a; g.cz -= a; g.mz -= a;
        q.segs.push_back(g);
    }
    for (int e = 0; e < 2; e++) {
        auto& r = e ? rb : ra;
        std::sort(r.begin(), r.end());
        if (r.size() % 2) r.insert(r.begin(), 0.0);
        for (size_t i = 0; i + 1 < r.size(); i += 2) {
            Seg c; c.kind = Seg::Plane; c.brk = true; c.z0 = c.z1 = e ? q.length : 0; c.r0 = r[i]; c.r1 = r[i + 1];
            q.segs.push_back(c);
        }
    }
    return q;
}

static Drawing layoutBase(const Profile& p, const Meta& meta) {
    Drawing d = layoutImpl(p, meta, Opt{});
    if (findOverlaps(d).empty()) return d;
    // zona densa: vista de detalle ampliada de la ventana más pequeña que deja legible vista principal y detalle
    std::vector<double> zs{0, p.length};
    for (auto& g : p.segs) { zs.push_back(g.z0); zs.push_back(g.z1); }
    std::sort(zs.begin(), zs.end());
    zs.erase(std::unique(zs.begin(), zs.end(), [](double a, double b) { return b - a < kEps; }), zs.end());
    struct W { double a, b; };
    std::vector<W> ws;  // ventanas que, quitadas de la vista principal, la dejan sin solapes (de la más estrecha a la más ancha)
    for (double f : {0.05, 0.08, 0.12, 0.17, 0.25, 0.35, 0.5})
        for (size_t i = 0; i + 3 < zs.size(); i++) {
            size_t j = i;
            while (j + 1 < zs.size() && zs[j + 1] - zs[i] <= f * p.length + kEps) j++;
            if (j < i + 3) continue;
            Opt om; om.wz0 = zs[i]; om.wz1 = zs[j];
            if (findOverlaps(layoutImpl(p, meta, om)).empty() && (ws.empty() || ws.back().a != zs[i] || ws.back().b != zs[j])) ws.push_back({zs[i], zs[j]});
        }
    std::stable_sort(ws.begin(), ws.end(), [](const W& x, const W& y) { return x.b - x.a < y.b - y.a; });
    int tries = 0;
    bool found = false;
    Drawing best;
    for (auto& w : ws)
        for (int si = (int)(sizeof(kScales) / sizeof(*kScales)) - 1; si >= 0; si--) {
            const double ds = kScales[si];
            if (ds <= 1.5 * d.scale || ds > 20) continue;
            if (++tries > 250) goto fallback;
            Opt dt; dt.detail = true; dt.ds = ds;
            Drawing e = layoutImpl(clipProfile(p, w.a, w.b), meta, dt);
            if (!findOverlaps(e).empty()) continue;
            Opt om; om.wz0 = w.a; om.wz1 = w.b; om.ds = ds; om.det = &e; om.detW = e.sheetW; om.detH = e.sheetH;
            Drawing m = layoutImpl(p, meta, om);
            if (m.warnings.size() <= d.warnings.size() && findOverlaps(m).empty() && (!found || m.sheetW * m.sheetH < best.sheetW * best.sheetH - 1)) { best = std::move(m); found = true; }
        }
fallback:
    if (found) return best;
    for (double ms : {2.0, 5.0}) {  // sin ventana única: se agranda la escala con una hoja mayor
        if (ms <= d.scale) continue;
        Opt os; os.minS = ms;
        Drawing e = layoutImpl(p, meta, os);
        if (e.scale >= ms && findOverlaps(e).empty()) return e;
    }
    Opt od; od.dense = true;
    return layoutImpl(p, meta, od);
}

Drawing layout(const Profile& p, const Meta& meta) {
    Drawing d = layoutBase(p, meta);
    mergeNearParallel(d);
    return d;
}
}  // namespace diedro
