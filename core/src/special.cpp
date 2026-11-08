// Muelles helicoidales (ISO 2162-1) y levas planas: el motor de torneado/prismático no los dibuja bien.
// Todo se MIDE del sólido (malla fina); lo que el STEP no trae sale «NO DEFINIDO» o lo da el usuario (claves de tolerancias).
#include "special.hpp"
#include "classify.hpp"
#include "notice_paths.hpp"
#include <sys/stat.h>
#include <algorithm>
#include <array>
#include <functional>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <BRepAdaptor_Curve.hxx>
#include <HLRAlgo_Projector.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <gp_Ax2.hxx>
#include <gp_Torus.hxx>
#include <gp_Cylinder.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <GProp_GProps.hxx>
#include <GProp_PrincipalProps.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include "i18n.hpp"
#include "projsym.hpp"
#include "stack.hpp"

namespace diedro {
namespace {
bool fail(int l) { if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "special.cpp:%d\n", l); return false; }
const double kPi = 3.14159265358979323846, kThick = 0.5, kThin = 0.25, kTxt = 3.5;
std::string gL = "es";
std::string T(const char* es) { return tr(es, gL); }
std::string fmt(double v) {
    char b[32]; std::snprintf(b, sizeof b, "%.2f", v);
    std::string s = b;
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
    if (decimalComma(gL)) { auto i = s.find('.'); if (i != std::string::npos) s[i] = ','; }
    return s;
}
std::string fmt1(double v) { char b[32]; std::snprintf(b, sizeof b, "%.1f", v); std::string s = b; if (s.size() > 2 && s.substr(s.size() - 2) == ".0") s.resize(s.size() - 2); if (decimalComma(gL)) { auto i = s.find('.'); if (i != std::string::npos) s[i] = ','; } return s; }

struct V3 { double x, y, z; };
struct Mesh { std::vector<V3> v; std::vector<std::array<int, 3>> t; };

bool readShape(const std::string& path, TopoDS_Shape& S) {
    // una lectura por fichero: muelle, leva, árbol de levas y leva 3D se prueban en cadena sobre el mismo STEP (ruta+tamaño+fecha)
    static std::string kPath; static long long kSize = -1, kTime = -1; static TopoDS_Shape kShape;
    struct stat st; const bool ok = ::stat(path.c_str(), &st) == 0;
    if (ok && !kShape.IsNull() && path == kPath && (long long)st.st_size == kSize && (long long)st.st_mtime == kTime) { S = kShape; return true; }
    STEPControl_Reader rd;
    if (rd.ReadFile(path.c_str()) != IFSelect_RetDone) return false;
    rd.TransferRoots();
    S = rd.OneShape();
    if (S.IsNull()) return false;
    if (ok) { kPath = path; kSize = st.st_size; kTime = st.st_mtime; kShape = S; }
    return true;
}
Mesh meshOf(const TopoDS_Shape& S, double defl) {
    BRepMesh_IncrementalMesh(S, defl, false, 0.2, true);
    Mesh m;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
        if (tri.IsNull()) continue;
        const int b = (int)m.v.size();
        for (int i = 1; i <= tri->NbNodes(); i++) { gp_Pnt q = tri->Node(i).Transformed(loc.Transformation()); m.v.push_back({q.X(), q.Y(), q.Z()}); }
        for (int i = 1; i <= tri->NbTriangles(); i++) { int a, c, e; tri->Triangle(i).Get(a, c, e); m.t.push_back({b + a - 1, b + c - 1, b + e - 1}); }
    }
    return m;
}

// ---------------------------------------------------------------- hoja: marco, cajetín, notas
struct Sheet { const char* name; double w, h; };
const Sheet kSheets[] = {{"A4", 297, 210}, {"A3", 420, 297}, {"A2", 594, 420}, {"A1", 841, 594}, {"A0", 1189, 841}};
const double kScales[] = {50, 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01};  // ISO 5455

void ln(Drawing& d, double x1, double y1, double x2, double y2, double w = kThin, LineType t = LineType::Continuous) { d.lines.push_back({x1, y1, x2, y2, t, w}); }
void arrow(Drawing& d, double x, double y, double dx, double dy) {  // flecha cerrada rellena de 30° (ISO 129-1 5.4.1)
    const double n = std::hypot(dx, dy), L = 3.0, W = 0.8;
    dx /= n; dy /= n;
    Poly p; p.pts = {{x, y}, {x + dx * L - dy * W, y + dy * L + dx * W}, {x + dx * L + dy * W, y + dy * L - dx * W}};
    d.polys.push_back(p);
}
std::string scaleText(double s) { return s >= 1 ? fmt(s) + ":1" : "1:" + fmt(1 / s); }

struct Frame { double fx0, fy0, fx1, fy1, s, zx0, zy0, zx1, zy1; };
// Elige hoja y escala para que quepan las vistas (needW × needH en mm de modelo, más mw × mh mm de hoja para cotas) y dibuja marco, cajetín y notas.
Frame makeSheet(Drawing& d, const Meta& meta, double needW, double needH, double mw, double mh, const std::vector<std::string>& notes, double minS = 1) {
    const double margL = 20, margO = 10, titleH = 42, notesH = notes.size() * 4.5 + 4;
    bool forced = false;
    for (auto& c : kSheets) forced |= meta.sheet == c.name;
    const Sheet* sh = &kSheets[0];
    double s = 0;
    if (minS < 1 && !forced) {   // preferir 1:1 hasta A2 y, si no cabe, 1:2 hasta A2 antes que hojas mayores
        for (double lo : {1.0, 0.5, 0.2, minS}) {
            for (int i = 0; i < 3 && s == 0; i++) {
                const Sheet& c = kSheets[i]; const double zw = c.w - margL - margO - 30, zh = c.h - 2 * margO - titleH - notesH - 12;
                for (double k : kScales) if (k >= lo && k * needW + mw <= zw && k * needH + mh <= zh && k <= 20) { s = k; sh = &c; break; }
            }
            if (s > 0) break;
        }
    }
    const bool pre = s > 0;
    for (auto& c : kSheets) {
        if (pre) break;
        if (forced && meta.sheet != c.name) continue;
        const double zw = c.w - margL - margO - 30, zh = c.h - 2 * margO - titleH - notesH - 12;
        for (double k : kScales) if (k * needW + mw <= zw && k * needH + mh <= zh && k <= 20) { s = k; break; }
        sh = &c;
        if (s >= (minS < 1 ? 1.0 : minS) || forced) break;
    }
    if (s == 0) { s = 0.01; for (double k : kScales) if (k <= 20) { s = k; if (k * needW + mw <= sh->w - 60 && k * needH + mh <= sh->h - 90) break; } }
    d.sheetW = sh->w; d.sheetH = sh->h; d.sheetName = sh->name; d.scale = s;
    Frame f; f.fx0 = margL; f.fy0 = margO; f.fx1 = sh->w - margO; f.fy1 = sh->h - margO; f.s = s;
    ln(d, f.fx0, f.fy0, f.fx1, f.fy0, kThick); ln(d, f.fx1, f.fy0, f.fx1, f.fy1, kThick); ln(d, f.fx1, f.fy1, f.fx0, f.fy1, kThick); ln(d, f.fx0, f.fy1, f.fx0, f.fy0, kThick);
    // cajetín ISO 7200 simplificado
    const double bw = std::min(180.0, f.fx1 - f.fx0), bx0 = f.fx1 - bw, by1 = f.fy0 + 36, fy0 = f.fy0;
    ln(d, bx0, fy0, bx0, by1, kThick); ln(d, bx0, by1, f.fx1, by1, kThick);
    ln(d, bx0, fy0 + 24, f.fx1, fy0 + 24); ln(d, bx0, fy0 + 12, f.fx1, fy0 + 12);
    const double split1 = bx0 + bw * 0.62, split2 = bx0 + bw * 0.5, split3 = bx0 + bw * 0.75;
    ln(d, split1, fy0 + 24, split1, by1); ln(d, split2, fy0, split2, fy0 + 24); ln(d, split3, fy0, split3, fy0 + 12);
    auto field = [&](double x, double y, const std::string& name, const std::string& v) {
        text(d, x + 1.5, y + 7.8, 2.2, name);
        if (v.empty()) text(d, x + 1.5, y + 2, kTxt, T("NO DEFINIDO"), 0, true); else text(d, x + 1.5, y + 2, kTxt, v);
    };
    field(bx0, fy0 + 24, T("Pieza"), meta.title); field(split1, fy0 + 24, T("N.° de plano"), meta.partNo);
    field(bx0, fy0 + 12, T("Material"), meta.material); field(split2, fy0 + 12, T("Tolerancia general"), meta.generalTolerance);
    text(d, bx0 + 1.5, fy0 + 7.8, 2.2, T("Escala")); text(d, bx0 + 1.5, fy0 + 2, kTxt, scaleText(s));
    text(d, split2 + 1.5, fy0 + 7.8, 2.2, T("Formato")); text(d, split2 + 1.5, fy0 + 2, kTxt, d.sheetName);
    text(d, split3 + 1.5, fy0 + 7.8, 2.2, T("Unidades")); text(d, split3 + 1.5, fy0 + 2, kTxt, "mm");
    projSymbol(d, f.fx1 - 25, fy0 + 2.5);
    text(d, bx0 + 1.5, by1 + 1.5, 2.2, "Diedro");
    // notas: a la izquierda del cajetín si caben, si no encima
    double wmax = 0;
    for (auto& n : notes) wmax = std::max(wmax, textW(n, kTxt));
    double ny = fy0 + (wmax > bx0 - f.fx0 - 8 ? titleH : 0) + 3;
    for (auto it = notes.rbegin(); it != notes.rend(); ++it) {
        const bool undef = it->rfind(T("No definidos en el STEP (indicar antes de fabricar)"), 0) == 0;
        text(d, f.fx0 + 3, ny, kTxt, *it, 0, undef); ny += 4.5;
    }
    f.zx0 = f.fx0 + 15 + mw / 2; f.zx1 = f.fx1 - 15 - mw / 2; f.zy0 = ny + 6 + mh / 2; f.zy1 = f.fy1 - 12 - mh / 2;
    return f;
}

// cota lineal horizontal entre xa y xb (hoja); ya/yb: y de los puntos acotados; yd: y de la línea de cota
void dimH(Drawing& d, double xa, double xb, double ya, double yb, double yd, const std::string& txt, const std::string& kind, double val) {
    if (xa > xb) { std::swap(xa, xb); std::swap(ya, yb); }
    const double sg = yd > ya ? 1 : -1;
    ln(d, xa, ya + sg * 1, xa, yd + sg * 2); ln(d, xb, yb + sg * 1, xb, yd + sg * 2);
    const double tw = textW(txt, kTxt);
    if (xb - xa >= tw + 8) { ln(d, xa, yd, xb, yd); arrow(d, xa, yd, 1, 0); arrow(d, xb, yd, -1, 0); text(d, 0.5 * (xa + xb) - tw / 2, yd + 1, kTxt, txt); }
    else { ln(d, xa - 6, yd, xb + 6, yd); arrow(d, xa, yd, -1, 0); arrow(d, xb, yd, 1, 0); text(d, xb + 8, yd - 1.2, kTxt, txt); }
    d.dims.push_back({kind, val, txt});
}
void dimV(Drawing& d, double ya, double yb, double xa, double xb, double xd, const std::string& txt, const std::string& kind, double val) {
    if (ya > yb) { std::swap(ya, yb); std::swap(xa, xb); }
    const double sg = xd > xa ? 1 : -1;
    ln(d, xa + sg * 1, ya, xd + sg * 2, ya); ln(d, xb + sg * 1, yb, xd + sg * 2, yb);
    const double tw = textW(txt, kTxt);
    if (yb - ya >= tw + 8) { ln(d, xd, ya, xd, yb); arrow(d, xd, ya, 0, 1); arrow(d, xd, yb, 0, -1); text(d, xd - 1.2, 0.5 * (ya + yb) - tw / 2, kTxt, txt, 90); }
    else { ln(d, xd, ya - 6, xd, yb + 6); arrow(d, xd, ya, 0, -1); arrow(d, xd, yb, 0, 1); text(d, xd - 1.2, yb + 8, kTxt, txt, 90); }
    d.dims.push_back({kind, val, txt});
}
// cota alineada (paralela al segmento 1-2); off>0 desplaza a la izquierda del sentido 1→2 (ISO 129-1, 7.1)
void dimA(Drawing& d, double x1, double y1, double x2, double y2, double off, const std::string& txt, const std::string& kind, double val) {
    const double L = std::hypot(x2 - x1, y2 - y1); if (L < 1e-6) return;
    const double ux = (x2 - x1) / L, uy = (y2 - y1) / L, nx = -uy, ny = ux, sg = off >= 0 ? 1 : -1;
    const double ax = x1 + nx * off, ay = y1 + ny * off, bx = x2 + nx * off, by = y2 + ny * off;
    ln(d, x1 + nx * sg, y1 + ny * sg, ax + nx * sg * 2, ay + ny * sg * 2); ln(d, x2 + nx * sg, y2 + ny * sg, bx + nx * sg * 2, by + ny * sg * 2);
    const double tw = textW(txt, kTxt); double tx, ty;   // dirección de lectura del texto
    double th = std::atan2(uy, ux) * 57.29578; tx = ux; ty = uy; if (th > 90.001 || th < -89.999) { th += 180; tx = -ux; ty = -uy; }
    const double mx = 0.5 * (ax + bx), my = 0.5 * (ay + by);
    if (L >= tw + 8) { ln(d, ax, ay, bx, by); arrow(d, ax, ay, ux, uy); arrow(d, bx, by, -ux, -uy); text(d, mx - tx * tw / 2 - ty * 1.0, my - ty * tw / 2 + tx * 1.0, kTxt, txt, th); }
    else { ln(d, ax - ux * 6, ay - uy * 6, bx + ux * 6, by + uy * 6); arrow(d, ax, ay, -ux, -uy); arrow(d, bx, by, ux, uy); text(d, bx + ux * 8 - ty * 1.0, by + uy * 8 + tx * 1.0, kTxt, txt, th); }
    d.dims.push_back({kind, val, txt});
}
void centerCross(Drawing& d, double cx, double cy, double r) { ln(d, cx - r, cy, cx + r, cy, 0.18, LineType::Center); ln(d, cx, cy - r, cx, cy + r, 0.18, LineType::Center); }
std::string userKey(const Meta& m, const char* k) { auto it = m.tols.find(k); return it == m.tols.end() ? std::string() : it->second; }
void finish(Drawing& d, const Meta& meta, const std::string& kind) { (void)meta; d.kind = kind; d.label = kind; }
}  // namespace

