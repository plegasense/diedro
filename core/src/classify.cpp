// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include <sys/stat.h>
#include "classify.hpp"
#include "prism.hpp"
#include "cx.hpp"
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepBndLib.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Bnd_Box.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepGProp.hxx>
#include <Bnd_OBB.hxx>
#include <GProp_GProps.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <STEPControl_Reader.hxx>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <BRep_Tool.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Vertex.hxx>
#include <set>
#include <tuple>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

namespace diedro {
const char* groupName(int g) {
    static const char* n[] = {"Sin clasificar", "Torneada", "Fresada prismática", "Mixta (torneado+fresado)", "Perfil/tubo", "Fundición/forja/inyección",
                              "Engranaje/muelle/leva", "Conjunto/soldadura", "", "", "", "Utillaje/molde", "", "Tubería", "Cable/mazo", "Descarte"};
    return g >= 0 && g <= 15 ? n[g] : "";
}

namespace {
enum Kind { PLANE, CYL, CONE, SPH, TOR, SPLINE, OTHER };
struct F {
    Kind k = OTHER;
    double area = 0;
    gp_Pnt c;
    gp_Dir n{0, 0, 1};  // normal del plano / eje del cilindro, cono o toro
    gp_Pnt o;           // punto del eje
    double r = 0;
    int nw = 1;         // contornos de la cara
    bool dirOK = false;
    double semi = 0;    // cono: semiángulo, grados
    double sweep = 0;   // cilindro: ángulo recorrido por la cara, grados
};
double ang(const gp_Dir& a, const gp_Dir& b) { return std::acos(std::min(1.0, std::fabs(a.Dot(b)))) * 57.29578; }  // 0..90°, ignora sentido
bool onAxis(const F& f, const gp_Pnt& o, const gp_Dir& d) {
    return ang(f.n, d) < 0.01 && gp_Lin(gp_Ax1(o, d)).Distance(f.o) < 1e-4 * 1.0 + 1e-6;
}
}  // namespace

// Grupos de sólidos que se interpenetran (cuerpo+rosca de una tuerca): cada grupo es una sola pieza; los conjuntos reales se tocan sin solaparse.
static int independentParts(const TopoDS_Shape& shape) {
    std::vector<TopoDS_Shape> so;
    std::vector<Bnd_Box> bb;
    std::vector<double> vol;
    std::vector<long> cost;
    std::vector<char> frag;   // sólido pequeño con superficie B-spline (≤12 caras): candidato a diente de rosca modelada como sólido suelto
    std::vector<char> light;  // solo se intersectan sólidos sencillos: la booleana con B-splines grandes tarda minutos
    for (TopExp_Explorer e(shape, TopAbs_SOLID); e.More(); e.Next()) {
        so.push_back(e.Current());
        int nf = 0; bool bs = false;
        for (TopExp_Explorer fe(e.Current(), TopAbs_FACE); fe.More(); fe.Next()) { nf++; bs = bs || BRepAdaptor_Surface(TopoDS::Face(fe.Current())).GetType() == GeomAbs_BSplineSurface; }
        frag.push_back(nf <= 12 && bs);
        const long pl = splinePoles(e.Current());
        light.push_back(nf <= 120 && pl <= 1500);
        cost.push_back(nf + pl);
        Bnd_Box b; BRepBndLib::Add(e.Current(), b); bb.push_back(b);
        GProp_GProps g; BRepGProp::VolumeProperties(e.Current(), g); vol.push_back(std::fabs(g.Mass()));
    }
    int n = (int)so.size();
    std::vector<int> p(n);
    for (int i = 0; i < n; i++) p[i] = i;
    auto find = [&](int i) { while (p[i] != i) i = p[i] = p[p[i]]; return i; };
    // Una rosca modelada como decenas de poliedros diminutos pegados a un cuerpo grande no es un conjunto: se funden con él (≥6 y todos dentro de su caja).
    if (n > 6) {
        int M = (int)(std::max_element(vol.begin(), vol.end()) - vol.begin());
        Bnd_Box g = bb[M]; double dx, dy, dz; { double a, b, c, d, e2, f; g.Get(a, b, c, d, e2, f); dx = d - a; dy = e2 - b; dz = f - c; }
        std::vector<int> fr;
        for (int i = 0; i < n; i++) if (i != M && frag[i] && vol[i] < 0.03 * vol[M]) {
            double a, b, c, d, e2, f, A, B, C, D, E, F; bb[i].Get(a, b, c, d, e2, f); g.Get(A, B, C, D, E, F);
            const double x = (a + d) / 2, y = (b + e2) / 2, z = (c + f) / 2;  // el centro del diente cae sobre el cuerpo (el diente sobresale de su caja)
            if (x >= A && x <= D && y >= B && y <= E && z >= C && z <= F) fr.push_back(i);
        }
        if (fr.size() >= 6) for (int i : fr) p[find(i)] = find(M);
    }
    if (n > 60) { int k = 0; for (int i = 0; i < n; i++) if (find(i) == i) k++; return k; }
    long spent = 0;  // presupuesto de coste (caras + polos) para las booleanas: mismo STEP, mismo resultado
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++) {
            if (find(i) == find(j) || bb[i].IsOut(bb[j]) || !light[i] || !light[j] || spent >= 6000) continue;
            spent += cost[i] + cost[j];
            BRepAlgoAPI_Common cm(so[i], so[j]);
            if (!cm.IsDone()) continue;
            GProp_GProps g; BRepGProp::VolumeProperties(cm.Shape(), g);
            if (std::fabs(g.Mass()) > 0.01 * std::min(vol[i], vol[j])) p[find(i)] = find(j);
        }
    int k = 0;
    for (int i = 0; i < n; i++) if (find(i) == i) k++;
    return k;
}