// ================================================================== MUELLE
namespace {
bool springImpl(const std::string& path, const Meta& meta, Drawing& d, int mode) {   // mode 0: cilíndrico/cónico/tracción; mode 1: torsión (patas rectas fuera del cuerpo)
    gL = meta.lang;
    TopoDS_Shape S;
    if (!readShape(path, S)) return fail(__LINE__);
    int nPlane = 0, nFree = 0, nOther = 0;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        BRepAdaptor_Surface su(TopoDS::Face(ex.Current()));
        const GeomAbs_SurfaceType t = su.GetType();
        if (t == GeomAbs_Plane) nPlane++; else if (t == GeomAbs_Cylinder || t == GeomAbs_Cone || t == GeomAbs_Sphere || t == GeomAbs_Torus) nOther++; else nFree++;
    }
    if (nFree == 0 || nFree > 40 || nPlane > 16 || nOther > 12) return fail(__LINE__);
    Mesh m = meshOf(S, 0.01);
    if (m.v.size() < 200) return fail(__LINE__);
    GProp_GProps g; BRepGProp::VolumeProperties(S, g);
    const gp_Pnt G = g.CentreOfMass();
    const GProp_PrincipalProps pp = g.PrincipalProperties();
    gp_Dir ax[3] = {pp.FirstAxisOfInertia(), pp.SecondAxisOfInertia(), pp.ThirdAxisOfInertia()};
    // eje del muelle: el que deja el hueco central más ancho respecto al diámetro exterior
    int best = -1; double bestScore = 0;
    for (int i = 0; i < 3; i++) {
        const gp_Dir u = ax[i];
        double r0 = 1e18, r1 = 0;
        for (auto& q : m.v) {
            const double x = q.x - G.X(), y = q.y - G.Y(), z = q.z - G.Z(), a = x * u.X() + y * u.Y() + z * u.Z();
            const double r = std::sqrt(std::max(0.0, x * x + y * y + z * z - a * a));
            r0 = std::min(r0, r); r1 = std::max(r1, r);
        }
        if (r1 > 0 && r0 / r1 > bestScore) { bestScore = r0 / r1; best = i; }
    }
    bool hook = false; int weakBi = -1;
    gp_Dir uAx = best >= 0 ? ax[best] : gp_Dir(0, 0, 1);
    if (bestScore < 0.2 || mode == 1) {   // ¿muelle de tracción (ganchos) o de torsión (patas)? los ganchos cruzan el eje: eje de inercia con más vértices a un radio casi constante y vértices cerca del eje solo en los extremos
            double bh = 0; int bi = -1;
            for (int i = 0; i < 3; i++) {
                std::vector<double> rr; rr.reserve(m.v.size());
                for (auto& q : m.v) {
                    const double x = q.x - G.X(), y = q.y - G.Y(), z = q.z - G.Z(), a = x * ax[i].X() + y * ax[i].Y() + z * ax[i].Z();
                    rr.push_back(std::sqrt(std::max(0.0, x * x + y * y + z * z - a * a)));
                }
                std::vector<double> t = rr; std::nth_element(t.begin(), t.begin() + t.size() / 2, t.end());
                const double md = t[t.size() / 2]; size_t c = 0;
                size_t cn = 0;
                for (double r : rr) { if (std::fabs(r - md) < 0.1 * md) c++; if (r < 0.6 * md) cn++; }
                const double sc = (cn >= 0.02 * rr.size() || mode == 1) ? (double)c / rr.size() : 0; if (sc > bh) { bh = sc; bi = i; }
            }
            if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "hook axis score=%g axis=%d (%g %g %g)\n", bh, bi, bi >= 0 ? ax[bi].X() : 0, bi >= 0 ? ax[bi].Y() : 0, bi >= 0 ? ax[bi].Z() : 0);
            if (bi >= 0 && mode == 0 && bh >= 0.35 && bh < 0.45) weakBi = bi;   // gancho dudoso: se decide tras el barrido de ejes
            if (bi >= 0 && bh >= 0.45) { hook = true; uAx = ax[bi]; bestScore = bh;
                if (mode == 1) {   // las patas descentran el eje de inercia: afinar la dirección con la puntuación robusta
                    auto hs = [&](const gp_Dir& u) {
                        std::vector<double> rr; for (size_t i = 0; i < m.v.size(); i += 5) { const auto& q = m.v[i]; const double x = q.x - G.X(), y = q.y - G.Y(), z = q.z - G.Z(), a = x * u.X() + y * u.Y() + z * u.Z(); rr.push_back(std::sqrt(std::max(0.0, x * x + y * y + z * z - a * a))); }
                        std::vector<double> t = rr; std::nth_element(t.begin(), t.begin() + t.size() / 2, t.end()); const double md = t[t.size() / 2]; size_t c = 0;
                        for (double r : rr) if (std::fabs(r - md) < 0.05 * md) c++;
                        return (double)c / rr.size(); };
                    double bs = hs(uAx); gp_Dir bu = uAx;
                    for (double step : {0.1, 0.03, 0.01, 0.003}) for (int it = 0; it < 20; it++) {
                        bool imp = false;
                        for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) {
                            if (!dx && !dy) continue;
                            gp_Dir e1 = std::fabs(bu.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0);
                            e1 = gp_Dir(e1.XYZ() - bu.XYZ() * e1.Dot(bu)); const gp_Dir e2 = bu.Crossed(e1);
                            const gp_Dir uu(bu.XYZ() + e1.XYZ() * (dx * step) + e2.XYZ() * (dy * step));
                            const double sc = hs(uu); if (sc > bs + 1e-12) { bs = sc; bu = uu; imp = true; }
                        }
                        if (!imp) break;
                    }
                    if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "torsion axis refined score=%g (%g %g %g)\n", bs, bu.X(), bu.Y(), bu.Z());
                    uAx = bu;
                }
            }
            }
    if (mode == 1 && !hook) return fail(__LINE__);
    if (bestScore < 0.2 && !hook) {   // ejes de inercia casi degenerados (muelle cónico): barrido de direcciones; el eje deja el mayor r_mín/r_máx
        auto score = [&](const gp_Dir& u, size_t stp) {
            double r0 = 1e18, r1 = 0;
            for (size_t i = 0; i < m.v.size(); i += stp) {
                const auto& q = m.v[i];
                const double x = q.x - G.X(), y = q.y - G.Y(), z = q.z - G.Z(), a = x * u.X() + y * u.Y() + z * u.Z();
                const double r = std::sqrt(std::max(0.0, x * x + y * y + z * z - a * a));
                r0 = std::min(r0, r); r1 = std::max(r1, r);
            }
            return r1 > 0 ? r0 / r1 : 0;
        };
        double bs = 0; gp_Dir bu(0, 0, 1);
        const int NF = 2000;
        for (int i = 0; i < NF; i++) {   // Fibonacci en la semiesfera
            const double zc = (i + 0.5) / NF, ph = i * 2.399963229728653, rr = std::sqrt(1 - zc * zc);
            const gp_Dir u(rr * std::cos(ph), rr * std::sin(ph), zc);
            const double sc = score(u, 7); if (sc > bs) { bs = sc; bu = u; }
        }
        for (double step : {0.05, 0.01, 0.002}) {   // refinamiento local con todos los vértices
            for (int it = 0; it < 12; it++) {
                bool imp = false;
                for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) {
                    if (!dx && !dy) continue;
                    gp_Dir e1 = std::fabs(bu.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0);
                    e1 = gp_Dir(e1.XYZ() - bu.XYZ() * e1.Dot(bu)); const gp_Dir e2 = bu.Crossed(e1);
                    const gp_Dir u(bu.XYZ() + e1.XYZ() * (dx * step) + e2.XYZ() * (dy * step));
                    const double sc = score(u, 1); if (sc > bs + 1e-12) { bs = sc; bu = u; imp = true; }
                }
                if (!imp) break;
            }
        }
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "axis scan score=%g\n", bs);
        if (weakBi >= 0 && bs < 0.45) { hook = true; uAx = ax[weakBi]; bestScore = 0.4; }
        else { if (bs < 0.2) return fail(__LINE__); uAx = bu; bestScore = bs; }
    }
    const gp_Dir u = uAx;
    gp_Dir e1 = std::fabs(u.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0);
    e1 = gp_Dir(e1.XYZ() - u.XYZ() * e1.Dot(u));
    const gp_Dir e2 = u.Crossed(e1);
    std::vector<V3> P;   // (x,y,z) en el sistema del muelle; z = a lo largo del eje
    P.reserve(m.v.size());
    for (auto& q : m.v) {
        const gp_Vec w(q.x - G.X(), q.y - G.Y(), q.z - G.Z());
        P.push_back({w.Dot(e1), w.Dot(e2), w.Dot(u)});
    }
    double xl = 1e18, xh = -1e18, yl = 1e18, yh = -1e18, zl = 1e18, zh = -1e18;
    for (auto& q : P) { xl = std::min(xl, q.x); xh = std::max(xh, q.x); yl = std::min(yl, q.y); yh = std::max(yh, q.y); zl = std::min(zl, q.z); zh = std::max(zh, q.z); }
    // ---- ¿muelle cónico? Se miden los lazos de corte del hilo en el semiplano φ (≈ círculos): Ø del hilo = extensión radial; radio del centro del hilo lineal en z
    struct Loop { double zc, rc, dr; };
    auto loopsAt = [&](double phi) {
        const double c = std::cos(phi), sn = std::sin(phi);
        std::map<unsigned long long, int> id; std::vector<int> par; std::vector<std::array<double, 2>> pt;   // (r, z)
        auto find = [&](int a) { while (par[a] != a) a = par[a] = par[par[a]]; return a; };
        for (auto& t : m.t) {
            int ids[3], n = 0;
            for (int e = 0; e < 3; e++) {
                const int ia = t[e], ib = t[(e + 1) % 3];
                const V3 &va = P[ia], &vb = P[ib];
                const double sa = -va.x * sn + va.y * c, sb = -vb.x * sn + vb.y * c;
                if ((sa > 0) == (sb > 0)) continue;
                const double k = sa / (sa - sb), x = va.x + k * (vb.x - va.x), y = va.y + k * (vb.y - va.y);
                if (x * c + y * sn <= 0) continue;
                const unsigned long long key = ((unsigned long long)std::min(ia, ib) << 32) | (unsigned)std::max(ia, ib);
                auto it = id.find(key); int q;
                if (it == id.end()) { q = (int)pt.size(); id[key] = q; par.push_back(q); pt.push_back({x * c + y * sn, va.z + k * (vb.z - va.z)}); } else q = it->second;
                ids[n++] = q;
            }
            if (n == 2) par[find(ids[0])] = find(ids[1]);
        }
        {   // caras vecinas (p. ej. barridos B-spline) no comparten vértices en la malla: unir puntos de corte coincidentes en el espacio
            std::map<std::pair<long long, long long>, int> at;
            for (size_t i = 0; i < pt.size(); i++) {
                const auto key = std::make_pair((long long)std::llround(pt[i][0] * 2e4), (long long)std::llround(pt[i][1] * 2e4));
                auto it = at.find(key);
                if (it == at.end()) at[key] = (int)i; else par[find((int)i)] = find(it->second);
            }
        }
        std::map<int, std::array<double, 4>> g;   // rmin, rmax, zmin, zmax
        for (size_t i = 0; i < pt.size(); i++) {
            auto& v = g.emplace(find((int)i), std::array<double, 4>{1e18, -1e18, 1e18, -1e18}).first->second;
            v[0] = std::min(v[0], pt[i][0]); v[1] = std::max(v[1], pt[i][0]); v[2] = std::min(v[2], pt[i][1]); v[3] = std::max(v[3], pt[i][1]);
        }
        std::vector<Loop> out;
        for (auto& kv : g) if (kv.second[1] - kv.second[0] > 1e-3) out.push_back({0.5 * (kv.second[2] + kv.second[3]), 0.5 * (kv.second[0] + kv.second[1]), kv.second[1] - kv.second[0]});
        std::sort(out.begin(), out.end(), [](const Loop& a, const Loop& b) { return a.zc < b.zc; });
        return out;
    };
    bool cone = false; double dL = 0, R0c = 0, kc = 0;
    if (!hook) {
        std::vector<Loop> l0 = loopsAt(0), l2 = loopsAt(kPi);
        std::vector<double> drs; for (auto& q : l0) drs.push_back(q.dr); for (auto& q : l2) drs.push_back(q.dr);
        if (drs.size() >= 6) {
            std::sort(drs.begin(), drs.end()); dL = drs[drs.size() / 2];
            auto fit = [&](std::vector<Loop> v, double& a0, double& k0) {
                v.erase(std::remove_if(v.begin(), v.end(), [&](const Loop& q) { return q.dr < 0.8 * dL || q.dr > 1.2 * dL; }), v.end());
                if (v.size() < 3) return false;
                double sz = 0, sr = 0, szz = 0, szr = 0; const double n = (double)v.size();
                for (auto& q : v) { const double z = q.zc - zl; sz += z; sr += q.rc; szz += z * z; szr += z * q.rc; }
                const double den = n * szz - sz * sz; if (std::fabs(den) < 1e-9) return false;
                k0 = (n * szr - sz * sr) / den; a0 = (sr - k0 * sz) / n; return true;
            };
            double a0, k0, a2, k2;
            if (fit(l0, a0, k0) && fit(l2, a2, k2)) {   // la inclinación del eje da pendientes opuestas; la conicidad, iguales
                kc = 0.5 * (k0 + k2); R0c = 0.5 * (a0 + a2);
                cone = std::fabs(kc) * (zh - zl) > 0.35 * dL && k0 * k2 > 0;
            }
        }
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "cone=%d dL=%g R0=%g k=%g\n", (int)cone, dL, R0c, kc);
    }
    if (!cone) {   // afina el eje (los ejes de inercia se tuercen si las espiras no son enteras): minimiza rmax − rmin con inclinación (a,b) y desplazamiento (cx,cy)
        const double zm = 0.5 * (zl + zh);
        const size_t stp = 1;
        std::vector<size_t> sub;   // vértices que miden el eje: todos (con ganchos, solo el 40 % central, donde no hay ganchos)
        for (size_t i = 0; i < P.size(); i++) if (!hook || std::fabs(P[i].z - zm) < 0.2 * (zh - zl)) sub.push_back(i);
        auto rot = [&](const V3& p, const double* k) {   // traslada el eje a (cx,cy) y lo gira a (rotación en Y, luego en X) hasta Z
            const double x = p.x - k[2], y = p.y - k[3], z = p.z - zm, ca = std::cos(k[0]), sa = std::sin(k[0]), cb = std::cos(k[1]), sb = std::sin(k[1]);
            const double x1 = x * ca + z * sa, z1 = -x * sa + z * ca;
            return V3{x1, y * cb - z1 * sb, y * sb + z1 * cb};
        };
        auto cost = [&](const double* k, bool smooth) {
            double r0 = 1e18, r1 = 0, sm = 0, sq = 0;
            for (size_t i : sub) { const V3 w = rot(P[i], k); const double r = std::hypot(w.x, w.y); r0 = std::min(r0, r); r1 = std::max(r1, r); sm += r; sq += r * r; }
            const double n = (double)sub.size();
            return smooth ? sq / n - (sm / n) * (sm / n) : r1 - r0;
        };
        double k[4] = {0, 0, 0.5 * (xl + xh), 0.5 * (yl + yh)};
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "refine sub=%zu/%zu cost0=%g bbox x %g..%g y %g..%g z %g..%g\n", sub.size(), P.size(), cost(k, false), xl, xh, yl, yh, zl, zh);
        for (int pass = 0; pass < 2; pass++) {   // 1.ª pasada: varianza del radio (suave); 2.ª: rmax − rmin (exacto)
            double st[4] = {0.02, 0.02, 0.5, 0.5}, c = cost(k, pass == 0);
            if (pass == 1) { st[0] = st[1] = 0.003; st[2] = st[3] = 0.05; if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "pass0 k=%g %g %g %g c=%g\n", k[0], k[1], k[2], k[3], c); }
            for (int it = 0; it < 600 && st[2] > 1e-7; it++) {
                bool imp = false;
                for (int j = 0; j < 4; j++) for (double sg : {1.0, -1.0}) { double t[4] = {k[0], k[1], k[2], k[3]}; t[j] += sg * st[j]; const double v = cost(t, pass == 0); if (v < c - 1e-14) { c = v; for (int q = 0; q < 4; q++) k[q] = t[q]; imp = true; } }
                if (!imp) for (int j = 0; j < 4; j++) st[j] *= 0.5;
            }
        }
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "axis k=%g %g %g %g cost=%g\n", k[0], k[1], k[2], k[3], cost(k, false));
        for (auto& q : P) { q = rot(q, k); q.z += zm; }
        zh -= zl; zl = 1e18; for (auto& q : P) zl = std::min(zl, q.z);
        zh = 0; for (auto& q : P) { zh = std::max(zh, q.z); }
        for (auto& q : P) q.z -= zl;
        zh -= zl; zl = 0;
    }
    if (cone) { for (auto& q : P) q.z -= zl; zh -= zl; zl = 0; }
    double rmin = 1e18, rmax = 0, zlo = 0, zhi = zh, vh = 0, wy = 0, bodyZ0 = 0, bodyZ1 = zh;
    int nLeg = 0; double legR[2] = {0, 0}, legA[2] = {0, 0};
    if (hook) {   // radios del cuerpo (40 % central); extremos del cuerpo = lazos circulares del hilo; ganchos = lo que sobresale
        for (auto& q : P) if (std::fabs(q.z - 0.5 * zh) < 0.2 * zh) { const double r = std::hypot(q.x, q.y); rmin = std::min(rmin, r); rmax = std::max(rmax, r); }
        const double dwh = rmax - rmin, Rh = 0.5 * (rmax + rmin);
        double a = 1e18, b = -1e18;
        for (int pi8 = 0; pi8 < 8; pi8++) for (auto& q : loopsAt(pi8 * 0.25 * kPi)) if (std::fabs(q.dr - dwh) < 0.25 * dwh && std::fabs(q.rc - Rh) < 0.3 * dwh) { a = std::min(a, q.zc); b = std::max(b, q.zc); }
        if (b - a < 2 * dwh) return fail(__LINE__);
        bodyZ0 = a - 0.5 * dwh; bodyZ1 = b + 0.5 * dwh;
        double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0; size_t nh = 0;
        const double rout = rmax + 0.3 * dwh;
        auto isApp = [&](const V3& q) { return mode == 1 ? std::hypot(q.x, q.y) > rout : (q.z < bodyZ0 - 0.3 * dwh || q.z > bodyZ1 + 0.3 * dwh); };
        for (auto& q : P) if (isApp(q)) { sx += q.x; sy += q.y; sxx += q.x * q.x; syy += q.y * q.y; sxy += q.x * q.y; nh++; }
        if (nh < 20) return fail(__LINE__);
        const double cxx = sxx / nh - sx * sx / (double)nh / nh, cyy = syy / nh - sy * sy / (double)nh / nh, cxy = sxy / nh - sx * sy / (double)nh / nh;
        const double th = 0.5 * std::atan2(2 * cxy, cxx - cyy), ct = std::cos(th), st = std::sin(th);   // eje mayor del gancho → vertical de la vista (x)
        for (auto& q : P) { const double x = q.x * ct + q.y * st, y = -q.x * st + q.y * ct; q.x = x; q.y = y; vh = std::max(vh, 2 * std::fabs(x)); wy = std::max(wy, 2 * std::fabs(y)); }
        if (mode == 1) {   // patas: puntas por grupos de ángulo (hueco mayor entre ángulos de vértices fuera del cuerpo)
            std::vector<std::array<double, 3>> av;   // ángulo, radio, índice
            for (auto& q : P) if (isApp(q)) av.push_back({std::atan2(q.y, q.x), std::hypot(q.x, q.y), 0});
            std::sort(av.begin(), av.end());
            size_t gi = 0; double gmax = -1;
            for (size_t i = 0; i < av.size(); i++) { const double nx = i + 1 < av.size() ? av[i + 1][0] : av[0][0] + 2 * kPi, gp = nx - av[i][0]; if (gp > gmax) { gmax = gp; gi = i; } }
            double bR[2] = {0, 0}, bA[2] = {0, 0};
            int cur = 0;
            for (size_t k = 0; k < av.size(); k++) {   // el grupo 0 empieza tras el hueco mayor; el 1, en el primer salto > 20°
                const size_t i = (gi + 1 + k) % av.size(), pi = (i + av.size() - 1) % av.size();
                if (k > 0) { double dg = av[i][0] - av[pi][0]; if (dg < 0) dg += 2 * kPi; if (dg > 0.35) cur = 1; }
                if (av[i][1] > bR[cur]) { bR[cur] = av[i][1]; bA[cur] = av[i][0]; }
            }
            nLeg = bR[1] > 0 ? 2 : 1; legR[0] = bR[0]; legA[0] = bA[0]; legR[1] = bR[1]; legA[1] = bA[1];
        }
        for (auto& q : P) q.z -= bodyZ0;
        zlo = -bodyZ0; zhi = zh - bodyZ0; bodyZ1 -= bodyZ0; bodyZ0 = 0;
        zl = 0; zh = bodyZ1;
    } else
    for (auto& q : P) { const double r = std::hypot(q.x, q.y); rmin = std::min(rmin, r); rmax = std::max(rmax, r); }
    const double L = zh - zl, dw = cone ? dL : rmax - rmin;
    const double zs0 = 0.5 * dw, ze0 = L - 0.5 * dw;
    auto Rmf = [&](double z) { return cone ? R0c + kc * z : 0.5 * (rmax + rmin); };   // radio del centro del hilo a la altura z
    if (cone) { rmax = std::max(Rmf(zs0), Rmf(ze0)) + 0.5 * dw; rmin = std::min(Rmf(zs0), Rmf(ze0)) - 0.5 * dw; }
    const double De = 2 * rmax, Di = 2 * rmin, Dm = rmax + rmin, Rm = 0.5 * Dm;
    const double Des = cone ? 2 * (std::min(Rmf(zs0), Rmf(ze0)) + 0.5 * dw) : De;   // Ø exterior del extremo menor
    if (dw < 0.05 || L < 2 * dw || (!cone && (Dm < 2 * dw || dw > 0.5 * Dm)) || (cone && rmin < 0.2 * dw)) return fail(__LINE__);
    // cortes con el semiplano φ: círculos del hilo (z de sus centros)
    auto cuts = [&](double phi) {
        const double c = std::cos(phi), s = std::sin(phi);
        std::vector<double> zs;
        for (auto& t : m.t) {
            const V3* q[3] = {&P[t[0]], &P[t[1]], &P[t[2]]};
            for (int e = 0; e < 3; e++) {
                const V3 &a = *q[e], &b = *q[(e + 1) % 3];
                const double sa = -a.x * s + a.y * c, sb = -b.x * s + b.y * c;
                if ((sa > 0) == (sb > 0)) continue;
                const double k = sa / (sa - sb), x = a.x + k * (b.x - a.x), y = a.y + k * (b.y - a.y);
                if (x * c + y * s > 0) zs.push_back(a.z + k * (b.z - a.z));
            }
        }
        std::sort(zs.begin(), zs.end());
        std::vector<double> cl;   // centro de cada grupo de cortes (un círculo de hilo)
        for (size_t i = 0; i < zs.size();) {
            size_t j = i;
            while (j + 1 < zs.size() && zs[j + 1] - zs[j] < 0.25 * dw) j++;
            if (zs[j] - zs[i] > 0.6 * dw) cl.push_back(0.5 * (zs[i] + zs[j]));
            i = j + 1;
        }
        return cl;
    };
    auto coilCuts = [&](double ph) { std::vector<double> o; for (auto& q : loopsAt(ph)) if (std::fabs(q.dr - dw) < 0.25 * dw && std::fabs(q.rc - Rm) < 0.3 * dw && q.zc > 0.3 * dw && q.zc < L - 0.3 * dw) o.push_back(q.zc); return o; };
    std::vector<double> c0 = hook ? coilCuts(0) : cuts(0), c1 = hook ? coilCuts(0.5 * kPi) : cuts(0.5 * kPi), c2 = hook ? coilCuts(kPi) : cuts(kPi);
    if (std::getenv("DIEDRO_DBG")) { for (auto& q : loopsAt(0)) std::fprintf(stderr, "loop z=%.2f r=%.2f dr=%.2f\n", q.zc, q.rc, q.dr); }
    if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "spring L=%g De=%g Di=%g dw=%g c0=%zu c1=%zu\n", L, De, Di, dw, c0.size(), c1.size());
    if (c0.size() < 2 || c1.size() < 2) return fail(__LINE__);
    std::vector<double> df;
    for (size_t i = 1; i < c0.size(); i++) df.push_back(c0[i] - c0[i - 1]);
    std::sort(df.begin(), df.end());
    const double pitch = df[df.size() / 2];
    if (std::getenv("DIEDRO_DBG")) { std::fprintf(stderr, "pitch=%g dw=%g c0:", pitch, dw); for (double z : c0) std::fprintf(stderr, " %.2f", z); std::fprintf(stderr, "\n"); }
    if (pitch < 0.9 * dw) return fail(__LINE__);
    // fase (en vueltas) del hilo en z: lineal a trozos entre cortes consecutivos a 0° (vale con paso variable, p. ej. cónico)
    auto turnAt = [&](double z) {
        size_t k = 0;
        while (k + 2 < c0.size() && z > c0[k + 1]) k++;
        return (double)k + (z - c0[k]) / (c0[k + 1] - c0[k]);
    };
    double shift = 0; int ns = 0;   // fracción de vuelta del corte a 90° tras el de 0°: ~+1/4 hélice derecha, ~−1/4 izquierda
    for (double z1 : c1) { double f = turnAt(z1); f -= std::floor(f); shift += f < 0.5 ? f : f - 1; ns++; }
    shift /= std::max(1, ns);
    const bool lh = shift < 0;
    const bool varPitch = cone;   // cónico: extremos con paso distinto; contar por fase; si no, (L−d)/p
    const double turns = varPitch ? turnAt(L - 0.5 * dw) - turnAt(0.5 * dw) : (L - dw) / pitch;
    if (turns < 1.4) return fail(__LINE__);
    const double turnsQ = std::round(turns * 4) / 4;

    // ---- notas
    gL = meta.lang;
    std::vector<std::string> notes;
    if (hook && mode == 1) {
        notes.push_back(T("Muelle helicoidal de torsión de hilo cilíndrico (vista real; patas dibujadas tal como están)"));
        notes.push_back(T("Ø del hilo") + " d = " + fmt(dw) + "; " + T("Ø exterior") + " De = " + fmt(De) + "; " + T("Ø interior") + " Di = " + fmt(Di) + "; " + T("Ø medio") + " Dm = " + fmt(Dm) + " (" + T("medidos") + ")");
    } else if (hook) {
        notes.push_back(T("Muelle helicoidal de tracción de hilo cilíndrico (vista real; ganchos dibujados tal como están, tipo de gancho sin clasificar)"));
        notes.push_back(T("Ø del hilo") + " d = " + fmt(dw) + "; " + T("Ø exterior") + " De = " + fmt(De) + "; " + T("Ø interior") + " Di = " + fmt(Di) + "; " + T("Ø medio") + " Dm = " + fmt(Dm) + " (" + T("medidos") + ")");
    } else if (cone) {
        notes.push_back(T("Muelle helicoidal cónico de hilo cilíndrico (vista real; sentido de hélice según ISO 2162-1 §4 b)"));
        notes.push_back(T("Ø del hilo") + " d = " + fmt(dw) + "; " + T("Ø exterior mayor") + " De = " + fmt(De) + "; " + T("Ø exterior menor") + " De' = " + fmt(Des) + "; " + T("Ø interior menor") + " Di = " + fmt(Di) + " (" + T("medidos") + ")");
    } else {
    notes.push_back(T("Muelle helicoidal de hilo cilíndrico (vista real; sentido de hélice según ISO 2162-1 §4 b)"));
    notes.push_back(T("Ø del hilo") + " d = " + fmt(dw) + "; " + T("Ø exterior") + " De = " + fmt(De) + "; " + T("Ø interior") + " Di = " + fmt(Di) + "; " + T("Ø medio") + " Dm = " + fmt(Dm) + " (" + T("medidos") + ")");
    }
    if (mode == 1) {
        std::string lg = T("Longitud del cuerpo") + " Lc = " + fmt(L) + "; " + T("paso") + " p = " + fmt(pitch) + "; " + T("espiras totales") + " ≈ " + fmt(turnsQ) + " (" + T("medidas") + ")";
        notes.push_back(lg);
        std::string lp = T("Distancia eje–punta de pata") + ": " + fmt(legR[0]); if (nLeg > 1) lp += " / " + fmt(legR[1]);
        if (nLeg > 1) { double dA = std::fabs(legA[0] - legA[1]) * 180 / kPi; if (dA > 180) dA = 360 - dA; lp += "; " + T("Ángulo entre patas") + " = " + fmt(dA) + "°"; }
        notes.push_back(lp + " (" + T("medidos") + ")");
    } else
    if (hook) notes.push_back(T("Longitud total (con ganchos)") + " Lt = " + fmt(zhi - zlo) + "; " + T("Longitud del cuerpo") + " Lc = " + fmt(L) + "; " + T("paso") + " p = " + fmt(pitch) + "; " + T("espiras totales") + " ≈ " + fmt(turnsQ) + " (" + T("medidas") + ")");
    else notes.push_back(T("Longitud libre") + " L0 = " + fmt(L) + "; " + T("paso") + " p = " + fmt(pitch) + "; " + T("espiras totales") + " ≈ " + fmt(turnsQ) + " (" + T("medidas") + ")");
    notes.push_back(lh ? T("Hélice izquierda") + " (LH)" : T("Hélice derecha (normal, sin indicación)"));
    std::string line, missing;
    const char* want[][2] = {{mode == 1 ? "Tipo de patas" : hook ? "Tipo de ganchos" : "Tipo de extremos (ISO 2162-1, 4 c)", mode == 1 ? "patas" : hook ? "ganchos" : "extremos"}, {"Carga / rigidez", "carga"}, {"Tolerancias del muelle", "tolmuelle"}, {"Tratamiento", "tratamiento"}};
    for (auto& w : want) { const std::string v = userKey(meta, w[1]); if (v.empty()) missing += (missing.empty() ? "" : ", ") + T(w[0]); else line += (line.empty() ? "" : "; ") + T(w[0]) + ": " + v; }
    if (!line.empty()) notes.push_back(line);
    if (!missing.empty()) notes.push_back(T("No definidos en el STEP (indicar antes de fabricar)") + ": " + missing);

    // ---- hoja (primer diedro: vista principal con el eje horizontal; la vista desde la izquierda va a su derecha)
    d = Drawing();
    d.groups = {T("Vista"), T("Vista desde la izquierda")};
    const double sideW = mode == 1 ? std::max(De, wy) : De;
    const Frame f = makeSheet(d, meta, (zhi - zlo) + sideW, std::max(De, vh) + (hook ? 14 : 0), 80, 60, notes);
    const double s = f.s, yc = 0.5 * (f.zy0 + f.zy1);
    const double x0 = f.fx0 + 30 - s * zlo, xe = x0 + s * zhi + 45 + s * 0.5 * De;
    const double dz = 0.5 * dw / std::cos(std::atan2(pitch * 0.5, 2 * Rm));
    const int sgn = lh ? -1 : 1;
    auto phiOf = [&](double z) { return sgn * 2 * kPi * turnAt(z); };
    auto Zx = [&](double z) { return x0 + s * z; };      // eje del muelle → horizontal
    auto Xy = [&](double x) { return yc + s * x; };      // radio → vertical
    auto hookSilhouette = [&](int view) {   // silueta (proyección) de ganchos (zonas z<0 y z>L) o patas (triángulos fuera del cuerpo): contorno de celdas ocupadas
        auto A = [&](const V3& q) { return view == 0 ? q.z : q.x; }; auto B = [&](const V3& q) { return view == 0 ? q.x : q.y; };
        const double rout = rmax + 0.2 * dw;
        std::vector<size_t> ts;
        double a0 = 1e18, a1 = -1e18, b0 = 1e18, b1 = -1e18;
        for (size_t i = 0; i < m.t.size(); i++) {
            const auto& t = m.t[i];
            if (mode == 1) { const V3 c{(P[t[0]].x + P[t[1]].x + P[t[2]].x) / 3, (P[t[0]].y + P[t[1]].y + P[t[2]].y) / 3, 0}; if (std::hypot(c.x, c.y) <= rout) continue; }
            ts.push_back(i);
            for (int e = 0; e < 3; e++) { a0 = std::min(a0, A(P[t[e]])); a1 = std::max(a1, A(P[t[e]])); b0 = std::min(b0, B(P[t[e]])); b1 = std::max(b1, B(P[t[e]])); }
        }
        if (ts.empty()) return;
        const double cs = std::max(0.03, std::max(a1 - a0, b1 - b0) / 1500);
        const int nz = (int)std::ceil((a1 - a0) / cs) + 3, nx = (int)std::ceil((b1 - b0) / cs) + 3;
        std::vector<char> g((size_t)nz * nx, 0);
        auto cz = [&](double z) { return (z - a0) / cs + 1; }; auto cx = [&](double x) { return (x - b0) / cs + 1; };
        for (size_t ti : ts) {
            const auto& t = m.t[ti];
            const V3 *q[3] = {&P[t[0]], &P[t[1]], &P[t[2]]};
            double az = 1e18, bz = -1e18, ax0 = 1e18, bx0v = -1e18;
            for (int e = 0; e < 3; e++) { az = std::min(az, cz(A(*q[e]))); bz = std::max(bz, cz(A(*q[e]))); ax0 = std::min(ax0, cx(B(*q[e]))); bx0v = std::max(bx0v, cx(B(*q[e]))); }
            for (int iz = std::max(0, (int)az); iz <= std::min(nz - 1, (int)bz); iz++) for (int ix = std::max(0, (int)ax0); ix <= std::min(nx - 1, (int)bx0v); ix++) {
                const double pz = iz + 0.5, px = ix + 0.5; bool in = true, any = false; double sgn0 = 0;
                for (int e = 0; e < 3; e++) {
                    const V3 &a = *q[e], &b = *q[(e + 1) % 3];
                    const double e1z = cz(A(b)) - cz(A(a)), e1x = cx(B(b)) - cx(B(a)), w = e1z * (px - cx(B(a))) - e1x * (pz - cz(A(a)));
                    if (std::fabs(w) > 1e-12) { if (sgn0 == 0) sgn0 = w > 0 ? 1 : -1; else if ((w > 0 ? 1 : -1) != sgn0) in = false; }
                    if ((int)cz(A(a)) == iz && (int)cx(B(a)) == ix) any = true;
                }
                if (in || any) g[(size_t)iz * nx + ix] = 1;
            }
        }
        auto at = [&](int iz, int ix) { return iz >= 0 && iz < nz && ix >= 0 && ix < nx && g[(size_t)iz * nx + ix]; };
        auto aOf = [&](double iz) { return a0 + (iz - 1) * cs; }; auto bOf = [&](double ix) { return b0 + (ix - 1) * cs; };
        auto zone = [&](double a) { return mode == 1 || view == 1 || a < -0.01 || a > L + 0.01; };
        auto X = [&](double a) { return view == 0 ? Zx(a) : xe + s * a; }; auto Y = [&](double b) { return view == 0 ? Xy(b) : yc + s * b; };
        for (int ix = 0; ix <= nx; ix++) {
            int run = -1;
            for (int iz = 0; iz <= nz; iz++) {
                const bool e = at(iz, ix) != at(iz, ix - 1) && zone(aOf(iz));
                if (e && run < 0) run = iz;
                if (!e && run >= 0) { ln(d, X(aOf(run)), Y(bOf(ix)), X(aOf(iz)), Y(bOf(ix)), kThick); run = -1; }
            }
        }
        for (int iz = 0; iz <= nz; iz++) {
            if (!zone(aOf(iz))) continue;
            int run = -1;
            for (int ix = 0; ix <= nx; ix++) {
                const bool e = at(iz, ix) != at(iz - 1, ix);
                if (e && run < 0) run = ix;
                if (!e && run >= 0) { ln(d, X(aOf(iz)), Y(bOf(run)), X(aOf(iz)), Y(bOf(ix)), kThick); run = -1; }
            }
        }
    };
    Pos p0 = d.pos();
    {   // hebras vistas (y<0): dos líneas a ±d/2 en el eje
        const double step = pitch / 48;
        std::vector<std::array<double, 2>> run;
        auto flush = [&]() {
            if (run.size() >= 2) for (int sd : {1, -1}) for (size_t i = 0; i + 1 < run.size(); i++) ln(d, Zx(run[i][1] + sd * dz), Xy(run[i][0]), Zx(run[i + 1][1] + sd * dz), Xy(run[i + 1][0]), kThick);
            run.clear();
        };
        for (double z = zs0; z <= ze0 + 1e-9; z += step) {
            const double ph = phiOf(z);
            if (Rmf(z) * std::sin(ph) < 0) run.push_back({Rmf(z) * std::cos(ph), z}); else flush();
        }
        flush();
        for (double z : c0) if (z > zs0 - 1e-6 && z < ze0 + 1e-6) d.arcs.push_back({Zx(z), Xy(Rmf(z)), s * 0.5 * dw, 0, 180, LineType::Continuous, kThick});
        for (double z : c2) if (z > zs0 - 1e-6 && z < ze0 + 1e-6) d.arcs.push_back({Zx(z), Xy(-Rmf(z)), s * 0.5 * dw, 180, 360, LineType::Continuous, kThick});
        for (double z : {zs0, ze0}) { const double ph = phiOf(z); if (Rmf(z) * std::sin(ph) < 0) ln(d, Zx(z - dz), Xy(Rmf(z) * std::cos(ph)), Zx(z + dz), Xy(Rmf(z) * std::cos(ph)), kThick); }
    }
    if (hook) hookSilhouette(0);
    ln(d, Zx(zlo) - 4, yc, Zx(zhi) + 4, yc, 0.18, LineType::Center);
    if (!cone) dimV(d, Xy(-0.5 * De), Xy(0.5 * De), Zx(zlo), Zx(zlo), Zx(zlo) - 14, "Ø" + fmt(De), "diameter", De);
    else {   // cónico: Ø exterior de cada extremo
        const bool bigL = Rmf(zs0) >= Rmf(ze0);
        dimV(d, Xy(-0.5 * (bigL ? De : Des)), Xy(0.5 * (bigL ? De : Des)), Zx(0), Zx(0), Zx(0) - 14, "Ø" + fmt(bigL ? De : Des), "diameter", bigL ? De : Des);
        dimV(d, Xy(-0.5 * (bigL ? Des : De)), Xy(0.5 * (bigL ? Des : De)), Zx(L), Zx(L), Zx(L) + 14, "Ø" + fmt(bigL ? Des : De), "diameter", bigL ? Des : De);
    }
    if (hook && mode == 0) {
        const double yb = Xy(-0.5 * std::max(De, vh));
        dimH(d, Zx(zlo), Zx(zhi), yb, yb, yb - 12, fmt(zhi - zlo), "length", zhi - zlo);
        dimH(d, Zx(0), Zx(L), yb, yb, yb - 22, fmt(L), "length", L);
    } else
    dimH(d, Zx(0), Zx(L), Xy(-0.5 * De), Xy(-0.5 * De), Xy(-0.5 * De) - 12, fmt(L), "length", L);
    {   // d y p sobre el primer par de círculos del hilo del borde superior
        const double z1 = c0[std::min<size_t>(1, c0.size() - 1)];
        dimH(d, Zx(z1 - 0.5 * dw), Zx(z1 + 0.5 * dw), Xy(Rmf(z1) + 0.5 * dw), Xy(Rmf(z1) + 0.5 * dw), Xy(0.5 * De) + 8, "Ø" + fmt(dw), "diameter", dw);
        if (c0.size() >= 3) dimH(d, Zx(c0[1]), Zx(c0[2]), Xy(Rmf(c0[1])), Xy(Rmf(c0[2])), Xy(0.5 * De) + 18, fmt(c0[2] - c0[1]), "length", c0[2] - c0[1]);
    }
    if (lh) text(d, Zx(zhi) - 8, Xy(0.5 * De) + 3, kTxt, "LH");
    d.tag(p0, 0);
    // vista desde la izquierda: circunferencias exterior e interior
    p0 = d.pos();
    d.arcs.push_back({xe, yc, s * rmax, 0, 360, LineType::Continuous, kThick});
    d.arcs.push_back({xe, yc, s * rmin, 0, 360, LineType::Continuous, kThick});
    centerCross(d, xe, yc, s * std::max(rmax, 0.5 * wy) + 4);
    if (mode == 1) hookSilhouette(1);
    dimH(d, xe - s * rmin, xe + s * rmin, yc - s * rmin, yc - s * rmin, yc - s * rmax - 12, "Ø" + fmt(Di), "diameter", Di);
    d.tag(p0, 1);
    finish(d, meta, "spring");
    return true;
}
}  // namespace
bool readShapeCached(const std::string& path, TopoDS_Shape& S) { return readShape(path, S); }
bool layoutSpring(const std::string& path, const Meta& meta, Drawing& d) { return springImpl(path, meta, d, 0) || springImpl(path, meta, d, 1); }

// ================================================================== LEVA
double gCamMinH = 0;   // espesor mínimo / Rmáx (pieza suelta: un lóbulo es grueso; arandelas con lengüeta no)
int gCamshaftMinLobes = 2;   // pieza pesada en conjunto: 1 lóbulo basta (árbol de levas con piñón)
bool gCamStrict = false;   // dentro de un conjunto: solo contornos de arcos de ≥2 radios distintos con taladro (lóbulo de leva), no cualquier placa
bool layoutCam(const std::string& path, const Meta& meta, Drawing& d) {
    gL = meta.lang;
    TopoDS_Shape S;
    if (!readShape(path, S)) return false;
    // placa: la cara plana mayor (con su normal exterior) y el volumen = área × espesor
    TopoDS_Face top; double aBest = 0;
    int nPlane = 0, nOther = 0;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face f = TopoDS::Face(ex.Current());
        BRepAdaptor_Surface su(f);
        if (su.GetType() == GeomAbs_Plane) { GProp_GProps g; BRepGProp::SurfaceProperties(f, g); nPlane++; if (g.Mass() > aBest) { aBest = g.Mass(); top = f; } } else nOther++;   // el área solo importa en planos (en roscas B-spline costaba 0,3 s)
    }
    if (top.IsNull() || nPlane < 2) return false;
    BRepAdaptor_Surface st(top);
    gp_Dir n = st.Plane().Axis().Direction();
    if (top.Orientation() == TopAbs_REVERSED) n = n.Reversed();
    {   // cara de vista determinista: la normal con su mayor componente positiva (θ antihorario visto desde +eje del modelo)
        const double c[3] = {n.X(), n.Y(), n.Z()}; int k = 0;
        for (int i = 1; i < 3; i++) if (std::fabs(c[i]) > std::fabs(c[k])) k = i;
        if (c[k] < 0) n = n.Reversed();
    }
    GProp_GProps gv; BRepGProp::VolumeProperties(S, gv);
    const double H = gv.Mass() / aBest;
    {   // espesor medido con la caja a lo largo de n
        Mesh mm = meshOf(S, 0.05);
        double a = 1e18, b = -1e18;
        for (auto& q : mm.v) { const double t = q.x * n.X() + q.y * n.Y() + q.z * n.Z(); a = std::min(a, t); b = std::max(b, t); }
        if (std::fabs((b - a) - H) > 0.02 * H + 0.02) return false;   // no es una placa prismática (cubo, escalones...)
    }
    gp_Dir e1 = std::fabs(n.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0);
    e1 = gp_Dir(e1.XYZ() - n.XYZ() * e1.Dot(n));
    const gp_Dir e2 = n.Crossed(e1);
    auto wireToPts = [&](const TopoDS_Wire& w) {
        std::vector<std::array<double, 2>> pts;
        for (TopExp_Explorer ee(w, TopAbs_EDGE); ee.More(); ee.Next()) {
            BRepAdaptor_Curve c(TopoDS::Edge(ee.Current()));
            GCPnts_QuasiUniformDeflection qd(c, 0.005);
            if (!qd.IsDone()) continue;
            std::vector<std::array<double, 2>> e;
            for (int i = 1; i <= qd.NbPoints(); i++) { gp_Pnt q = qd.Value(i); e.push_back({gp_Vec(q.X(), q.Y(), q.Z()).Dot(e1), gp_Vec(q.X(), q.Y(), q.Z()).Dot(e2)}); }
            if (TopoDS::Edge(ee.Current()).Orientation() == TopAbs_REVERSED) std::reverse(e.begin(), e.end());
            pts.insert(pts.end(), e.begin(), e.end());
        }
        return pts;
    };
    const TopoDS_Wire ow = BRepTools::OuterWire(top);
    std::vector<std::array<double, 2>> out = wireToPts(ow);
    if (out.size() < 20) return false;
    if (gCamStrict) {
        std::vector<double> rs; int nArc = 0;
        for (TopExp_Explorer ee(ow, TopAbs_EDGE); ee.More(); ee.Next()) {
            BRepAdaptor_Curve c(TopoDS::Edge(ee.Current()));
            if (c.GetType() != GeomAbs_Circle) continue;
            nArc++; const double r = c.Circle().Radius();
            bool nw = true; for (double q : rs) if (std::fabs(q - r) < 0.02 * r) nw = false;
            if (nw) rs.push_back(r);
        }
        int nIn = 0; for (TopExp_Explorer ew(top, TopAbs_WIRE); ew.More(); ew.Next()) nIn++;
        if (nArc < 3 || rs.size() < 2 || nIn < 2) return false;
    }
    // agujeros del plano: círculos (Ø y posición) y otros
    struct Hole { double cx, cy, r; };
    std::vector<Hole> holes; int nOtherInner = 0;
    for (TopExp_Explorer ew(top, TopAbs_WIRE); ew.More(); ew.Next()) {
        const TopoDS_Wire w = TopoDS::Wire(ew.Current());
        if (w.IsSame(ow)) continue;
        int ne = 0; bool circ = true; double r = 0; gp_Pnt cc;
        for (TopExp_Explorer ee(w, TopAbs_EDGE); ee.More(); ee.Next()) {
            BRepAdaptor_Curve c(TopoDS::Edge(ee.Current()));
            ne++;
            if (c.GetType() != GeomAbs_Circle) { circ = false; break; }
            r = c.Circle().Radius(); cc = c.Circle().Location();
        }
        if (circ && ne >= 1 && ne <= 2) holes.push_back({gp_Vec(cc.X(), cc.Y(), cc.Z()).Dot(e1), gp_Vec(cc.X(), cc.Y(), cc.Z()).Dot(e2), r}); else nOtherInner++;
    }
    // centro de giro: el agujero central (el mayor círculo interior); si no hay, el centro del círculo de base (mínimo radio) no se puede conocer → centro de la caja
    double ox, oy; bool haveBore = false; double boreR = 0;
    if (!holes.empty()) {
        size_t bi = 0;
        for (size_t i = 1; i < holes.size(); i++) if (holes[i].r > holes[bi].r) bi = i;
        ox = holes[bi].cx; oy = holes[bi].cy; boreR = holes[bi].r; haveBore = true;
        holes.erase(holes.begin() + bi);
    } else {
        double a = 1e18, b = -1e18, c = 1e18, e = -1e18;
        for (auto& q : out) { a = std::min(a, q[0]); b = std::max(b, q[0]); c = std::min(c, q[1]); e = std::max(e, q[1]); }
        ox = 0.5 * (a + b); oy = 0.5 * (c + e);
    }
    for (auto& q : out) { q[0] -= ox; q[1] -= oy; }
    for (auto& h : holes) { h.cx -= ox; h.cy -= oy; }
    // R(θ) por trazado de rayos: punto más lejano del contorno
    const int NB = 360;
    std::vector<double> R(NB, 0);
    for (int k = 0; k < NB; k++) {
        const double c = std::cos(k * kPi / 180), s = std::sin(k * kPi / 180);
        double best = 0;
        for (size_t i = 0; i < out.size(); i++) {
            const auto &a = out[i], &b = out[(i + 1) % out.size()];
            const double ex = b[0] - a[0], ey = b[1] - a[1], den = c * ey - s * ex;
            if (std::fabs(den) < 1e-12) continue;
            const double t = (a[0] * ey - a[1] * ex) / den, u = (a[0] * s - a[1] * c) / den;   // a + u·e = t·dir
            (void)u;
            const double uu = (t * s - a[1]) / (ey == 0 ? 1e-12 : ey);
            double uparam;
            if (std::fabs(ex) > std::fabs(ey)) uparam = (t * c - a[0]) / ex; else uparam = (t * s - a[1]) / ey;
            (void)uu;
            if (t > 1e-9 && uparam >= -1e-9 && uparam <= 1 + 1e-9) best = std::max(best, t);
        }
        R[k] = best;
    }
    double rmin = 1e18, rmax = 0; int kmin = 0, kmax = 0;
    for (int k = 0; k < NB; k++) { rmin = std::min(rmin, R[k]); rmax = std::max(rmax, R[k]); }
    for (int k = NB - 1; k >= 0; k--) { if (R[k] <= rmin + 0.01) kmin = k; if (R[k] >= rmax - 0.01) kmax = k; }
    if (rmax < 1 || rmax - rmin < 0.02 * rmax || (gCamStrict && H < gCamMinH * rmax)) return false;
    if (gCamStrict) {   // lóbulo: Rmáx/Rmín ≤ 3 y sin saltos (una palanca o chapa con brazos tiene relación mayor y flancos casi radiales)
        double dm = 0; for (int k = 0; k < NB; k++) dm = std::max(dm, std::fabs(R[(k + 1) % NB] - R[k]));
        if (rmax > 3 * rmin || dm > 0.05 * rmax) return false;
    }   // un disco: no es una leva
    // tramos de reposo (R constante ≥ 8°) y de variación
    struct Run { int a, b; bool dwell; double r0, r1; };
    std::vector<Run> runs;
    {
        int i = 0;
        while (i < NB) {
            int j = i;
            while (j + 1 < NB && std::fabs(R[j + 1] - R[i]) <= std::max(0.03, 0.005 * rmax)) j++;
            if (j - i + 1 >= 8) { runs.push_back({i, j, true, R[i], R[j]}); i = j + 1; }
            else {
                int k2 = i;
                while (k2 + 1 < NB) { int jj = k2 + 1; int e = jj; while (e + 1 < NB && std::fabs(R[e + 1] - R[jj]) <= std::max(0.03, 0.005 * rmax)) e++; if (e - jj + 1 >= 8) break; k2 = e; }
                if (k2 + 1 >= NB) k2 = NB - 1;
                runs.push_back({i, k2, false, R[i], R[k2]}); i = k2 + 1;
            }
        }
    }
    {   // un tramo de variación que contiene un máximo/mínimo interior se parte ahí (subida y bajada por separado)
        std::vector<Run> o2;
        for (auto& r : runs) {
            if (r.dwell || r.b - r.a < 12) { o2.push_back(r); continue; }
            int im = r.a, iM = r.a;
            for (int k = r.a; k <= r.b; k++) { if (R[k] < R[im]) im = k; if (R[k] > R[iM]) iM = k; }
            std::vector<int> cuts;   // extremos locales con histéresis de 0,5 mm
            {
                int ext = r.a; bool up = true, init = false;
                for (int k = r.a + 1; k <= r.b; k++) {
                    if (!init) { if (std::fabs(R[k] - R[r.a]) > 0.5) { up = R[k] > R[r.a]; init = true; ext = k; } continue; }
                    if (up ? R[k] > R[ext] : R[k] < R[ext]) ext = k;
                    else if (std::fabs(R[k] - R[ext]) > 0.5) { if (ext > r.a + 3) cuts.push_back(ext); up = !up; ext = k; }
                }
            }
            std::sort(cuts.begin(), cuts.end());
            int p = r.a;
            for (int c : cuts) { o2.push_back({p, c, false, R[p], R[c]}); p = c; }
            o2.push_back({p, r.b, false, R[p], R[r.b]});
        }
        for (auto& r : o2) if (!r.dwell) {   // el tramo termina en su máximo/mínimo; lo que sigue es un salto brusco
            int im = r.a, iM = r.a;
            for (int k = r.a; k <= r.b; k++) { if (R[k] < R[im]) im = k; if (R[k] > R[iM]) iM = k; }
            const bool rise = R[iM] - R[r.a] >= R[r.a] - R[im];
            r.b = rise ? iM : im; r.r0 = R[r.a]; r.r1 = R[r.b];
        }
        runs = o2;
    }
    std::vector<std::string> jumps;
    for (int k = 0; k < NB; k++) {   // salto = variación brusca; los grados consecutivos de un mismo escalón se unen
        if (std::fabs(R[(k + 1) % NB] - R[k]) <= 1.0 || std::fabs(R[k] - R[(k + NB - 1) % NB]) > 1.0) continue;
        int e = k; while (std::fabs(R[(e + 1) % NB] - R[e]) > 1.0 && e < k + 20) e++;
        jumps.push_back(T("Salto radial en") + " θ " + fmt1((k + 1) % NB) + "°: R " + fmt(R[k]) + " → " + fmt(R[(e + 1) % NB]) + " (" + T("sin acuerdo") + ")");
    }
    // ---- notas
    std::vector<std::string> notes;
    notes.push_back(T("Leva plana: R(θ) medido desde el centro de giro; θ antihorario visto desde el +eje dominante del modelo, 0° = eje X"));
    notes.push_back("R mín = " + fmt(rmin) + " (θ " + fmt1(kmin) + "°); R máx = " + fmt(rmax) + " (θ " + fmt1(kmax) + "°); " + T("espesor") + " = " + fmt(H));
    for (auto& r : runs) {
        if (!r.dwell && r.b - r.a < 5) continue;   // flancos del salto, ya van en «Salto radial»
        const std::string a = fmt1(r.a) + "°–" + fmt1(r.b) + "°";
        notes.push_back(r.dwell ? T("Reposo") + " " + a + ": R = " + fmt(r.r0) : (r.r1 > r.r0 ? T("Elevación") : T("Descenso")) + " " + a + ": R " + fmt(r.r0) + " → " + fmt(r.r1));
        if (notes.size() > 9) break;
    }
    for (auto& j : jumps) notes.push_back(j);
    if (!haveBore) notes.push_back(T("Sin agujero central: el centro de giro se toma en el centro de la caja del perfil (indicar el eje real)"));
    if (nOtherInner) notes.push_back(T("NO ACOTADO: contornos interiores que no son círculos") + " ×" + std::to_string(nOtherInner));
    std::string line, missing;
    const char* want[][2] = {{"Ley de movimiento del seguidor", "ley"}, {"Tipo de seguidor", "seguidor"}, {"Tolerancia del perfil", "tolperfil"}, {"Tratamiento", "tratamiento"}};
    for (auto& w : want) { const std::string v = userKey(meta, w[1]); if (v.empty()) missing += (missing.empty() ? "" : ", ") + T(w[0]); else line += (line.empty() ? "" : "; ") + T(w[0]) + ": " + v; }
    if (!line.empty()) notes.push_back(line);
    if (!missing.empty()) notes.push_back(T("No definidos en el STEP (indicar antes de fabricar)") + ": " + missing);

    // ---- hoja (primer diedro): planta a la izquierda, vista desde la izquierda (espesor) a su derecha, tabla R(θ) a la derecha (cada 15°)
    double ylo = 1e18, yhi = -1e18;
    for (auto& q : out) { ylo = std::min(ylo, q[1]); yhi = std::max(yhi, q[1]); }
    d = Drawing();
    d.groups = {T("Vista"), T("Vista desde la izquierda"), T("Tabla")};
    const Frame f = makeSheet(d, meta, 2 * rmax + H, 2 * rmax, 30 + 105, 30, notes);
    const double s = f.s, cyc = 0.5 * (f.zy0 + f.zy1), vx = f.fx0 + 25 + s * rmax;
    Pos p0 = d.pos();
    auto Px = [&](double x) { return vx + s * x; };
    auto Py = [&](double y) { return cyc + s * y; };
    for (size_t i = 0; i < out.size(); i++) { const auto &a = out[i], &b = out[(i + 1) % out.size()]; ln(d, Px(a[0]), Py(a[1]), Px(b[0]), Py(b[1]), kThick); }
    if (haveBore) d.arcs.push_back({Px(0), Py(0), s * boreR, 0, 360, LineType::Continuous, kThick});
    for (auto& h : holes) d.arcs.push_back({Px(h.cx), Py(h.cy), s * h.r, 0, 360, LineType::Continuous, kThick});
    centerCross(d, Px(0), Py(0), std::max(s * boreR, 3.0) + 4);
    auto radDim = [&](int kdeg, double r) {   // radio con línea de cota desde el centro de giro (ISO 129-1)
        const double a = kdeg * kPi / 180, c = std::cos(a), sn = std::sin(a);
        ln(d, Px(0), Py(0), Px(r * c), Py(r * sn), kThin);
        arrow(d, Px(r * c), Py(r * sn), -c, -sn);
        const std::string t = std::string("R") + fmt(r);
        text(d, Px(0.5 * r * c) + 1.5, Py(0.5 * r * sn) + 1.5, kTxt, t);
        d.dims.push_back({"radius", r, t});
    };
    radDim(kmax, rmax);
    if (std::abs(kmin - kmax) > 10) radDim(kmin, rmin);
    if (haveBore) dimH(d, Px(-boreR), Px(boreR), Py(-boreR), Py(-boreR), Py(ylo) - 12, "Ø" + fmt(2 * boreR), "hole", 2 * boreR);
    for (auto& h : holes) { const std::string t = "Ø" + fmt(2 * h.r) + " (" + fmt(h.cx) + "; " + fmt(h.cy) + ")"; text(d, Px(h.cx) - textW(t, kTxt) / 2, Py(h.cy) - s * h.r - 5, kTxt, t); d.dims.push_back({"hole", 2 * h.r, t}); }
    d.tag(p0, 0);
    // vista desde la izquierda: espesor, con el agujero a trazos
    p0 = d.pos();
    const double ex0 = Px(rmax) + 30;
    ln(d, ex0, Py(ylo), ex0 + s * H, Py(ylo), kThick); ln(d, ex0, Py(yhi), ex0 + s * H, Py(yhi), kThick);
    ln(d, ex0, Py(ylo), ex0, Py(yhi), kThick); ln(d, ex0 + s * H, Py(ylo), ex0 + s * H, Py(yhi), kThick);
    if (haveBore) for (double sg : {1.0, -1.0}) ln(d, ex0, Py(sg * boreR), ex0 + s * H, Py(sg * boreR), 0.25, LineType::Hidden);
    ln(d, ex0 - 4, Py(0), ex0 + s * H + 4, Py(0), 0.18, LineType::Center);
    dimH(d, ex0, ex0 + s * H, Py(yhi), Py(yhi), Py(yhi) + 10, fmt(H), "length", H);
    d.tag(p0, 1);
    // tabla R(θ) cada 15° (acotación por coordenadas polares: decisión propia, ver NORMAS_G6.md)
    p0 = d.pos();
    const double tx0 = f.fx1 - 15 - 96, rowH = 4.8, ty1 = cyc + 0.5 * (12 * rowH + 14);
    text(d, tx0, ty1 + 3, kTxt, T("Perfil: R en función de θ"));
    const int rows = 12;
    for (int col = 0; col < 2; col++) {
        const double x0 = tx0 + col * 50;
        ln(d, x0, ty1, x0 + 46, ty1); text(d, x0 + 2, ty1 - 5, 2.8, "θ [°]"); text(d, x0 + 26, ty1 - 5, 2.8, "R [mm]"); ln(d, x0, ty1 - 7, x0 + 46, ty1 - 7);
        for (int r = 0; r < rows; r++) {
            const int deg = (col * rows + r) * 15;
            const double y = ty1 - 7 - (r + 1) * rowH;
            text(d, x0 + 2, y + 1.2, 2.8, std::to_string(deg)); text(d, x0 + 26, y + 1.2, 2.8, fmt(R[deg % 360]));
        }
        ln(d, x0, ty1 - 7 - rows * rowH, x0 + 46, ty1 - 7 - rows * rowH);
        ln(d, x0 + 24, ty1, x0 + 24, ty1 - 7 - rows * rowH);
        ln(d, x0, ty1, x0, ty1 - 7 - rows * rowH); ln(d, x0 + 46, ty1, x0 + 46, ty1 - 7 - rows * rowH);
    }
    d.tag(p0, 2);
    finish(d, meta, "cam");
    return true;
}