static double rmaxOf(const std::vector<F>& fs) { double r = 0; for (auto& f : fs) if (f.k == CYL) r = std::max(r, f.r); return r; }
static Classification classifyStepRaw(const std::string& path) {
    Classification C;
    const auto T0 = std::chrono::steady_clock::now();
    auto TS = [&](const char* w) { if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "CLS %s %.1fs\n", w, std::chrono::duration<double>(std::chrono::steady_clock::now() - T0).count()); };
    STEPControl_Reader rd;
    if (rd.ReadFile(path.c_str()) != IFSelect_RetDone) { C.error = "No se pudo leer el archivo STEP."; C.group = 15; C.discard = 1; return C; }
    TS("read");
    rd.TransferRoots();
    TS("transfer");
    TopoDS_Shape shape = rd.OneShape();
    if (shape.IsNull()) { C.error = "El STEP no contiene ninguna forma sólida."; C.group = 15; C.discard = 2; return C; }
    int nSol = 0;
    for (TopExp_Explorer e(shape, TopAbs_SOLID); e.More(); e.Next()) nSol++;
    if (!nSol) { C.error = "El STEP no contiene ningún sólido."; C.group = 15; C.discard = 2; return C; }
    int nParts = nSol > 1 ? independentParts(shape) : 1;
    TS("parts");
    C.nParts = nParts;
    if (nParts > 400) { C.group = 15; C.discard = 6; C.conf = 1; C.reason = std::to_string(nParts) + " piezas"; return C; }
    if (nParts > 1 && !std::getenv("DIEDRO_CLASSIFY_FEAT")) {  // conjunto: la regla no depende de las demás medidas; evita recorrer todas las caras (segundos en conjuntos grandes)
        char b[200]; std::snprintf(b, sizeof b, "%d piezas (%d sólidos)", nParts, nSol);
        C.group = 7; C.conf = 0.95; C.reason = b; return C;
    }

    std::vector<F> fs;
    double A = 0, Ak[7] = {0};
    for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next()) {
        TopoDS_Face fc = TopoDS::Face(e.Current());
        GProp_GProps gp;
        BRepGProp::SurfaceProperties(fc, gp);
        F f;
        f.area = gp.Mass();
        f.c = gp.CentreOfMass();
        BRepAdaptor_Surface su(fc);
        switch (su.GetType()) {
            case GeomAbs_Plane: f.k = PLANE; f.n = su.Plane().Axis().Direction(); break;
            case GeomAbs_Cylinder: f.k = CYL; f.n = su.Cylinder().Axis().Direction(); f.o = su.Cylinder().Location(); f.r = su.Cylinder().Radius(); f.sweep = (su.LastUParameter() - su.FirstUParameter()) * 57.29578; break;
            case GeomAbs_Cone: f.k = CONE; f.n = su.Cone().Axis().Direction(); f.o = su.Cone().Apex(); f.semi = std::fabs(su.Cone().SemiAngle()) * 57.29578; break;
            case GeomAbs_Sphere: f.k = SPH; f.o = su.Sphere().Location(); break;
            case GeomAbs_Torus: f.k = TOR; f.n = su.Torus().Axis().Direction(); f.o = su.Torus().Location(); f.r = su.Torus().MinorRadius(); break;
            case GeomAbs_BezierSurface: case GeomAbs_BSplineSurface: f.k = SPLINE; break;
            case GeomAbs_SurfaceOfExtrusion: f.k = OTHER; f.n = su.Direction(); f.dirOK = true; break;
            default: f.k = OTHER;
        }
        { int nw = 0; for (TopExp_Explorer w(fc, TopAbs_WIRE); w.More(); w.Next()) nw++; f.nw = nw; }
        A += f.area; Ak[f.k] += f.area;
        fs.push_back(f);
    }
    if (fs.empty() || A <= 0) { C.error = "El STEP no contiene caras."; return C; }

    Bnd_OBB ob;
    BRepBndLib::AddOBB(shape, ob, false, false, false);
    gp_Dir ax[3] = {ob.XDirection(), ob.YDirection(), ob.ZDirection()};
    double dim[3] = {2 * ob.XHSize(), 2 * ob.YHSize(), 2 * ob.ZHSize()};
    int ord[3] = {0, 1, 2};
    std::sort(ord, ord + 3, [&](int a, int b) { return dim[a] > dim[b]; });
    const double a0 = dim[ord[0]], b0 = dim[ord[1]], c0 = dim[ord[2]];
    const gp_Dir Ldir = ax[ord[0]], Tdir = ax[ord[2]];  // eje largo y eje de menor espesor
    auto feat = [&](const char* k, double v) { C.feat.push_back({k, v}); };
    auto done = [&](int g, double conf, const std::string& why) { C.group = g; C.conf = std::max(0.0, std::min(1.0, conf)); C.reason = why; };
    char b[200];

    // eje de revolución dominante: el eje de cilindro/cono con más área de superficies coaxiales
    double bestRev = 0;
    gp_Pnt bo; gp_Dir bd(0, 0, 1);
    for (auto& f : fs) {
        if (f.k != CYL && f.k != CONE) continue;
        double s = 0;
        for (auto& g : fs) if ((g.k == CYL || g.k == CONE || g.k == TOR) && onAxis(g, f.o, f.n)) s += g.area;
        if (s > bestRev) { bestRev = s; bo = f.o; bd = f.n; }
    }
    double axial = 0;  // planos perpendiculares al eje (caras frontales de una pieza torneada)
    for (auto& f : fs) if (f.k == PLANE && ang(f.n, bd) < 0.01) axial += f.area;
    const double turn = bestRev > 0 ? std::min(1.0, (bestRev + axial) / A) : 0;

    // referencia de planos: normal del plano mayor y del mayor plano perpendicular a él (mejor que la caja orientada, que puede girar unas décimas)
    gp_Dir pf[3] = {ax[0], ax[1], ax[2]};
    {
        const F* p0 = nullptr; const F* p1 = nullptr;
        for (auto& f : fs) if (f.k == PLANE && (!p0 || f.area > p0->area)) p0 = &f;
        if (p0) for (auto& f : fs) if (f.k == PLANE && ang(f.n, p0->n) > 89.0 && (!p1 || f.area > p1->area)) p1 = &f;
        if (p0 && p1) { pf[0] = p0->n; pf[1] = p1->n; pf[2] = gp_Dir(gp_Vec(p0->n).Crossed(gp_Vec(p1->n))); }
    }
    std::vector<gp_Pnt> vt;
    for (TopExp_Explorer e(shape, TopAbs_VERTEX); e.More(); e.Next()) vt.push_back(BRep_Tool::Pnt(TopoDS::Vertex(e.Current())));
    // extrusión: existe un eje d tal que todas las caras son paralelas a d salvo planos de extremo, y es alargada respecto a su sección
    double extLen = 0, extSec = 0; bool extrusion = false, extRound = false, extOneR = false, extThin = false;
    for (auto& d : {pf[0], pf[1], pf[2], ax[0], ax[1], ax[2]}) {
        int endPl = 0, latPl = 0; bool ok = true; double endA = 0, latBest = 0; gp_Dir lbN(1, 0, 0);
        std::vector<double> rad;
        for (auto& f : fs) {
            if (f.k == PLANE) { if (ang(f.n, d) > 89.5) { latPl++; if (f.area > latBest) { latBest = f.area; lbN = f.n; } continue; } endPl++; endA = std::max(endA, f.area); }
            else if (f.k == CYL) { if (ang(f.n, d) < 0.5) { bool seen = false; for (double r : rad) if (std::fabs(r - f.r) < 1e-6) seen = true; if (!seen) rad.push_back(f.r); } else { ok = false; break; } }
            else if (f.k == OTHER && f.dirOK && ang(f.n, d) < 0.5) {}
            else { ok = false; break; }
        }
        if (!ok || endPl != 2) continue;
        gp_Dir u = latPl ? lbN : (std::fabs(d.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0));
        u = gp_Dir(gp_Vec(d).Crossed(gp_Vec(u)));
        gp_Dir v(gp_Vec(d).Crossed(gp_Vec(u)));
        double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
        for (auto& q : vt) {
            double c[3] = {gp_Vec(q.XYZ()).Dot(gp_Vec(d)), gp_Vec(q.XYZ()).Dot(gp_Vec(u)), gp_Vec(q.XYZ()).Dot(gp_Vec(v))};
            for (int k = 0; k < 3; k++) { lo[k] = std::min(lo[k], c[k]); hi[k] = std::max(hi[k], c[k]); }
        }
        double rmx = 0; for (double r : rad) rmx = std::max(rmx, r);
        double len = hi[0] - lo[0], sec = std::max({hi[1] - lo[1], hi[2] - lo[2], 2 * rmx});
        const double solid = latPl ? endA / std::max(1e-12, (hi[1] - lo[1]) * (hi[2] - lo[2])) : 1.0;
        const bool thin = solid < 0.45;
        if (sec > 0 && (len / sec >= 1.0 || (thin && len / sec >= 0.08)) && (!extrusion || len / sec > extLen / extSec)) {
            extrusion = true; extLen = len; extSec = sec;
            extThin = thin; extRound = latPl == 0; extOneR = extRound && rad.size() == 1;
            CutInfo& ci = C.cut; ci = CutInfo(); ci.ok = true; ci.planes = latPl; ci.round = latPl == 0;
            // eje exacto (la regla de extrusión admite 0,5° de holgura): de dos planos laterales no paralelos o del eje de un cilindro
            gp_Dir dd = d; gp_Pnt cax; bool haveC = false;
            {
                const F* l1 = nullptr; const F* l2 = nullptr;
                for (auto& f : fs) if (f.k == PLANE && ang(f.n, d) > 89.5) { if (!l1 || f.area > l1->area) l1 = &f; }
                if (l1) for (auto& f : fs) if (f.k == PLANE && ang(f.n, d) > 89.5 && ang(f.n, l1->n) > 5 && ang(f.n, l1->n) < 175 && (!l2 || f.area > l2->area)) l2 = &f;
                if (l1 && l2) { gp_Dir x = gp_Dir(gp_Vec(l1->n).Crossed(gp_Vec(l2->n))); dd = ang(x, d) > 90 ? x.Reversed() : x; }
                else for (auto& f : fs) if (f.k == CYL && ang(f.n, d) < 0.5) { dd = ang(f.n, d) > 90 ? f.n.Reversed() : f.n; cax = f.o; haveC = true; break; }
            }
            gp_Dir uu = latPl ? gp_Dir(gp_Vec(dd).Crossed(gp_Vec(lbN).Crossed(gp_Vec(dd)))) : gp_Dir(gp_Vec(dd).Crossed(gp_Vec(std::fabs(dd.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0))));
            gp_Dir vv = gp_Dir(gp_Vec(dd).Crossed(gp_Vec(uu)));
            double ulo = 1e300, uhi = -1e300, vlo = 1e300, vhi = -1e300;
            for (auto& q : vt) { const double a1 = gp_Vec(q.XYZ()).Dot(gp_Vec(uu)), b1 = gp_Vec(q.XYZ()).Dot(gp_Vec(vv)); ulo = std::min(ulo, a1); uhi = std::max(uhi, a1); vlo = std::min(vlo, b1); vhi = std::max(vhi, b1); }
            std::sort(rad.begin(), rad.end());
            ci.w = uhi - ulo; ci.h = vhi - vlo;
            if (ci.round) { ci.w = ci.h = 2 * rad.back(); ci.dOut = 2 * rad.back(); ci.dIn = rad.size() >= 2 ? 2 * rad.front() : 0; }
            std::vector<const F*> ends; for (auto& f : fs) if (f.k == PLANE && ang(f.n, dd) <= 89.5) ends.push_back(&f);
            if (ends.size() == 2) {
                auto zc = [&](const F* f) { return gp_Vec(f->c.XYZ()).Dot(gp_Vec(dd)); };
                if (zc(ends[0]) > zc(ends[1])) std::swap(ends[0], ends[1]);
                auto zAt = [&](const F* f, double a1, double b1) {
                    const double nz = gp_Vec(f->n).Dot(gp_Vec(dd)), nu = gp_Vec(f->n).Dot(gp_Vec(uu)), nv = gp_Vec(f->n).Dot(gp_Vec(vv));
                    return (gp_Vec(f->n).Dot(gp_Vec(f->c.XYZ())) - nu * a1 - nv * b1) / nz;
                };
                for (int e = 0; e < 2; e++) {
                    const F* f = ends[e];
                    const double nz = gp_Vec(f->n).Dot(gp_Vec(dd)), nu = gp_Vec(f->n).Dot(gp_Vec(uu)), nv = gp_Vec(f->n).Dot(gp_Vec(vv));
                    ci.tilt[e][0] = std::atan2(std::fabs(nu), std::fabs(nz)) * 57.29578 * (nu * nz < 0 ? -1 : 1);
                    ci.tilt[e][1] = std::atan2(std::fabs(nv), std::fabs(nz)) * 57.29578 * (nv * nz < 0 ? -1 : 1);
                    ci.wires = std::max(ci.wires, f->nw);
                }
                ci.lenMax = -1e300; ci.lenMin = 1e300;
                if (haveC && latPl == 0) {   // redondo: la fibra es lineal en la sección; extremos a ±R del centro en la dirección del gradiente
                    const double a1 = gp_Vec(cax.XYZ()).Dot(gp_Vec(uu)), b1 = gp_Vec(cax.XYZ()).Dot(gp_Vec(vv));
                    auto g = [&](const F* f, int k) { const double nz = gp_Vec(f->n).Dot(gp_Vec(dd)); return gp_Vec(f->n).Dot(gp_Vec(k ? vv : uu)) / nz; };
                    const double gu = g(ends[0], 0) - g(ends[1], 0), gv = g(ends[0], 1) - g(ends[1], 1), gm = std::hypot(gu, gv) * rad.back();
                    const double fc = zAt(ends[1], a1, b1) - zAt(ends[0], a1, b1);
                    ci.lenMax = fc + gm; ci.lenMin = fc - gm;
                } else for (auto& q : vt) {
                    const double a1 = gp_Vec(q.XYZ()).Dot(gp_Vec(uu)), b1 = gp_Vec(q.XYZ()).Dot(gp_Vec(vv));
                    const double fl = zAt(ends[1], a1, b1) - zAt(ends[0], a1, b1);
                    ci.lenMax = std::max(ci.lenMax, fl); ci.lenMin = std::min(ci.lenMin, fl);
                }
            } else { ci.lenMax = ci.lenMin = hi[0] - lo[0]; }
            // caras coplanares en un extremo de la sección: puntas de U, alas de I
            int ext2 = 0;
            for (int k = 0; k < 2; k++) for (int sg = 0; sg < 2; sg++) {
                const gp_Dir& w = k ? vv : uu; const double ex = (k ? (sg ? vhi : vlo) : (sg ? uhi : ulo)); int n = 0;
                for (auto& f : fs) if (f.k == PLANE && ang(f.n, dd) > 89.5 && (ang(f.n, w) < 0.5 || ang(f.n, w) > 179.5) && std::fabs(gp_Vec(f.c.XYZ()).Dot(gp_Vec(w)) - ex) < 1e-5 * std::max(1.0, a0)) n++;
                ext2 = std::max(ext2, n);
            }
            if (latPl >= 6 || (latPl == 4 && ci.wires >= 2)) {   // espesores: menor hueco entre planos laterales paralelos a cada eje de la sección (alma/ala o pared)
                double tg[2] = {0, 0};
                for (int k = 0; k < 2; k++) {
                    const gp_Dir& w = k ? vv : uu; std::vector<double> o;
                    for (auto& f : fs) if (f.k == PLANE && ang(f.n, dd) > 89.5 && (ang(f.n, w) < 0.5 || ang(f.n, w) > 179.5)) o.push_back(gp_Vec(f.c.XYZ()).Dot(gp_Vec(w)));
                    std::sort(o.begin(), o.end()); double g = 1e300;
                    for (size_t i = 1; i < o.size(); i++) if (o[i] - o[i - 1] > 1e-4) g = std::min(g, o[i] - o[i - 1]);
                    if (g < 0.5 * (k ? ci.h : ci.w)) tg[k] = g;
                }
                ci.t1 = std::min(tg[0] > 0 ? tg[0] : 1e300, tg[1] > 0 ? tg[1] : 1e300); if (ci.t1 > 1e299) ci.t1 = 0;
                ci.t2 = std::max(tg[0], tg[1]);
            }
            if (ci.round) ci.kind = rad.size() >= 2 ? 7 : 0;
            else if (ci.wires >= 2) ci.kind = 2;
            else if (latPl == 4) ci.kind = 1;
            else if (latPl == 6) ci.kind = 3;
            else if (latPl == 12) ci.kind = 4;
            else if (latPl == 8) ci.kind = ext2 >= 2 ? 5 : 6;
        }
    }
    // ¿barra o tubo redondo liso? es torneado si lleva cualquier otra cosa; se deja como perfil solo si es sección redonda sin escalones
    const double latF = extrusion ? 1.0 : 0.0;
    const int nonLat = 0; const bool roundOnly = extRound, slantEnd = false;
    // desmoldeo: planos casi paralelos a un eje de la caja, con inclinación de 0,3° a 10°
    // la dirección de desmoldeo d es la que más área tiene casi paralela a ella (80°-89,7° respecto a la normal); los conos coaxiales (taladros, resaltes) suman si hay planos con salida
    double draft = 0;
    int draftN = 0;   // mayor grupo de planos con la misma salida
    {
        std::vector<gp_Dir> cand;
        std::vector<const F*> pls;
        for (auto& f : fs) if (f.k == PLANE) pls.push_back(&f);
        std::sort(pls.begin(), pls.end(), [](const F* a, const F* b) { return a->area > b->area; });
        for (size_t i = 0; i < pls.size() && i < 6; i++) cand.push_back(pls[i]->n);
        // la salida de una pieza de fundición es uniforme: se agrupan los planos por el mismo ángulo (±0,15°) y se toma el mayor grupo
        for (auto& d : cand) {
            for (auto& g : fs) {
                if (g.k != PLANE) continue;
                const double th = 90.0 - ang(g.n, d);
                if (th < 0.5 || th > 10.0) continue;
                double pa = 0, ca = 0; int np = 0;
                for (auto& f : fs) {
                    if (f.k == PLANE) { if (std::fabs(90.0 - ang(f.n, d) - th) < 0.15) { pa += f.area; np++; } }
                    else if (f.k == CONE && ang(f.n, d) < 0.5 && std::fabs(f.semi - th) < 0.15) ca += f.area;
                }
                if (np >= 2) draft = std::max(draft, pa + ca);
                draftN = std::max(draftN, np);
            }
        }
    }
    // cuerpo de revolución solo con conos suaves (≥2, ninguna superficie cilíndrica): es un fundido con salida a los dos lados de la partición, no un torneado
    if (draft == 0 && bestRev > 0) {
        int nc = 0, ncy = 0; double ca = 0;
        for (auto& f : fs) if ((f.k == CYL || f.k == CONE || f.k == TOR) && onAxis(f, bo, bd)) { if (f.k == CONE && f.semi > 0.3 && f.semi < 10.0) { nc++; ca += f.area; } else ncy++; }
        if (nc >= 2 && ncy == 0) draft = ca;
    }
    const double draftF = draft / A;

    // grupo de caras congruentes y repartidas en corona alrededor del eje (dientes, levas)
    int rep = 0;
    if (bestRev > 0) {
        std::vector<std::pair<double, double>> v;  // área, distancia al eje
        for (auto& f : fs) {
            if (f.k == CYL || f.k == SPH || f.k == TOR || f.k == CONE) continue;
            v.push_back({f.area, gp_Lin(gp_Ax1(bo, bd)).Distance(f.c)});
        }
        std::sort(v.begin(), v.end());
        for (size_t i = 0; i < v.size(); i++) {
            size_t j = i; double mn = v[i].second, mx = mn;
            while (j + 1 < v.size() && v[j + 1].first <= v[i].first * 1.005) { j++; mn = std::min(mn, v[j].second); mx = std::max(mx, v[j].second); }
            if (mx > 0 && (mx - mn) / mx < 0.05 && v[i].first > 1e-9) rep = std::max(rep, (int)(j - i + 1));
        }
    }
    // taladros cilíndricos paralelos al espesor (placas de utillaje)
    int holesT = 0;
    {
        std::set<std::tuple<long, long, long>> seen;
        gp_Dir u = std::fabs(Tdir.X()) < 0.9 ? gp_Dir(1, 0, 0) : gp_Dir(0, 1, 0);
        u = gp_Dir(gp_Vec(Tdir).Crossed(gp_Vec(u)));
        gp_Dir v(gp_Vec(Tdir).Crossed(gp_Vec(u)));
        const double q = a0 * 1e-4;
        for (auto& f : fs) if (f.k == CYL && ang(f.n, Tdir) < 1.0 && f.r < 0.25 * b0 && f.area >= 0.45 * 6.2832 * f.r * c0) {
            gp_Vec o(f.o.XYZ());
            seen.insert({std::lround(o.Dot(gp_Vec(u)) / q), std::lround(o.Dot(gp_Vec(v)) / q), std::lround(f.r / q)});
        }
        holesT = (int)seen.size();
    }
    double rmaxCyl = 0;
    for (auto& f : fs) if (f.k == CYL || f.k == TOR) rmaxCyl = std::max(rmaxCyl, f.k == CYL ? f.r : f.r);
    int distinctAx = 0;
    {
        std::vector<gp_Dir> dirs;
        for (auto& f : fs) if (f.k == CYL || f.k == TOR) {
            bool seen = false;
            for (auto& d : dirs) if (ang(d, f.n) < 1.0) { seen = true; break; }
            if (!seen) dirs.push_back(f.n);
        }
        distinctAx = (int)dirs.size();
    }
    const double pl = Ak[PLANE] / A, cyl = (Ak[CYL] + Ak[TOR]) / A, oth = (Ak[SPLINE] + Ak[OTHER]) / A;
    feat("solidos", nSol); feat("caras", (double)fs.size()); feat("a0", a0); feat("b0", b0); feat("c0", c0);
    feat("plano", pl); feat("cil_tor", cyl); feat("spline_otras", oth); feat("giro", turn); feat("lateral", latF);
    feat("extrusion", extrusion ? extLen / extSec : 0); feat("desmoldeo", draftF); feat("corona", rep); feat("taladros_esp", holesT); feat("ejes", distinctAx);

    if (nParts > 1) { std::snprintf(b, sizeof b, "%d piezas (%d sólidos)", nParts, nSol); done(7, 0.95, b); return C; }
    // cables: hilos finos con curvas
    bool hollowT = false;   // tubo hueco (pared + taladro): es tubería aunque sea muy esbelto; los cables/hilos son macizos
    { double ao = 0, ai = 0; for (auto& f : fs) if (f.k == CYL || f.k == TOR) { if (f.r > 0.98 * rmaxCyl) ao += f.area; else if (f.r > 0.4 * rmaxCyl) ai += f.area; } hollowT = ai > 0.3 * ao; }
    // G15 descartes (chapa plegada, lata embutida, forma libre): se reconocen y no se dibujan con un motor que no les corresponde
    {
        GProp_GProps gv; BRepGProp::VolumeProperties(shape, gv);
        const double V = std::fabs(gv.Mass()), t = A > 0 ? 2 * V / A : 0;   // espesor medio de una pieza delgada
        auto disc = [&](int code, const std::string& why) { C.group = 15; C.discard = code; C.conf = 0.8; C.reason = why; };
        if (t > 0 && t <= 8 && t <= 0.15 * b0 && (fs.size() <= 60 || (fs.size() <= 150 && t <= 0.03 * b0))) {   // chapa: pocas caras (un cubo con muchos detalles no es chapa); muy fina admite taladros y ranuras
            int bends = 0;
            for (size_t i = 0; i < fs.size() && !bends; i++) if (fs[i].k == CYL && fs[i].sweep < 330)
                for (size_t j = 0; j < fs.size(); j++) if (j != i && fs[j].k == CYL && fs[j].sweep < 330 && ang(fs[i].n, fs[j].n) < 0.5 && gp_Lin(gp_Ax1(fs[i].o, fs[i].n)).Distance(fs[j].o) < 0.02 * t + 1e-4 && std::fabs(fs[j].r - fs[i].r - t) <= 0.2 * t) { bends++; break; }
            if (bends && turn >= 0.7) { std::snprintf(b, sizeof b, "pieza embutida: pared %.2f mm, Ø%.0f (revolución con acuerdos concéntricos)", t, 2 * rmaxOf(fs)); disc(4, b); return C; }   // lata de fondo abombado
            if (bends) { std::snprintf(b, sizeof b, "chapa de %.2f mm con plegados concéntricos", t); disc(3, b); return C; }
            if (t < 0.1 && Ak[PLANE] >= 0.3 * A) { std::snprintf(b, sizeof b, "lámina de %.2f mm", t); disc(3, b); return C; }
        }
        if (turn >= 0.9 && t > 0 && t <= 1.5 && t <= 0.03 * 2 * rmaxOf(fs)) {   // revolución de pared fina con fondo cerrado
            double base = 0; for (auto& f : fs) if (f.k == PLANE && ang(f.n, bd) < 0.01) base = std::max(base, f.area);
            const double R = rmaxOf(fs);
            double lat = 0; for (auto& f : fs) if (f.k == CYL || f.k == CONE) lat += f.area;   // una arandela tiene pared lateral despreciable
            if (base >= 0.6 * 3.14159265 * R * R && lat >= 0.3 * A) { std::snprintf(b, sizeof b, "pieza embutida: pared %.2f mm, Ø%.0f con fondo cerrado", t, 2 * R); disc(4, b); return C; }
        }
        bool fullCyl = false; for (auto& f : fs) if (f.k == CYL && f.sweep >= 330) fullCyl = true;   // agujero/cabeza de engranaje helicoidal: no es forma libre
        BRepClass3d_SolidClassifier cl3(shape, ob.Center(), 1e-6); const bool centerIn = cl3.State() == TopAbs_IN;   // un muelle es hueco por el centro
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "G15 t=%.2f in=%d\n", t, (int)centerIn);
        if (oth >= 0.6 && Ak[OTHER] / A < 0.4 && centerIn && !fullCyl) { std::snprintf(b, sizeof b, "forma libre: %.0f%% del área son superficies no analíticas", oth * 100); disc(5, b); return C; }
    }
    {   // mazo ramificado: hilos finos del mismo Ø en ≥2 direcciones (un taladro cruzado es de menor Ø: eso es una pieza torneada)
        std::vector<gp_Dir> dirs;
        for (auto& f : fs) if ((f.k == CYL || f.k == TOR) && f.r >= 0.9 * rmaxCyl) { bool seen = false; for (auto& d : dirs) if (ang(d, f.n) < 1.0) { seen = true; break; } if (!seen) dirs.push_back(f.n); }
        if (cyl > 0.97 && dirs.size() >= 2 && a0 > 0 && rmaxCyl / a0 < 0.05 && !hollowT && nSol == 1) { std::snprintf(b, sizeof b, "hilos finos del mismo Ø en %zu direcciones (mazo)", dirs.size()); done(14, 0.7, b); return C; }
    }
    if (Ak[TOR] > 0 && cyl > 0.9 && distinctAx >= 2 && a0 > 0 && rmaxCyl / a0 < 0.02 && !hollowT) { std::snprintf(b, sizeof b, "tubo muy fino curvado (r/L=%.3f)", rmaxCyl / a0); done(14, 0.7, b); return C; }
    if (Ak[TOR] > 0 && cyl > 0.9 && distinctAx >= 2 && rmaxCyl / a0 < 0.3) { std::snprintf(b, sizeof b, "tubo con codos, %d direcciones", distinctAx); done(13, 0.8, b); return C; }
    // engranaje o leva: corona de caras iguales; muelle: pocas caras casi todas de forma libre
    if (rep >= 12 && rep * 14 >= (int)fs.size()) { std::snprintf(b, sizeof b, "%d caras iguales en corona", rep); done(6, std::min(1.0, rep / 24.0), b); return C; }
    if (fs.size() <= 12 && oth > 0.7) { std::snprintf(b, sizeof b, "%zu caras, %.0f%% de forma libre (hélice)", fs.size(), oth * 100); done(6, 0.5, b); return C; }
    // perfil: sección constante a lo largo del eje mayor, con pocos cortes
    if (extrusion && !extOneR) {
        // un bloque corto con sección llena es igual de bien una pieza fresada: se dice y se ofrece la alternativa
        const bool amb = extLen / extSec < 3 && !extThin && !extRound;
        std::snprintf(b, sizeof b, "sección constante, largo/sección=%.1f%s%s", extLen / extSec, extRound ? " (tubo redondo)" : "", amb ? "; podría ser fresada (G2)" : "");
        if (amb) C.alt = 2;
        done(4, amb ? 0.45 : std::min(1.0, 0.6 + extLen / extSec / 10), b); return C;
    }
    // fundición con muchos acuerdos: la salida solo afecta a pocas caras (<15% del área) pero hay ≥4 planos con la misma salida y 150+ caras
    if (draftF >= 0.01 && draftN >= 4 && fs.size() >= 150 && turn < 0.6) { std::snprintf(b, sizeof b, "%d planos con la misma salida de 0,5-10° y %zu caras (acuerdos de fundición)", draftN, fs.size()); done(5, 0.62, b); return C; }
    if (draftF >= 0.15) { std::snprintf(b, sizeof b, "%.0f%% del área con salida de 0,3-10°", draftF * 100); done(5, std::min(1.0, draftF * 3), b); return C; }
    // cuerpo de forma libre (pocas caras spline grandes) con planos y taladros mecanizados, sin eje de revolución dominante: fundición mecanizada
    if (Ak[SPLINE] / A >= 0.3 && Ak[SPLINE] / A <= 0.8 && Ak[OTHER] / A < 0.05 && turn < 0.4 && pl >= 0.15 && fs.size() >= 40) {
        int ns = 0; double big = 0; for (auto& f : fs) if (f.k == SPLINE) { ns++; big = std::max(big, f.area); }
        if (ns <= 60 && big >= 0.08 * A) { std::snprintf(b, sizeof b, "cuerpo de forma libre (%.0f%%, %d caras spline) con planos y taladros mecanizados", Ak[SPLINE] / A * 100, ns); done(5, 0.62, b); return C; }
    }
    if (turn >= 0.9) { std::snprintf(b, sizeof b, "%.0f%% del área es de revolución o frontal", turn * 100); done(1, (turn - 0.8) * 5, b); return C; }
    if (turn >= 0.45 && bestRev / A >= 0.3) { std::snprintf(b, sizeof b, "%.0f%% de revolución + %.0f%% de otras caras", turn * 100, (1 - turn) * 100); done(3, 0.6, b); return C; }
    if (c0 <= 0.25 * b0 && holesT >= 8 && pl >= 0.5) { std::snprintf(b, sizeof b, "placa (e/b=%.2f) con %d taladros", c0 / b0, holesT); done(11, 0.7, b); return C; }
    if (pl + cyl >= 0.6) { std::snprintf(b, sizeof b, "%.0f%% de planos, %.0f%% de cilindros", pl * 100, cyl * 100); done(2, pl + cyl - 0.5, b); return C; }
    std::snprintf(b, sizeof b, "ninguna regla da confianza (forma libre %.0f%%)", oth * 100);
    done(0, 0, b);
    return C;
}
bool chooseEnginePrism(const std::string& path, const Profile& p) {
    Classification c = classifyStep(path);
    if (c.error.empty() && c.conf >= 0.6) {
        if (c.group == 2 || c.group == 4 || c.group == 5 || c.group == 11) return true;
        if (c.group == 1 && p.error.empty()) {   // torneada, salvo que el propio perfil de revolución diga que no lo es (chapa con chavetero, lata con anilla)
            double rmax = 0;
            for (auto& g : p.segs) rmax = std::max(rmax, std::max(g.r0, g.r1));
            return (p.totArea > 0 && p.unsupArea > 0.25 * p.totArea) || p.rShape > 1.3 * rmax + 0.5;
        }
    }
    if (c.error.empty() && c.group == 2 && p.error.empty()) {   // fresada de baja confianza: si el perfil de revolución no la explica (araña, placa con brazos), es prisma
        double rmax = 0;
        for (auto& g : p.segs) rmax = std::max(rmax, std::max(g.r0, g.r1));
        if ((p.totArea > 0 && p.unsupArea > 0.25 * p.totArea) || p.rShape > 1.3 * rmax + 0.5) return true;
    }
    return preferPrism(p);
}

// El CLI y el motor piden la clasificación varias veces por fichero: la última se recuerda (misma ruta, tamaño y fecha).
Classification classifyStep(const std::string& path) {
    static std::string kPath, kStamp; static Classification kC;
    std::string stamp;
    struct stat st;
    if (stat(path.c_str(), &st) == 0) stamp = std::to_string(st.st_size) + ":" + std::to_string((long long)st.st_mtime) + (std::getenv("DIEDRO_CLASSIFY_FEAT") ? "F" : "");
    if (!stamp.empty() && path == kPath && stamp == kStamp) return kC;
    Classification c = classifyStepRaw(path);
    if (!stamp.empty()) { kPath = path; kStamp = stamp; kC = c; }
    return c;
}
}  // namespace diedro