// ================================================================== ÁRBOL DE LEVAS
// Eje con varios lóbulos. Eje = cilindro coaxial de mayor área; lóbulo = par de caras planas ⟂ eje con el mismo contorno no circular.
// Se da: vista lateral (eje horizontal), vista del extremo derecho con las narices y tabla de lóbulos (x desde el extremo izquierdo, Ø base, alzada, ángulo φ
// respecto a la nariz 1) + perfil R(θ) común + tabla de tramos del eje. Sin norma de acotado de árboles de levas: decisión propia (NORMAS_G6.md).
bool layoutCamshaft(const std::string& path, const Meta& meta, Drawing& d) {
    gL = meta.lang;
    TopoDS_Shape S;
    if (!readShape(path, S)) return false;
    struct Cy { gp_Ax1 ax; double r, area; };
    std::vector<Cy> cys;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        BRepAdaptor_Surface su(TopoDS::Face(ex.Current()));
        if (su.GetType() != GeomAbs_Cylinder) continue;
        GProp_GProps g; BRepGProp::SurfaceProperties(TopoDS::Face(ex.Current()), g);
        cys.push_back({su.Cylinder().Axis(), su.Cylinder().Radius(), g.Mass()});
    }
    if (cys.size() < 3) return false;
    auto coax = [](const gp_Ax1& a, const gp_Ax1& b) {
        if (std::fabs(a.Direction().Dot(b.Direction())) < 0.99999) return false;
        const gp_Vec w(a.Location(), b.Location());
        return w.Crossed(gp_Vec(a.Direction())).Magnitude() < 0.05;
    };
    size_t bi = 0; double bs = 0;
    for (size_t i = 0; i < cys.size(); i++) { double s = 0; for (auto& c : cys) if (coax(cys[i].ax, c.ax)) s += c.area; if (s > bs) { bs = s; bi = i; } }
    gp_Ax1 ax = cys[bi].ax;
    gp_Dir a = ax.Direction();
    {   const double c[3] = {a.X(), a.Y(), a.Z()}; int k = 0; for (int i = 1; i < 3; i++) if (std::fabs(c[i]) > std::fabs(c[k])) k = i; if (c[k] < 0) a = a.Reversed(); }
    const gp_Pnt O = ax.Location();
    gp_Dir e1 = std::fabs(a.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0);
    e1 = gp_Dir(e1.XYZ() - a.XYZ() * e1.Dot(a));
    const gp_Dir e2 = a.Crossed(e1);
    auto TT = [&](const gp_Pnt& p) { return gp_Vec(O, p).Dot(gp_Vec(a)); };
    auto UU = [&](const gp_Pnt& p) { return gp_Vec(O, p).Dot(gp_Vec(e1)); };
    auto VV = [&](const gp_Pnt& p) { return gp_Vec(O, p).Dot(gp_Vec(e2)); };
    double tmin = 1e18, tmax = -1e18;
    for (TopExp_Explorer ex(S, TopAbs_VERTEX); ex.More(); ex.Next()) { const double t = TT(BRep_Tool::Pnt(TopoDS::Vertex(ex.Current()))); tmin = std::min(tmin, t); tmax = std::max(tmax, t); }
    const double L = tmax - tmin;
    if (L < 1) return false;
    // ---- lóbulos: caras planas ⟂ eje con contorno exterior no circular
    struct End { double t; std::vector<double> R; double rmin, rmax; };
    std::vector<End> ends;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face f = TopoDS::Face(ex.Current());
        BRepAdaptor_Surface su(f);
        if (su.GetType() != GeomAbs_Plane || std::fabs(su.Plane().Axis().Direction().Dot(a)) < 0.9999) continue;
        std::vector<std::array<double, 2>> out;
        for (TopExp_Explorer ee(BRepTools::OuterWire(f), TopAbs_EDGE); ee.More(); ee.Next()) {
            BRepAdaptor_Curve c(TopoDS::Edge(ee.Current()));
            GCPnts_QuasiUniformDeflection qd(c, 0.005);
            if (!qd.IsDone()) continue;
            std::vector<std::array<double, 2>> e;
            for (int i = 1; i <= qd.NbPoints(); i++) { gp_Pnt q = qd.Value(i); e.push_back({UU(q), VV(q)}); }
            if (TopoDS::Edge(ee.Current()).Orientation() == TopAbs_REVERSED) std::reverse(e.begin(), e.end());
            out.insert(out.end(), e.begin(), e.end());
        }
        if (out.size() < 20) continue;
        End en; en.t = TT(su.Plane().Location()); en.R.assign(360, 0);
        for (int k = 0; k < 360; k++) {
            const double c = std::cos(k * kPi / 180), s = std::sin(k * kPi / 180);
            double best = 0;
            for (size_t i = 0; i < out.size(); i++) {
                const auto &p = out[i], &q = out[(i + 1) % out.size()];
                const double ex2 = q[0] - p[0], ey = q[1] - p[1], den = c * ey - s * ex2;
                if (std::fabs(den) < 1e-12) continue;
                const double t = (p[0] * ey - p[1] * ex2) / den, u = (p[0] * s - p[1] * c) / den;
                if (t > 1e-9 && u >= -1e-9 && u <= 1 + 1e-9) best = std::max(best, t);
            }
            en.R[k] = best;
        }
        en.rmin = 1e18; en.rmax = 0;
        for (double r : en.R) { en.rmin = std::min(en.rmin, r); en.rmax = std::max(en.rmax, r); }
        if (en.rmax - en.rmin < 0.3 || en.rmin < 0.5) continue;   // redondo (tramo del eje) o sin sentido
        ends.push_back(en);
    }
    std::sort(ends.begin(), ends.end(), [](const End& x, const End& y) { return x.t < y.t; });
    struct Lobe { double t0, t1, rb, rmax, th0, phi; std::vector<double> R, Rn; };   // th0: ángulo de la nariz (modelo); Rn: R desde la nariz
    std::vector<Lobe> lobes;
    {
        std::vector<bool> used(ends.size(), false);
        for (size_t i = 0; i < ends.size(); i++) {
            if (used[i]) continue;
            for (size_t j = i + 1; j < ends.size(); j++) {
                if (used[j] || ends[j].t - ends[i].t < 0.1) continue;
                double dm = 0; for (int k = 0; k < 360; k++) dm = std::max(dm, std::fabs(ends[i].R[k] - ends[j].R[k]));
                if (dm > 0.1) continue;
                used[i] = used[j] = true;
                Lobe lb; lb.t0 = ends[i].t; lb.t1 = ends[j].t; lb.rb = ends[i].rmin; lb.rmax = ends[i].rmax; lb.R = ends[i].R;
                double sx = 0, sy = 0;
                for (int k = 0; k < 360; k++) if (lb.R[k] >= lb.rmax - 0.02) { sx += std::cos(k * kPi / 180); sy += std::sin(k * kPi / 180); }
                lb.th0 = std::fmod(std::atan2(sy, sx) * 180 / kPi + 360, 360);
                lobes.push_back(lb);
                break;
            }
        }
    }
    if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "CAMSHAFT cys=%zu ends=%zu lobes=%zu L=%.1f\n", cys.size(), ends.size(), lobes.size(), L);
    if ((int)lobes.size() < gCamshaftMinLobes) return false;
    std::sort(lobes.begin(), lobes.end(), [](const Lobe& x, const Lobe& y) { return x.t0 < y.t0; });
    const double th1 = lobes[0].th0;
    bool common = true;
    for (auto& lb : lobes) {
        lb.phi = std::fmod(lb.th0 - th1 + 360, 360);
        lb.Rn.assign(360, 0);
        for (int k = 0; k < 360; k++) lb.Rn[k] = lb.R[((int)std::lround(lb.th0) + k) % 360];
        double dm = 0; for (int k = 0; k < 360; k++) dm = std::max(dm, std::fabs(lb.Rn[k] - lobes[0].Rn[k]));
        if (dm > 0.15) common = false;
    }
    double rmaxAll = 0;
    for (auto& lb : lobes) rmaxAll = std::max(rmaxAll, lb.rmax);
    auto inLobe = [&](double t) { for (auto& lb : lobes) if (t > lb.t0 - 1e-6 && t < lb.t1 + 1e-6) return true; return false; };
    // ---- silueta del eje: cilindros y conos coaxiales fuera de los lóbulos
    struct Sg { double t0, r0, t1, r1; bool env = false; };
    std::vector<Sg> sg; int nCone = 0, nOther = 0;
    std::vector<TopoDS_Face> otherF;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face f = TopoDS::Face(ex.Current());
        BRepAdaptor_Surface su(f);
        double t0 = 1e18, t1 = -1e18, rr0 = 0, rr1 = 0;
        for (TopExp_Explorer ev(f, TopAbs_VERTEX); ev.More(); ev.Next()) {
            const gp_Pnt q = BRep_Tool::Pnt(TopoDS::Vertex(ev.Current())); const double t = TT(q), r = std::hypot(UU(q), VV(q));
            if (t < t0) { t0 = t; rr0 = r; } if (t > t1) { t1 = t; rr1 = r; }
        }
        if (t1 < t0) continue;
        const bool lob = inLobe(0.5 * (t0 + t1)) || (t1 - t0 < 1e-6 && inLobe(t0));
        const GeomAbs_SurfaceType ty = su.GetType();
        if (ty == GeomAbs_Plane && std::fabs(su.Plane().Axis().Direction().Dot(a)) > 0.9999) continue;
        if (ty == GeomAbs_Cylinder && coax(su.Cylinder().Axis(), ax)) { if (!lob && t1 - t0 > 1e-3) sg.push_back({t0, su.Cylinder().Radius(), t1, su.Cylinder().Radius()}); continue; }
        if (ty == GeomAbs_Cone && std::fabs(su.Cone().Axis().Direction().Dot(a)) > 0.9999) { if (!lob) { nCone++; sg.push_back({t0, rr0, t1, rr1}); } continue; }
        if (!lob) { nOther++; otherF.push_back(f); }
    }
    {   // caras libres (dentado, hélices, acuerdos) fuera de lóbulos: envolvente radial por tramos axiales para la silueta
        const int nb = (int)std::min(400.0, std::max(20.0, std::ceil(L / 0.5)));
        std::vector<double> env(nb, 0.0);
        for (auto& f : otherF) {
            BRepMesh_IncrementalMesh(f, 0.2, false, 0.5, true);
            TopLoc_Location loc; Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(f, loc);
            if (tri.IsNull()) continue;
            for (int i = 1; i <= tri->NbNodes(); i++) {
                const gp_Pnt q = tri->Node(i).Transformed(loc.Transformation());
                const int k = std::min(nb - 1, std::max(0, (int)((TT(q) - tmin) / L * nb)));
                env[k] = std::max(env[k], std::hypot(UU(q), VV(q)));
            }
        }
        for (int k = 0; k < nb; k++) { const double t0 = tmin + L * k / nb, t1 = tmin + L * (k + 1) / nb; if (env[k] > 0.2 && !inLobe(0.5 * (t0 + t1))) { Sg g{t0, env[k], t1, env[k]}; g.env = true; sg.push_back(g); } }
    }
    for (auto& g : sg) rmaxAll = std::max(rmaxAll, std::max(g.r0, g.r1));
    std::vector<double> bp = {tmin, tmax};
    for (auto& s2 : sg) { bp.push_back(s2.t0); bp.push_back(s2.t1); }
    for (auto& lb : lobes) { bp.push_back(lb.t0); bp.push_back(lb.t1); }
    std::sort(bp.begin(), bp.end());
    { std::vector<double> u; for (double b : bp) if (u.empty() || b - u.back() > 1e-4) u.push_back(b); bp = u; }
    auto rAt = [&](double t) { double best = 0; for (auto& s2 : sg) if (t >= s2.t0 - 1e-6 && t <= s2.t1 + 1e-6) { const double u2 = s2.t1 > s2.t0 ? (t - s2.t0) / (s2.t1 - s2.t0) : 0; best = std::max(best, s2.r0 + u2 * (s2.r1 - s2.r0)); } return best; };
    // tramos cilíndricos del eje (tabla): intervalos entre puntos de corte con el mismo radio de cilindro
    struct Sec { double t0, t1, r; };
    std::vector<Sec> secs;
    for (auto& s2 : sg) if (!s2.env && std::fabs(s2.r1 - s2.r0) < 1e-6 && s2.t1 - s2.t0 > 1) secs.push_back({s2.t0, s2.t1, s2.r0});
    std::sort(secs.begin(), secs.end(), [](const Sec& x, const Sec& y) { return x.t0 < y.t0; });
    { std::vector<Sec> m; for (auto& s2 : secs) { if (!m.empty() && std::fabs(m.back().r - s2.r) < 1e-6 && s2.t0 <= m.back().t1 + 1e-3) m.back().t1 = std::max(m.back().t1, s2.t1); else m.push_back(s2); } secs = m; }
    // quitar los tramos totalmente cubiertos por otro de mayor radio (taladros interiores)
    { std::vector<Sec> m; for (auto& s2 : secs) { bool cov = false; for (auto& o : secs) if (o.r > s2.r + 1e-6 && o.t0 <= s2.t0 + 1e-3 && o.t1 >= s2.t1 - 1e-3) cov = true; if (!cov) m.push_back(s2); } secs = m; }
    { std::vector<Sec> m; for (auto& s2 : secs) { bool f2 = false; for (auto& o : m) if (std::fabs(o.r - s2.r) < 1e-6) { o.t0 = std::min(o.t0, s2.t0); o.t1 = std::max(o.t1, s2.t1); f2 = true; } if (!f2) m.push_back(s2); } secs = m; }   // tramos del mismo Ø separados por levas: una fila
    std::vector<Sec> secDim;   // cota de Ø: en el tramo continuo más largo de cada diámetro
    for (auto& s2 : secs) { Sec best = s2; double bl = 0; double a0 = s2.t0; std::vector<double> cuts = {s2.t0}; for (auto& lb : lobes) if (lb.t0 > s2.t0 && lb.t1 < s2.t1) { cuts.push_back(lb.t0); cuts.push_back(lb.t1); } cuts.push_back(s2.t1); (void)a0; for (size_t i = 0; i + 1 < cuts.size(); i += 2) if (cuts[i + 1] - cuts[i] > bl) { bl = cuts[i + 1] - cuts[i]; best = {cuts[i], cuts[i + 1], s2.r}; } secDim.push_back(best); }
    // ---- notas
    std::vector<std::string> notes;
    notes.push_back(T("Árbol de levas") + ": " + std::to_string(lobes.size()) + " " + T("levas") + ", " + T("longitud") + " " + fmt(L) + ", Ø" + fmt(2 * (secs.empty() ? lobes[0].rb : secs.front().r)));
    notes.push_back(T("x medida desde el extremo izquierdo; φ = ángulo de la nariz de cada leva respecto a la nariz 1, antihorario visto desde el extremo derecho"));
    if (common) notes.push_back(T("Las levas tienen el mismo perfil: R(θ) desde la nariz (θ = 0°), antihorario visto desde el extremo derecho"));
    else notes.push_back(T("Los perfiles de las levas difieren: R(θ) por leva en la tabla"));
    if (nCone) notes.push_back(T("NO ACOTADO: tramos cónicos o chaflanes") + " ×" + std::to_string(nCone));
    if (nOther) notes.push_back(T("NO ACOTADO: caras fuera de revolución en el eje (taladros, chaveteros, planos)") + " ×" + std::to_string(nOther));
    std::string line, missing;
    const char* want[][2] = {{"Tolerancia del perfil", "tolperfil"}, {"Tratamiento", "tratamiento"}};
    for (auto& w : want) { const std::string v = userKey(meta, w[1]); if (v.empty()) missing += (missing.empty() ? "" : ", ") + T(w[0]); else line += (line.empty() ? "" : "; ") + T(w[0]) + ": " + v; }
    if (!line.empty()) notes.push_back(line);
    if (!missing.empty()) notes.push_back(T("No definidos en el STEP (indicar antes de fabricar)") + ": " + missing);

    // ---- hoja: vista del extremo (izquierda), vista lateral, tablas debajo
    const double rowH = 4.8, nrowT = common ? 13 : (double)lobes.size() + 1, tabH = std::max(nrowT, (double)std::max(lobes.size(), secs.size()) + 2) * rowH + 8;
    d = Drawing();
    d.groups = {T("Vista"), T("Vista desde la derecha"), T("Tabla")};
    const double mh = tabH + 30;
    const Frame f = makeSheet(d, meta, L + 2 * rmaxAll, 2 * rmaxAll, 2 * 25 + 30, mh, notes);
    const double s = f.s, freeY0 = f.zy0 - mh / 2, freeY1 = f.zy1 + mh / 2;
    const double cyc = 0.5 * (freeY0 + tabH + 12 + freeY1);
    const double cx = f.fx0 + 22 + s * rmaxAll, sx0 = cx + s * rmaxAll + 30;
    const double th0r = th1 * kPi / 180;
    Pos p0 = d.pos();
    // vista lateral
    auto SX = [&](double t) { return sx0 + s * (t - tmin); };
    auto SY = [&](double y) { return cyc + s * y; };
    ln(d, SX(tmin) - 4, SY(0), SX(tmax) + 4, SY(0), 0.18, LineType::Center);
    for (size_t i = 0; i + 1 < bp.size(); i++) {
        const double ta = bp[i], tb = bp[i + 1], eps = std::min(1e-3, (tb - ta) / 4);
        if (inLobe(0.5 * (ta + tb))) continue;
        const double ra = rAt(ta + eps), rb2 = rAt(tb - eps);
        if (ra < 1e-6 || rb2 < 1e-6) continue;
        for (double sgn : {1.0, -1.0}) ln(d, SX(ta), SY(sgn * ra), SX(tb), SY(sgn * rb2), kThick);
    }
    for (double b : bp) {
        if (b <= tmin + 1e-4 || b >= tmax - 1e-4) { const double r = rAt(b <= tmin + 1e-4 ? b + 1e-3 : b - 1e-3); if (inLobe(b)) continue; ln(d, SX(b), SY(-r), SX(b), SY(r), kThick); continue; }
        if (inLobe(b - 1e-3) || inLobe(b + 1e-3)) continue;
        const double rl = rAt(b - 1e-3), rr = rAt(b + 1e-3);
        if (rl < 1e-6 || rr < 1e-6 || std::fabs(rl - rr) < 1e-3) continue;
        for (double sgn : {1.0, -1.0}) ln(d, SX(b), SY(sgn * rl), SX(b), SY(sgn * rr), kThick);
    }
    int idx = 0;
    for (auto& lb : lobes) {
        idx++;
        double ylo = 1e18, yhi = -1e18;
        for (int k = 0; k < 360; k++) { const double y = lb.R[k] * std::cos(k * kPi / 180 - th0r); ylo = std::min(ylo, y); yhi = std::max(yhi, y); }
        ln(d, SX(lb.t0), SY(ylo), SX(lb.t1), SY(ylo), kThick); ln(d, SX(lb.t0), SY(yhi), SX(lb.t1), SY(yhi), kThick);
        ln(d, SX(lb.t0), SY(ylo), SX(lb.t0), SY(yhi), kThick); ln(d, SX(lb.t1), SY(ylo), SX(lb.t1), SY(yhi), kThick);
        const std::string n = std::to_string(idx);
        text(d, SX(0.5 * (lb.t0 + lb.t1)) - textW(n, kTxt) / 2, SY(yhi) + 3, kTxt, n);
    }
    // cotas: longitud total y ancho de la leva 1; Ø de cada tramo del eje
    dimH(d, SX(tmin), SX(tmax), SY(-rmaxAll), SY(-rmaxAll), SY(-rmaxAll) - 14, fmt(L), "length", L);
    dimH(d, SX(lobes[0].t0), SX(lobes[0].t1), SY(rmaxAll), SY(rmaxAll), SY(rmaxAll) + 12, fmt(lobes[0].t1 - lobes[0].t0), "length", lobes[0].t1 - lobes[0].t0);
    for (auto& sc : secDim) {
        const std::string t = "Ø" + fmt(2 * sc.r);
        dimV(d, SY(-sc.r), SY(sc.r), SX(0.5 * (sc.t0 + sc.t1)), SX(0.5 * (sc.t0 + sc.t1)), SX(0.5 * (sc.t0 + sc.t1)), t, "hole", 2 * sc.r);
    }
    d.tag(p0, 0);
    // vista desde el extremo derecho: leva 1 con la nariz arriba, narices de todas las levas
    p0 = d.pos();
    auto EX = [&](double u) { return cx + s * u; };
    auto EY = [&](double v) { return cyc + s * v; };
    {
        const double rot = 90 * kPi / 180 - th0r;
        for (int k = 0; k < 360; k++) {
            const double a1 = k * kPi / 180 + rot, a2 = (k + 1) * kPi / 180 + rot, r1 = lobes[0].R[k], r2 = lobes[0].R[(k + 1) % 360];
            ln(d, EX(r1 * std::cos(a1)), EY(r1 * std::sin(a1)), EX(r2 * std::cos(a2)), EY(r2 * std::sin(a2)), kThick);
        }
        const double rs = secs.empty() ? lobes[0].rb : secs.front().r;
        d.arcs.push_back({EX(0), EY(0), s * rs, 0, 360, LineType::Hidden, 0.25});
        centerCross(d, EX(0), EY(0), s * rmaxAll + 6);
        int i2 = 0;
        for (auto& lb : lobes) {
            i2++;
            const double an = 90 * kPi / 180 + lb.phi * kPi / 180, c = std::cos(an), sn = std::sin(an);
            ln(d, EX(0), EY(0), EX((rmaxAll + 6) * c), EY((rmaxAll + 6) * sn), 0.18, LineType::Center);
            const std::string n = std::to_string(i2);
            text(d, EX((rmaxAll + 9) * c) - textW(n, kTxt) / 2, EY((rmaxAll + 9) * sn) - 1.5, kTxt, n);
        }
        const double a0 = 90 * kPi / 180;
        ln(d, EX(0), EY(0), EX(lobes[0].rmax * std::cos(a0 + 0.35)), EY(lobes[0].rmax * std::sin(a0 + 0.35)), kThin);
        arrow(d, EX(lobes[0].rmax * std::cos(a0 + 0.35)), EY(lobes[0].rmax * std::sin(a0 + 0.35)), -std::cos(a0 + 0.35), -std::sin(a0 + 0.35));
        const std::string tr1 = "R" + fmt(lobes[0].rmax);
        text(d, EX((lobes[0].rmax + 2) * std::cos(a0 + 0.35)), EY((lobes[0].rmax + 2) * std::sin(a0 + 0.35)) + 1, kTxt, tr1);
        d.dims.push_back({"radius", lobes[0].rmax, tr1});
        const double a3 = a0 + 1.6, rb = lobes[0].rb;
        ln(d, EX(0), EY(0), EX(rb * std::cos(a3)), EY(rb * std::sin(a3)), kThin);
        arrow(d, EX(rb * std::cos(a3)), EY(rb * std::sin(a3)), -std::cos(a3), -std::sin(a3));
        const std::string tr2 = "R" + fmt(rb);
        text(d, EX((rb + 2) * std::cos(a3)) - textW(tr2, kTxt), EY((rb + 2) * std::sin(a3)) - 4, kTxt, tr2);
        d.dims.push_back({"radius", rb, tr2});
    }
    d.tag(p0, 1);
    // tablas
    p0 = d.pos();
    const double ty1 = freeY0 + tabH;
    auto grid = [&](double x0, double ytop, const std::vector<double>& cw, const std::vector<std::vector<std::string>>& rows) {
        double W = 0; for (double w : cw) W += w;
        const double yb = ytop - rows.size() * rowH;
        ln(d, x0, ytop, x0 + W, ytop); ln(d, x0, ytop - rowH, x0 + W, ytop - rowH); ln(d, x0, yb, x0 + W, yb);
        double xx = x0; ln(d, xx, ytop, xx, yb);
        for (double w : cw) { xx += w; ln(d, xx, ytop, xx, yb); }
        for (size_t r = 0; r < rows.size(); r++) { xx = x0; for (size_t c = 0; c < cw.size() && c < rows[r].size(); c++) { text(d, xx + 1.2, ytop - (r + 1) * rowH + 1.2, 2.8, rows[r][c]); xx += cw[c]; } }
        return W;
    };
    double tx = f.fx0 + 5;
    {
        std::vector<std::vector<std::string>> rows = {{"N", "x0", "x1", "R base", "R máx", "φ [°]"}};
        for (size_t i = 0; i < lobes.size(); i++) rows.push_back({std::to_string(i + 1), fmt(lobes[i].t0 - tmin), fmt(lobes[i].t1 - tmin), fmt(lobes[i].rb), fmt(lobes[i].rmax), fmt1(lobes[i].phi)});
        text(d, tx, ty1 + 2, kTxt, T("Levas"));
        tx += grid(tx, ty1, {10, 20, 20, 20, 20, 18}, rows) + 8;
    }
    if (!secs.empty()) {
        std::vector<std::vector<std::string>> rows = {{"x0", "x1", "Ø"}};
        for (auto& sc : secs) rows.push_back({fmt(sc.t0 - tmin), fmt(sc.t1 - tmin), fmt(2 * sc.r)});
        text(d, tx, ty1 + 2, kTxt, T("Tramos del eje"));
        tx += grid(tx, ty1, {22, 22, 22}, rows) + 8;
    }
    if (common) {
        for (int col = 0; col < 2; col++) {
            std::vector<std::vector<std::string>> rows = {{"θ [°]", "R [mm]"}};
            for (int r = 0; r < 12; r++) { const int deg = (col * 12 + r) * 15; rows.push_back({std::to_string(deg), fmt(lobes[0].Rn[deg % 360])}); }
            if (col == 0) text(d, tx, ty1 + 2, kTxt, T("Perfil de la leva: R en función de θ"));
            tx += grid(tx, ty1, {20, 24}, rows) + 4;
        }
    } else {
        std::vector<std::vector<std::string>> rows = {{"N"}};
        for (int dg = 0; dg < 360; dg += 30) rows[0].push_back(std::to_string(dg));
        for (size_t i = 0; i < lobes.size(); i++) { std::vector<std::string> r = {std::to_string(i + 1)}; for (int dg = 0; dg < 360; dg += 30) r.push_back(fmt(lobes[i].Rn[dg])); rows.push_back(r); }
        text(d, tx, ty1 + 2, kTxt, T("R(θ) por leva desde la nariz"));
        grid(tx, ty1, std::vector<double>(1, 8).size() ? std::vector<double>{8, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12} : std::vector<double>{}, rows);
    }
    d.tag(p0, 2);
    finish(d, meta, "camshaft");
    return true;
}

// ================================================================== LEVA DE CARA / DE TAMBOR
// Leva de cara: la cara frontal de un cilindro es la superficie de trabajo, altura h(θ) a Ø medio.
// Leva de tambor: ranura en la superficie lateral; línea media z(θ), ancho y profundidad. Ambas se dan por desarrollo y tabla (decisión propia, NORMAS_G6.md).
bool layoutCam3D(const std::string& path, const Meta& meta, Drawing& d) {
    gL = meta.lang;
    TopoDS_Shape S;
    if (!readShape(path, S)) return false;
    double rOut = 0; gp_Ax1 ax0; bool haveCyl = false; std::vector<std::pair<double, gp_Ax1>> cyls;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        BRepAdaptor_Surface su(TopoDS::Face(ex.Current()));
        if (su.GetType() != GeomAbs_Cylinder) continue;
        const gp_Cylinder cy = su.Cylinder(); cyls.push_back({cy.Radius(), cy.Axis()});
        if (cy.Radius() > rOut) { rOut = cy.Radius(); ax0 = cy.Axis(); haveCyl = true; }
    }
    if (!haveCyl || rOut < 3) return false;
    double rIn = 0;
    for (auto& c : cyls) { const gp_Vec w(ax0.Location(), c.second.Location()); if (c.second.Direction().IsParallel(ax0.Direction(), 1e-4) && w.Crossed(gp_Vec(ax0.Direction())).Magnitude() < 1e-3 && c.first < 0.9 * rOut) rIn = std::max(rIn, c.first); }
    Mesh m = meshOf(S, 0.02);
    if (m.v.size() < 300) return false;
    gp_Dir u = ax0.Direction();
    { const double c[3] = {u.X(), u.Y(), u.Z()}; int k = 0; for (int i = 1; i < 3; i++) if (std::fabs(c[i]) > std::fabs(c[k])) k = i; if (c[k] < 0) u = u.Reversed(); }
    gp_Dir e1 = std::fabs(u.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0);
    e1 = gp_Dir(e1.XYZ() - u.XYZ() * e1.Dot(u));
    const gp_Dir e2 = u.Crossed(e1);
    const gp_Pnt O = ax0.Location();
    std::vector<V3> P; P.reserve(m.v.size());
    double z0 = 1e18, z1 = -1e18, rmaxA = 0;
    for (auto& q : m.v) {
        const gp_Vec w(q.x - O.X(), q.y - O.Y(), q.z - O.Z());
        const V3 v{w.Dot(e1), w.Dot(e2), w.Dot(gp_Vec(u))}; P.push_back(v);
        z0 = std::min(z0, v.z); z1 = std::max(z1, v.z); rmaxA = std::max(rmaxA, std::hypot(v.x, v.y));
    }
    const double H = z1 - z0;
    if (H < 1 || std::fabs(rmaxA - rOut) > 0.01 * rOut + 0.02) return false;   // cilindro de revolución con la cara/ranura trabajada
    // ---- ¿leva de cara? alturas extremas por rayo axial a Ø medio
    const int NB = 360; const double rm = 0.5 * (rIn + rOut);
    std::vector<double> top(NB, -1e18), bot(NB, 1e18);
    for (int k = 0; k < NB; k++) {
        const double px = rm * std::cos(k * kPi / 180), py = rm * std::sin(k * kPi / 180);
        for (auto& t : m.t) {
            const V3 &a = P[t[0]], &b = P[t[1]], &c = P[t[2]];
            if (std::max({a.x, b.x, c.x}) < px || std::min({a.x, b.x, c.x}) > px || std::max({a.y, b.y, c.y}) < py || std::min({a.y, b.y, c.y}) > py) continue;
            const double den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
            if (std::fabs(den) < 1e-12) continue;
            const double l1 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / den, l2 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / den, l3 = 1 - l1 - l2;
            if (l1 < -1e-9 || l2 < -1e-9 || l3 < -1e-9) continue;
            const double z = l1 * a.z + l2 * b.z + l3 * c.z;
            top[k] = std::max(top[k], z); bot[k] = std::min(bot[k], z);
        }
    }
    auto range = [&](const std::vector<double>& a, double& lo, double& hi) { lo = 1e18; hi = -1e18; for (double v : a) { if (std::fabs(v) > 1e17) return false; lo = std::min(lo, v); hi = std::max(hi, v); } return true; };
    double tl, th, bl, bh;
    const bool okT = range(top, tl, th), okB = range(bot, bl, bh);
    bool face = okT && okB && std::max(th - tl, bh - bl) >= std::max(0.3, 0.02 * H);
    if (face) {   // una leva tiene superficie continua: los taladros ciegos o dientes sueltos dan saltos en h(θ)
        const std::vector<double>& a = (bh - bl) > (th - tl) ? bot : top; const double rg = std::max(th - tl, bh - bl); int nj = 0;
        for (int k = 0; k < NB; k++) if (std::fabs(a[(k + 1) % NB] - a[k]) > 0.2 * rg) nj++;
        if (nj > 2) face = false;
    }
    std::vector<std::string> notes;
    std::vector<double> hv(NB, 0);   // face: h(θ); drum: z de la línea media
    std::vector<char> have(NB, 1);
    double gw = 0, gdepth = 0, lo = 0, hi = 0, base = 0;
    const std::string dEx = fmt(2 * rOut), dIn = rIn > 0 ? fmt(2 * rIn) : "";
    if (face) {
        const bool flip = (bh - bl) > (th - tl);   // la cara trabajada es la inferior: se mira desde el otro extremo
        for (int k = 0; k < NB; k++) hv[k] = flip ? (z1 - bot[(NB - k) % NB]) : (top[k] - z0);
        range(hv, lo, hi); base = lo;
        notes.push_back(T("Leva de cara: altura h(θ) de la superficie de trabajo a Ø medio; θ antihorario visto desde la cara trabajada, 0° = eje X"));
        notes.push_back("Ø " + dEx + (rIn > 0 ? "; " + T("agujero") + " Ø " + dIn : "") + "; " + T("Altura total") + " = " + fmt(H) + "; h mín = " + fmt(lo) + "; h máx = " + fmt(hi) + "; " + T("Carrera") + " = " + fmt(hi - lo) + "; Ø " + T("medio") + " = " + fmt(2 * rm));
    } else {
        const int GB = 120; std::vector<double> zl(GB, 1e18), zh(GB, -1e18); double rg = 1e18; int nb = 0;
        for (auto& q : P) {
            const double r = std::hypot(q.x, q.y);
            if (r < 1.05 * rIn + 0.5 || r > rOut - 0.15 || q.z < z0 + 0.02 || q.z > z1 - 0.02) continue;
            double a = std::atan2(q.y, q.x) * 180 / kPi; if (a < 0) a += 360;
            const int b = std::min(GB - 1, (int)(a / 3));
            zl[b] = std::min(zl[b], q.z); zh[b] = std::max(zh[b], q.z); rg = std::min(rg, r);
        }
        std::vector<double> zc(GB, 0); std::vector<char> hv2(GB, 0);
        double wsum = 0, wmax = 0; std::vector<double> ws;
        for (int b = 0; b < GB; b++) if (zh[b] > -1e17) { zc[b] = 0.5 * (zl[b] + zh[b]); hv2[b] = 1; nb++; const double w = zh[b] - zl[b]; wsum += w; ws.push_back(w); wmax = std::max(wmax, w); }
        if (nb < GB / 2 || wmax > 0.4 * H) return false;
        double a = 1e18, b2 = -1e18; for (int b = 0; b < GB; b++) if (hv2[b]) { a = std::min(a, zc[b]); b2 = std::max(b2, zc[b]); }
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "drum nb=%d wmax=%g H=%g stroke=%g rOut=%g rIn=%g\n", nb, wmax, H, b2 - a, rOut, rIn);
        if (b2 - a < std::max(1.5, 0.05 * H)) return false;
        std::sort(ws.begin(), ws.end()); gw = ws[ws.size() / 4]; (void)wsum; gdepth = rOut - rg; lo = a; hi = b2;
        for (int k = 0; k < NB; k++) { const int b = std::min(GB - 1, k / 3); have[k] = hv2[b]; hv[k] = zc[b] - z0; }
        lo -= z0; hi -= z0;
        notes.push_back(T("Leva de tambor: línea media z(θ) de la ranura sobre el cilindro desarrollado (z desde un extremo); θ antihorario visto desde +eje, 0° = eje X"));
        notes.push_back("Ø " + dEx + (rIn > 0 ? "; " + T("agujero") + " Ø " + dIn : "") + "; " + T("Longitud") + " = " + fmt(H) + "; " + T("Ancho de ranura") + " = " + fmt(gw) + "; " + T("Profundidad de ranura") + " = " + fmt(gdepth) + "; z mín = " + fmt(lo) + "; z máx = " + fmt(hi) + "; " + T("Carrera") + " = " + fmt(hi - lo));
    }
    std::string line, missing;
    const char* want[][2] = {{"Ley de movimiento del seguidor", "ley"}, {"Tipo de seguidor", "seguidor"}, {"Tolerancia del perfil", "tolperfil"}, {"Tratamiento", "tratamiento"}};
    for (auto& w : want) { const std::string v = userKey(meta, w[1]); if (v.empty()) missing += (missing.empty() ? "" : ", ") + T(w[0]); else line += (line.empty() ? "" : "; ") + T(w[0]) + ": " + v; }
    if (!line.empty()) notes.push_back(line);
    if (!missing.empty()) notes.push_back(T("No definidos en el STEP (indicar antes de fabricar)") + ": " + missing);

    // ---- hoja: vista frontal (eje vertical), desarrollo h/z(θ), tabla
    d = Drawing();
    d.groups = {T("Vista"), T("Desarrollo"), T("Tabla")};
    const double devW = 100;
    const Frame f = makeSheet(d, meta, 2 * rOut, H, 30 + devW + 30 + 96, 40, notes);
    const double s = f.s, cyc = 0.5 * (f.zy0 + f.zy1), vx = f.fx0 + 25 + s * rOut, y0 = cyc - 0.5 * s * H;
    Pos p0 = d.pos();
    ln(d, vx - s * rOut, y0, vx + s * rOut, y0, kThick); ln(d, vx - s * rOut, y0 + s * H, vx + s * rOut, y0 + s * H, kThick);
    ln(d, vx - s * rOut, y0, vx - s * rOut, y0 + s * H, kThick); ln(d, vx + s * rOut, y0, vx + s * rOut, y0 + s * H, kThick);
    if (rIn > 0) for (double sg : {1.0, -1.0}) ln(d, vx + sg * s * rIn, y0, vx + sg * s * rIn, y0 + s * H, 0.25, LineType::Hidden);
    ln(d, vx, y0 - 4, vx, y0 + s * H + 4, 0.18, LineType::Center);
    if (face) ln(d, vx - s * rOut, y0 + s * lo, vx + s * rOut, y0 + s * lo, 0.25, LineType::Hidden);
    dimH(d, vx - s * rOut, vx + s * rOut, y0, y0, y0 - 10, "Ø" + dEx, "diameter", 2 * rOut);
    if (rIn > 0) dimH(d, vx - s * rIn, vx + s * rIn, y0 + s * H, y0 + s * H, y0 + s * H + 10, "Ø" + dIn, "hole", 2 * rIn);
    dimV(d, y0, y0 + s * H, vx + s * rOut, vx + s * rOut, vx + s * rOut + 10, fmt(H), "length", H);
    d.tag(p0, 0);
    p0 = d.pos();
    const double dx0 = vx + s * rOut + 30, dsx = devW / 360.0;
    const double dTop = face ? hi : hi + 0.5 * gw, dBot = face ? 0 : std::max(0.0, lo - 0.5 * gw);
    (void)dTop; (void)dBot;
    ln(d, dx0, y0, dx0 + devW, y0, kThick); ln(d, dx0, y0 + s * H, dx0 + devW, y0 + s * H, kThick);
    ln(d, dx0, y0, dx0, y0 + s * H, kThick); ln(d, dx0 + devW, y0, dx0 + devW, y0 + s * H, kThick);
    for (int a = 0; a <= 360; a += 90) { ln(d, dx0 + a * dsx, y0, dx0 + a * dsx, y0 - 2); text(d, dx0 + a * dsx - 3, y0 - 6, 2.8, std::to_string(a) + "°"); }
    for (int k = 0; k < NB; k++) {
        const int k2 = (k + 1) % NB; if (k2 == 0 || !have[k] || !have[k2]) continue;
        if (face) ln(d, dx0 + k * dsx, y0 + s * hv[k], dx0 + k2 * dsx, y0 + s * hv[k2], kThick);
        else {
            ln(d, dx0 + k * dsx, y0 + s * hv[k], dx0 + k2 * dsx, y0 + s * hv[k2], 0.18, LineType::Center);
            ln(d, dx0 + k * dsx, y0 + s * (hv[k] + 0.5 * gw), dx0 + k2 * dsx, y0 + s * (hv[k2] + 0.5 * gw), kThick);
            ln(d, dx0 + k * dsx, y0 + s * (hv[k] - 0.5 * gw), dx0 + k2 * dsx, y0 + s * (hv[k2] - 0.5 * gw), kThick);
        }
    }
    text(d, dx0, y0 + s * H + 4, kTxt, T("Desarrollo") + (face ? " Ø" + fmt(2 * rm) : " Ø" + dEx));
    if (face) { dimV(d, y0, y0 + s * lo, dx0 + devW, dx0 + devW, dx0 + devW + 8, fmt(lo), "length", lo); dimV(d, y0 + s * lo, y0 + s * hi, dx0, dx0, dx0 - 8, fmt(hi - lo), "length", hi - lo); }
    else { dimV(d, y0 + s * lo, y0 + s * hi, dx0, dx0, dx0 - 8, fmt(hi - lo), "length", hi - lo); }
    d.tag(p0, 1);
    p0 = d.pos();
    const double tx0 = f.fx1 - 15 - 96, rowH = 4.8, ty1 = cyc + 0.5 * (12 * rowH + 14);
    text(d, tx0, ty1 + 3, kTxt, face ? T("Perfil: h en función de θ") : T("Perfil: z de la ranura en función de θ"));
    const int rows = 12;
    for (int col = 0; col < 2; col++) {
        const double x0 = tx0 + col * 50;
        ln(d, x0, ty1, x0 + 46, ty1); text(d, x0 + 2, ty1 - 5, 2.8, "θ [°]"); text(d, x0 + 26, ty1 - 5, 2.8, face ? "h [mm]" : "z [mm]"); ln(d, x0, ty1 - 7, x0 + 46, ty1 - 7);
        for (int r = 0; r < rows; r++) {
            const int deg = (col * rows + r) * 15;
            const double y = ty1 - 7 - (r + 1) * rowH;
            text(d, x0 + 2, y + 1.2, 2.8, std::to_string(deg)); text(d, x0 + 26, y + 1.2, 2.8, have[deg % 360] ? fmt(hv[deg % 360]) : "—");
        }
        ln(d, x0, ty1 - 7 - rows * rowH, x0 + 46, ty1 - 7 - rows * rowH);
        ln(d, x0 + 24, ty1, x0 + 24, ty1 - 7 - rows * rowH);
        ln(d, x0, ty1, x0, ty1 - 7 - rows * rowH); ln(d, x0 + 46, ty1, x0 + 46, ty1 - 7 - rows * rowH);
    }
    d.tag(p0, 2);
    if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "CAM3D %s\n", face ? "cara" : "tambor");
    finish(d, meta, "cam");
    return true;
}

// ================================================================== TUBO CURVADO (G13)
// Línea media sacada de los cilindros y toros exteriores; tabla de curvado (recta, ángulo, rotación, radio) y coordenadas de los vértices (ISO 129-1 §8.5.1).
namespace {
struct PEl { bool arc; gp_Pnt a, b, c; gp_Vec n, ta, tb; double R = 0, ang = 0; };
double angOf(const gp_Vec& u, const gp_Vec& v, const gp_Vec& ax) { return std::atan2(u.Crossed(v).Dot(ax), u.Dot(v)); }
}
bool layoutPipe(const std::string& path, const Meta& meta, Drawing& d, bool cable) {
    gL = meta.lang;
    TopoDS_Shape S;
    if (!readShape(path, S)) return fail(__LINE__);
    // ---- radios: exterior = el de mayor área entre los grandes; interior = el siguiente menor
    std::map<long long, double> areaR;   // radio (µm) -> área
    auto key = [](double r) { return (long long)std::llround(r * 1000); };
    std::vector<TopoDS_Face> faces;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face f = TopoDS::Face(ex.Current()); BRepAdaptor_Surface sf(f);
        double r = 0;
        if (sf.GetType() == GeomAbs_Cylinder) r = sf.Cylinder().Radius(); else if (sf.GetType() == GeomAbs_Torus) r = sf.Torus().MinorRadius(); else continue;
        GProp_GProps g; BRepGProp::SurfaceProperties(f, g);
        areaR[key(r)] += g.Mass(); faces.push_back(f);
    }
    if (areaR.empty()) return fail(__LINE__);
    double amax = 0; for (auto& kv : areaR) amax = std::max(amax, kv.second);
    double Ro = 0; for (auto& kv : areaR) if (kv.second >= 0.3 * amax) Ro = std::max(Ro, kv.first / 1000.0);
    double Ri = 0; for (auto& kv : areaR) { const double r = kv.first / 1000.0; if (r < 0.98 * Ro && kv.second >= 0.05 * amax) Ri = std::max(Ri, r); }
    const double tol = std::max(1e-4, 0.02 * Ro);
    std::vector<gp_Pnt> extraC; double extraA = 0;   // caras que no son tubo liso: solo se admiten en los extremos (conformados), se avisa
    {   // todo lo que no sea tubo liso (bridas, abocardados, taladros, conos, tuercas): este motor no lo dibujaría → el motor general lo trata
        double ext = 0, tot = 0; int endPl = 0;
        const double aEnd = kPi * (Ro * Ro - Ri * Ri) * 1.05;
        for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
            TopoDS_Face f = TopoDS::Face(ex.Current()); BRepAdaptor_Surface sf(f);
            GProp_GProps g; BRepGProp::SurfaceProperties(f, g); const double a = g.Mass(); tot += a;
            double r = -1; if (sf.GetType() == GeomAbs_Cylinder) r = sf.Cylinder().Radius(); else if (sf.GetType() == GeomAbs_Torus) r = sf.Torus().MinorRadius();
            if (r > 0 && (std::fabs(r - Ro) < 0.01 * Ro || (Ri > 0 && std::fabs(r - Ri) < 0.01 * Ri))) continue;
            if (sf.GetType() == GeomAbs_Plane && a <= aEnd && endPl < 2) { endPl++; continue; }
            ext += a; { GProp_GProps gc; BRepGProp::SurfaceProperties(f, gc); extraC.push_back(gc.CentreOfMass()); }
        }
        extraA = ext;
        if (ext > 0.6 * tot) return fail(__LINE__);
    }
    // ---- piezas de la línea media
    std::vector<PEl> el;
    for (auto& f : faces) {
        BRepAdaptor_Surface sf(f);
        TopTools_IndexedMapOfShape vm; TopExp::MapShapes(f, TopAbs_VERTEX, vm);
        std::vector<gp_Pnt> vs; for (int i = 1; i <= vm.Extent(); i++) vs.push_back(BRep_Tool::Pnt(TopoDS::Vertex(vm(i))));
        if (vs.size() < 2) continue;
        PEl e{};
        if (sf.GetType() == GeomAbs_Cylinder) {
            gp_Cylinder cy = sf.Cylinder(); if (std::fabs(cy.Radius() - Ro) > 0.01 * Ro) continue;
            gp_Pnt o = cy.Location(); gp_Vec z(cy.Axis().Direction());
            double t0 = 1e18, t1 = -1e18; for (auto& q : vs) { const double t = gp_Vec(o, q).Dot(z); t0 = std::min(t0, t); t1 = std::max(t1, t); }
            if (t1 - t0 < 1e-6) continue;
            e.arc = false; e.a = o.Translated(z * t0); e.b = o.Translated(z * t1);
        } else {
            gp_Torus to = sf.Torus(); if (std::fabs(to.MinorRadius() - Ro) > 0.01 * Ro && !(to.MinorRadius() >= 0.5 * Ro && to.MinorRadius() <= 1.01 * Ro && to.MajorRadius() >= to.MinorRadius())) continue;   // codos de racor: la curva puede tener otra sección que los enchufes
            gp_Pnt c = to.Location(); gp_Vec n(to.Axis().Direction()), x0(to.XAxis().Direction()), y0 = n.Crossed(x0);
            std::vector<double> th;
            for (auto& q : vs) { gp_Vec w(c, q); w -= n * w.Dot(n); if (w.Magnitude() < 1e-9) continue; th.push_back(std::atan2(w.Dot(y0), w.Dot(x0))); }
            if (th.size() < 2) continue;
            std::sort(th.begin(), th.end());
            double gap = th[0] + 2 * kPi - th.back(), gs = th.back(); int gi = (int)th.size() - 1;
            for (size_t i = 0; i + 1 < th.size(); i++) if (th[i + 1] - th[i] > gap) { gap = th[i + 1] - th[i]; gs = th[i]; gi = (int)i; }
            const double t0 = th[(gi + 1) % th.size()], span = 2 * kPi - gap;
            if (span < 1e-4) continue;
            const double R = to.MajorRadius();
            auto at = [&](double t) { return c.Translated((x0 * std::cos(t) + y0 * std::sin(t)) * R); };
            e.arc = true; e.c = c; e.n = n; e.R = R; e.ang = span; e.a = at(t0); e.b = at(t0 + span); (void)gs;
        }
        bool dup = false;
        for (auto& o : el) if (o.arc == e.arc && ((o.a.Distance(e.a) < tol && o.b.Distance(e.b) < tol) || (o.a.Distance(e.b) < tol && o.b.Distance(e.a) < tol))) dup = true;
        if (!dup) el.push_back(e);
    }
    if (el.size() < 1 || el.size() > 60) return fail(__LINE__);
    auto flip = [](PEl& e) { std::swap(e.a, e.b); if (e.arc) e.n.Reverse(); };
    auto dirOf = [](const PEl& e) { return gp_Vec(e.a, e.b).Normalized(); };
    // ---- fusionar piezas contiguas del mismo tipo (caras partidas)
    for (bool ch = true; ch;) {
        ch = false;
        for (size_t i = 0; i < el.size() && !ch; i++) for (size_t j = 0; j < el.size() && !ch; j++) {
            if (i == j || el[i].arc != el[j].arc) continue;
            PEl A = el[i], B = el[j];
            for (int k = 0; k < 4 && !ch; k++) {
                if (k == 1) flip(A); else if (k == 2) flip(B); else if (k == 3) flip(A);
                if (A.b.Distance(B.a) > tol) {   // hueco tapado por un anillo/virola (cara fuera del tubo liso): se puentea si es la misma recta
                    const double g = A.b.Distance(B.a); const gp_Pnt M((A.b.XYZ() + B.a.XYZ()) * 0.5);
                    bool ring = false; for (auto& c : extraC) ring |= c.Distance(M) <= g;
                    if (A.arc || !ring || g > 4 * Ro + 12 || dirOf(A).Dot(gp_Vec(A.b, B.a).Normalized()) < 0.99999 || dirOf(A).Dot(dirOf(B)) < 0.99999) continue;
                }
                if (!A.arc) { if (dirOf(A).Dot(dirOf(B)) < 0.99999) continue; PEl m = A; m.b = B.b; el[i] = m; }
                else { if (A.c.Distance(B.c) > tol || std::fabs(A.n.Dot(B.n)) < 0.99999 || A.n.Dot(B.n) < 0) continue; PEl m = A; m.b = B.b; m.ang = A.ang + B.ang; el[i] = m; }
                el.erase(el.begin() + j); ch = true;
            }
        }
    }
    if (std::getenv("DIEDRO_PIPE")) for (auto& e : el) std::printf("PIEZA %s a=%g,%g,%g b=%g,%g,%g R=%g\n", e.arc ? "arco" : "recta", e.a.X(), e.a.Y(), e.a.Z(), e.b.X(), e.b.Y(), e.b.Z(), e.R);
    // ---- encadenar desde un extremo libre (un hueco recto y colineal entre piezas —escalón de un enchufe— se puentea)
    const size_t N = el.size();
    auto ends = [&](size_t i, int k) { return k ? el[i].b : el[i].a; };
    auto outDir = [&](size_t i, int k) {
        const PEl& e = el[i];
        if (!e.arc) { gp_Vec d = dirOf(e); return k ? d : -d; }
        return k ? e.n.Crossed(gp_Vec(e.c, e.b)).Normalized() : -e.n.Crossed(gp_Vec(e.c, e.a)).Normalized();
    };
    // siguiente pieza más allá de un extremo: j,m; g = hueco (0 si se tocan)
    auto nextOf = [&](const gp_Pnt& tip, const gp_Vec& d, size_t self, const std::vector<char>& u, int& fj, int& fm, double& fg) {
        fj = -1; double best = 1e18;
        for (size_t j = 0; j < N; j++) if (j != self && !u[j]) for (int m = 0; m < 2; m++) {
            gp_Vec w(tip, ends(j, m)); const double g = w.Magnitude();
            bool ok = g < tol;
            if (!ok && g <= 4 * Ro + 12 && !extraC.empty()) { const double al = w.Dot(d); ok = al > 0 && (w - d * al).Magnitude() < tol; if (ok) { const gp_Vec dj = outDir(j, m); ok = dj.Dot(d) < -0.999; } }
            if (ok && g < best) { best = g; fj = (int)j; fm = m; fg = g; }
        }
        return fj >= 0;
    };
    int start = -1, startK = 0;
    { std::vector<char> none(N, 0);
      for (size_t i = 0; i < N && start < 0; i++) for (int k = 0; k < 2 && start < 0; k++) {
        int fj, fm; double fg; if (!nextOf(ends(i, k), outDir(i, k), i, none, fj, fm, fg)) { start = (int)i; startK = k; }
      } }
    if (start < 0) return fail(__LINE__);
    std::vector<PEl> ch; std::vector<char> used(N, 0);
    { PEl e = el[start]; if (startK == 1) flip(e); ch.push_back(e); used[start] = 1; }
    for (;;) {
        const gp_Pnt tip = ch.back().b; const gp_Vec dtip = ch.back().arc ? ch.back().n.Crossed(gp_Vec(ch.back().c, ch.back().b)).Normalized() : dirOf(ch.back());
        int fj, fm; double fg; std::vector<char> u2 = used;
        // la pieza actual cuenta como usada
        if (!nextOf(tip, dtip, (size_t)-1, u2, fj, fm, fg)) break;
        if (fg >= tol) { PEl x; x.arc = false; x.n = gp_Vec(0, 0, 1); x.c = tip; x.a = tip; x.b = ends(fj, fm); ch.push_back(x); }
        PEl e = el[fj]; if (fm == 1) flip(e); ch.push_back(e); used[fj] = 1;
    }
    for (size_t j = 0; j < N; j++) if (!used[j]) return fail(__LINE__);
    for (auto& e : ch) { if (e.arc) { e.ta = e.n.Crossed(gp_Vec(e.c, e.a)).Normalized(); e.tb = e.n.Crossed(gp_Vec(e.c, e.b)).Normalized(); } else e.ta = e.tb = dirOf(e); }
    {   // enchufes/abocardados en los extremos (codos de PVC, racores): la línea media se prolonga recta hasta el extremo de la pieza
        std::vector<gp_Pnt> vp; for (TopExp_Explorer ex(S, TopAbs_VERTEX); ex.More(); ex.Next()) vp.push_back(BRep_Tool::Pnt(TopoDS::Vertex(ex.Current())));
        for (int side = 0; side < 2; side++) {
            const gp_Pnt tip = side ? ch.back().b : ch.front().a; gp_Vec d = side ? ch.back().tb : -ch.front().ta;
            double ext = 0; for (auto& q : vp) { gp_Vec w(tip, q); const double u = w.Dot(d); if ((w - d * u).Magnitude() < 2 * Ro) ext = std::max(ext, u); }
            if (ext < 4 * tol) continue;
            PEl x; x.arc = false; x.n = gp_Vec(0, 0, 1); x.ang = 0; x.c = tip; x.R = 0;
            const gp_Pnt far = tip.Translated(d * ext);
            if (side) { x.a = tip; x.b = far; x.ta = x.tb = d; ch.push_back(x); } else { x.a = far; x.b = tip; x.ta = x.tb = -d; ch.insert(ch.begin(), x); }
        }
    }
    for (size_t i = 0; i + 1 < ch.size(); i++) if (ch[i].tb.Dot(ch[i + 1].ta) < 0.9990) return fail(__LINE__);   // no es tangente continua (bridas, codos con cambio de sección…)
    // ---- tabla de curvado
    struct Bend { double L, ang, rot, R; };
    std::vector<Bend> bd; std::vector<gp_Pnt> V; std::vector<double> Ls;
    const gp_Pnt P0 = ch.front().a;
    V.push_back(P0);
    double Lcur = 0, dev = 0; gp_Vec prevN, prevD; bool first = true;
    for (auto& e : ch) {
        if (!e.arc) { const double l = e.a.Distance(e.b); Lcur += l; dev += l; continue; }
        if (e.ang > 170 * kPi / 180) return fail(__LINE__);
        double rot = 0;
        if (!first) { double r = angOf(prevN, e.n, e.ta); if (r < 0) r += 2 * kPi; if (r > 2 * kPi - 1e-4) r = 0; rot = r; }
        bd.push_back({Lcur, e.ang, rot, e.R});
        V.push_back(e.a.Translated(e.ta * (e.R * std::tan(e.ang / 2))));
        dev += e.R * e.ang; Lcur = 0; prevN = e.n; first = false;
    }
    const double Llast = Lcur; V.push_back(ch.back().b);
    if (std::getenv("DIEDRO_PIPE")) { for (auto& b : bd) std::printf("CURVA %g %g %g %g\n", b.L, b.ang * 180 / kPi, b.rot * 180 / kPi, b.R); std::printf("FIN %g\n", Llast); for (auto& q : V) std::printf("VERT %g %g %g\n", q.X() - P0.X(), q.Y() - P0.Y(), q.Z() - P0.Z()); }
    if (bd.empty()) return fail(__LINE__);
    for (auto& c : extraC) if (c.Distance(P0) > 4 * Ro + 12 && c.Distance(ch.back().b) > 4 * Ro + 12) return fail(__LINE__);   // fuera de los extremos: no es un tubo con conformado
    // ---- extensión de la línea media
    std::vector<gp_Pnt> poly;
    for (auto& e : ch) {
        if (!e.arc) { poly.push_back(e.a); poly.push_back(e.b); continue; }
        const gp_Vec x0(e.c, e.a), y0 = e.n.Crossed(x0);
        for (int k = 0; k <= 24; k++) { const double t = e.ang * k / 24; poly.push_back(e.c.Translated(x0 * std::cos(t) + y0 * std::sin(t))); }
    }
    double lo[3] = {1e18, 1e18, 1e18}, hi[3] = {-1e18, -1e18, -1e18};
    for (auto& q : poly) { const double c[3] = {q.X(), q.Y(), q.Z()}; for (int i = 0; i < 3; i++) { lo[i] = std::min(lo[i], c[i]); hi[i] = std::max(hi[i], c[i]); } }
    int ord[3] = {0, 1, 2};
    std::sort(ord, ord + 3, [&](int a, int b) { return hi[a] - lo[a] > hi[b] - lo[b]; });
    auto axis = [&](int i) { return gp_Vec(i == 0, i == 1, i == 2); };
    const gp_Vec eh = axis(ord[0]), ev = axis(ord[1]), et = eh.Crossed(ev);
    const bool planar = (hi[ord[2]] - lo[ord[2]]) < 0.5 * 2 * Ro;
    // ---- vistas (HLR, solo aristas vistas; el taladro oculto no se dibuja)
    struct VW { std::vector<std::array<double, 4>> L; double u0 = 1e18, u1 = -1e18, w0 = 1e18, w1 = -1e18; gp_Vec N, X, Y; };
    auto mkView = [&](const gp_Vec& N, const gp_Vec& X) {
        VW v; v.N = N; v.X = X; v.Y = N.Crossed(X);
        HLRAlgo_Projector pr(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(N), gp_Dir(X)));
        Handle(HLRBRep_Algo) alg = new HLRBRep_Algo(); alg->Add(S); alg->Projector(pr); alg->Update(); alg->Hide();
        HLRBRep_HLRToShape h(alg);
        for (const TopoDS_Shape& c : {h.VCompound(), h.OutLineVCompound()}) {
            if (c.IsNull()) continue;
            for (TopExp_Explorer ex(c, TopAbs_EDGE); ex.More(); ex.Next()) {
                BRepAdaptor_Curve cu(TopoDS::Edge(ex.Current()));
                GCPnts_QuasiUniformDeflection q(cu, std::max(0.01, Ro * 0.004));
                if (!q.IsDone()) continue;
                for (int i = 1; i < q.NbPoints(); i++) { gp_Pnt a = q.Value(i), b = q.Value(i + 1); v.L.push_back({a.X(), a.Y(), b.X(), b.Y()}); }
            }
        }
        if (v.L.empty()) return v;
        for (auto& l : v.L) for (int k = 0; k < 2; k++) { v.u0 = std::min(v.u0, l[2 * k]); v.u1 = std::max(v.u1, l[2 * k]); v.w0 = std::min(v.w0, l[2 * k + 1]); v.w1 = std::max(v.w1, l[2 * k + 1]); }
        return v;
    };
    std::vector<VW> vw;
    vw.push_back(mkView(et, eh));                    // principal: eh horizontal, ev vertical
    if (!planar) { vw.push_back(mkView(ev, eh)); vw.push_back(mkView(eh.Reversed(), et)); }   // planta debajo, perfil izquierdo a la derecha
    for (auto& v : vw) if (v.L.empty()) return fail(__LINE__);
    // ---- notas
    std::vector<std::string> notes;
    const bool hollow = Ri > 0;
    double Rm = bd[0].R; bool sameR = true; for (auto& b : bd) if (std::fabs(b.R - Rm) > 0.01 * Rm) sameR = false;
    notes.push_back((cable ? T("Cable/hilo") : hollow ? T("Tubo curvado") : T("Barra curvada")) + " Ø" + fmt(2 * Ro) + (hollow ? " × " + fmt(Ro - Ri) : "") + (hollow ? " (" + T("Ø exterior × pared") + ")" : "") + "; " + std::to_string(bd.size()) + " " + T("curvas") + (sameR ? "; R = " + fmt(Rm) + " (" + T("a eje") + ")" : ""));
    notes.push_back(T("Longitud desarrollada (eje)") + " = " + fmt(dev) + " (" + T("medida") + ")");
    if (cable) {
        notes.push_back(T("Tolerancia de longitud: la de la documentación de ingeniería; si no, IPC/WHMA-A-620E Tabla 11-1"));
        double rmin = 1e18; for (auto& e : el) if (e.arc && e.R > 0) rmin = std::min(rmin, e.R);
        if (rmin < 5 * 2 * Ro) notes.push_back(T("AVISO: radio de curvado del eje") + " " + fmt(rmin) + " < 5×Ø = " + fmt(10 * Ro) + " (IPC/WHMA-A-620E Tabla 14-1, " + T("valor de referencia; comprobar con el tipo de cable") + ")");
    }
    if (!extraC.empty()) notes.push_back(T("NO ACOTADO: conformado de los extremos (abocardado, anillo, rosca); la longitud del eje es la del tubo liso"));
    notes.push_back(T("Origen de coordenadas en el extremo 1 (ISO 129-1, 8.5.1); rotación entre planos de curvado mirando del extremo 1 al 2, la primera curva es la referencia"));
    if (cable) { std::string miss = userKey(meta, "datoscable"); notes.push_back(miss.empty() ? T("No definidos en el STEP (indicar antes de fabricar)") + ": " + T("Sección del conductor, número de hilos, aislamiento, color, terminales y conectores (pines)") : miss); }
    else { std::string miss = userKey(meta, "tolcurvado"); if (miss.empty()) notes.push_back(T("No definidos en el STEP (indicar antes de fabricar)") + ": " + T("Tolerancias de longitud y de ángulo, ovalización, acabado de los extremos")); else notes.push_back(T("Tolerancias de curvado") + ": " + miss); }
    // ---- hoja
    d = Drawing();
    d.groups = {T("Vista"), T("Planta"), T("Vista desde la izquierda"), T(cable ? "Sección del cable" : "Sección del tubo")};
    const double wA = vw[0].u1 - vw[0].u0, hA = vw[0].w1 - vw[0].w0;
    const double tabW = 104, nVr = (double)V.size() + 1, nBr = (double)bd.size() + 3;
    double needW = wA, needH = hA;
    if (!planar) { needW += (vw[2].u1 - vw[2].u0); needH += (vw[1].w1 - vw[1].w0); }
    const Frame f = makeSheet(d, meta, needW, needH, tabW + 55, planar ? 35 : 50, notes, 0.1);
    const double s = f.s;
    const double zl = f.fx0 + 30, zr = f.fx1 - tabW - 25, zb = f.zy0 - (planar ? 17 : 25), zt = f.zy1 + (planar ? 17 : 25);
    const double gap = 25;
    const double totW = s * needW + (planar ? 0 : gap), totH = s * needH + (planar ? 0 : gap);
    double X0 = zl + std::max(0.0, (zr - zl - totW) / 2), Ytop = zt - std::max(0.0, (zt - zb - totH) / 2);
    std::vector<std::function<void()>> pend;   // números de vértice: se colocan al final, con las cotas ya dibujadas
    auto drawView = [&](const VW& v, double bx, double by, int grp) {   // (bx,by): esquina inferior izquierda
        Pos p0 = d.pos();
        auto sx = [&](double u) { return bx + s * (u - v.u0); }; auto sy = [&](double w) { return by + s * (w - v.w0); };
        for (auto& l : v.L) ln(d, sx(l[0]), sy(l[1]), sx(l[2]), sy(l[3]), kThick);
        auto proj = [&](const gp_Pnt& q, double& x, double& y) { gp_Vec w(gp_Pnt(0, 0, 0), q); x = sx(w.Dot(v.X)); y = sy(w.Dot(v.Y)); };
        for (size_t i = 0; i + 1 < poly.size(); i++) { double x1, y1, x2, y2; proj(poly[i], x1, y1); proj(poly[i + 1], x2, y2); if (std::hypot(x2 - x1, y2 - y1) > 0.05) ln(d, x1, y1, x2, y2, 0.18, LineType::Center); }
        {   // vértices: los que caen en el mismo punto de esta vista comparten marca y número («2,3»); el número va en el cuadrante libre de líneas y de otros números
            std::vector<std::array<double, 4>> segs;   // líneas de la vista: perfil y eje
            for (auto& l : v.L) segs.push_back({sx(l[0]), sy(l[1]), sx(l[2]), sy(l[3])});
            for (size_t i = 0; i + 1 < poly.size(); i++) { double x1, y1, x2, y2; proj(poly[i], x1, y1); proj(poly[i + 1], x2, y2); segs.push_back({x1, y1, x2, y2}); }
            struct Mk { double x, y; std::string t; };
            std::vector<Mk> mk;
            for (size_t i = 0; i < V.size(); i++) {
                double x, y; proj(V[i], x, y);
                bool found = false;
                for (auto& m : mk) if (std::hypot(m.x - x, m.y - y) < 1.2) { m.t += "," + std::to_string(i + 1); found = true; break; }
                if (!found) mk.push_back({x, y, std::to_string(i + 1)});
            }
            pend.push_back([=, &d]() mutable {
            std::vector<std::array<double, 4>> used;   // cajas de texto ya puestas
            auto hit = [&](double bx0, double by0, double bx1, double by1) {
                for (auto& u : used) if (bx0 < u[2] && bx1 > u[0] && by0 < u[3] && by1 > u[1]) return true;
                for (auto& g : segs) {
                    const double len = std::hypot(g[2] - g[0], g[3] - g[1]); const int n = std::max(1, (int)(len / 0.4));
                    for (int k = 0; k <= n; k++) { const double px = g[0] + (g[2] - g[0]) * k / n, py = g[1] + (g[3] - g[1]) * k / n; if (px > bx0 && px < bx1 && py > by0 && py < by1) return true; }
                }
                for (auto& l : d.lines) {   // cotas y líneas de referencia ya dibujadas
                    if (std::min(l.x1, l.x2) > bx1 || std::max(l.x1, l.x2) < bx0 || std::min(l.y1, l.y2) > by1 || std::max(l.y1, l.y2) < by0) continue;
                    const double len = std::hypot(l.x2 - l.x1, l.y2 - l.y1); const int n = std::max(1, (int)(len / 0.4));
                    for (int k = 0; k <= n; k++) { const double px = l.x1 + (l.x2 - l.x1) * k / n, py = l.y1 + (l.y2 - l.y1) * k / n; if (px > bx0 && px < bx1 && py > by0 && py < by1) return true; }
                }
                return false;
            };
            for (auto& m : mk) {
                const double r = 1.6; ln(d, m.x - r, m.y, m.x + r, m.y, 0.18); ln(d, m.x, m.y - r, m.x, m.y + r, 0.18);
                const double tw = 1.9 * m.t.size() + 0.4, th = 3.0;
                double bestX = m.x + 1.8, bestY = m.y + 1.8; bool ok = false;
                for (double rad : {1.8, 3.2, 4.8}) {
                    const double offs[8][2] = {{1, 1}, {-1, 1}, {1, -1}, {-1, -1}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}};
                    for (auto& o : offs) {
                        const double tx = o[0] > 0 ? m.x + rad : (o[0] < 0 ? m.x - rad - tw : m.x - tw / 2), ty = o[1] > 0 ? m.y + rad : (o[1] < 0 ? m.y - rad - th : m.y - th / 2);
                        if (!hit(tx, ty, tx + tw, ty + th)) { bestX = tx; bestY = ty; ok = true; break; }
                    }
                    if (ok) break;
                }
                used.push_back({bestX, bestY, bestX + tw, bestY + th});
                text(d, bestX, bestY, 3.0, m.t);
            }
            });
        }
        d.tag(p0, grp);
    };
    const double bxA = X0, byA = Ytop - s * hA;
    drawView(vw[0], bxA, byA, 0);
    dimH(d, bxA, bxA + s * wA, byA + s * hA, byA + s * hA, byA + s * hA + 10, fmt(wA), "length", wA);
    dimV(d, byA, byA + s * hA, bxA, bxA, bxA - 12, fmt(hA), "length", hA);
    if (!planar) {
        const double hB = vw[1].w1 - vw[1].w0, wC = vw[2].u1 - vw[2].u0, hC = vw[2].w1 - vw[2].w0;
        const double byB = byA - gap - s * hB, bxC = bxA + s * wA + gap;
        drawView(vw[1], bxA, byB, 1);
        dimV(d, byB, byB + s * hB, bxA, bxA, bxA - 12, fmt(hB), "length", hB);
        drawView(vw[2], bxC, byA + s * hA - s * hC, 2);
        dimH(d, bxC, bxC + s * wC, byA + s * hA, byA + s * hA, byA + s * hA + 10, fmt(wC), "length", wC);
    }
    for (auto& fn : pend) fn();
    // ---- sección transversal del tubo (escala propia) y tablas
    const double tx0 = f.fx1 - tabW - 8;
    double ty = f.zy1 + (planar ? 17 : 25) + 0;   // borde superior disponible
    Pos p0 = d.pos();
    const double ss = std::min(4.0, 26.0 / (2 * Ro)), cxs = tx0 + 24, cys = ty - 16;
    d.arcs.push_back({cxs, cys, ss * Ro, 0, 360, LineType::Continuous, kThick});
    if (hollow) d.arcs.push_back({cxs, cys, ss * Ri, 0, 360, LineType::Continuous, kThick});
    centerCross(d, cxs, cys, ss * Ro + 3);
    dimH(d, cxs - ss * Ro, cxs + ss * Ro, cys - ss * Ro, cys - ss * Ro, cys - ss * Ro - 8, "Ø" + fmt(2 * Ro), "diameter", 2 * Ro);
    if (hollow) { d.dims.push_back({"diameter", 2 * Ri, "Ø" + fmt(2 * Ri)}); text(d, cxs + ss * Ro + 6, cys + 2, kTxt, "Ø" + fmt(2 * Ri)); text(d, cxs + ss * Ro + 6, cys - 3, 2.6, "(" + T("pared") + " " + fmt(Ro - Ri) + ")"); }
    text(d, tx0, cys + 15, 2.8, T(cable ? "Sección del cable" : "Sección del tubo") + " (" + scaleText(ss) + ")");
    d.tag(p0, 3);
    // tablas
    const double avail = (cys - ss * Ro - 14) - (f.zy0 - (planar ? 17 : 25));
    const double rowH = std::max(3.2, std::min(5.2, avail / (nVr + nBr + 2.5)));
    const double th = rowH > 4.2 ? 3.0 : 2.6;
    double y = cys - ss * Ro - 14;
    auto row = [&](double x0, const std::vector<std::string>& c, const std::vector<double>& w, bool hd) {
        double xx = x0; ln(d, x0, y, x0 + tabW, y, hd ? 0.35 : 0.18);
        for (size_t i = 0; i < c.size(); i++) { text(d, xx + 1.2, y - rowH + 0.9, th, c[i]); xx += w[i]; }
        y -= rowH; ln(d, x0, y, x0 + tabW, y, hd ? 0.35 : 0.18);
    };
    auto vbar = [&](double x0, const std::vector<double>& w, double ytop, double ybot) { double xx = x0; ln(d, xx, ytop, xx, ybot, 0.35); for (double ww : w) { xx += ww; ln(d, xx, ytop, xx, ybot, 0.18); } ln(d, x0 + tabW, ytop, x0 + tabW, ybot, 0.35); };
    auto cz = [](double v) { return std::fabs(v) < 0.005 ? 0.0 : v; };
    p0 = d.pos();
    {   // coordenadas de los vértices virtuales (cruce de ejes)
        const std::vector<double> w = {14, 30, 30, 30};
        text(d, tx0, y + 1, th, T("Vértices (intersección de ejes)")); const double yt = y;
        row(tx0, {"Pt", "X", "Y", "Z"}, w, true);
        for (size_t i = 0; i < V.size(); i++) row(tx0, {std::to_string(i + 1), fmt(cz(V[i].X() - P0.X())), fmt(cz(V[i].Y() - P0.Y())), fmt(cz(V[i].Z() - P0.Z()))}, w, false);
        vbar(tx0, w, yt, y);
    }
    y -= rowH * 1.6;
    {   // tabla de curvado
        const std::vector<double> w = {14, 24, 22, 22, 22};
        text(d, tx0, y + 1, th, T("Tabla de curvado")); const double yt = y;
        row(tx0, {"N.°", "L", "A [°]", "B [°]", "R"}, w, true);
        for (size_t i = 0; i < bd.size(); i++) row(tx0, {std::to_string(i + 1), fmt(bd[i].L), fmt1(bd[i].ang * 180 / kPi), fmt1(bd[i].rot * 180 / kPi), fmt(bd[i].R)}, w, false);
        row(tx0, {T("fin"), fmt(Llast), "", "", ""}, w, false);
        vbar(tx0, w, yt, y);
        text(d, tx0, y - 3.4, 2.5, "L: " + T("recta entre tangentes") + "; A: " + T("ángulo de curva") + "; B: " + T("rotación") + "; R: " + T("radio a eje"));
    }
    d.tag(p0, 3);
    finish(d, meta, "pipe");
    return true;
}

// G14: mazo ramificado (cilindros y toros del mismo Ø formando un árbol): nodos (extremos y empalmes) + ramales con longitud medida
bool layoutHarness(const std::string& path, const Meta& meta, Drawing& d) {
    gL = meta.lang;
    TopoDS_Shape S;
    if (!readShape(path, S)) return fail(__LINE__);
    std::map<long long, double> areaR; std::vector<TopoDS_Face> faces;
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face f = TopoDS::Face(ex.Current()); BRepAdaptor_Surface sf(f); double r;
        if (sf.GetType() == GeomAbs_Cylinder) r = sf.Cylinder().Radius(); else if (sf.GetType() == GeomAbs_Torus) r = sf.Torus().MinorRadius(); else if (sf.GetType() == GeomAbs_Plane) continue; else return fail(__LINE__);
        GProp_GProps g; BRepGProp::SurfaceProperties(f, g); areaR[(long long)std::llround(r * 1000)] += g.Mass(); faces.push_back(f);
    }
    if (areaR.empty()) return fail(__LINE__);
    double Ro = 0; for (auto& kv : areaR) Ro = std::max(Ro, kv.first / 1000.0);
    for (auto& kv : areaR) if (std::fabs(kv.first / 1000.0 - Ro) > 0.01 * Ro) return fail(__LINE__);   // un solo Ø de hilo
    const double tol = std::max(1e-4, 0.05 * Ro);
    std::vector<PEl> el;
    for (auto& f : faces) {
        BRepAdaptor_Surface sf(f);
        TopTools_IndexedMapOfShape vm; TopExp::MapShapes(f, TopAbs_VERTEX, vm);
        std::vector<gp_Pnt> vs; for (int i = 1; i <= vm.Extent(); i++) vs.push_back(BRep_Tool::Pnt(TopoDS::Vertex(vm(i))));
        if (vs.size() < 2) continue;
        PEl e{};
        if (sf.GetType() == GeomAbs_Cylinder) {
            gp_Cylinder cy = sf.Cylinder(); gp_Pnt o = cy.Location(); gp_Vec z(cy.Axis().Direction());
            double t0 = 1e18, t1 = -1e18; for (auto& q : vs) { const double t = gp_Vec(o, q).Dot(z); t0 = std::min(t0, t); t1 = std::max(t1, t); }
            if (t1 - t0 < 1e-6) continue;
            e.arc = false; e.a = o.Translated(z * t0); e.b = o.Translated(z * t1);
        } else {
            gp_Torus to = sf.Torus(); gp_Pnt c = to.Location(); gp_Vec n(to.Axis().Direction()), x0(to.XAxis().Direction()), y0 = n.Crossed(x0);
            std::vector<double> th;
            for (auto& q : vs) { gp_Vec w(c, q); w -= n * w.Dot(n); if (w.Magnitude() < 1e-9) continue; th.push_back(std::atan2(w.Dot(y0), w.Dot(x0))); }
            if (th.size() < 2) continue;
            std::sort(th.begin(), th.end());
            double gap = th[0] + 2 * kPi - th.back(); int gi = (int)th.size() - 1;
            for (size_t i = 0; i + 1 < th.size(); i++) if (th[i + 1] - th[i] > gap) { gap = th[i + 1] - th[i]; gi = (int)i; }
            const double t0 = th[(gi + 1) % th.size()], span = 2 * kPi - gap; if (span < 1e-4) continue;
            const double R = to.MajorRadius(); auto at = [&](double t) { return c.Translated((x0 * std::cos(t) + y0 * std::sin(t)) * R); };
            e.arc = true; e.c = c; e.n = n; e.R = R; e.ang = span; e.a = at(t0); e.b = at(t0 + span);
        }
        bool dup = false;
        for (auto& o : el) if (o.arc == e.arc && ((o.a.Distance(e.a) < tol && o.b.Distance(e.b) < tol) || (o.a.Distance(e.b) < tol && o.b.Distance(e.a) < tol))) dup = true;
        if (!dup) el.push_back(e);
    }
    if (el.empty() || el.size() > 80) return fail(__LINE__);
    auto flip = [](PEl& e) { std::swap(e.a, e.b); if (e.arc) e.n.Reverse(); };
    auto dirOf = [](const PEl& e) { return gp_Vec(e.a, e.b).Normalized(); };
    for (bool ch = true; ch;) {   // fusionar caras partidas del mismo tramo
        ch = false;
        for (size_t i = 0; i < el.size() && !ch; i++) for (size_t j = 0; j < el.size() && !ch; j++) {
            if (i == j || el[i].arc != el[j].arc) continue;
            PEl A = el[i], B = el[j];
            for (int k = 0; k < 4 && !ch; k++) {
                if (k == 1) flip(A); else if (k == 2) flip(B); else if (k == 3) flip(A);
                if (A.b.Distance(B.a) > tol) continue;
                if (!A.arc) { if (dirOf(A).Dot(dirOf(B)) < 0.99999) continue; PEl m = A; m.b = B.b; el[i] = m; }
                else { if (A.c.Distance(B.c) > tol || A.n.Dot(B.n) < 0.99999) continue; PEl m = A; m.b = B.b; m.ang = A.ang + B.ang; el[i] = m; }
                el.erase(el.begin() + j); ch = true;
            }
        }
    }
    // uniones de rectas por cruce de ejes: T (el extremo de una recta cae sobre otra) y esquinas vivas
    for (int it = 0; it < 200; it++) {
        bool done = true;
        for (size_t j = 0; j < el.size() && done; j++) for (size_t i = 0; i < el.size() && done; i++) {
            if (i == j || el[i].arc || el[j].arc) continue;
            const gp_Vec di = dirOf(el[i]), dj = dirOf(el[j]); const double sn = di.Crossed(dj).Magnitude(); if (sn < 0.15) continue;
            // cierre mínimo entre las rectas infinitas
            const gp_Vec w(el[i].a, el[j].a); const double dd = di.Dot(dj), den = 1 - dd * dd;
            const double u = (w.Dot(di) - dd * w.Dot(dj)) / den, t = (dd * w.Dot(di) - w.Dot(dj)) / den;
            const gp_Pnt P = el[i].a.Translated(di * u), Q = el[j].a.Translated(dj * t);
            if (P.Distance(Q) > 0.5 * Ro) continue;
            const gp_Pnt X((P.XYZ() + Q.XYZ()) * 0.5); const double lim = 4 * Ro / sn, Li = el[i].a.Distance(el[i].b), Lj = el[j].a.Distance(el[j].b);
            if (u > lim && u < Li - lim && t > lim && t < Lj - lim) {   // X: se cruzan por dentro; se parten las dos
                PEl ni = el[i], nj = el[j]; ni.a = X; nj.a = X; el[i].b = X; el[j].b = X; el.push_back(ni); el.push_back(nj); done = false; continue;
            }
            int kj = -1; if (el[j].a.Distance(X) < el[j].b.Distance(X)) { if (el[j].a.Distance(X) < lim && t < 0.5 * Lj) kj = 0; } else if (el[j].b.Distance(X) < lim && t > 0.5 * Lj) kj = 1;
            if (kj < 0 || u < -lim || u > Li + lim) continue;
            auto onArc = [&](const gp_Pnt& q) { for (auto& o : el) if (o.arc && (o.a.Distance(q) < tol || o.b.Distance(q) < tol)) return true; return false; };
            if (onArc(kj == 0 ? el[j].a : el[j].b)) continue;   // el extremo ya enlaza con un arco: no es una esquina viva
            const bool already = (kj == 0 ? el[j].a : el[j].b).Distance(X) < 1e-7;
            if (u > lim && u < Li - lim) { PEl nw = el[i]; nw.a = X; el[i].b = X; el.push_back(nw); (kj ? el[j].b : el[j].a) = X; done = false; }   // T: se parte la recta atravesada
            else { gp_Pnt& ei = u <= lim ? el[i].a : el[i].b; if (onArc(ei)) continue; const bool same = ei.Distance(X) < 1e-7 && already; if (same) continue; ei = X; (kj ? el[j].b : el[j].a) = X; done = false; }
        }
        if (done) break;
    }
    // nodos
    std::vector<gp_Pnt> nodes; std::vector<std::array<int, 2>> pn(el.size());
    auto nodeOf = [&](const gp_Pnt& q) { for (size_t i = 0; i < nodes.size(); i++) if (nodes[i].Distance(q) < tol) return (int)i; nodes.push_back(q); return (int)nodes.size() - 1; };
    for (size_t i = 0; i < el.size(); i++) { pn[i][0] = nodeOf(el[i].a); pn[i][1] = nodeOf(el[i].b); if (pn[i][0] == pn[i][1]) return fail(__LINE__); }
    std::vector<int> deg(nodes.size(), 0); for (auto& q : pn) { deg[q[0]]++; deg[q[1]]++; }
    if (std::getenv("DIEDRO_DBG")) for (size_t i = 0; i < el.size(); i++) std::fprintf(stderr, "el %zu %s %.3f,%.3f,%.3f -> %.3f,%.3f,%.3f\n", i, el[i].arc ? "arco" : "rec", el[i].a.X(), el[i].a.Y(), el[i].a.Z(), el[i].b.X(), el[i].b.Y(), el[i].b.Z());
    bool branched = false; for (int g : deg) branched |= g >= 3; if (!branched) return fail(__LINE__);
    // ramales: caminos entre nodos de grado ≠ 2
    struct Br { int n0, n1; double len; int bends; std::vector<gp_Pnt> poly; };
    std::vector<Br> brs; std::vector<char> used(el.size(), 0);
    auto walk = [&](int n0, size_t first) {
        Br b{n0, n0, 0, 0, {nodes[n0]}}; int cur = n0; size_t pi = first; gp_Vec lastT; bool hv = false;
        for (;;) {
            used[pi] = 1; PEl e = el[pi]; if (pn[pi][0] != cur) flip(e);
            const int nx = pn[pi][0] == cur ? pn[pi][1] : pn[pi][0];
            gp_Vec ta = e.arc ? e.n.Crossed(gp_Vec(e.c, e.a)).Normalized() : dirOf(e), tb = e.arc ? e.n.Crossed(gp_Vec(e.c, e.b)).Normalized() : dirOf(e);
            if (hv && lastT.Dot(ta) < 0.999) b.bends++;
            if (e.arc) { b.bends++; b.len += e.R * e.ang; const gp_Vec x0(e.c, e.a), y0 = e.n.Crossed(x0); for (int k = 1; k <= 24; k++) { const double t = e.ang * k / 24; b.poly.push_back(e.c.Translated(x0 * std::cos(t) + y0 * std::sin(t))); } }
            else { b.len += e.a.Distance(e.b); b.poly.push_back(e.b); }
            lastT = tb; hv = true; cur = nx;
            if (deg[cur] != 2) break;
            size_t nxt = (size_t)-1; for (size_t k = 0; k < el.size(); k++) if (!used[k] && (pn[k][0] == cur || pn[k][1] == cur)) { nxt = k; break; }
            if (nxt == (size_t)-1) break; pi = nxt;
        }
        b.n1 = cur; return b;
    };
    // el nodo 1 es un extremo libre; se numera por recorrido
    int root = -1; for (size_t i = 0; i < nodes.size(); i++) if (deg[i] == 1 && (root < 0 || nodes[i].X() < nodes[root].X() - 1e-9 || (std::fabs(nodes[i].X() - nodes[root].X()) < 1e-9 && nodes[i].Y() < nodes[root].Y() - 1e-9))) root = (int)i;
    if (root < 0) return fail(__LINE__);
    std::vector<int> order{root}, num(nodes.size(), -1); num[root] = 0;
    for (size_t qi = 0; qi < order.size(); qi++) {
        const int n = order[qi];
        for (size_t k = 0; k < el.size(); k++) if (!used[k] && (pn[k][0] == n || pn[k][1] == n)) {
            Br b = walk(n, k); brs.push_back(b);
            if (num[b.n1] < 0) { num[b.n1] = (int)order.size(); order.push_back(b.n1); }
        }
    }
    for (size_t k = 0; k < el.size(); k++) if (!used[k]) { if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "sin usar %zu/%zu nodos %zu pn %d-%d deg %d,%d\n", k, el.size(), nodes.size(), pn[k][0], pn[k][1], deg[pn[k][0]], deg[pn[k][1]]); return fail(__LINE__); }
    size_t nKey = 0; for (size_t i = 0; i < nodes.size(); i++) if (deg[i] != 2) nKey++;
    if (order.size() != nKey || brs.size() < 3 || brs.size() > 16) return fail(__LINE__);
    double tot = 0; for (auto& b : brs) tot += b.len;
    if (std::getenv("DIEDRO_PIPE")) { for (auto& b : brs) std::printf("RAMAL %d %d %g %d\n", num[b.n0] + 1, num[b.n1] + 1, b.len, b.bends); }
    // ---- vistas
    const gp_Pnt P0 = nodes[root];
    double lo[3] = {1e18, 1e18, 1e18}, hi[3] = {-1e18, -1e18, -1e18};
    for (auto& b : brs) for (auto& q : b.poly) { const double c[3] = {q.X(), q.Y(), q.Z()}; for (int i = 0; i < 3; i++) { lo[i] = std::min(lo[i], c[i]); hi[i] = std::max(hi[i], c[i]); } }
    int ord[3] = {0, 1, 2}; std::sort(ord, ord + 3, [&](int a, int b) { return hi[a] - lo[a] > hi[b] - lo[b]; });
    auto axis = [&](int i) { return gp_Vec(i == 0, i == 1, i == 2); };
    const gp_Vec eh = axis(ord[0]), ev = axis(ord[1]), et = eh.Crossed(ev);
    const bool planar = (hi[ord[2]] - lo[ord[2]]) < 0.5 * 2 * Ro + 1e-6;
    struct VW { std::vector<std::array<double, 4>> L; double u0 = 1e18, u1 = -1e18, w0 = 1e18, w1 = -1e18; gp_Vec N, X, Y; };
    auto mkView = [&](const gp_Vec& N, const gp_Vec& X) {
        VW v; v.N = N; v.X = X; v.Y = N.Crossed(X);
        HLRAlgo_Projector pr(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(N), gp_Dir(X)));
        Handle(HLRBRep_Algo) alg = new HLRBRep_Algo(); alg->Add(S); alg->Projector(pr); alg->Update(); alg->Hide();
        HLRBRep_HLRToShape h(alg);
        for (const TopoDS_Shape& c : {h.VCompound(), h.OutLineVCompound()}) {
            if (c.IsNull()) continue;
            for (TopExp_Explorer ex(c, TopAbs_EDGE); ex.More(); ex.Next()) {
                BRepAdaptor_Curve cu(TopoDS::Edge(ex.Current())); GCPnts_QuasiUniformDeflection q(cu, std::max(0.01, Ro * 0.004));
                if (!q.IsDone()) continue;
                for (int i = 1; i < q.NbPoints(); i++) { gp_Pnt a = q.Value(i), b = q.Value(i + 1); v.L.push_back({a.X(), a.Y(), b.X(), b.Y()}); }
            }
        }
        for (auto& l : v.L) for (int k = 0; k < 2; k++) { v.u0 = std::min(v.u0, l[2 * k]); v.u1 = std::max(v.u1, l[2 * k]); v.w0 = std::min(v.w0, l[2 * k + 1]); v.w1 = std::max(v.w1, l[2 * k + 1]); }
        return v;
    };
    std::vector<VW> vw; vw.push_back(mkView(et, eh));
    if (!planar) { vw.push_back(mkView(ev, eh)); vw.push_back(mkView(eh.Reversed(), et)); }
    for (auto& v : vw) if (v.L.empty()) return fail(__LINE__);
    // ---- notas
    std::vector<std::string> notes;
    notes.push_back(T("Mazo ramificado") + " Ø" + fmt(2 * Ro) + "; " + std::to_string(brs.size()) + " " + T("ramales") + ", " + std::to_string(order.size()) + " " + T("nodos"));
    notes.push_back(T("Longitud total de ramales (eje)") + " = " + fmt(tot) + " (" + T("medida") + ")");
    notes.push_back(T("Tolerancia de longitud de ramal: la de la documentación de ingeniería; si no, IPC/WHMA-A-620E Tabla 11-1"));
    { double rmin = 1e18; for (auto& e : el) if (e.arc && e.R > 0) rmin = std::min(rmin, e.R);
      if (rmin < 5 * 2 * Ro) notes.push_back(T("AVISO: radio de curvado del eje") + " " + fmt(rmin) + " < 5×Ø = " + fmt(10 * Ro) + " (IPC/WHMA-A-620E Tabla 14-1, " + T("valor de referencia; comprobar con el tipo de cable") + ")"); }
    notes.push_back(T("Origen de coordenadas en el extremo 1 (ISO 129-1, 8.5.1); rotación entre planos de curvado mirando del extremo 1 al 2, la primera curva es la referencia").substr(0, T("Origen de coordenadas en el extremo 1 (ISO 129-1, 8.5.1); rotación entre planos de curvado mirando del extremo 1 al 2, la primera curva es la referencia").find(';')));
    { std::string miss = userKey(meta, "datoscable"); notes.push_back(miss.empty() ? T("No definidos en el STEP (indicar antes de fabricar)") + ": " + T("Sección del conductor, número de hilos, aislamiento, color, terminales y conectores (pines)") : miss); }
    d = Drawing();
    d.groups = {T("Vista"), T("Planta"), T("Vista desde la izquierda"), T("Ramales")};
    const double wA = vw[0].u1 - vw[0].u0, hA = vw[0].w1 - vw[0].w0;
    const double tabW = 104, nVr = (double)nodes.size() + 1, nBr = (double)brs.size() + 2;
    double needW = wA, needH = hA;
    if (!planar) { needW += (vw[2].u1 - vw[2].u0); needH += (vw[1].w1 - vw[1].w0); }
    const Frame f = makeSheet(d, meta, needW, needH, tabW + 55, planar ? 35 : 50, notes, 0.1);
    const double s = f.s, zl = f.fx0 + 30, zr = f.fx1 - tabW - 25, zb = f.zy0 - (planar ? 17 : 25), zt = f.zy1 + (planar ? 17 : 25), gap = 25;
    const double totW = s * needW + (planar ? 0 : gap), totH = s * needH + (planar ? 0 : gap);
    double X0 = zl + std::max(0.0, (zr - zl - totW) / 2), Ytop = zt - std::max(0.0, (zt - zb - totH) / 2);
    std::vector<std::array<double, 4>> segs, usedBox;   // líneas dibujadas y cajas de texto puestas: los números de nodo buscan un hueco libre (se colocan al final, cuando ya están las cotas)
    std::vector<std::function<void()>> deferred;
    auto hitBox = [&](double bx0, double by0, double bx1, double by1) {
        for (auto& u : usedBox) if (bx0 < u[2] && bx1 > u[0] && by0 < u[3] && by1 > u[1]) return true;
        auto segHit = [&](double x1, double y1, double x2, double y2) {
            const double len = std::hypot(x2 - x1, y2 - y1); const int n = std::max(1, (int)(len / 0.4));
            for (int k = 0; k <= n; k++) { const double px = x1 + (x2 - x1) * k / n, py = y1 + (y2 - y1) * k / n; if (px > bx0 && px < bx1 && py > by0 && py < by1) return true; }
            return false;
        };
        for (auto& g : segs) if (segHit(g[0], g[1], g[2], g[3])) return true;
        for (auto& l : d.lines) if (l.g == 0 || true) { if (std::min(l.x1, l.x2) > bx1 || std::max(l.x1, l.x2) < bx0 || std::min(l.y1, l.y2) > by1 || std::max(l.y1, l.y2) < by0) continue; if (segHit(l.x1, l.y1, l.x2, l.y2)) return true; }
        return false;
    };
    auto drawView = [&](const VW& v, double bx, double by, int grp, bool lab) {
        Pos p0 = d.pos();
        auto sx = [&](double u) { return bx + s * (u - v.u0); }; auto sy = [&](double w) { return by + s * (w - v.w0); };
        for (auto& l : v.L) ln(d, sx(l[0]), sy(l[1]), sx(l[2]), sy(l[3]), kThick);
        auto proj = [&](const gp_Pnt& q, double& x, double& y) { gp_Vec w(gp_Pnt(0, 0, 0), q); x = sx(w.Dot(v.X)); y = sy(w.Dot(v.Y)); };
        for (auto& b : brs) for (size_t i = 0; i + 1 < b.poly.size(); i++) { double x1, y1, x2, y2; proj(b.poly[i], x1, y1); proj(b.poly[i + 1], x2, y2); if (std::hypot(x2 - x1, y2 - y1) > 0.05) ln(d, x1, y1, x2, y2, 0.18, LineType::Center); }
        // posiciones de nodo en la hoja y dirección media de sus ramales
        std::vector<double> npx(nodes.size()), npy(nodes.size()), dx(nodes.size(), 0), dy(nodes.size(), 0); double gx = 0, gy = 0;
        for (size_t i = 0; i < nodes.size(); i++) { proj(nodes[i], npx[i], npy[i]); gx += npx[i] / nodes.size(); gy += npy[i] / nodes.size(); }
        for (auto& b : brs) for (int e = 0; e < 2; e++) {
            if (b.poly.size() < 2) continue;
            double x1, y1, x2, y2; proj(e ? b.poly.back() : b.poly.front(), x1, y1); proj(e ? b.poly[b.poly.size() - 2] : b.poly[1], x2, y2);
            const double L = std::hypot(x2 - x1, y2 - y1); if (L > 1e-6) { dx[e ? b.n1 : b.n0] += (x2 - x1) / L; dy[e ? b.n1 : b.n0] += (y2 - y1) / L; }
        }
        for (auto& l : v.L) segs.push_back({sx(l[0]), sy(l[1]), sx(l[2]), sy(l[3])});
        for (auto& b : brs) for (size_t i = 0; i + 1 < b.poly.size(); i++) { double x1, y1, x2, y2; proj(b.poly[i], x1, y1); proj(b.poly[i + 1], x2, y2); segs.push_back({x1, y1, x2, y2}); }
        // ramales: etiqueta y cota (cota solo en la vista principal y si el ramal es recto y se ve en verdadera magnitud)
        for (size_t bi = 0; bi < brs.size() && lab; bi++) {
            auto& b = brs[bi]; if (b.poly.size() < 2) continue;
            double x1, y1, x2, y2; proj(b.poly.front(), x1, y1); proj(b.poly.back(), x2, y2);
            const double Lp = std::hypot(x2 - x1, y2 - y1), mx = 0.5 * (x1 + x2), my = 0.5 * (y1 + y2);
            const bool straight = b.bends == 0;
            double ux = Lp > 1e-6 ? (x2 - x1) / Lp : 1, uy = Lp > 1e-6 ? (y2 - y1) / Lp : 0, nx = -uy, ny = ux;
            const double sgn = (nx * (mx - gx) + ny * (my - gy)) >= -1e-9 ? 1 : -1;   // lado exterior
            if (straight && Lp >= 0.97 * s * b.len && Lp >= 10) {
                double off = sgn * 8; const double twd = textW(fmt(b.len), kTxt);
                if (Lp >= twd + 8) for (double o : {8.0, -8.0, 14.0, -14.0, 20.0, -20.0}) {   // lado/distancia con el texto libre de hilos
                    const double of = sgn * o, cx = mx + nx * of, cy = my + ny * of, hx = 0.5 * (std::fabs(ux) * twd + std::fabs(uy) * 3.5) + 0.5, hy = 0.5 * (std::fabs(uy) * twd + std::fabs(ux) * 3.5) + 0.5;
                    bool bad = hitBox(cx - hx, cy - hy, cx + hx, cy + hy);
                    for (int k = 1; !bad && k < 12; k++) { const double px = x1 + (x2 - x1) * k / 12 + nx * of, py = y1 + (y2 - y1) * k / 12 + ny * of; bad = hitBox(px - 0.4, py - 0.4, px + 0.4, py + 0.4); }   // ni la línea de cota cruza otra
                    if (!bad) { off = of; break; }
                }
                dimA(d, x1, y1, x2, y2, off, fmt(b.len), "length", b.len);
            }
            const bool dimmed = straight && Lp >= 0.97 * s * b.len && Lp >= 10;
            double lx, ly; if (straight) { lx = mx - sgn * nx * 3.6; ly = my - sgn * ny * 3.6; } else { proj(b.poly[b.poly.size() / 2], lx, ly); const double ex = lx - gx, ey = ly - gy, en = std::max(1e-6, std::hypot(ex, ey)); lx += 5 * ex / en; ly += 5 * ey / en; }
            std::string t = "R" + std::to_string(bi + 1); if (!dimmed) t += " L=" + fmt(b.len);   // longitud desarrollada del eje (ISO 129-1 §7.15, §7.6)
            const double tw = textW(t, 3.0), ox = (straight && std::fabs(nx) > 0.5) ? (-sgn * nx > 0 ? 2.0 : -tw - 2.0) : (straight ? -tw / 2 : (lx >= bx + s * 0 && lx > gx ? 0.0 : -tw));   // texto junto a la línea, no encima
            double qx = lx + ox, qy = ly - 1.0;
            if (hitBox(qx, qy, qx + tw, qy + 3.0)) {   // hilo o cota encima: se busca el hueco más cercano
                bool ok = false; double bd = 1e9;
                for (int ix = -2; ix <= 2; ix++) for (int iy = -3; iy <= 3; iy++) {
                    const double cx2 = qx + ix * (tw * 0.5 + 1.0), cy2 = qy + iy * 3.4, dd = std::hypot(ix * (tw * 0.5 + 1.0), iy * 3.4);
                    if (dd < bd && !hitBox(cx2, cy2, cx2 + tw, cy2 + 3.0)) { bd = dd; lx = cx2; ly = cy2 + 1.0; ok = true; }
                }
                if (ok) { qx = lx; qy = ly - 1.0; }
            }
            text(d, qx, qy, 3.0, t); usedBox.push_back({qx - 0.3, qy, qx + tw + 0.3, qy + 3.0});
        }
        // nodos: marca + número (los nodos que coinciden en esta vista comparten etiqueta «2/3»)
        deferred.push_back([=, &d, &order, &usedBox, &hitBox]() {
        std::vector<char> merged(order.size(), 0);
        for (size_t i = 0; i < order.size(); i++) {
            if (merged[i]) continue; const int ni = order[i]; std::string t = std::to_string(i + 1); int grp3 = 0;
            for (size_t j = i + 1; j < order.size(); j++) if (std::hypot(npx[order[j]] - npx[ni], npy[order[j]] - npy[ni]) < 3.0) { merged[j] = 1; t += "/" + std::to_string(j + 1); ++grp3; }
            const double r = 1.6, x = npx[ni], y = npy[ni]; ln(d, x - r, y, x + r, y, 0.18); ln(d, x, y - r, x, y + r, 0.18);
            double vx = -dx[ni], vy = -dy[ni]; const double vn = std::hypot(vx, vy); if (vn > 0.3) { vx /= vn; vy /= vn; } else { vx = 0.7; vy = -0.7; }
            if (grp3 <= 1) {
                const double tw = textW(t, 3.0) + 0.4, th = 3.0; double bx0 = x + vx * 5.0 - tw / 2, by0 = y + vy * 5.0 - 1.0;
                if (hitBox(bx0, by0, bx0 + tw, by0 + th)) {
                    const double offs[8][2] = {{1, 1}, {-1, 1}, {1, -1}, {-1, -1}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}}; bool ok = false;
                    for (double rad : {2.2, 3.6, 5.2}) { for (auto& o : offs) {
                        const double tx = o[0] > 0 ? x + rad : (o[0] < 0 ? x - rad - tw : x - tw / 2), ty = o[1] > 0 ? y + rad : (o[1] < 0 ? y - rad - th : y - th / 2);
                        if (!hitBox(tx, ty, tx + tw, ty + th)) { bx0 = tx; by0 = ty; ok = true; break; } } if (ok) break; }
                }
                usedBox.push_back({bx0, by0, bx0 + tw, by0 + th}); text(d, bx0, by0, 3.0, t);
            }
        }
        });
        d.tag(p0, grp);
    };
    const double bxA = X0, byA = Ytop - s * hA;
    drawView(vw[0], bxA, byA, 0, true);
    auto cext = [&](const VW& v, double& u0, double& u1, double& w0, double& w1) {
        u0 = w0 = 1e18; u1 = w1 = -1e18;
        for (auto& b : brs) for (auto& q : b.poly) { const gp_Vec w(gp_Pnt(0, 0, 0), q); const double u = w.Dot(v.X), t = w.Dot(v.Y); u0 = std::min(u0, u); u1 = std::max(u1, u); w0 = std::min(w0, t); w1 = std::max(w1, t); }
    };
    double cu0, cu1, cw0, cw1; cext(vw[0], cu0, cu1, cw0, cw1);
    dimH(d, bxA + s * (cu0 - vw[0].u0), bxA + s * (cu1 - vw[0].u0), byA + s * hA, byA + s * hA, byA + s * hA + 10, fmt(cu1 - cu0), "length", cu1 - cu0);
    dimV(d, byA + s * (cw0 - vw[0].w0), byA + s * (cw1 - vw[0].w0), bxA, bxA, bxA - 12, fmt(cw1 - cw0), "length", cw1 - cw0);
    if (!planar) {
        const double hB = vw[1].w1 - vw[1].w0, wC = vw[2].u1 - vw[2].u0, hC = vw[2].w1 - vw[2].w0;
        const double byB = byA - gap - s * hB, bxC = bxA + s * wA + gap;
        drawView(vw[1], bxA, byB, 1, false);
        { double u0, u1, w0, w1; cext(vw[1], u0, u1, w0, w1); dimV(d, byB + s * (w0 - vw[1].w0), byB + s * (w1 - vw[1].w0), bxA, bxA, bxA - 12, fmt(w1 - w0), "length", w1 - w0); }
        drawView(vw[2], bxC, byA + s * hA - s * hC, 2, false);
        { double u0, u1, w0, w1; cext(vw[2], u0, u1, w0, w1); dimH(d, bxC + s * (u0 - vw[2].u0), bxC + s * (u1 - vw[2].u0), byA + s * hA, byA + s * hA, byA + s * hA + 10, fmt(u1 - u0), "length", u1 - u0); }
    }
    for (auto& fn : deferred) fn();   // números de nodo, ya con las cotas dibujadas
    // ---- sección del hilo y tablas
    const double tx0 = f.fx1 - tabW - 8; const double ty = f.zy1 + (planar ? 17 : 25);
    Pos p0 = d.pos();
    const double ss = std::min(4.0, 26.0 / (2 * Ro)), cxs = tx0 + 24, cys = ty - 16;
    d.arcs.push_back({cxs, cys, ss * Ro, 0, 360, LineType::Continuous, kThick});
    centerCross(d, cxs, cys, ss * Ro + 3);
    dimH(d, cxs - ss * Ro, cxs + ss * Ro, cys - ss * Ro, cys - ss * Ro, cys - ss * Ro - 8, "Ø" + fmt(2 * Ro), "diameter", 2 * Ro);
    text(d, tx0, cys + 15, 2.8, T("Sección del cable") + " (" + scaleText(ss) + ")");
    d.tag(p0, 3);
    const double avail = (cys - ss * Ro - 14) - (f.zy0 - (planar ? 17 : 25));
    const double rowH = std::max(3.2, std::min(5.2, avail / (nVr + nBr + 2.5))), th = rowH > 4.2 ? 3.0 : 2.6;
    double y = cys - ss * Ro - 14;
    auto row = [&](double x0, const std::vector<std::string>& c, const std::vector<double>& w, bool hd) {
        double xx = x0; ln(d, x0, y, x0 + tabW, y, hd ? 0.35 : 0.18);
        for (size_t i = 0; i < c.size(); i++) { text(d, xx + 1.2, y - rowH + 0.9, th, c[i]); xx += w[i]; }
        y -= rowH; ln(d, x0, y, x0 + tabW, y, hd ? 0.35 : 0.18);
    };
    auto vbar = [&](double x0, const std::vector<double>& w, double ytop, double ybot) { double xx = x0; ln(d, xx, ytop, xx, ybot, 0.35); for (double ww : w) { xx += ww; ln(d, xx, ytop, xx, ybot, 0.18); } ln(d, x0 + tabW, ytop, x0 + tabW, ybot, 0.35); };
    auto cz = [](double v) { return std::fabs(v) < 0.005 ? 0.0 : v; };
    p0 = d.pos();
    {
        const std::vector<double> w = {14, 30, 30, 30};
        text(d, tx0, y + 1, th, T("Nodos (cruce de ejes)")); const double yt = y;
        row(tx0, {"Pt", "X", "Y", "Z"}, w, true);
        for (size_t i = 0; i < order.size(); i++) { const gp_Pnt& q = nodes[order[i]]; row(tx0, {std::to_string(i + 1), fmt(cz(q.X() - P0.X())), fmt(cz(q.Y() - P0.Y())), fmt(cz(q.Z() - P0.Z()))}, w, false); }
        vbar(tx0, w, yt, y);
    }
    y -= rowH * 1.6;
    {
        const std::vector<double> w = {14, 22, 22, 24, 22};
        text(d, tx0, y + 1, th, T("Ramales")); const double yt = y;
        row(tx0, {"R", T("De nodo"), T("A nodo"), "L", T("curvas")}, w, true);
        for (size_t i = 0; i < brs.size(); i++) row(tx0, {std::to_string(i + 1), std::to_string(num[brs[i].n0] + 1), std::to_string(num[brs[i].n1] + 1), fmt(brs[i].len), std::to_string(brs[i].bends)}, w, false);
        vbar(tx0, w, yt, y);
        text(d, tx0, y - 3.4, 2.5, "L: " + T("Longitud desarrollada (eje)"));
    }
    d.tag(p0, 3);
    finish(d, meta, "harness");
    return true;
}

// G15: hoja de aviso en lugar del plano (la pieza queda fuera de alcance; no se inventan vistas ni cotas)
static const char* kDiscWhy[7] = {"", "No se pudo leer el archivo STEP (vacío, corrupto o no es un STEP).", "El archivo no contiene ningún sólido (solo superficies o nada).",
    "Chapa plegada o lámina: necesita desarrollo plano y tabla de plegados.", "Pieza embutida de pared fina (lata, cubilete).",
    "Forma libre u orgánica: superficies no analíticas que no se pueden acotar de forma fiable.", "Conjunto con más de 400 piezas."};
static const char* kDiscAlt[7] = {"", "Vuelve a exportar desde tu CAD en STEP (AP203, AP214 o AP242).", "Cierra las superficies y exporta un sólido.",
    "Usa una herramienta de chapa (desarrollo plano y plegados).", "Se necesita plano de embutición y de utillaje; Diedro no lo genera.",
    "Usa el modelo 3D como referencia o un plano con perfiles y secciones.", "Divide el conjunto en subconjuntos y exporta cada uno."};
std::vector<std::string> discardText(const Classification& c, const Meta& meta) {   // aviso para la app: {título, motivo, alternativa, detalle}
    const int k = c.discard >= 1 && c.discard <= 6 ? c.discard : 1;
    return {tr("PIEZA FUERA DE ALCANCE: NO SE GENERA PLANO", meta.lang), tr(kDiscWhy[k], meta.lang), tr(kDiscAlt[k], meta.lang), c.reason};
}
Drawing layoutDiscard(const Classification& c, const Meta& meta, const std::string& path) {
    Drawing d; d.sheetName = "A4"; d.sheetW = 297; d.sheetH = 210; d.kind = "discard"; d.label = "G15";
    auto ln = [&](double x1, double y1, double x2, double y2, double w) { d.lines.push_back({x1, y1, x2, y2, LineType::Continuous, w}); };
    ln(10, 10, 287, 10, 0.7); ln(287, 10, 287, 200, 0.7); ln(287, 200, 10, 200, 0.7); ln(10, 200, 10, 10, 0.7);
    auto wrap = [&](const std::string& s, size_t n) { std::vector<std::string> o; std::string cur; size_t i = 0;
        while (i < s.size()) { size_t j = s.find(' ', i); if (j == std::string::npos) j = s.size(); std::string w = s.substr(i, j - i);
            auto len = [](const std::string& x) { size_t k = 0; for (unsigned char ch : x) if ((ch & 0xC0) != 0x80) k++; return k; };
            if (!cur.empty() && len(cur) + 1 + len(w) > n) { o.push_back(cur); cur.clear(); }
            cur += (cur.empty() ? "" : " ") + w; i = j + 1; }
        if (!cur.empty()) o.push_back(cur); return o; };
    const int k = c.discard >= 1 && c.discard <= 6 ? c.discard : 1;
    std::string name = path.substr(path.find_last_of('/') == std::string::npos ? 0 : path.find_last_of('/') + 1);
    double y = 175;
    // ja/ko/zh/tw/th/hi: la fuente del PDF no los tiene -> contornos vectoriales ya modelados (notice_paths.cpp)
    auto glyphs = [&](const std::string& es, double x, double yy, double h, bool& ok) -> double {
        const NoticeText* nt = noticeText(meta.langUi, es); ok = nt != nullptr; if (!nt) return 0;
        const double s = h * 1.35 / 1000.0; double adv = 0;
        for (unsigned i = 0; i < nt->nlines; i++, adv += h * 1.6) {
            const int* p = nt->lines[i].d; const int* e = p + nt->lines[i].n;
            while (p < e) { int n = *p++; for (int q = 0; q < n; q++) { int a = q, b = (q + 1) % n; d.lines.push_back({x + p[2*a] * s, yy - adv + p[2*a+1] * s, x + p[2*b] * s, yy - adv + p[2*b+1] * s, LineType::Continuous, h > 6 ? 0.3 : 0.18}); } p += 2 * n; }
        }
        return adv;
    };
    bool ok;
    { double a = glyphs("PIEZA FUERA DE ALCANCE: NO SE GENERA PLANO", 20, y, 9, ok);
      if (ok) y -= a + 8; else { d.texts.push_back({20, y, 9, tr("PIEZA FUERA DE ALCANCE: NO SE GENERA PLANO", meta.lang), 0, true}); y -= 16; } }
    { double a = glyphs("Archivo", 20, y, 4, ok);
      if (ok) { d.texts.push_back({20 + 18, y, 4, ": " + name}); y -= 14; } else { d.texts.push_back({20, y, 4, tr("Archivo", meta.lang) + ": " + name}); y -= 14; (void)a; } }
    for (const char* kk : {kDiscWhy[k], kDiscAlt[k]}) {
        double a = glyphs(kk, 20, y, 5, ok);
        if (ok) y -= a + 6; else { for (auto& l : wrap(tr(kk, meta.lang), 80)) { d.texts.push_back({20, y, 5, l}); y -= 8; } y -= 6; }
    }
    if (!c.reason.empty()) { y -= 8; d.texts.push_back({20, y, 3.5, c.reason}); }
    { const char* ft = "Diedro no inventa cotas: ante una pieza que no sabe dibujar bien, se detiene y avisa.";
      double a = glyphs(ft, 20, 18, 3, ok); if (!ok) d.texts.push_back({20, 18, 3, tr(ft, meta.lang)}); (void)a; }
    d.warnings.push_back(tr(kDiscWhy[k], meta.lang));
    return d;
}
}  // namespace diedro
