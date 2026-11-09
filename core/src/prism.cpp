// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include <optional>
// Piezas prismáticas: STEP -> tres vistas (alzado, planta, perfil izquierdo; primer diedro) con líneas ocultas (HLR),
// cotas por ordenadas desde la esquina de referencia, taladros con tag + nota (n×, profundidad), radios y chaflanes en notas.
// Todo lo que se acota sale de la geometría; tolerancias, ajustes y roscas solo del usuario o del PMI.
#include "progress.hpp"
#include "special.hpp"
#include "prism.hpp"
#include "cx.hpp"
#include "classify.hpp"
#include <cctype>
#include <cstdlib>
#include <cstdio>
#include <array>
#include <set>
#include <map>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepBndLib.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <gp_Pln.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <memory>
#include <BRepMesh_IncrementalMesh.hxx>
#include <Geom_BSplineSurface.hxx>
#include <HLRBRep_PolyAlgo.hxx>
#include <HLRBRep_PolyHLRToShape.hxx>
#include <BRepGProp.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <GeomLib_IsPlanarSurface.hxx>
#include <Bnd_Box.hxx>
#include <TopLoc_Location.hxx>
#include <Poly_Triangulation.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <GProp_GProps.hxx>
#include <HLRAlgo_Projector.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <STEPControl_Reader.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Edge.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Cone.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Trsf.hxx>
#include <algorithm>
#include <cmath>
#include <map>
#include <array>
#include <set>
#include "analyze.hpp"
#include "font.hpp"
#include "stack.hpp"
#include "projsym.hpp"
#include "i18n.hpp"

namespace diedro {
namespace {
const double kThick = 0.5, kThin = 0.25, kTxt = 3.5, kTol = 0.01;

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
std::string fmtK(double v) { return trimNum(v, 2); }
std::string fmt(double v) { return decSep(gLoc.imperial ? trimNum(v / 25.4, 3) : trimNum(v, 2)); }
std::string fnum(double v) { return decSep(trimNum(v, 2)); }
std::string T(const char* es) { return tr(es, gLoc.lang); }
std::string Tf(const char* es, std::initializer_list<std::string> a) {
    std::string s = T(es);
    int i = 0;
    for (auto& v : a) {
        std::string k = "{" + std::to_string(i++) + "}";
        for (size_t p; (p = s.find(k)) != std::string::npos;) s.replace(p, k.size(), v);
    }
    return s;
}
// ISO 129-1 6.2: una desviación nula se escribe «0» sin signo
std::string devTxt(double v) { return std::fabs(v) < 1e-9 ? "0" : (v > 0 ? "+" : "-") + fmt(std::fabs(v)); }
std::string scaleText(double s) { return s >= 1 ? fnum(s) + ":1" : "1:" + fnum(1 / s); }

void line(Drawing& d, double x1, double y1, double x2, double y2, double w = kThin, LineType t = LineType::Continuous) { d.lines.push_back({x1, y1, x2, y2, t, w}); }
void arrow(Drawing& d, double x, double y, double dx, double dy) {
    double n = std::hypot(dx, dy);
    dx /= n; dy /= n;
    const double L = 3.0, W = 0.8;   // ISO 129-1 5.4: flecha cerrada rellena de 30° incluidos (tan15°·3)
    Poly p;
    p.pts = {{x, y}, {x + dx * L - dy * W, y + dy * L + dx * W}, {x + dx * L + dy * W, y + dy * L - dx * W}};
    d.polys.push_back(p);
}

// ---------------------------------------------------------------- análisis 3D
struct Ln { double u1, w1, u2, w2; };
struct Ar { double cu, cw, r, a0, a1; };
struct View { std::vector<Ln> vis, hid; std::vector<Ar> vArc, hArc; };

struct Feat {  // coordenada acotable: plano axial (pared/suelo/escalón) o centro de taladro/resalte
    int axis; double c; bool point = false; int forceView = -1; double area = 0;
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
};
struct Stage { double r, a0, a1; bool cone; double r0, r1; };
struct HoleGroup { std::string txt; int view; bool boss; std::vector<std::pair<double, double>> pos; std::vector<std::string> parts, keys; std::vector<double> dias; };  // pos en coordenadas (u,w) de la vista

struct Part {
    double W = 0, D = 0, H = 0;
    View v[3];
    std::vector<Feat> feats;
    std::vector<HoleGroup> holes;
    std::vector<std::string> notes;
    std::map<std::string, int> unsup;
    double unsupArea = 0, totArea = 0;
    double inclArea = 0, coneArea = 0;            // área de planos inclinados y conos suaves (salida de fundición)
    std::vector<std::array<double, 5>> coneRev;   // conos convexos con salida: eje, a0, a1, r0, r1 (cuerpos de revolución fundidos)
    bool g5 = false;   // clasificada como fundición/inyección
    std::vector<std::array<double, 4>> inclNote;   // nota, ángulo, rango de Feat creadas   // índice de la nota "Cara inclinada" y su ángulo (en G5 se funde con la salida medida)
    struct Draft { int p = -1; double th = 0, zp = 0, thMin = 0, thMax = 0; int n = 0; bool oneSide = false; } dr;   // salida medida: eje de desmoldeo, ángulo, plano de partición
    std::vector<std::array<double, 4>> softCyl;   // cilindros casi paralelos a un eje (acuerdos con salida): radio, ángulo, eje, área
    std::vector<std::pair<TopoDS_Face, double>> freeF;   // caras de forma libre y su área
    double org[3] = {0, 0, 0};   // esquina mínima de la caja
    int freeN = 0; double freeArea = 0;          // superficies de forma libre (acuerdos de fundición) sin acotar
    std::vector<std::array<double, 5>> cornerF;   // cara oblicua casi paralela a un eje k: k, ángulo en planta, ancho, área, (reservado)
    std::vector<std::array<double, 4>> softCones;   // semiángulo, Ø menor, Ø mayor, longitud
    int nSolids = 0;
    std::vector<GdtTol> gdt;
    std::vector<int> gdtView;                     // vista donde se ve la cara de cada tolerancia (-1: no situada)
    std::vector<std::pair<double, double>> gdtUW;
    gp_Trsf toModel;                              // sistema del STEP -> sistema de la pieza (el de las vistas)
    bool invalid = false;                         // BRepCheck: el STEP trae geometría inválida
    std::vector<PmiDim> pmi;
    struct Pocket { double l, w, dmin, dmax; bool rect; int a; double q[3]; int open = 0; double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0}; };   // lo/hi: caja de la cara del fondo   // 0 cerrada, 1 abierta por un lado, 2 ranura (dos lados)
    std::vector<Pocket> pockets;
    struct Section { bool on = false; double x = 0; View v; std::vector<Ln> seg; } sec;  // corte A-A por x=cte, visto desde el perfil: (u,w) como la vista de perfil
};

const int kHA[3] = {0, 0, 1}, kVA[3] = {2, 1, 2};  // eje de modelo horizontal / vertical de cada vista (alzado, planta, perfil)
double toU(int view, double x, double y) { return view == 2 ? 0 : (view == 0 ? x : x) + 0 * y; }

void collect(const TopoDS_Shape& s, std::vector<Ln>& L, std::vector<Ar>& A, double du) {
    if (s.IsNull()) return;
    for (TopExp_Explorer e(s, TopAbs_EDGE); e.More(); e.Next()) {
        BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
        double f = c.FirstParameter(), l = c.LastParameter();
        if (c.GetType() == GeomAbs_Line) {
            gp_Pnt a = c.Value(f), b = c.Value(l);
            L.push_back({a.X() + du, a.Y(), b.X() + du, b.Y()});
        } else if (c.GetType() == GeomAbs_Circle) {
            gp_Circ ci = c.Circle();
            gp_Pnt o = ci.Location();
            auto ang = [&](double u) { gp_Pnt p = c.Value(u); return std::atan2(p.Y() - o.Y(), p.X() - o.X()) * 180 / M_PI; };
            if (std::fabs(l - f - 2 * M_PI) < 1e-6) { A.push_back({o.X() + du, o.Y(), ci.Radius(), 0, 360}); continue; }
            double a0 = ang(f), a1 = ang(l), am = ang((f + l) / 2);
            auto n = [](double x) { while (x < 0) x += 360; while (x >= 360) x -= 360; return x; };
            if (n(am - a0) > n(a1 - a0)) std::swap(a0, a1);
            A.push_back({o.X() + du, o.Y(), ci.Radius(), a0, a1});
        } else {
            GCPnts_QuasiUniformDeflection q(c, 0.05);
            if (!q.IsDone()) continue;
            for (int i = 1; i < q.NbPoints(); i++) { gp_Pnt a = q.Value(i), b = q.Value(i + 1); L.push_back({a.X() + du, a.Y(), b.X() + du, b.Y()}); }
        }
    }
}

View makeView(const TopoDS_Shape& sh, const gp_Dir& N, const gp_Dir& Vx, double du) {
    View v;
    const long poles = splinePoles(sh);  // muelles, mallas: el HLR exacto tarda decenas de segundos; se usa el de malla
    HLRAlgo_Projector pr(gp_Ax2(gp_Pnt(0, 0, 0), N, Vx));
    if (poles > 800) {
        Bnd_Box bb; BRepBndLib::Add(sh, bb);
        double x0, y0, z0, x1, y1, z1; bb.Get(x0, y0, z0, x1, y1, z1);
        BRepMesh_IncrementalMesh(sh, std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0)) * 0.002, false, 0.5, false);
        Handle(HLRBRep_PolyAlgo) alg = new HLRBRep_PolyAlgo();
        alg->Load(sh);
        alg->Projector(pr);
        alg->Update();
        HLRBRep_PolyHLRToShape h;
        h.Update(alg);
        collect(h.VCompound(), v.vis, v.vArc, du);
        collect(h.OutLineVCompound(), v.vis, v.vArc, du);
        collect(h.HCompound(), v.hid, v.hArc, du);
        return v;
    }
    Handle(HLRBRep_Algo) alg = new HLRBRep_Algo();
    alg->Add(sh);
    alg->Projector(pr);
    alg->Update();
    alg->Hide();
    HLRBRep_HLRToShape h(alg);
    collect(h.VCompound(), v.vis, v.vArc, du);
    collect(h.OutLineVCompound(), v.vis, v.vArc, du);
    collect(h.HCompound(), v.hid, v.hArc, du);
    collect(h.OutLineHCompound(), v.hid, v.hArc, du);
    return v;
}

double ax3(const gp_Pnt& p, int a) { return a == 0 ? p.X() : a == 1 ? p.Y() : p.Z(); }

// (u,w) de un punto del modelo en cada vista
void viewPt(const Part& P, int view, const double q[3], double& u, double& w) {
    if (view == 0) { u = q[0]; w = q[2]; }
    else if (view == 1) { u = q[0]; w = q[1]; }
    else { u = P.D - q[1]; w = q[2]; }
}

bool analyze(const std::string& path, Part& P, std::string& err) {
    TopoDS_Shape shape;
    if (!readShapeCached(path, shape)) { err = "No se pudo leer el archivo STEP."; return false; }
    if (shape.IsNull()) { err = "El STEP no contiene ninguna forma sólida."; return false; }
    for (TopExp_Explorer e(shape, TopAbs_SOLID); e.More(); e.Next()) P.nSolids++;
    if (!P.nSolids) { err = "El STEP no contiene ningún sólido."; return false; }
    int nF0 = 0; for (TopExp_Explorer fe(shape, TopAbs_FACE); fe.More(); fe.Next()) nF0++;
    if (P.nSolids <= 5 && nF0 <= 800) P.invalid = !BRepCheck_Analyzer(shape).IsValid();   // >800 caras (moleteado, fundición): se omite el chequeo de validez (30 % del tiempo; solo da un aviso)

    // ---- sistema de coordenadas de la pieza: Z = normal plana dominante, X = la otra dirección dominante (la más larga)
    struct Cl { gp_Dir d; double area; };
    std::vector<Cl> cls;
    for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next()) {
        BRepAdaptor_Surface su(TopoDS::Face(e.Current()));
        if (su.GetType() != GeomAbs_Plane) continue;
        GProp_GProps g; BRepGProp::SurfaceProperties(TopoDS::Face(e.Current()), g);
        gp_Dir n = su.Plane().Axis().Direction();
        bool f = false;
        for (auto& c : cls) if (std::fabs(c.d.Dot(n)) > 1 - 1e-9) { c.area += g.Mass(); f = true; break; }
        if (!f) cls.push_back({n, g.Mass()});
    }
    if (cls.empty()) { err = "No se encontró ninguna cara plana: no es una pieza prismática."; return false; }
    std::sort(cls.begin(), cls.end(), [](const Cl& a, const Cl& b) { return a.area > b.area; });
    gp_Dir A = cls[0].d, B;
    if (cls.size() > 1) {   // Z = la normal plana con más superficie, salvo que otra de área comparable (≥50 %) dé una planta claramente mayor (electrodos con nervaduras: la base, no los costados de las nervaduras)
        std::vector<gp_Pnt> vp;
        { std::set<std::array<long, 3>> seen; for (TopExp_Explorer ve(shape, TopAbs_VERTEX); ve.More(); ve.Next()) { gp_Pnt q = BRep_Tool::Pnt(TopoDS::Vertex(ve.Current())); if (seen.insert({lround(q.X() * 1e4), lround(q.Y() * 1e4), lround(q.Z() * 1e4)}).second) vp.push_back(q); } }
        auto foot = [&](const gp_Dir& d, double& ok) {
            gp_Dir b; bool hb = false;
            for (auto& c : cls) if (std::fabs(c.d.Dot(d)) < 1e-6) { b = c.d; hb = true; break; }
            ok = hb ? 1 : 0; if (!hb) return 0.0;
            gp_Dir c2 = d.Crossed(b); double m1[2] = {1e30, -1e30}, m2[2] = {1e30, -1e30};
            for (auto& q : vp) { const double u = q.X() * b.X() + q.Y() * b.Y() + q.Z() * b.Z(), w = q.X() * c2.X() + q.Y() * c2.Y() + q.Z() * c2.Z(); m1[0] = std::min(m1[0], u); m1[1] = std::max(m1[1], u); m2[0] = std::min(m2[0], w); m2[1] = std::max(m2[1], w); }
            return (m1[1] - m1[0]) * (m2[1] - m2[0]);
        };
        double ok, best = foot(A, ok); if (!ok) best = 0;
        gp_Dir pick = A;
        for (size_t i = 1; i < cls.size() && i < 6; i++) {
            if (cls[i].area < 0.5 * cls[0].area) break;
            double o2; const double f = foot(cls[i].d, o2);
            if (o2 && f > 1.15 * best) { best = f; pick = cls[i].d; }
        }
        A = pick;
    }
    bool hasB = false;
    for (auto& c : cls) if (std::fabs(c.d.Dot(A)) < 1e-6) { B = c.d; hasB = true; break; }
    if (!hasB) B = gp_Ax2(gp_Pnt(0, 0, 0), A).XDirection();
    gp_Dir C = A.Crossed(B);
    gp_Trsf t1;
    t1.SetTransformation(gp_Ax3(gp_Pnt(0, 0, 0), A, B));  // global -> (X=B, Y=A×B, Z=A)
    gp_Trsf tAll = t1;
    (void)C;
    TopoDS_Shape s1 = BRepBuilderAPI_Transform(shape, t1, true).Shape();
    auto bbox = [](const TopoDS_Shape& s, double mn[3], double mx[3]) {
        Bnd_Box bb; BRepBndLib::AddOptimal(s, bb, false, false);
        bb.Get(mn[0], mn[1], mn[2], mx[0], mx[1], mx[2]);
    };
    double mn[3], mx[3];
    bbox(s1, mn, mx);
    if (mx[1] - mn[1] > mx[0] - mn[0] + 1e-6) {  // el eje X debe ser el más largo
        gp_Trsf r; r.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1)), M_PI / 2);
        s1 = BRepBuilderAPI_Transform(s1, r, true).Shape();
        tAll = r.Multiplied(tAll);
        bbox(s1, mn, mx);
    }
    gp_Trsf t2; t2.SetTranslation(gp_Vec(-mn[0], -mn[1], -mn[2]));
    TopoDS_Shape S = BRepBuilderAPI_Transform(s1, t2, true).Shape();
    P.toModel = t2.Multiplied(tAll);
    if (std::getenv("DIEDRO_TOMODEL")) { std::printf("TOMODEL"); for (int r = 1; r <= 3; r++) for (int c = 1; c <= 4; c++) std::printf(" %.9g", P.toModel.Value(r, c)); std::printf("\n"); }   // verificación independiente: STEP -> sistema de las vistas
    P.W = mx[0] - mn[0]; P.D = mx[1] - mn[1]; P.H = mx[2] - mn[2]; for (int k = 0; k < 3; k++) P.org[k] = mn[k];
    if (P.W < 1e-3 || P.D < 1e-3 || P.H < 1e-3) { err = "La pieza no tiene volumen."; return false; }

    // ---- caras
    struct PF { int a; double c; double lo[3], hi[3]; int up; double area; };
    struct CF { int a; double o[2]; double r, a0, a1, span; bool concave; };
    struct KF { int a; double o[2]; double r0, r1, a0, a1; bool concave; double span = 7; };
    std::vector<PF> planes; std::vector<CF> cyls; std::vector<KF> cones;
    std::map<std::string, int> chamf;  // c×45° -> nº
    std::map<std::pair<int, std::string>, int> incl;  // (eje, ángulo°) -> nº de caras inclinadas
    struct IP { int j, z; std::string th; double lo[3], hi[3], area, thv, pe; bool outer; };   // cara inclinada: eje cercano a su normal, eje que contiene, extremos
    std::vector<IP> inclP;
    std::set<std::array<std::string, 4>> oblq;  // (Ø, eje, ángulo°, recta del eje): un cilindro oblicuo = una recta
    auto unsup = [&](const std::string& k, double area) { P.unsup[k]++; P.unsupArea += area; };
    auto others = [](int a, int& b, int& c) { b = a == 0 ? 1 : 0; c = a == 2 ? 1 : 2; };
    for (TopExp_Explorer e(S, TopAbs_FACE); e.More(); e.Next()) {
        TopoDS_Face f = TopoDS::Face(e.Current());
        BRepAdaptor_Surface su(f);
        GProp_GProps g; BRepGProp::SurfaceProperties(f, g);
        const double area = g.Mass();
        P.totArea += area;
        Bnd_Box bb;
        { const GeomAbs_SurfaceType st0 = su.GetType(); if (st0 == GeomAbs_BSplineSurface || st0 == GeomAbs_BezierSurface || st0 == GeomAbs_OtherSurface) BRepBndLib::Add(f, bb, false); else BRepBndLib::AddOptimal(f, bb, false, false); }   // forma libre: la caja óptima es lentísima (Extrema_ExtSS); la de polos basta para situarla
        double lo[3], hi[3]; bb.Get(lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]);
        const bool rev = f.Orientation() == TopAbs_REVERSED;
        double u0, u1, v0, v1; BRepTools::UVBounds(f, u0, u1, v0, v1);
        gp_Pnt Pm; gp_Vec du, dv;
        su.D1((u0 + u1) / 2, (v0 + v1) / 2, Pm, du, dv);
        gp_Vec nrm = du.Crossed(dv);
        if (nrm.Magnitude() > 1e-12) nrm.Normalize();
        if (rev) nrm.Reverse();
        GeomAbs_SurfaceType ty = su.GetType();
        gp_Pln flatPl; bool flat = false;
        if (ty == GeomAbs_BSplineSurface || ty == GeomAbs_BezierSurface || ty == GeomAbs_SurfaceOfExtrusion) {   // plano exportado como superficie libre (salidas de fundición, tapers)
            GeomLib_IsPlanarSurface ip(BRep_Tool::Surface(f), 1e-5);
            if (ip.IsPlanar()) { flatPl = ip.Plan(); flat = true; ty = GeomAbs_Plane; }
        }
        if (ty == GeomAbs_Plane) {
            gp_Dir n = (flat ? flatPl : su.Plane()).Axis().Direction();
            double nv[3] = {n.X(), n.Y(), n.Z()};
            int a = -1;
            for (int i = 0; i < 3; i++) if (std::fabs(nv[i]) > 1 - 1e-6) a = i;
            if (a >= 0) { PF p; p.a = a; p.up = (a == 0 ? nrm.X() : a == 1 ? nrm.Y() : nrm.Z()) > 0 ? 1 : -1; p.area = area; p.c = (lo[a] + hi[a]) / 2; for (int i = 0; i < 3; i++) { p.lo[i] = lo[i]; p.hi[i] = hi[i]; } planes.push_back(p); continue; }
            int i1 = -1, i2 = -1;
            for (int i = 0; i < 3; i++) if (std::fabs(std::fabs(nv[i]) - M_SQRT1_2) < 1e-4) (i1 < 0 ? i1 : i2) = i;
            if (i2 >= 0) {
                double e1 = hi[i1] - lo[i1], e2 = hi[i2] - lo[i2];
                if (std::fabs(e1 - e2) < 0.02 * std::max(e1, e2) && e1 > 0.05) { chamf[trimNum(e1, 2)]++; continue; }
            }
            {   // plano que contiene un eje: su ángulo respecto al eje más cercano a la normal es un dato exacto de la geometría
                int z = -1, j = 0;
                for (int i = 0; i < 3; i++) { if (std::fabs(nv[i]) < 1e-6) z = i; if (std::fabs(nv[i]) > std::fabs(nv[j])) j = i; }
                if (z >= 0 && z != j) {
                    const double th = std::acos(std::min(1.0, std::fabs(nv[j]))) * 180 / M_PI;
                    incl[{j, trimNum(th, 1)}]++;
                    {   // salida: eje de desmoldeo p (el que no es ni j ni z); extremo de la cara con más saliente = plano de partición
                        IP q; q.j = j; q.z = z; q.th = trimNum(th, 1); q.thv = th; q.area = area; for (int i = 0; i < 3; i++) { q.lo[i] = lo[i]; q.hi[i] = hi[i]; }
                        const int pa = 3 - j - z;
                        const gp_Pln pl = flat ? flatPl : su.Plane(); double cf[4]; pl.Coefficients(cf[0], cf[1], cf[2], cf[3]);
                        const double sj = (j == 0 ? nrm.X() : j == 1 ? nrm.Y() : nrm.Z()) > 0 ? 1 : -1;
                        auto lat = [&](double pv) { return -(cf[3] + cf[pa] * pv) / cf[j]; };
                        q.pe = sj * lat(lo[pa]) > sj * lat(hi[pa]) ? lo[pa] : hi[pa];
                        q.outer = sj > 0 ? std::fabs(hi[j] - (j == 0 ? P.W : j == 1 ? P.D : P.H)) < 0.02 : lo[j] < 0.02;
                        inclP.push_back(q);
                    }
                    P.unsupArea += area; P.inclArea += area;
                    continue;
                }
            }
            {   // chaflán de esquina con salida: normal casi perpendicular a un eje k (≤10°) y oblicua en los otros dos
                const double nv[3] = {nrm.X(), nrm.Y(), nrm.Z()};
                for (int k = 0; k < 3; k++) {
                    const int a = (k + 1) % 3, b = (k + 2) % 3;
                    if (std::fabs(nv[k]) <= 0.18 && std::fabs(nv[a]) > 0.1 && std::fabs(nv[b]) > 0.1) {
                        double wl = 0, wh = 0;   // ancho de la cara en cada extremo del eje k: distancia entre sus dos vértices extremos
                        {
                            std::vector<gp_Pnt> pl, ph; TopExp_Explorer ev(f, TopAbs_VERTEX);
                            for (; ev.More(); ev.Next()) { gp_Pnt q = BRep_Tool::Pnt(TopoDS::Vertex(ev.Current())); const double c = k == 0 ? q.X() : k == 1 ? q.Y() : q.Z(); if (std::fabs(c - lo[k]) < 0.02) pl.push_back(q); else if (std::fabs(c - hi[k]) < 0.02) ph.push_back(q); }
                            auto wd = [&](const std::vector<gp_Pnt>& v) { double m = 0; for (size_t i = 0; i < v.size(); i++) for (size_t j = i + 1; j < v.size(); j++) m = std::max(m, v[i].Distance(v[j])); return m; };
                            wl = wd(pl); wh = wd(ph);
                        }
                        if (wl <= 0 || wh <= 0) break;
                        P.cornerF.push_back({(double)k, std::atan2(std::fabs(nv[b]), std::fabs(nv[a])) * 180 / M_PI, wl, area, wh});
                        break;
                    }
                }
            }
            unsup("cara oblicua", area);
        } else if (ty == GeomAbs_Cylinder) {
            gp_Cylinder cy = su.Cylinder();
            gp_Dir ad = cy.Axis().Direction();
            double dv3[3] = {ad.X(), ad.Y(), ad.Z()};
            int a = -1;
            for (int i = 0; i < 3; i++) if (std::fabs(dv3[i]) > 1 - 1e-6) a = i;
            if (a < 0) {
                int z = -1, j = 0;   // eje contenido en un plano coordenado: ángulo exacto al eje más cercano
                for (int i = 0; i < 3; i++) { if (std::fabs(dv3[i]) < 1e-6) z = i; if (std::fabs(dv3[i]) > std::fabs(dv3[j])) j = i; }
                if (z < 0 || z == j) {
                    int jm = 0; for (int i = 1; i < 3; i++) if (std::fabs(dv3[i]) > std::fabs(dv3[jm])) jm = i;
                    const double tj = std::acos(std::min(1.0, std::fabs(dv3[jm]))) * 180 / M_PI;
                    if (tj < 10.0) P.softCyl.push_back({cy.Radius(), tj, (double)jm, area});
                    unsup("cilindro oblicuo", area); continue;
                }
                const double th = std::acos(std::min(1.0, std::fabs(dv3[j]))) * 180 / M_PI;
                const double sg = (dv3[j] < 0) ? -1 : 1;
                gp_Pnt lc = cy.Axis().Location();
                const gp_Vec m = gp_Vec(lc.X(), lc.Y(), lc.Z()).Crossed(gp_Vec(sg * dv3[0], sg * dv3[1], sg * dv3[2]));
                oblq.insert({trimNum(2 * cy.Radius(), 2), std::to_string(j), trimNum(th, 1), trimNum(m.X(), 1) + "," + trimNum(m.Y(), 1) + "," + trimNum(m.Z(), 1)});
                P.unsupArea += area;
                continue;
            }
            CF c; c.a = a; c.r = cy.Radius(); c.a0 = lo[a]; c.a1 = hi[a];
            int b, cc; others(a, b, cc);
            gp_Pnt loc = cy.Axis().Location();
            c.o[0] = ax3(loc, b); c.o[1] = ax3(loc, cc);
            c.span = u1 - u0;
            gp_Vec rad(loc, Pm);
            rad -= gp_Vec(ad) * rad.Dot(gp_Vec(ad));
            c.concave = nrm.Dot(rad) < 0;
            cyls.push_back(c);
        } else if (ty == GeomAbs_Cone) {
            gp_Cone co = su.Cone();
            gp_Dir ad = co.Axis().Direction();
            double dv3[3] = {ad.X(), ad.Y(), ad.Z()};
            int a = -1;
            for (int i = 0; i < 3; i++) if (std::fabs(dv3[i]) > 1 - 1e-6) a = i;
            if (a < 0) { unsup("cono oblicuo", area); continue; }
            KF k; k.a = a; k.a0 = lo[a]; k.a1 = hi[a];
            int b, cc; others(a, b, cc);
            gp_Pnt loc = co.Axis().Location();
            k.o[0] = ax3(loc, b); k.o[1] = ax3(loc, cc);
            // radio en cada extremo axial: a partir del vértice del cono
            const double ta = std::tan(co.SemiAngle());
            gp_Pnt ap = co.Apex();
            double sgn = (dv3[a] > 0 ? 1 : -1);
            k.r0 = std::fabs((k.a0 - ax3(ap, a)) * sgn * ta);
            k.r1 = std::fabs((k.a1 - ax3(ap, a)) * sgn * ta);
            gp_Vec rad(loc, Pm); rad -= gp_Vec(ad) * rad.Dot(gp_Vec(ad));
            k.concave = nrm.Dot(rad) < 0;
            k.span = u1 - u0;
            cones.push_back(k);
        } else {
            if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "CURVA tipo=%d area=%.1f\n", (int)ty, area);
            if (ty == GeomAbs_BSplineSurface) { P.freeN++; P.freeArea += area; P.freeF.push_back({f, area}); }
            unsup("superficie curva compleja", area);
        }
    }

    // ---- sólido: ¿un punto está en material?
    std::vector<std::pair<Bnd_Box, TopoDS_Solid>> solids;  // caja de cada sólido: descarta rápido los puntos lejanos
    for (TopExp_Explorer e(S, TopAbs_SOLID); e.More(); e.Next()) {
        Bnd_Box bb; BRepBndLib::AddOptimal(e.Current(), bb, false, false);
        solids.push_back({bb, TopoDS::Solid(e.Current())});
    }
    std::vector<std::unique_ptr<BRepClass3d_SolidClassifier>> classifiers(solids.size());  // uno por sólido, creado al primer uso
    size_t nInside = 0;   // llamadas al clasificador (caro en piezas con rosca modelada): tras muchas se afloja el muestreo
    // Piezas con muchas caras (fundiciones, roscas modeladas): el clasificador exacto cuesta ~5 ms por punto; se sustituye por paridad de un rayo
    // contra la malla (flecha 0,03 mm), con rejilla XY. Las piezas normales siguen con el exacto.
    struct MeshIn {
        bool on = false; std::vector<std::array<double, 9>> tr; std::vector<std::vector<int>> cell; double x0 = 0, y0 = 0, cw = 1, ch = 1; int nx = 48, ny = 48;
    } mi;
    struct { const double dx = 0.00137, dy = 0.00291; } MeshIn_k;   // rayo +Z casi vertical: evita aristas exactas
    #define MI_DX MeshIn_k.dx
    #define MI_DY MeshIn_k.dy
    {
        int nF = 0; for (TopExp_Explorer fe(S, TopAbs_FACE); fe.More(); fe.Next()) nF++;
        if (nF > 300 && !std::getenv("DIEDRO_EXACT_INSIDE")) {
            BRepMesh_IncrementalMesh mesh(S, 0.03, false, 0.3, true);
            Bnd_Box all; double zr = 0;
            for (TopExp_Explorer fe(S, TopAbs_FACE); fe.More(); fe.Next()) {
                TopLoc_Location loc; Handle(Poly_Triangulation) T = BRep_Tool::Triangulation(TopoDS::Face(fe.Current()), loc);
                if (T.IsNull()) continue;
                for (int i = 1; i <= T->NbTriangles(); i++) {
                    int a1, a2, a3; T->Triangle(i).Get(a1, a2, a3);
                    gp_Pnt P1 = T->Node(a1).Transformed(loc), P2 = T->Node(a2).Transformed(loc), P3 = T->Node(a3).Transformed(loc);
                    if (fe.Current().Orientation() == TopAbs_REVERSED) std::swap(P2, P3);
                    mi.tr.push_back({P1.X(), P1.Y(), P1.Z(), P2.X(), P2.Y(), P2.Z(), P3.X(), P3.Y(), P3.Z()});
                    all.Add(P1); all.Add(P2); all.Add(P3);
                }
            }
            if (!mi.tr.empty()) {
                double a0, b0, c0, a1, b1, c1; all.Get(a0, b0, c0, a1, b1, c1);
                zr = c1 - c0; mi.x0 = a0 - 1e-6; mi.y0 = b0 - 1e-6; mi.cw = (a1 - a0 + 2e-6) / mi.nx; mi.ch = (b1 - b0 + 2e-6) / mi.ny;
                mi.cell.assign((size_t)mi.nx * mi.ny, {});
                for (size_t k = 0; k < mi.tr.size(); k++) {
                    auto& t = mi.tr[k];
                    double xa = std::min({t[0], t[3], t[6]}) - 1e-6, xb = std::max({t[0], t[3], t[6]}) + 1e-6, ya = std::min({t[1], t[4], t[7]}) - 1e-6, yb = std::max({t[1], t[4], t[7]}) + 1e-6;
                    xa -= MI_DX * zr; xb += MI_DX * zr; ya -= MI_DY * zr; yb += MI_DY * zr;   // el rayo se inclina hasta dx·Δz
                    xa = std::min(xa, xa); 
                    int i0 = std::max(0, (int)((xa - mi.x0) / mi.cw)), i1 = std::min(mi.nx - 1, (int)((xb - mi.x0) / mi.cw)), j0 = std::max(0, (int)((ya - mi.y0) / mi.ch)), j1 = std::min(mi.ny - 1, (int)((yb - mi.y0) / mi.ch));
                    for (int j = j0; j <= j1; j++) for (int i = i0; i <= i1; i++) mi.cell[(size_t)j * mi.nx + i].push_back((int)k);
                }
                mi.on = true;
            }
        }
    }
    auto insideMesh = [&](const double q[3]) {
        int ci = (int)((q[0] - mi.x0) / mi.cw), cj = (int)((q[1] - mi.y0) / mi.ch);
        if (ci < 0 || cj < 0 || ci >= mi.nx || cj >= mi.ny) return false;
        const double d[3] = {MI_DX, MI_DY, 1.0};
        int hits = 0;
        for (int k : mi.cell[(size_t)cj * mi.nx + ci]) {
            const double* t = mi.tr[k].data();
            const double e1[3] = {t[3] - t[0], t[4] - t[1], t[5] - t[2]}, e2[3] = {t[6] - t[0], t[7] - t[1], t[8] - t[2]};
            const double h[3] = {d[1] * e2[2] - d[2] * e2[1], d[2] * e2[0] - d[0] * e2[2], d[0] * e2[1] - d[1] * e2[0]};
            const double det = e1[0] * h[0] + e1[1] * h[1] + e1[2] * h[2];
            if (std::fabs(det) < 1e-14) continue;
            const double inv = 1 / det, sv[3] = {q[0] - t[0], q[1] - t[1], q[2] - t[2]};
            const double u = inv * (sv[0] * h[0] + sv[1] * h[1] + sv[2] * h[2]);
            if (u < 0 || u > 1) continue;
            const double qv[3] = {sv[1] * e1[2] - sv[2] * e1[1], sv[2] * e1[0] - sv[0] * e1[2], sv[0] * e1[1] - sv[1] * e1[0]};
            const double v = inv * (d[0] * qv[0] + d[1] * qv[1] + d[2] * qv[2]);
            if (v < 0 || u + v > 1) continue;
            if (inv * (e2[0] * qv[0] + e2[1] * qv[1] + e2[2] * qv[2]) > 0) hits++;
        }
        return (hits & 1) != 0;
    };
    auto inside = [&](const double q[3]) {
        nInside++;
        const gp_Pnt pt(q[0], q[1], q[2]);
        if (mi.on) return insideMesh(q);
        for (size_t i = 0; i < solids.size(); i++) {
            if (solids[i].first.IsOut(pt)) continue;
            if (!classifiers[i]) classifiers[i].reset(new BRepClass3d_SolidClassifier(solids[i].second));
            classifiers[i]->Perform(pt, 1e-6);
            if (classifiers[i]->State() == TopAbs_IN) return true;
        }
        return false;
    };

    // ---- cilindros: agrupar por (eje, centro, radio, extensión) y sumar ángulo
    struct CG { int a; double o[2], r, a0, a1, span; bool concave; int n; };
    std::vector<CG> cg;
    for (auto& c : cyls) {
        bool f = false;
        for (auto& g : cg)
            if (g.a == c.a && g.concave == c.concave && std::fabs(g.o[0] - c.o[0]) < 1e-4 && std::fabs(g.o[1] - c.o[1]) < 1e-4 && std::fabs(g.r - c.r) < 1e-5 && std::fabs(g.a0 - c.a0) < 1e-4 && std::fabs(g.a1 - c.a1) < 1e-4) { g.span += c.span; g.n++; f = true; break; }
        if (!f) cg.push_back({c.a, {c.o[0], c.o[1]}, c.r, c.a0, c.a1, c.span, c.concave, 1});
    }
    std::map<std::string, int> radii;  // radio de acuerdo/redondeo -> nº de caras
    struct Stack { int a; double o[2]; std::vector<Stage> st; };
    std::vector<Stack> stacks;
    std::vector<CG> bosses;
    for (auto& g : cg) {
        if (g.span < 2 * M_PI - 0.05 && !(g.concave && g.span > M_PI + 0.05)) { if (g.r <= std::max({P.W, P.D, P.H})) radii[trimNum(g.r, 2)] += g.n; continue; }   // radio mayor que la pieza: es una superficie curva de forma libre, no un acuerdo

        if (!g.concave) { bosses.push_back(g); continue; }
        Stack* s = nullptr;
        for (auto& k : stacks) if (k.a == g.a && std::fabs(k.o[0] - g.o[0]) < 1e-4 && std::fabs(k.o[1] - g.o[1]) < 1e-4) s = &k;
        if (!s) { stacks.push_back({g.a, {g.o[0], g.o[1]}, {}}); s = &stacks.back(); }
        s->st.push_back({g.r, g.a0, g.a1, false, g.r, g.r});
    }
    for (auto& k : cones) {
        bool ok = false;
        if (k.concave && k.span < M_PI - 0.05) { P.unsup["cono"]++; continue; }   // sector de cono (pared de carcasa, casco): no es un taladro, no se acota como tal
        if (k.concave)
            for (auto& s : stacks)
                if (s.a == k.a && std::fabs(s.o[0] - k.o[0]) < 1e-4 && std::fabs(s.o[1] - k.o[1]) < 1e-4) { s.st.push_back({std::max(k.r0, k.r1), k.a0, k.a1, true, k.r0, k.r1}); ok = true; }
        if (k.concave && !ok) { stacks.push_back({k.a, {k.o[0], k.o[1]}, {}}); stacks.back().st.push_back({std::max(k.r0, k.r1), k.a0, k.a1, true, k.r0, k.r1}); ok = true; }   // taladro cónico sin tramo cilíndrico (fundición)
        if (!ok) {
            const double semi = std::atan(std::fabs(k.r1 - k.r0) / std::max(1e-9, k.a1 - k.a0)) * 180 / M_PI;
            if (semi > 0.3 && semi < 10.0) { P.softCones.push_back({semi, 2 * std::min(k.r0, k.r1), 2 * std::max(k.r0, k.r1), k.a1 - k.a0}); if (!k.concave) P.coneRev.push_back({(double)k.a, k.a0, k.a1, k.r0, k.r1}); continue; }
            P.unsup["cono"]++;
        }
    }

    // ---- taladros
    struct HE { int a; double o0, o1; std::vector<double> e; };
    std::vector<HE> holeEnds;
    std::vector<HoleGroup>& HG = P.holes;
    auto addHole = [&](const std::string& txt, int view, bool boss, double u, double w, const std::vector<std::string>& parts, const std::vector<std::string>& keys, const std::vector<double>& dias) {
        for (auto& h : HG) if (h.txt == txt && h.view == view && h.boss == boss) { h.pos.push_back({u, w}); return; }
        HG.push_back({txt, view, boss, {{u, w}}, parts, keys, dias});
    };
    const int viewOfAxis[3] = {2, 0, 1};  // eje del taladro -> vista donde se ve como círculo (X: perfil, Y: alzado, Z: planta)
    auto addCenters = [&](int a, double c1, double c2) {  // centro: dos coordenadas de ordenada, forzadas a la vista del círculo
        int b, cc; others(a, b, cc);
        for (int k = 0; k < 2; k++) {
            Feat f; f.axis = k ? cc : b; f.c = k ? c2 : c1; f.point = true; f.forceView = viewOfAxis[a];
            double q[3] = {0, 0, 0}; q[b] = c1; q[cc] = c2;
            for (int i = 0; i < 3; i++) f.lo[i] = f.hi[i] = q[i];
            P.feats.push_back(f);
        }
    };
    auto tolText = [&](const std::string& base, double dia) {
        std::string key = "Ø" + fmtK(dia);
        return key;  // la tolerancia se añade al final, en el texto de la nota
    };
    (void)tolText;
    for (auto& s : stacks) {
        std::sort(s.st.begin(), s.st.end(), [](const Stage& x, const Stage& y) { return x.a0 < y.a0 || (x.a0 == y.a0 && x.a1 < y.a1); });
        double lo = 1e18, hi = -1e18;
        for (auto& g : s.st) { lo = std::min(lo, g.a0); hi = std::max(hi, g.a1); }
        int b, cc; others(s.a, b, cc);
        double q[3]; q[b] = s.o[0]; q[cc] = s.o[1];
        const double extA = P.W * (s.a == 0) + P.D * (s.a == 1) + P.H * (s.a == 2);
        // extremo abierto: sin material al otro lado; «aire» = ningún material más allá; si no, desemboca en otra cavidad
        auto endState = [&](double from, int dir) {  // 0 cerrado, 1 aire, 2 desemboca en cavidad
            q[s.a] = from + dir * 0.02;
            if (inside(q)) return 0;
            const double stp = std::max(0.25, extA / (nInside > 100 ? 8 : 80));
            for (double t = from + dir * (0.02 + stp); dir > 0 ? t < extA + 1e-9 : t > -1e-9; t += dir * stp) { q[s.a] = t; if (inside(q)) return 2; }
            return 1;
        };
        const int sLo = endState(lo, -1), sHi = endState(hi, 1);
        if (sLo == 0 && sHi == 0) { P.unsup["cavidad interna"]++; continue; }
        if ((sLo == 2 && sHi != 1) || (sHi == 2 && sLo != 1)) { P.unsup["cavidad interna"]++; continue; }
        const bool through = sLo == 1 && sHi == 1;
        const bool breaks = sLo == 2 || sHi == 2;
        bool entryHi;
        if (through) {
            double rl = 0, rh = 0;
            for (auto& g : s.st) { if (std::fabs(g.a0 - lo) < 1e-4) rl = std::max(rl, g.r); if (std::fabs(g.a1 - hi) < 1e-4) rh = std::max(rh, g.r); }
            if (std::fabs(rl - rh) > 1e-4) entryHi = rh > rl; else entryHi = s.a == 2;
        } else entryHi = sHi == 1;
        holeEnds.push_back({s.a, s.o[0], s.o[1], {}});
        for (auto& g : s.st) { holeEnds.back().e.push_back(g.a0); holeEnds.back().e.push_back(g.a1); }
        std::vector<Stage> ord = s.st;
        auto dist = [&](const Stage& g) { return entryHi ? hi - g.a1 : g.a0 - lo; };
        std::sort(ord.begin(), ord.end(), [&](const Stage& x, const Stage& y) { return dist(x) < dist(y); });
        // cilindros de la última etapa: la profundidad llega al fondo del último cilindro
        int lastCyl = -1;
        for (int i = 0; i < (int)ord.size(); i++) if (!ord[i].cone) lastCyl = i;
        if (lastCyl < 0 && ord.empty()) continue;
        std::string txt;
        std::vector<std::string> parts, keys;
        std::vector<double> dias;
        if (lastCyl < 0) {   // taladro solo cónico (salida de fundición): Ø menor y mayor, ángulo total y profundidad
            double big = 0, small = 1e18, ang = 0;
            for (auto& g : ord) { big = std::max(big, std::max(g.r0, g.r1)); small = std::min(small, std::min(g.r0, g.r1)); ang = std::max(ang, 2 * std::atan(std::fabs(g.r1 - g.r0) / std::max(1e-9, g.a1 - g.a0)) * 180 / M_PI); }
            txt = Tf("taladro cónico Ø{0} → Ø{1}, ángulo {2}° {3}", {fmt(2 * small), fmt(2 * big), fnum(ang), through ? T("pasante") : (std::string("↧") + (fmt(hi - lo)))});
            parts.push_back(txt); keys.push_back(""); dias.push_back(2 * big);
        }
        for (int i = 0; i <= lastCyl; i++) {
            const Stage& g = ord[i];
            std::string part;
            if (g.cone) {
                double big = std::max(g.r0, g.r1), small = std::min(g.r0, g.r1);
                double ang = 2 * std::atan((big - small) / std::max(1e-9, g.a1 - g.a0)) * 180 / M_PI;
                part = ("⌵Ø" + fmt(2 * big) + " " + fnum(ang) + "°");
            } else {
                double depth = entryHi ? hi - g.a0 : g.a1 - lo;
                bool cb = false;   // ISO 129-1 7.1: «⌴» si es un cilindro mayor seguido de otro menor (refrentado/abocardado)
                for (int j = i + 1; j <= lastCyl; j++) if (!ord[j].cone) { cb = ord[j].r < g.r - 1e-6; break; }
                part = std::string(cb ? "⌴" : "") + "Ø" + fmt(2 * g.r);
                if (i == lastCyl) part += breaks ? "" : " " + (through ? T("pasante") : (std::string("↧") + (fmt(depth))));
                else part += " " + (std::string("↧") + (fmt(entryHi ? hi - g.a0 : g.a1 - lo)));
            }
            txt += (txt.empty() ? "" : " + ") + part;
            parts.push_back(part);
            keys.push_back(g.cone ? "" : "Ø" + fmtK(2 * g.r));
            dias.push_back(g.cone ? 2 * std::max(g.r0, g.r1) : 2 * g.r);
        }
        const bool viewSideHi = s.a == 2;  // alzado mira desde -Y, perfil desde -X, planta desde +Z
        std::string suf;
        if (breaks) suf += " " + T("desemboca en otro taladro");
        if (entryHi != viewSideHi) suf += " " + T("(cara opuesta)");
        txt += suf;
        parts.back() += suf;
        double cq[3]; cq[b] = s.o[0]; cq[cc] = s.o[1]; cq[s.a] = 0;
        double u, w; viewPt(P, viewOfAxis[s.a], cq, u, w);
        addHole(txt, viewOfAxis[s.a], false, u, w, parts, keys, dias);
        addCenters(s.a, s.o[0], s.o[1]);
    }
    for (auto& g : bosses) {
        double cq[3]; int b, cc; others(g.a, b, cc); cq[b] = g.o[0]; cq[cc] = g.o[1]; cq[g.a] = 0;
        double u, w; viewPt(P, viewOfAxis[g.a], cq, u, w);
        const std::string bt = Tf("resalte cilíndrico Ø{0}", {fmt(2 * g.r)});
        addHole(bt, viewOfAxis[g.a], true, u, w, {bt}, {"Ø" + fmtK(2 * g.r)}, {2 * g.r});
        addCenters(g.a, g.o[0], g.o[1]);
    }

    // ---- planos axiales -> ordenadas (se omiten los del contorno: ya los dan las cotas totales)
    const double ext[3] = {P.W, P.D, P.H};
    auto isFloor = [&](const PF& p) {
        int b, cc; others(p.a, b, cc);
        for (auto& h : holeEnds) {
            if (h.a != p.a) continue;
            double rmax = 0;
            for (auto& st : stacks) if (st.a == h.a && std::fabs(st.o[0] - h.o0) < 1e-4 && std::fabs(st.o[1] - h.o1) < 1e-4) for (auto& g : st.st) rmax = std::max(rmax, g.r);
            for (auto& g : bosses) if (g.a == h.a && std::fabs(g.o[0] - h.o0) < 1e-4 && std::fabs(g.o[1] - h.o1) < 1e-4) rmax = std::max(rmax, g.r);
            if (p.lo[b] < h.o0 - rmax - 1e-3 || p.hi[b] > h.o0 + rmax + 1e-3 || p.lo[cc] < h.o1 - rmax - 1e-3 || p.hi[cc] > h.o1 + rmax + 1e-3) continue;
            for (double e : h.e) if (std::fabs(e - p.c) < 1e-4) return true;
        }
        return false;
    };
    for (auto& p : planes) {
        if (p.c < kTol || p.c < 0.12 || std::fabs(p.c - ext[p.a]) < std::max(kTol, 0.12) || isFloor(p)) continue;   // escalones <0,12 mm no se leen en el plano (junto al 0 se pisan)
        Feat f; f.axis = p.a; f.c = p.c; f.area = p.area;
        for (int i = 0; i < 3; i++) { f.lo[i] = p.lo[i]; f.hi[i] = p.hi[i]; }
        P.feats.push_back(f);

        // fondo de cajera: cara plana con material debajo y paredes en sus cuatro lados (tres = cajera abierta no se acota: sería inventar el cierre)
        int b, cc; others(p.a, b, cc);
        const double mb = (p.lo[b] + p.hi[b]) / 2, mc = (p.lo[cc] + p.hi[cc]) / 2;
        const double sd[4][2] = {{p.lo[b] - 0.02, mc}, {p.hi[b] + 0.02, mc}, {mb, p.lo[cc] - 0.02}, {mb, p.hi[cc] + 0.02}};
        double dmin = 1e18, dmax = 0;
        double dtan = 0; for (auto& q : inclP) if (q.thv > 0.3 && q.thv < 10) dtan = std::max(dtan, std::tan(q.thv * M_PI / 180));   // paredes con salida: la sonda sigue la pared
        if (p.hi[b] - p.lo[b] < 0.5 || p.hi[cc] - p.lo[cc] < 0.5) continue;   // mismo descarte que más abajo, antes de sondear el sólido
        if (planes.size() > 400) continue;  // pieza muy compleja: la búsqueda de cajeras costaría demasiado
        int nIn = 0;
        bool in4[4];
        for (int i = 0; i < 4; i++) {
            double q[3]; q[b] = sd[i][0]; q[cc] = sd[i][1]; q[p.a] = p.c + p.up * 0.02;
            in4[i] = inside(q); nIn += in4[i];
        }
        const bool two = nIn == 2 && ((in4[0] && in4[1]) || (in4[2] && in4[3]));   // ranura: dos paredes enfrentadas
        const bool open1 = nIn == 3 || two;
        int walls = (nIn >= 3 || two) ? 4 : 0;
        double wt0[4] = {0, 0, 0, 0}, wt1[4] = {-1, -1, -1, -1};   // pared i: material en wt0, ya no en wt1
        auto shw = [&](int i, double sb0, double sc0, double sgn, double tt, double* q) { (i < 2 ? q[b] = sb0 + sgn * tt * dtan : q[cc] = sc0 + sgn * tt * dtan); q[p.a] = p.c + p.up * tt; };
        for (int i = 0; i < 4 && walls == 4; i++) {   // 1.ª pasada: marcha gruesa por cada pared
            if (!in4[i]) continue;
            double q[3]; q[b] = sd[i][0]; q[cc] = sd[i][1];
            const double sb0 = q[b], sc0 = q[cc], sgn = (i % 2 == 0) ? -1.0 : 1.0;
            const double stp = std::max(0.5, ext[p.a] / 16);
            double t0 = 0.02, t1 = -1;
            for (double t = 0.02 + stp; t < ext[p.a] + stp; t += stp) { shw(i, sb0, sc0, sgn, t, q); if (!inside(q)) { t1 = t; break; } t0 = t; }
            if (t1 < 0) { walls = -9; break; }
            wt0[i] = t0; wt1[i] = t1;
        }
        if (walls == 4 && open1) {   // lados libres: la profundidad debe coincidir en todas las paredes; si los intervalos ya no se solapan, descarta sin afinar
            double mx0 = 0, mn1 = 1e18; for (int i = 0; i < 4; i++) if (in4[i]) { mx0 = std::max(mx0, wt0[i]); mn1 = std::min(mn1, wt1[i]); }
            if (mx0 - mn1 > 0.02) continue;
        }
        for (int i = 0; i < 4 && walls == 4; i++) {   // 2.ª pasada: bisección
            if (!in4[i]) continue;
            double q[3]; q[b] = sd[i][0]; q[cc] = sd[i][1];
            const double sb0 = q[b], sc0 = q[cc], sgn = (i % 2 == 0) ? -1.0 : 1.0;
            double t0 = wt0[i], t1 = wt1[i];
            for (int it = 0; it < 16; it++) { const double m = (t0 + t1) / 2; shw(i, sb0, sc0, sgn, m, q); (inside(q) ? t0 : t1) = m; }
            dmin = std::min(dmin, t1); dmax = std::max(dmax, t1);
        }
        if (walls != 4) continue;
        const double l1 = p.hi[b] - p.lo[b], l2 = p.hi[cc] - p.lo[cc];
        if (l1 < 0.5 || l2 < 0.5 || dmin < 0.1 || (open1 && (dmax - dmin > 0.02 || dmax > std::max(l1, l2))) || (two && p.area < 0.985 * l1 * l2)) continue;
        for (int oi = 0; oi < 4 && open1; oi++) {   // cada lado libre debe salir al exterior: sin material a media profundidad hasta el borde de la pieza
            if (in4[oi]) continue;
            const int ob = oi < 2 ? b : cc, oc = oi < 2 ? cc : b;
            const double lim = oi % 2 == 0 ? 0 : (oi < 2 ? (b == 0 ? P.W : b == 1 ? P.D : P.H) : (cc == 0 ? P.W : cc == 1 ? P.D : P.H));
            double q[3]; q[p.a] = p.c + p.up * dmin / 2; q[oc] = oi < 2 ? mc : mb;
            const double st = (oi % 2 == 0 ? p.lo[ob] : p.hi[ob]);
            const double en = oi % 2 == 0 ? 0.0 : lim;
            bool clear = true;
            for (int i = 1; i <= 24 && clear; i++) { q[ob] = st + (en - st) * i / 24.0; if (inside(q)) clear = false; }
            if (!clear) { walls = -9; break; }
        }
        if (walls != 4) continue;
        Part::Pocket k{std::max(l1, l2), std::min(l1, l2), dmin, dmax, p.area > 0.985 * l1 * l2, p.a, {0, 0, 0}};
        k.q[b] = mb; k.q[cc] = mc; k.q[p.a] = p.c; k.open = two ? 2 : open1 ? 1 : 0; for (int i = 0; i < 3; i++) { k.lo[i] = p.lo[i]; k.hi[i] = p.hi[i]; }
        P.pockets.push_back(k);
    }
    if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "INSIDE calls=%zu\n", nInside);
    {
        std::vector<std::pair<std::string, int>> rv(radii.begin(), radii.end());
        if (rv.size() > 10) {   // listado largo: los 8 más repetidos y el resto resumido (decisión propia, no es cota)
            std::stable_sort(rv.begin(), rv.end(), [](auto& a, auto& b) { return a.second > b.second; });
            int rest = 0, nr = 0; for (size_t i = 8; i < rv.size(); i++) { rest += rv[i].second; nr++; }
            rv.resize(8);
            std::stable_sort(rv.begin(), rv.end(), [](auto& a, auto& b) { return std::atof(a.first.c_str()) < std::atof(b.first.c_str()); });
            for (auto& kv : rv) P.notes.push_back(Tf("Radios {1}× R{0}", {decSep(kv.first), std::to_string(kv.second)}));
            P.notes.push_back(Tf("Otros {0} radios de {1} valores distintos (ver el modelo 3D).", {std::to_string(rest), std::to_string(nr)}));
        } else for (auto& kv : rv) P.notes.push_back(Tf("Radios {1}× R{0}", {decSep(kv.first), std::to_string(kv.second)}));
    }
    {
        std::map<std::array<std::string, 3>, int> ob;
        for (auto& q : oblq) ob[{q[0], q[1], q[2]}]++;
        int smallN = 0;
        for (auto& kv : ob) {
            if (ob.size() > 6 && std::atof(kv.first[0].c_str()) < 5) { smallN += kv.second; continue; }   // facetas de forma libre, no taladros
            P.notes.push_back((kv.second > 1 ? std::to_string(kv.second) + "× " : std::string()) + Tf("Cilindro oblicuo Ø{0}, eje a {1}° respecto al eje {2}", {decSep(kv.first[0]), decSep(kv.first[2]), std::string(1, "XYZ"[std::stoi(kv.first[1])])}) + " " + T("(solo ángulo; posición sin acotar)"));
        }
        if (smallN) P.notes.push_back(Tf("Sin listar: {0} cilindros oblicuos menores de Ø5 (ver el modelo 3D).", {std::to_string(smallN)}));
    }
    {
        size_t shown = 0, more = 0, moreF = 0;
        for (auto& kv : incl) {
            if (++shown > 5) { more++; moreF += kv.second; continue; }
            // posición: se acotan los extremos de su arista en la vista donde se ve de canto (el plano contiene el eje z)
            const size_t fb = P.feats.size();
            for (auto& q : inclP) {
                if (q.j != kv.first.first || q.th != kv.first.second) continue;
                for (int a = 0; a < 3; a++) {
                    if (a == q.z) continue;
                    for (double c : {q.lo[a], q.hi[a]}) {
                        if (c < kTol || std::fabs(c - ext[a]) < kTol) continue;
                        Feat f; f.axis = a; f.c = c; f.area = q.area; f.forceView = q.z == 1 ? 0 : q.z == 2 ? 1 : 2;
                        for (int i = 0; i < 3; i++) { f.lo[i] = q.lo[i]; f.hi[i] = q.hi[i]; }
                        P.feats.push_back(f);
                    }
                }
            }
            P.inclNote.push_back({(double)P.notes.size(), std::atof(kv.first.second.c_str()), (double)fb, (double)P.feats.size()});
            P.notes.push_back((kv.second > 1 ? std::to_string(kv.second) + "× " : std::string()) + Tf("Cara inclinada {0}° respecto al eje {1}", {decSep(kv.first.second), std::string(1, "XYZ"[kv.first.first])}));
        }
        if (more) P.notes.push_back(Tf("Otras {0} caras inclinadas en {1} ángulos más (posición sin acotar).", {std::to_string(moreF), std::to_string(more)}));
    }
    {   // salida medida (solo se usa en G5): eje de desmoldeo con más área inclinada, su ángulo y el plano de partición
        double best = 0; int bp = -1;
        for (int pa = 0; pa < 3; pa++) { double a = 0; for (auto& q : inclP) if (3 - q.j - q.z == pa) a += q.area; if (a > best) { best = a; bp = pa; } }
        if (bp >= 0) {
            std::vector<double> ths, pes;
            for (auto& q : inclP) if (3 - q.j - q.z == bp && q.thv <= 10.0) { ths.push_back(q.thv); if (q.outer) pes.push_back(q.pe); }
            if (ths.size() >= 2 && !pes.empty()) {
                std::sort(ths.begin(), ths.end()); std::sort(pes.begin(), pes.end());
                P.dr.p = bp; P.dr.th = ths[ths.size() / 2]; P.dr.thMin = ths.front(); P.dr.thMax = ths.back(); P.dr.n = (int)ths.size();
                P.dr.zp = pes[pes.size() / 2];
                P.dr.oneSide = P.dr.zp < kTol || std::fabs(P.dr.zp - ext[bp]) < kTol;
            }
        }
        if (P.dr.p < 0 && !P.coneRev.empty()) {   // cuerpo de revolución (polea, brida): la salida está en conos coaxiales
            std::vector<double> ths, big; int ax = (int)P.coneRev[0][0];
            for (auto& k : P.coneRev) if ((int)k[0] == ax) {
                ths.push_back(std::atan(std::fabs(k[4] - k[3]) / std::max(1e-9, k[2] - k[1])) * 180 / M_PI);
                big.push_back(k[3] > k[4] ? k[1] : k[2]);   // cota del extremo ancho
            }
            std::sort(ths.begin(), ths.end());
            const double extA = ax == 0 ? P.W : ax == 1 ? P.D : P.H;
            double zp = big[0]; int nb = 0;
            for (double b : big) if (std::fabs(b - zp) < 0.05) nb++;
            P.dr.p = ax; P.dr.th = ths[ths.size() / 2]; P.dr.thMin = ths.front(); P.dr.thMax = ths.back(); P.dr.n = (int)ths.size();
            P.dr.zp = zp; P.dr.oneSide = nb < 2 || zp < kTol || std::fabs(zp - extA) < kTol;
        }
        for (auto& c : P.softCones) P.coneArea += 0;  // (el área de los conos suaves no se acumula: son pocos y pequeños)
    }
    {   // chaflanes: los 3 tamaños más repetidos; el resto resumido (evita notas que invaden las vistas)
        std::vector<std::pair<int, std::string>> cv; for (auto& kv : chamf) cv.push_back({-kv.second, kv.first});
        std::sort(cv.begin(), cv.end());
        int rest = 0, restN = 0;
        for (size_t i = 0; i < cv.size(); i++) {
            if (i < 3 || cv.size() == 4) P.notes.push_back(Tf("Chaflanes {1}× {0}×45°", {decSep(cv[i].second), std::to_string(-cv[i].first)}));
            else { rest -= cv[i].first; restN++; }
        }
        if (rest) P.notes.push_back(Tf("Otros {0} chaflanes de {1} tamaños distintos (×45°), sin listar", {std::to_string(rest), std::to_string(restN)}));
    }

    // ---- vistas (HLR)
    P.v[0] = makeView(S, gp_Dir(0, -1, 0), gp_Dir(1, 0, 0), 0);
    P.v[1] = makeView(S, gp_Dir(0, 0, 1), gp_Dir(1, 0, 0), 0);
    P.v[2] = makeView(S, gp_Dir(-1, 0, 0), gp_Dir(0, -1, 0), P.D);
    // ---- sección A-A por el centro de la cajera más profunda (solo si su eje no es X: se vería de canto)
    if (!P.pockets.empty()) {
        size_t bi = 0;
        for (size_t i = 1; i < P.pockets.size(); i++) if (P.pockets[i].dmax > P.pockets[bi].dmax) bi = i;
        const auto& k = P.pockets[bi];
        if (k.a != 0 && k.dmax >= 2) {
            const double cx = k.q[0];
            BRepPrimAPI_MakeBox mbx(gp_Pnt(cx, -1, -1), gp_Pnt(P.W + 1, P.D + 1, P.H + 1));
            TopoDS_Shape half = BRepAlgoAPI_Common(S, mbx.Shape()).Shape();
            if (!half.IsNull()) {
                P.sec.v = makeView(half, gp_Dir(-1, 0, 0), gp_Dir(0, -1, 0), P.D);
                BRepAlgoAPI_Section sc(S, gp_Pln(gp_Pnt(cx, 0, 0), gp_Dir(1, 0, 0)));
                for (TopExp_Explorer e(sc.Shape(), TopAbs_EDGE); e.More(); e.Next()) {
                    BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
                    GCPnts_QuasiUniformDeflection q(c, 0.05);
                    if (!q.IsDone()) continue;
                    for (int i = 1; i < q.NbPoints(); i++) { gp_Pnt a = q.Value(i), b = q.Value(i + 1); P.sec.seg.push_back({P.D - a.Y(), a.Z(), P.D - b.Y(), b.Z()}); }
                }
                P.sec.on = !P.sec.seg.empty(); P.sec.x = cx;
            }
        }
    }
    // ocultas: solo las de taladros y cajeras (rectángulo de cada uno en cada vista); el resto ensucia el plano
    {
        struct Rc { double u0, w0, u1, w1; };
        std::vector<Rc> rc;
        auto addBox = [&](const double lo[3], const double hi[3]) {
            for (int v = 0; v < 3; v++) {
                double u0, w0, u1, w1;
                viewPt(P, v, lo, u0, w0); viewPt(P, v, hi, u1, w1);
                rc.push_back({std::min(u0, u1) - 0.05, std::min(w0, w1) - 0.05, std::max(u0, u1) + 0.05, std::max(w0, w1) + 0.05});
            }
        };
        auto inRect = [&](int v, double u, double w) {
            for (size_t i = v; i < rc.size(); i += 3) if (u >= rc[i].u0 && u <= rc[i].u1 && w >= rc[i].w0 && w <= rc[i].w1) return true;
            return false;
        };
        for (auto& h : holeEnds) {
            double rmax = 0, lo = 1e18, hi = -1e18;
            for (auto& st : stacks) if (st.a == h.a && std::fabs(st.o[0] - h.o0) < 1e-4 && std::fabs(st.o[1] - h.o1) < 1e-4) for (auto& g : st.st) rmax = std::max(rmax, g.r);
            for (double e : h.e) { lo = std::min(lo, e); hi = std::max(hi, e); }
            int b, cc; others(h.a, b, cc);
            double l[3], u[3];
            l[h.a] = lo; u[h.a] = hi; l[b] = h.o0 - rmax; u[b] = h.o0 + rmax; l[cc] = h.o1 - rmax; u[cc] = h.o1 + rmax;
            addBox(l, u);
        }
        for (auto& k : P.pockets) {
            double l[3], u[3];
            const double r = std::max(k.l, k.w) / 2;
            for (int i = 0; i < 3; i++) { l[i] = k.q[i] - r; u[i] = k.q[i] + r; }
            l[k.a] = k.q[k.a] - k.dmax; u[k.a] = k.q[k.a] + k.dmax;
            addBox(l, u);
        }
        for (int v = 0; v < 3; v++) {
            std::vector<Ln> hl; std::vector<Ar> ha;
            for (auto& l : P.v[v].hid) if (inRect(v, l.u1, l.w1) && inRect(v, l.u2, l.w2)) hl.push_back(l);
            for (auto& a : P.v[v].hArc) if (inRect(v, a.cu, a.cw)) ha.push_back(a);
            P.v[v].hid = hl; P.v[v].hArc = ha;
        }
    }
    P.pmi = readPmi(path, &P.gdt);
    for (auto& g : P.gdt) {   // cara referida por el propio STEP, proyectada en la vista que la ve de frente
        int vw = -1; double u = 0, w = 0;
        if (g.hasPt && g.hasDir) {
            gp_Pnt q = gp_Pnt(g.pt[0], g.pt[1], g.pt[2]).Transformed(P.toModel);
            gp_Dir n = gp_Dir(g.dir[0], g.dir[1], g.dir[2]).Transformed(P.toModel);
            double qq[3] = {q.X(), q.Y(), q.Z()};
            for (int k = 0; k < 3; k++)
                if (std::fabs(n.Coord(k + 1)) > 0.999) { vw = k == 2 ? 1 : (k == 1 ? 0 : 2); viewPt(P, vw, qq, u, w); }
        }
        P.gdtView.push_back(vw);
        P.gdtUW.push_back({u, w});
    }
    return true;
}

// ---------------------------------------------------------------- composición
struct Sheet { const char* name; double w, h; };
const Sheet kSheets[] = {{"A4", 297, 210}, {"A3", 420, 297}, {"A2", 594, 420}, {"A1", 841, 594}, {"A0", 1189, 841}};
const double kScales[] = {50, 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01};

struct Ord { double c, p, au, aw; };  // valor de modelo, posición a lo largo del eje de la zona, ancla (u,w)
struct Group { std::vector<Ord> it; std::string pitch; };   // pitch: nota «N× paso = total» de una serie equidistante (UNE 1-039 / ISO 129-1)
enum Zone { ZTop, ZBottom, ZLeft, ZRight };

bool visibleAt(const View& v, bool horizOrient, double p, double l0, double l1) {
    for (auto& s : v.vis) {
        if (horizOrient) {  // línea vertical en u=p, tramo en w
            if (std::fabs(s.u1 - s.u2) > 1e-6 || std::fabs(s.u1 - p) > 0.02) continue;
            if (std::min(std::max(s.w1, s.w2), l1) - std::max(std::min(s.w1, s.w2), l0) > 0.2) return true;
        } else {
            if (std::fabs(s.w1 - s.w2) > 1e-6 || std::fabs(s.w1 - p) > 0.02) continue;
            if (std::min(std::max(s.u1, s.u2), l1) - std::max(std::min(s.u1, s.u2), l0) > 0.2) return true;
        }
    }
    return false;
}

void fan(const std::vector<double>& p, std::vector<double>& q, double sep) {
    q = p;
    for (int it = 0; it < 200; it++) {
        bool ch = false;
        for (size_t i = 0; i + 1 < q.size(); i++)
            if (q[i + 1] - q[i] < sep - 1e-9) { double d = (sep - (q[i + 1] - q[i])) / 2; q[i] -= d; q[i + 1] += d; ch = true; }
        if (!ch) break;
    }
}

const double kJog = 4;
bool gZeroMarks = true;   // marca «0» de origen en las ordenadas; se omite si con ella el candidato solapa

struct Built { Drawing d; bool fits; };

// grupos de ordenadas por vista: g[vista][0]=horizontal (a lo largo de u), g[vista][1]=vertical (a lo largo de w)
void makeGroups(const Part& P, Group g[3][2]) {
    const int prio[3][2] = {{1, 0}, {1, 2}, {0, 2}};  // por eje X,Y,Z: vistas candidatas
    auto addTo = [&](int view, const Feat& f) {
        bool horiz = f.axis == kHA[view];
        bool vert = f.axis == kVA[view];
        if (!horiz && !vert) return false;
        double q0[3], q1[3];
        double lo[3], hi[3];
        for (int i = 0; i < 3; i++) { lo[i] = f.lo[i]; hi[i] = f.hi[i]; }
        double ul, wl, uh, wh;
        q0[0] = lo[0]; q0[1] = lo[1]; q0[2] = lo[2]; q1[0] = hi[0]; q1[1] = hi[1]; q1[2] = hi[2];
        viewPt(P, view, q0, ul, wl); viewPt(P, view, q1, uh, wh);
        if (ul > uh) std::swap(ul, uh);
        if (wl > wh) std::swap(wl, wh);
        Ord o;
        o.c = f.c;
        Zone z;
        if (horiz) {
            o.p = view == 2 ? P.D - f.c : f.c;
            z = view == 1 ? ZBottom : ZTop;
            o.au = o.p; o.aw = z == ZBottom ? wl : wh;
            if (f.point) o.aw = wl;
        } else {
            o.p = f.c;
            z = view == 2 ? ZRight : ZLeft;
            o.aw = o.p; o.au = z == ZRight ? uh : ul;
            if (f.point) o.au = ul;
        }
        auto& G = g[view][horiz ? 0 : 1].it;
        for (auto& e : G) if (std::fabs(e.c - f.c) < kTol) return true;
        G.push_back(o);
        return true;
    };
    for (auto& f : P.feats) {
        if (f.forceView >= 0) { addTo(f.forceView, f); continue; }
        const int* pv = prio[f.axis];
        int pick = pv[0];
        for (int k = 0; k < 2; k++) {
            int view = pv[k];
            bool horiz = f.axis == kHA[view];
            int oa = horiz ? kVA[view] : kHA[view];
            bool vis;
            double l0 = f.lo[oa], l1 = f.hi[oa];
            if (view == 2 && oa == 1) { double a = P.D - l1, b = P.D - l0; l0 = a; l1 = b; }
            vis = visibleAt(P.v[view], horiz, horiz ? (view == 2 ? P.D - f.c : f.c) : f.c, l0, l1);
            if (vis) { pick = view; break; }
        }
        addTo(pick, f);
    }
    for (int v = 0; v < 3; v++)
        for (int o = 0; o < 2; o++) {
            auto& it = g[v][o].it;
            std::sort(it.begin(), it.end(), [](const Ord& a, const Ord& b) { return a.p < b.p; });
            // serie equidistante de ≥5 cotas: se dejan los extremos y se anota el paso (no se acota cada elemento por separado)
            size_t bs = 0, bl = 0;
            for (size_t i = 0; i + 1 < it.size();) {
                size_t j = i + 1;
                while (j + 1 < it.size() && std::fabs((it[j + 1].p - it[j].p) - (it[i + 1].p - it[i].p)) < 0.01) j++;
                if (j - i + 1 > bl) { bs = i; bl = j - i + 1; }
                i = j;
            }
            if (bl >= 5) {
                const double st = it[bs + 1].p - it[bs].p;
                g[v][o].pitch = Tf("Paso: {0}× {1} (={2})", {std::to_string(bl - 1), fmt(st), fmt(st * (bl - 1))});
                it.erase(it.begin() + bs + 1, it.begin() + bs + bl - 1);
            }
        }
}

std::string ordText(double c) { return fmt(c); }

Built build(const Part& P, const Group G[3][2], const Meta& meta, const Sheet& sh, double s, bool withSec) {
    const bool secOn = P.sec.on && withSec;
    Built B;
    Drawing& d = B.d;
    d.sheetW = sh.w; d.sheetH = sh.h; d.sheetName = sh.name; d.scale = s;
    const double fx0 = 20, fx1 = sh.w - 10, fy0 = 10, fy1 = sh.h - 10, titleH = 36;
    line(d, fx0, fy0, fx1, fy0, kThick); line(d, fx1, fy0, fx1, fy1, kThick); line(d, fx1, fy1, fx0, fy1, kThick); line(d, fx0, fy1, fx0, fy0, kThick);
    d.groups = {"Alzado", "Planta", "Perfil", "Sección A-A"};

    // textos de ordenadas y profundidad de cada zona
    auto zoneDepth = [&](int v, int o) {
        double tw = 0;
        for (auto& e : G[v][o].it) tw = std::max(tw, textW(ordText(e.c), kTxt));
        return G[v][o].it.empty() ? 0.0 : 1 + kJog + 1 + tw + 1;
    };
    const double zFT = zoneDepth(0, 0), zFL = zoneDepth(0, 1), zTB = zoneDepth(1, 0), zTL = zoneDepth(1, 1), zLT = zoneDepth(2, 0), zLR = zoneDepth(2, 1);
    const double Ws = P.W * s, Ds = P.D * s, Hs = P.H * s;
    // avisos y notas (cuántas líneas)
    std::vector<std::string> notes;
    for (auto& h : P.holes) {
        // el texto de cada nota lo lleva la letra; se construye después
        (void)h;
    }
    double x0 = fx0 + 4 + std::max(zFL, zTL) + 2;
    double xL = x0 + Ws + 16;
    double xHline = xL + Ds + zLR + 9;
    double yWline = fy1 - 6;
    double yFT = yWline - 4 - std::max(zFT, zLT) - 1;
    double yFB = yFT - Hs;
    double yT1 = yFB - 12, yT0 = yT1 - Ds;
    double lowest = yT0 - zTB - 3 - (P.g5 ? 5 : 0);   // en G5 más aire: las ordenadas bajo la planta rozaban las notas
    // tags/notas de taladros
    std::vector<std::string> noteLines;
    std::vector<std::string> tags;
    std::vector<std::vector<std::string>> shownParts;
    std::string letter = "A";
    auto nextTag = [&]() {   // A..Z, AA, AB… sin repetir nunca una etiqueta
        int i = (int)letter.size() - 1;
        while (i >= 0 && letter[i] == 'Z') letter[i--] = 'A';
        if (i < 0) letter = "A" + letter; else letter[i]++;
    };
    for (auto& h : P.holes) {
        std::string joined;
        std::vector<std::string> sp;
        for (size_t i = 0; i < h.parts.size(); i++) {
            std::string pt = h.parts[i];
            if (!h.keys[i].empty()) {
                // rosca o tolerancia: solo si el usuario (o el PMI del STEP) la declara; se añade tras el Ø
                std::string extra;
                auto it = meta.tols.find(h.keys[i]);
                if (it != meta.tols.end() && !it->second.empty()) extra = it->second;
                else if (!h.keys[i].empty())
                    for (auto& q : P.pmi)
                        if (q.diameter && !q.radius && std::fabs(q.value - h.dias[i]) < 1e-3) {
                            if (std::fabs(q.upper - q.lower) < 1e-9) extra = "±" + fmt(q.upper);
                            else extra = devTxt(q.upper) + "/" + devTxt(q.lower);
                            break;
                        }
                if (!extra.empty()) {
                    size_t sp0 = pt.find(' ');
                    pt = sp0 == std::string::npos ? pt + " " + extra : pt.substr(0, sp0) + " " + extra + pt.substr(sp0);
                }
            }
            if (!sp.empty() && sp.back() == pt && h.keys[i].empty()) {   // partes idénticas seguidas (p. ej. dos avellanados): «2× …»
                size_t at = joined.rfind(" + ");
                at = at == std::string::npos ? 0 : at + 3;
                size_t k = 0; while (at + k < joined.size() && std::isdigit((unsigned char)joined[at + k])) k++;
                const bool has = k > 0 && joined.compare(at + k, 3, "× ") == 0;   // «N× »: ya agrupada
                if (has) joined.replace(at, k, std::to_string(std::atoi(joined.c_str() + at) + 1));
                else joined.insert(at, "2× ");
            } else joined += (joined.empty() ? "" : " + ") + pt;
            sp.push_back(pt);
        }
        shownParts.push_back(sp);
        tags.push_back(letter);
        if (joined.size() > 170) { size_t c = joined.rfind(" + ", 150); if (c != std::string::npos) joined = joined.substr(0, c) + " + …"; }   // rosca modelada: escalones de hélice, no un taladro de 30 tramos
        noteLines.push_back(letter + ": " + (h.pos.size() > 1 ? std::to_string(h.pos.size()) + "× " : "") + joined);
        nextTag();
    }
    {   // tabla de centros (utillaje/placas con muchos taladros): cada letra con las coordenadas (u;w) de sus centros en la vista
        size_t tot = 0; int tv = -1;
        for (auto& h : P.holes) if (!h.boss && h.view == 1) tot += h.pos.size();
        if (tot >= 8) tv = 1;
        if (tv == 1) {
            for (size_t i = P.holes.size(); i-- > 0;) {   // las notas se rotulan en orden inverso al de inserción
                auto& h = P.holes[i];
                if (h.boss || h.view != 1) continue;
                std::string ln = tags[i] + ":";
                if (h.pos.size() < 40) { for (auto& q : h.pos) ln += " (" + fmt(q.first) + ";" + fmt(q.second) + ")"; noteLines.push_back(ln); continue; }
                {   // muchos centros: por filas, los tramos de paso constante (≥4 centros) se escriben «(x0→x1;y) paso p, n×»
                    std::map<long, std::vector<double>> rows;
                    for (auto& q : h.pos) rows[std::lround(q.second * 100)].push_back(q.first);
                    for (auto& r : rows) {
                        auto& xs = r.second; std::sort(xs.begin(), xs.end());
                        const std::string y = fmt(r.first / 100.0);
                        size_t i = 0;
                        while (i < xs.size()) {
                            size_t j = i + 1; const double st = j < xs.size() ? xs[j] - xs[i] : 0;
                            while (j < xs.size() && st > 0.05 && std::fabs(xs[j] - xs[j - 1] - st) < 0.02) j++;
                            if (j - i >= 4) { ln += " (" + fmt(xs[i]) + "→" + fmt(xs[j - 1]) + ";" + y + ") " + Tf("paso {0}, {1}×", {fmt(st), std::to_string(j - i)}); i = j; }
                            else { ln += " (" + fmt(xs[i]) + ";" + y + ")"; i++; }
                        }
                    }
                }
                noteLines.push_back(ln);
            }
            noteLines.push_back(T("Centros de taladros (X;Y) desde el origen de la planta:"));
        }
    }
    for (auto& n : P.notes) noteLines.push_back(n);
    for (int v = 0; v < 3; v++) for (int o = 0; o < 2; o++) if (!G[v][o].pitch.empty()) noteLines.push_back(G[v][o].pitch);
    // tolerancias geométricas del STEP: las de cara conocida se dibujan como marco T1, T2… con su etiqueta junto a la cara; el resto, en las notas
    static const char* gdtNm[] = {"", "Angularidad", "Alabeo circular", "Redondez", "Coaxialidad", "Concentricidad", "Cilindricidad", "Planitud", "Paralelismo", "Perpendicularidad", "Posición", "Perfil de línea", "Perfil de superficie", "Rectitud", "Simetría", "Alabeo total"};
    auto gdtCells = [&](const GdtTol& g) {
        std::vector<std::string> c{T(gdtNm[g.type]), g.value > 0 ? fmt(g.value) : "?"};
        size_t a = 0;
        while (a < g.datums.size()) {
            size_t b = g.datums.find(" | ", a);
            c.push_back(g.datums.substr(a, b == std::string::npos ? std::string::npos : b - a));
            if (b == std::string::npos) break;
            a = b + 3;
        }
        return c;
    };
    auto gdtW = [&](const GdtTol& g) { double w = 10; for (auto& c : gdtCells(g)) w += textW(c, kTxt) + 4; return w; };
    std::vector<size_t> frames;
    {
        const double yb = fy0 + 4.5 * (P.unsup.size() + 5) + 4, bxn = fx1 - std::min(180.0, fx1 - fx0);
        for (size_t i = 0; i < P.gdt.size() && frames.size() < 12; i++) {
            if (P.gdt[i].type <= 0 || P.gdt[i].type > 15 || P.gdtView[i] < 0) continue;
            if (yb + 9 * (frames.size() + 1) > lowest - 4) break;
            if (fx0 + 4 + gdtW(P.gdt[i]) > bxn - 4) continue;
            frames.push_back(i);
        }
        int shown = 0;
        for (size_t i = 0; i < P.gdt.size(); i++) {
            const GdtTol& g = P.gdt[i];
            if (g.type <= 0 || g.type > 15 || std::find(frames.begin(), frames.end(), i) != frames.end()) continue;
            if (++shown > 8) { noteLines.push_back("…"); break; }
            noteLines.push_back(T("Tol. geométrica:") + " " + T(gdtNm[g.type]) + " " + (g.value > 0 ? fmt(g.value) : T("(valor no leído del STEP)")) + (g.datums.empty() ? "" : " | " + g.datums));
        }
    }
    std::vector<std::string> pocketTag;
    {
        std::vector<int> cnt(P.pockets.size(), 1);
        std::vector<bool> dup(P.pockets.size(), false);
        for (size_t i = 0; i < P.pockets.size(); i++)
            for (size_t j = i + 1; j < P.pockets.size(); j++) {
                auto &a = P.pockets[i], &b = P.pockets[j];
                if (dup[j] || a.open != b.open || a.rect != b.rect || std::fabs(a.l - b.l) > 0.01 || std::fabs(a.w - b.w) > 0.01 || std::fabs(a.dmin - b.dmin) > 0.01 || std::fabs(a.dmax - b.dmax) > 0.01) continue;
                dup[j] = true; cnt[i]++;
            }
        for (size_t i = 0; i < P.pockets.size(); i++) {
            const auto& k = P.pockets[i];
            const std::string dep = (std::string("↧") + (k.dmax - k.dmin < 0.01 ? fmt(k.dmax) : fmt(k.dmin) + "–" + fmt(k.dmax)));
            if (dup[i]) {   // misma cajera que otra anterior: misma letra
                size_t f = 0;
                for (size_t j = 0; j < i; j++) { auto &a = P.pockets[j], &b = P.pockets[i]; if (!dup[j] && a.open == b.open && a.rect == b.rect && std::fabs(a.l - b.l) <= 0.01 && std::fabs(a.w - b.w) <= 0.01 && std::fabs(a.dmin - b.dmin) <= 0.01 && std::fabs(a.dmax - b.dmax) <= 0.01) { f = j; break; } }
                pocketTag.push_back(pocketTag[f]);
                continue;
            }
            pocketTag.push_back(letter);
            noteLines.push_back(letter + ": " + (cnt[i] > 1 ? std::to_string(cnt[i]) + "× " : "") + (k.rect && !k.open ? Tf("Cajera {0}×{1} {2}", {fmt(k.l), fmt(k.w), dep}) : Tf("Cajera ({3}) {0}×{1} {2}", {fmt(k.l), fmt(k.w), dep, std::string(k.open == 2 ? T("abierta por dos lados") : k.open ? T("abierta por un lado") : "") + (k.open && !k.rect ? ", " : "") + (k.rect ? "" : T("contorno no rectangular, envolvente"))})));
            nextTag();
        }
    }
    std::vector<std::string> warns = P.unsup.empty() ? std::vector<std::string>() : std::vector<std::string>();
    if (P.nSolids > 1) warns.insert(warns.begin(), Tf("CONJUNTO DE {0} SÓLIDOS: el plano los muestra juntos; NO es una pieza individual.", {std::to_string(P.nSolids)}));
    if (P.invalid) warns.push_back(T("GEOMETRÍA INVÁLIDA en el STEP: las cotas pueden ser incorrectas; compruébalas antes de fabricar."));
    if (!P.gdt.empty() && frames.empty()) warns.push_back(Tf("El STEP trae {0} tolerancias geométricas: se listan en las notas, sin situarlas sobre la pieza.", {std::to_string(P.gdt.size())}));
    for (auto& kv : P.unsup) warns.push_back(T("NO ACOTADO (rasgo no prismático):") + " " + T(kv.first.c_str()) + " ×" + std::to_string(kv.second));
    if (P.totArea > 0 && P.unsupArea > 0.35 * P.totArea) warns.insert(warns.begin(), T("PIEZA NO PRISMÁTICA: predominan rasgos sin acotar; este plano NO es válido para fabricar."));
    const double bw = std::min(180.0, fx1 - fx0), bx0 = fx1 - bw;
    {
        std::vector<std::string> w;
        for (auto& n : noteLines) {
            std::string cur;
            size_t i = 0; const size_t w0 = w.size();   // las notas se rotulan en orden inverso: los trozos de una nota larga se invierten para que lean de arriba abajo
            while (i < n.size()) {
                size_t j = n.find(' ', i);
                std::string word = n.substr(i, j == std::string::npos ? std::string::npos : j - i);
                std::string t = cur.empty() ? word : cur + " " + word;
                if (!cur.empty() && textW(t, kTxt) > bw - 4) { w.push_back(cur); cur = "  " + word; } else cur = t;
                if (j == std::string::npos) break;
                i = j + 1;
            }
            w.push_back(cur);
            std::reverse(w.begin() + w0, w.end());
        }
        noteLines = w;
    }
    const double notesH = 4.5 * noteLines.size(), warnH = 4.5 * warns.size();
    const bool overTitle = x0 + Ws + 12 > bx0;
    const double need = fy0 + std::max(2.0, std::max(warnH + 4, overTitle ? titleH + notesH + 8 : 0.0));
    const double ySec = yFB - 16 - Hs;  // base de la sección A-A, bajo el perfil
    const bool secFits = !secOn || (ySec >= fy0 + 3 && (xL + Ds + 4 <= bx0 || ySec >= fy0 + titleH + notesH + 6) && xL + Ds + 4 <= fx1);
    if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "FIT s=%g lowest=%g need=%g notesH=%g zTB=%g yT0=%g fy0=%g titleH=%g over=%d\n", s, lowest, need, notesH, zTB, yT0, fy0, titleH, (int)overTitle);
    B.fits = x0 >= fx0 && xHline + 4 <= fx1 && lowest >= need && yFT <= yWline - 2 && yFB > yT1 - 1e9 && secFits;

    // vistas
    auto X = [&](int v, double u) { return (v == 2 ? xL : x0) + u * s; };
    auto Y = [&](int v, double w) { return (v == 1 ? yT0 : yFB) + w * s; };
    for (int v = 0; v < 3; v++) {
        const Pos p0 = d.pos();
        for (auto& l : P.v[v].hid) line(d, X(v, l.u1), Y(v, l.w1), X(v, l.u2), Y(v, l.w2), kThin, LineType::Hidden);
        for (auto& a : P.v[v].hArc) d.arcs.push_back({X(v, a.cu), Y(v, a.cw), a.r * s, a.a0, a.a1, LineType::Hidden, kThin});
        d.tag(p0, v);
    }
    for (int v = 0; v < 3; v++) {
        const Pos p0 = d.pos();
        for (auto& l : P.v[v].vis) line(d, X(v, l.u1), Y(v, l.w1), X(v, l.u2), Y(v, l.w2), kThick);
        for (auto& a : P.v[v].vArc) d.arcs.push_back({X(v, a.cu), Y(v, a.cw), a.r * s, a.a0, a.a1, LineType::Continuous, kThick});
        d.tag(p0, v);
    }
    // plano de partición (G5, dos mitades), ISO 10135 §5 tabla 2 y §6.1: línea de partición en vistas = trazo continuo grueso (01.2), sobre la pieza (sin saliente);
    // símbolo de superficie de partición (rombo, fig. 1 a) sobre la prolongación de la línea (fig. 60), una vez (alzado)
    if (P.g5 && P.dr.p >= 0 && !P.dr.oneSide) {
        const double ext3[3] = {P.W, P.D, P.H}; const int pa = P.dr.p; const double zp = P.dr.zp;
        for (int v = 0; v < 3; v++) {
            const int au = v == 2 ? 1 : 0, aw = v == 0 ? 2 : v == 1 ? 1 : 2;   // eje de cada dirección de la vista
            if (pa != au && pa != aw) continue;
            const Pos p0 = d.pos();
            if (pa == aw) {
                line(d, X(v, 0), Y(v, zp), X(v, ext3[au]), Y(v, zp), kThick);
                if (v == 0) {
                    const double xe = X(v, ext3[au]), y = Y(v, zp), r = 2.5, cx = xe + 3 + r;
                    line(d, xe, y, cx + r + 3, y);
                    line(d, cx - r, y, cx, y + r); line(d, cx, y + r, cx + r, y); line(d, cx + r, y, cx, y - r); line(d, cx, y - r, cx - r, y);
                }
            } else { const double u = v == 2 ? P.D - zp : zp; line(d, X(v, u), Y(v, 0), X(v, u), Y(v, ext3[aw]), kThick); }
            d.tag(p0, v);
        }
    }
    // salida de desmoldeo (G5), ISO 10135 §6.7.2 fig. 62 y A.7: símbolo de inclinación sobre línea de referencia con directriz al canto en que vale la cota nominal; valor a la derecha del símbolo
    if (P.g5 && P.dr.p == 2 && P.dr.n > 0) {
        const double w0 = P.H * 0.72, w1 = P.dr.oneSide ? w0 : std::max(w0, P.dr.zp + (P.H - P.dr.zp) * 0.5);
        double ub = -1e9, sl = 0;
        for (auto& l : P.v[0].vis) {   // canto derecho inclinado a la altura w1
            const double dw = l.w2 - l.w1, du = l.u2 - l.u1;
            if (std::fabs(dw) < 0.5 * std::hypot(du, dw) || w1 < std::min(l.w1, l.w2) || w1 > std::max(l.w1, l.w2)) continue;
            { const double u = l.u1 + du * (w1 - l.w1) / dw; if (u > ub) { ub = u; sl = du / dw; } }
        }
        if (ub > -1e8) {
            const Pos p0 = d.pos();
            const double tx = X(0, ub), ty = Y(0, w1), ex = tx - 14, ey = ty - 9, h = 3.5;
            const std::string tv = fmt(P.dr.th) + "°";
            const double rw = h + 2 + textW(tv, kTxt) + 2, rx0 = ex - rw;
            line(d, tx, ty, ex, ey); arrow(d, tx, ty, ex - tx, ey - ty);
            line(d, rx0, ey, ex, ey);
            if (sl >= 0) { line(d, rx0 + 1 + h, ey, rx0 + 1 + h, ey + 2 * h, kThick); line(d, rx0 + 1, ey, rx0 + 1 + h, ey, kThick); line(d, rx0 + 1, ey, rx0 + 1 + h, ey + 2 * h, kThick); }   // hipotenusa = inclinación real de la pared (regla 1), cateto largo = eje de desmoldeo
            else { line(d, rx0 + 1, ey, rx0 + 1, ey + 2 * h, kThick); line(d, rx0 + 1, ey, rx0 + 1 + h, ey, kThick); line(d, rx0 + 1 + h, ey, rx0 + 1, ey + 2 * h, kThick); }
            text(d, rx0 + 1 + h + 1.5, ey + 1, kTxt, tv);
            d.tag(p0, 0);
        }
    }
    // ejes de taladros en su vista
    for (auto& h : P.holes)
        for (auto& pp : h.pos) {
            const Pos p0 = d.pos();
            double cx = X(h.view, pp.first), cy = Y(h.view, pp.second), r = 0;
            for (auto& a : P.v[h.view].vArc) if (std::fabs(a.cu - pp.first) < 0.01 && std::fabs(a.cw - pp.second) < 0.01 && a.a1 - a.a0 > 359) r = std::max(r, a.r);
            r = r * s + 2;
            line(d, cx - r, cy, cx + r, cy, kThin, LineType::Center); line(d, cx, cy - r, cx, cy + r, kThin, LineType::Center);
            d.tag(p0, h.view);
        }

    // ordenadas
    auto tolFor = [&](const std::string& key, const std::string& base) {
        auto it = meta.tols.find(key);
        if (it != meta.tols.end() && !it->second.empty()) return stackTol(base, it->second, decSep);
        return base;
    };
    for (int v = 0; v < 3; v++)
        for (int o = 0; o < 2; o++) {
            const auto& it = G[v][o].it;
            if (it.empty()) continue;
            const Pos p0 = d.pos();
            const Zone z = o == 0 ? (v == 1 ? ZBottom : ZTop) : (v == 2 ? ZRight : ZLeft);
            std::vector<double> pos, q;
            bool zero = gZeroMarks;   // ISO 129-1: la cota ordenada lleva marca «0» en el origen, salvo que ya haya una cota en él
            for (auto& e : it) if (e.c < 1e-6) zero = false;
            if ((o == 0 ? (v == 2 ? P.D : P.W) : (v == 1 ? P.D : P.H)) * s < 15) zero = false;   // vista diminuta: sin círculo de origen
            const double p00 = (o == 0 && v == 2) ? P.D : 0;
            if (zero && o == 1 && !G[v][0].it.empty()) {   // los dos círculos de origen de una vista caen juntos en la esquina: se deja solo el de las abscisas
                bool z0 = gZeroMarks;
                for (auto& e : G[v][0].it) if (e.c < 1e-6) z0 = false;
                const double p0b = v == 2 ? P.D : 0;
                const double cx0 = X(v, p0b), cy0 = (v == 1 ? Y(v, 0) - 1 : Y(v, P.H) + 1);   // centro del círculo de la fila 0 (aprox.)
                const double bx1 = (z == ZRight ? X(v, v == 2 ? P.D : P.W) + 1 : X(v, 0) - 1), cy1 = Y(v, 0);
                if (z0 && std::hypot(cx0 - bx1, cy0 - cy1) < 3.6) zero = false;
            }
            const double uw = v == 2 ? P.D : P.W, wh = v == 1 ? P.D : P.H;
            const size_t zeroAt = (o == 0 && v == 2) ? it.size() : 0;   // el origen va donde le toca por posición
            for (auto& e : it) pos.push_back(o == 0 ? X(v, e.p) : Y(v, e.p));
            if (zero) pos.insert(pos.begin() + zeroAt, o == 0 ? X(v, p00) : Y(v, p00));
            fan(pos, q, 4.4);
            for (size_t k = 0; k < pos.size(); k++) {
                const bool isZero = zero && k == zeroAt;
                const size_t i = k, j = zero && k > zeroAt ? k - 1 : k;   // i: posición en pos/q; j: cota en it
                std::string t = isZero ? "0" : tolFor(fmtK(it[j].c), ordText(it[j].c));
                const double tw = textW(t, kTxt);
                if (!isZero) d.dims.push_back({"length", it[j].c, t, fmtK(it[j].c), o == 0 ? (v == 2 ? 1 : 0) : (v == 1 ? 1 : 2)});   // axis: eje STEP de la cota ordenada (verificación)
                double au = isZero ? (o == 0 ? X(v, p00) : X(v, z == ZRight ? uw : 0)) : X(v, it[j].au);
                double aw = isZero ? (o == 0 ? Y(v, z == ZTop ? wh : 0) : Y(v, p00)) : Y(v, it[j].aw);
                if (z == ZBottom || z == ZTop) {
                    const double sg = z == ZTop ? 1 : -1;
                    const double base = (z == ZTop ? Y(v, v == 1 ? P.D : P.H) : Y(v, 0)) + sg * 1;
                    line(d, au, aw, pos[i], base);
                    line(d, pos[i], base, q[i], base + sg * kJog);
                    if (isZero) d.arcs.push_back({pos[i], base, 1.5, 0, 360, LineType::Continuous, kThin});   // ISO 129-1 5.4.2: círculo de origen
                    text(d, q[i] + 0.36 * kTxt, z == ZTop ? base + kJog + 1 : base - kJog - 1 - tw, kTxt, t, 90);
                } else {
                    const double sg = z == ZRight ? 1 : -1;
                    const double base = (z == ZRight ? X(v, v == 2 ? P.D : P.W) : X(v, 0)) + sg * 1;
                    line(d, au, aw, base, pos[i]);
                    line(d, base, pos[i], base + sg * kJog, q[i]);
                    if (isZero) d.arcs.push_back({base, pos[i], 1.5, 0, 360, LineType::Continuous, kThin});
                    text(d, z == ZRight ? base + kJog + 1 : base - kJog - 1 - tw, q[i] - 0.36 * kTxt, kTxt, t);
                }
            }
            d.tag(p0, v);
        }

    // sección A-A (corte por el centro de la cajera más profunda, vista desde la izquierda), con rayado a 45°
    if (secOn) {
        auto SX = [&](double u) { return xL + u * s; };
        auto SY = [&](double w) { return ySec + w * s; };
        const Pos p0 = d.pos();
        for (auto& l : P.sec.v.vis) line(d, SX(l.u1), SY(l.w1), SX(l.u2), SY(l.w2), kThick);
        for (auto& a : P.sec.v.vArc) d.arcs.push_back({SX(a.cu), SY(a.cw), a.r * s, a.a0, a.a1, LineType::Continuous, kThick});
        const double dk = 3.54 / s;
        for (int i = (int)std::floor(-P.D / dk) - 1; i <= (int)std::ceil(P.H / dk) + 1; i++) {
            const double k = (i + 0.37) * dk;
            std::vector<double> us;
            for (auto& g : P.sec.seg) {
                const double f1 = g.w1 - g.u1 - k, f2 = g.w2 - g.u2 - k;
                if ((f1 < 0) != (f2 < 0)) us.push_back(g.u1 + (g.u2 - g.u1) * f1 / (f1 - f2));
            }
            std::sort(us.begin(), us.end());
            for (size_t j = 0; j + 1 < us.size(); j += 2) line(d, SX(us[j]), SY(us[j] + k), SX(us[j + 1]), SY(us[j + 1] + k), kThin);
        }
        {   // contorno de la zona rayada para el HATCH del DXF: los segmentos del corte encadenados en lazos
            std::vector<Ln> rest = P.sec.seg; const int hid = (int)d.polys.size();
            auto same = [](double a, double b, double c, double e) { return std::fabs(a - c) < 1e-6 && std::fabs(b - e) < 1e-6; };
            while (!rest.empty()) {
                Poly h; h.hatch = 3.54 / std::sqrt(2.0); h.hid = hid;
                h.pts.push_back({SX(rest[0].u1), SY(rest[0].w1)}); double cu = rest[0].u2, cw = rest[0].w2; rest.erase(rest.begin());
                for (bool grew = true; grew;) {
                    grew = false;
                    for (size_t i = 0; i < rest.size(); i++) {
                        if (same(rest[i].u1, rest[i].w1, cu, cw)) { h.pts.push_back({SX(cu), SY(cw)}); cu = rest[i].u2; cw = rest[i].w2; rest.erase(rest.begin() + i); grew = true; break; }
                        if (same(rest[i].u2, rest[i].w2, cu, cw)) { h.pts.push_back({SX(cu), SY(cw)}); cu = rest[i].u1; cw = rest[i].w1; rest.erase(rest.begin() + i); grew = true; break; }
                    }
                }
                if (h.pts.size() >= 3) d.polys.push_back(h);
            }
        }
        text(d, xL + Ds / 2 - textW("A-A", kTxt) / 2, ySec + Hs + 3, kTxt, "A-A");
        // línea de corte en la planta, con flechas hacia +X (el sentido de mirada)
        const double xs = X(1, P.sec.x), yb = Y(1, 0), yt = Y(1, P.D);
        line(d, xs, yb - 3, xs, yt + 3, kThin, LineType::Center);
        for (int e = 0; e < 2; e++) {
            const double ye = e ? yt + 3 : yb - 3, sg = e ? 1 : -1;
            line(d, xs, ye, xs, ye + sg * 4, kThick);
            line(d, xs, ye + sg * 4, xs + 6, ye + sg * 4);
            arrow(d, xs + 6, ye + sg * 4, -1, 0);
            text(d, xs - 4, ye + sg * 4 - 1.2, kTxt, "A");
        }
        d.tag(p0, 3);
    }

    // cotas totales (flecha): W arriba, D a la derecha de la planta, H a la derecha del perfil
    {
        Pos q = d.pos();
        const double xa = X(0, 0), xb = X(0, P.W);
        line(d, xa, yFT + 1, xa, yWline + 1.5); line(d, xb, yFT + 1, xb, yWline + 1.5);
        line(d, xa, yWline, xb, yWline);
        arrow(d, xa, yWline, 1, 0); arrow(d, xb, yWline, -1, 0);
        std::string t = tolFor(fmtK(P.W), fmt(P.W));
        text(d, std::abs(xb - xa) < textW(t, kTxt) + 6 ? std::max(xa, xb) + 3 : (xa + xb) / 2 - textW(t, kTxt) / 2, yWline + 1, kTxt, t);   // cota corta: el texto va fuera de las flechas
        d.dims.push_back({"length", P.W, t, fmtK(P.W)});
        if (P.g5 && P.dr.p == 2) {   // salida en Z: el extremo estrecho de la vista de alzado también se acota (la cota total es la del extremo ancho)
            double lo0 = 1e9, lo1 = -1e9, hi0 = 1e9, hi1 = -1e9;
            for (auto& l : P.v[0].vis) {
                if (std::fabs(l.w1) < 1e-3 && std::fabs(l.w2) < 1e-3) { lo0 = std::min({lo0, l.u1, l.u2}); lo1 = std::max({lo1, l.u1, l.u2}); }
                if (std::fabs(l.w1 - P.H) < 1e-3 && std::fabs(l.w2 - P.H) < 1e-3) { hi0 = std::min({hi0, l.u1, l.u2}); hi1 = std::max({hi1, l.u1, l.u2}); }
            }
            const double wl = lo1 - lo0, wh = hi1 - hi0;
            if (wl > 0 && wh > 0 && std::fabs(wl - wh) > 0.3) {
                const bool top = wh < wl; const double u0 = top ? hi0 : lo0, u1 = top ? hi1 : lo1, ww = top ? wh : wl;
                const double ye = yFB, yd = top ? yFT - 4 : yFB - 6;   // extremo estrecho abajo: cota fuera, bajo el alzado; arriba: dentro de la silueta, bajo el borde superior
                {
                    if (!top) { line(d, X(0, u0), ye - 0.8, X(0, u0), yd - 1.5); line(d, X(0, u1), ye - 0.8, X(0, u1), yd - 1.5); }
                    line(d, X(0, u0), yd, X(0, u1), yd);
                    arrow(d, X(0, u0), yd, 1, 0); arrow(d, X(0, u1), yd, -1, 0);
                    const std::string tn = fmt(ww);
                    text(d, (X(0, u0) + X(0, u1)) / 2 - textW(tn, kTxt) / 2, top ? yd - 4.5 : yd - 4, kTxt, tn);
                    d.dims.push_back({"length", ww, tn, fmtK(ww)});
                }
            }
        }
        d.tag(q, 0); q = d.pos();
        const double xd = x0 + Ws + 9, ya = Y(1, 0), yb = Y(1, P.D);
        line(d, x0 + Ws + 1, ya, xd + 1.5, ya); line(d, x0 + Ws + 1, yb, xd + 1.5, yb);
        line(d, xd, ya, xd, yb);
        arrow(d, xd, ya, 0, 1); arrow(d, xd, yb, 0, -1);
        t = tolFor(fmtK(P.D), fmt(P.D));
        text(d, xd - 1, std::abs(yb - ya) < textW(t, kTxt) + 6 ? std::max(ya, yb) + 3 : (ya + yb) / 2 - textW(t, kTxt) / 2, kTxt, t, 90);
        d.dims.push_back({"length", P.D, t, fmtK(P.D)});
        d.tag(q, 1); q = d.pos();
        if (P.g5 && !P.cornerF.empty()) {   // chaflán de esquina visto en planta: se acota su longitud (la diagonal mayor) dentro de la silueta
            double best = 0, a1 = 0, b1 = 0, a2 = 0, b2 = 0;
            for (auto& l : P.v[1].vis) {
                const double du = l.u2 - l.u1, dw = l.w2 - l.w1, len = std::hypot(du, dw);
                if (len > best && std::fabs(du) > 0.2 * len && std::fabs(dw) > 0.2 * len) { best = len; a1 = l.u1; b1 = l.w1; a2 = l.u2; b2 = l.w2; }
            }
            if (best > 0.05 * std::max(P.W, P.D)) {   // ISO 129-1 Anexo B.1: chaflán de 45° «c × 45°» con directriz (c = cateto); otro ángulo: cateto × ángulo
                const double px = X(1, a1), py = Y(1, b1), qx = X(1, a2), qy = Y(1, b2);
                const double du = std::fabs(a2 - a1), dw = std::fabs(b2 - b1);
                const double cx = (X(1, 0) + X(1, P.W)) / 2, cy = (Y(1, 0) + Y(1, P.D)) / 2;
                const double mx = (px + qx) / 2, my = (py + qy) / 2;
                double nx = -(qy - py), ny = qx - px;   // normal hacia el interior de la planta
                const double nl = std::hypot(nx, ny); nx /= nl; ny /= nl;
                if (nx * (cx - mx) + ny * (cy - my) < 0) { nx = -nx; ny = -ny; }
                const bool c45 = std::fabs(du - dw) < 0.02 * best;
                const std::string tn = c45 ? fmt(du) + " × 45°" : fmt(du) + " × " + fmt(std::atan2(dw, du) * 180 / M_PI) + "°";
                const double ex = mx + nx * 10, ey = my + ny * 10, tw = textW(tn, kTxt), dir = nx >= 0 ? 1 : -1;
                line(d, mx, my, ex, ey); arrow(d, mx, my, nx, ny);
                line(d, ex, ey, ex + dir * (tw + 2), ey);
                text(d, dir > 0 ? ex + 1 : ex - tw - 1, ey + 1, kTxt, tn);
                d.dims.push_back({"length", du, fmt(du), fmtK(du)});
            }
            d.tag(q, 1); q = d.pos();
        }
        const double xh = xHline, ha = Y(2, 0), hb = Y(2, P.H);
        line(d, xL + Ds + 1, ha, xh + 1.5, ha); line(d, xL + Ds + 1, hb, xh + 1.5, hb);
        line(d, xh, ha, xh, hb);
        arrow(d, xh, ha, 0, 1); arrow(d, xh, hb, 0, -1);
        t = tolFor(fmtK(P.H), fmt(P.H));
        text(d, xh - 1, std::abs(hb - ha) < textW(t, kTxt) + 6 ? std::max(ha, hb) + 3 : (ha + hb) / 2 - textW(t, kTxt) / 2, kTxt, t, 90);
        d.dims.push_back({"length", P.H, t, fmtK(P.H)});
        d.tag(q, 2);
    }

    for (auto& k : P.pockets) {
        if (getenv("DIEDRO_TOMODEL")) { char b[256]; std::snprintf(b, sizeof b, "%d %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f", k.a, k.q[k.a], k.lo[0], k.hi[0], k.lo[1], k.hi[1], k.lo[2], k.hi[2], k.dmin, k.dmax, k.l); d.dims.push_back({"pocket", k.w, b}); }   // registro para la verificación independiente
        d.dims.push_back({"length", k.l, fmt(k.l), fmtK(k.l)});
        d.dims.push_back({"length", k.w, fmt(k.w), fmtK(k.w)});
        d.dims.push_back({"length", k.dmax, fmt(k.dmax), fmtK(k.dmax)});
        if (k.dmax - k.dmin >= 0.01) d.dims.push_back({"length", k.dmin, fmt(k.dmin), fmtK(k.dmin)});
    }
    // tags de taladros + notas
    std::vector<size_t> tagIdx;
    std::vector<std::pair<int, std::pair<double, double>>> tagPts;
    for (size_t hi = 0; hi < P.holes.size(); hi++) {
        auto& h = P.holes[hi];
        const std::string tg = tags[hi];
        for (size_t i = 0; i < shownParts[hi].size(); i++) d.dims.push_back({"diameter", h.dias[i], shownParts[hi][i], h.keys[i]});
        for (size_t k = 0; k < h.pos.size() && k < 6; k++) {
            double r = 0;
            for (auto& a : P.v[h.view].vArc) if (std::fabs(a.cu - h.pos[k].first) < 0.01 && std::fabs(a.cw - h.pos[k].second) < 0.01) r = std::max(r, a.r);
            for (auto& a : P.v[h.view].hArc) if (std::fabs(a.cu - h.pos[k].first) < 0.01 && std::fabs(a.cw - h.pos[k].second) < 0.01) r = std::max(r, a.r);
            double cx = X(h.view, h.pos[k].first), cy = Y(h.view, h.pos[k].second);
            {   // etiquetas de taladros coaxiales (D, E…): una junto a otra, no encimadas
                double tx = cx + (r * s + 2.5) * 0.7;
                double ty = cy + (r * s + 2.5) * 0.7;
                for (bool moved = true; moved;) {
                    moved = false;
                    for (auto& pp : tagPts) if (pp.first == h.view && std::fabs(pp.second.first - tx) < 3.6 && std::fabs(pp.second.second - ty) < 3.6) { ty = pp.second.second + 4.2; moved = true; }
                }
                tagPts.push_back({h.view, {tx, ty}});
                const Pos q = d.pos(); text(d, tx, ty, 3.5, tg); d.tag(q, h.view);
            }
            tagIdx.push_back(d.texts.size() - 1);
            if (!h.boss && h.dias.size()) {   // enlace con el visor 3D: la recta del eje en coordenadas del STEP
                const double u = h.pos[k].first, w = h.pos[k].second;
                const double D = P.D;
                double q[3], a[3];
                if (h.view == 0) { q[0] = u; q[1] = 0; q[2] = w; a[0] = 0; a[1] = 1; a[2] = 0; }
                else if (h.view == 1) { q[0] = u; q[1] = w; q[2] = 0; a[0] = 0; a[1] = 0; a[2] = 1; }
                else { q[0] = 0; q[1] = D - u; q[2] = w; a[0] = 1; a[1] = 0; a[2] = 0; }
                gp_Trsf inv = P.toModel.Inverted();
                gp_Pnt gq = gp_Pnt(q[0], q[1], q[2]).Transformed(inv);
                gp_Dir ga = gp_Dir(a[0], a[1], a[2]).Transformed(inv);
                HoleRef hr{cx, cy, {gq.X(), gq.Y(), gq.Z()}, {ga.X(), ga.Y(), ga.Z()}, h.dias[0], h.view};
                d.holeRefs.push_back(hr);
            }
        }
    }
    for (int v = 0; v < 3; v++) {   // enlace con el plano de sección del visor 3D
        if (P.v[v].vis.empty()) continue;
        auto f = [&](double x, double y, double z, double r[2]) {
            gp_Pnt q = gp_Pnt(x, y, z).Transformed(P.toModel);
            double u = v == 2 ? P.D - q.Y() : q.X(), w = v == 1 ? q.Y() : q.Z();
            r[0] = X(v, u); r[1] = Y(v, w);
        };
        ViewRef vr; vr.v = v;
        double a[2], b[2];
        f(0, 0, 0, vr.o);
        f(1, 0, 0, a); vr.e[0][0] = a[0] - vr.o[0]; vr.e[0][1] = a[1] - vr.o[1];
        f(0, 1, 0, a); vr.e[1][0] = a[0] - vr.o[0]; vr.e[1][1] = a[1] - vr.o[1];
        f(0, 0, 1, a); vr.e[2][0] = a[0] - vr.o[0]; vr.e[2][1] = a[1] - vr.o[1];
        const double uw = v == 2 ? P.D : P.W, wh = v == 1 ? P.D : P.H;
        vr.box[0] = X(v, 0); vr.box[1] = Y(v, 0); vr.box[2] = X(v, uw); vr.box[3] = Y(v, wh);
        d.viewRefs.push_back(vr);
    }
    for (size_t i = 0; i < P.pockets.size(); i++) {
        const int vw = P.pockets[i].a == 0 ? 2 : P.pockets[i].a == 1 ? 0 : 1;
        double u, w; viewPt(P, vw, P.pockets[i].q, u, w);
        { const Pos q = d.pos(); text(d, X(vw, u) + 2.5, Y(vw, w) - 1.2, 3.0, pocketTag[i]); d.tag(q, vw); }
        tagIdx.push_back(d.texts.size() - 1);
    }
    for (size_t ti : tagIdx) {
        const double x0t = d.texts[ti].x, y0t = d.texts[ti].y;
        bool ok = textClear(d, ti);
        for (double r : {2.0, 3.0, 4.5, 6.0, 8.0, 10.0, 13.0, 17.0})
            for (int k = 0; k < 16 && !ok; k++) {
                const double a = k * M_PI / 8;
                d.texts[ti].x = x0t + r * std::cos(a); d.texts[ti].y = y0t + r * std::sin(a);
                ok = textClear(d, ti);
            }
        if (!ok) { d.texts[ti].x = x0t; d.texts[ti].y = y0t; }
    }
    // marcos de tolerancia geométrica (valor y referencias tal como los declara el STEP) y su etiqueta junto a la cara
    for (size_t k = 0; k < frames.size(); k++) {
        const GdtTol& g = P.gdt[frames[k]];
        const std::string tag = "T" + std::to_string(k + 1);
        const double fy = fy0 + 4.5 * (P.unsup.size() + 5) + 4 + 9 * k, fh = 6;
        double fx = fx0 + 4;
        text(d, fx, fy + 1.5, kTxt, tag);
        fx += 10;
        const double fxa = fx;
        auto cells = gdtCells(g);
        for (size_t c = 0; c < cells.size(); c++) {
            const double cw = textW(cells[c], kTxt) + 4;
            text(d, fx + 2, fy + 1.5, kTxt, cells[c], 0, c == 1 && cells[c] == "?");
            fx += cw;
            if (c + 1 < cells.size()) line(d, fx, fy, fx, fy + fh, kThick);
        }
        line(d, fxa, fy, fx, fy, kThick); line(d, fxa, fy + fh, fx, fy + fh, kThick);
        line(d, fxa, fy, fxa, fy + fh, kThick); line(d, fx, fy, fx, fy + fh, kThick);
        const int v = P.gdtView[frames[k]];
        const double cx = X(v, P.gdtUW[frames[k]].first), cy = Y(v, P.gdtUW[frames[k]].second);
        const Pos q = d.pos();
        const double tw = textW(tag, kTxt);   // la etiqueta Tn va donde no pise cotas ni líneas (antes siempre arriba a la derecha: caía sobre «16,43» en stc_10)
        double ux = 1, uy = 1, ex = 0, ey = 0; bool okT = false;
        text(d, cx + 7.5, cy + 7.5, kTxt, tag); const size_t ti = d.texts.size() - 1;
        for (double r : {7.0, 10.0, 14.0, 19.0}) for (int k = 0; k < 4 && !okT; k++) {
            ux = k == 1 || k == 2 ? -1 : 1; uy = k >= 2 ? -1 : 1; ex = cx + ux * r; ey = cy + uy * r;
            d.texts[ti].x = ex + (ux > 0 ? 0.5 : -0.5 - tw); d.texts[ti].y = ey + (uy > 0 ? 0.5 : -0.5 - kTxt);
            okT = textClear(d, ti);
        }
        if (!okT) { ux = uy = 1; ex = cx + 7; ey = cy + 7; d.texts[ti].x = cx + 7.5; d.texts[ti].y = cy + 7.5; }
        arrow(d, cx, cy, ux, uy);
        line(d, cx + 2.1 * ux, cy + 2.1 * uy, ex, ey, kThin);
        d.tag(q, v);
        { std::string rq = tag; for (auto& cc : cells) rq += " " + cc; d.dims.push_back({"gdt", g.value, tag, "gdt:" + rq + "\t" + (g.value > 0 ? cells[1] : "NO DEFINIDO")}); }
    }
    double ny = fy0 + titleH + 7;
    for (auto& n : noteLines) { text(d, bx0 + 2, ny, kTxt, n); ny += 4.5; }
    // avisos visibles (rojo), abajo a la izquierda
    for (auto& w : P.unsup.empty() ? std::vector<std::string>() : warns) (void)w;
    double wy = fy0 + 3;
    for (auto& w : warns) { text(d, fx0 + 3, wy, 3.0, w, 0, true); wy += 4.5; d.warnings.push_back(w); }

    // cajetín
    const double by1 = fy0 + 36;
    line(d, bx0, fy0, bx0, by1, kThick); line(d, bx0, by1, fx1, by1, kThick);
    line(d, bx0, fy0 + 24, fx1, fy0 + 24); line(d, bx0, fy0 + 12, fx1, fy0 + 12);
    const double split1 = bx0 + bw * 0.62, split2 = bx0 + bw * 0.5, split3 = bx0 + bw * 0.75;
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
    text(d, bx0 + 1.5, fy0 + 7.8, 2.2, T("Escala"));
    text(d, bx0 + 1.5, fy0 + 2, kTxt, scaleText(s));
    text(d, split2 + 1.5, fy0 + 7.8, 2.2, T("Formato"));
    text(d, split2 + 1.5, fy0 + 2, kTxt, d.sheetName);
    text(d, split3 + 1.5, fy0 + 7.8, 2.2, T("Unidades"));
    text(d, split3 + 1.5, fy0 + 2, kTxt, gLoc.imperial ? "in" : "mm");
    projSymbol(d, fx1 - 25, fy0 + 2.5);
    text(d, bx0 + 1.5, by1 + 1.5, 2.2, "Diedro");
    return B;
}

// Centra las vistas (y sus cotas) en el ancho de la hoja si queda hueco a la derecha y no invade cajetín ni notas.
void centrar(Drawing& d) {
    thirdAngle(d, 0, 1, 2, 3);   // ISO 128-30 Anexo B: tercer diedro si el usuario lo pide
    const double fx1 = d.sheetW - 10;
    double mx = -1e9, mn = 1e9, lo = 1e9, loR = 1e9, noteTop = 0, noteX = fx1;
    const double bx0 = fx1 - std::min(180.0, fx1 - 20.0);   // el cajetín ocupa hasta fy0+36: no se corre ninguna vista bajo él
    auto ext = [&](double x0, double x1, double y) { mx = std::max(mx, std::max(x0, x1)); mn = std::min(mn, std::min(x0, x1)); lo = std::min(lo, y); if (std::max(x0, x1) > bx0) loR = std::min(loR, y); };
    for (auto& l : d.lines) if (l.g >= 0) ext(l.x1, l.x2, std::min(l.y1, l.y2));
    for (auto& a : d.arcs) if (a.g >= 0) ext(a.cx - a.r, a.cx + a.r, a.cy - a.r);
    for (auto& t : d.texts) if (t.g >= 0) {
        const double w = textW(t.s, t.height), c = std::cos(t.angle * M_PI / 180), sn = std::sin(t.angle * M_PI / 180);
        const double xe = t.x + w * c - t.height * sn, ye = t.y + w * sn + t.height * c;   // extremo opuesto del texto girado
        ext(std::min(t.x, xe), std::max(t.x, xe), std::min(t.y, ye));
    }
    if (mx < mn) return;
    for (auto& t : d.texts) if (t.g < 0 && t.x > bx0 && t.y < d.sheetH * 0.75) { noteTop = std::max(noteTop, t.y + 4); noteX = std::min(noteX, t.x - 2); }
    {   // vertical: hoja con las vistas pegadas arriba y media hoja vacía debajo (multicuerpo en formato grande) -> se bajan hasta repartir el hueco
        double hi = -1e9;
        for (auto& l : d.lines) if (l.g >= 0) hi = std::max(hi, std::max(l.y1, l.y2));
        for (auto& a : d.arcs) if (a.g >= 0) hi = std::max(hi, a.cy + a.r);
        for (auto& t : d.texts) if (t.g >= 0) hi = std::max(hi, t.y + t.height);
        double fTop = 0;   // cuadro de marcos GD&T (no pertenece a las vistas): las vistas no bajan encima de él
        for (auto& t : d.texts) if (t.g < 0 && t.x < bx0 && t.y > 40 && t.y < d.sheetH * 0.75 && t.x < 20 + 150) fTop = std::max(fTop, t.y + 5);
        for (auto& l : d.lines) if (l.g < 0 && std::min(l.x1, l.x2) > 21 && std::max(l.x1, l.x2) < bx0 && std::min(l.y1, l.y2) > 40) fTop = std::max(fTop, std::max(l.y1, l.y2));
        const double bot = std::max(fTop, (mx > bx0 ? std::max(noteTop, 46.0) : 10)) + 6, top = d.sheetH - 10 - 4;
        double dy = std::floor(((lo - bot) - (top - hi)) / 2);
        if (mx > bx0 && loR < 1e8) {   // lo que invade la columna de notas no baja de las notas; lo de la izquierda sí tiene hoja libre debajo
            const double reparto = std::floor(((lo - 16) - (top - hi)) / 2), tope = std::min(lo - std::max(16.0, fTop + 6), loR - bot);
            dy = std::max(dy, std::min(reparto, tope));
        }
        if (dy > 0.12 * d.sheetH) {
            for (auto& l : d.lines) if (l.g >= 0) { l.y1 -= dy; l.y2 -= dy; }
            for (auto& a : d.arcs) if (a.g >= 0) a.cy -= dy;
            for (auto& t : d.texts) if (t.g >= 0) t.y -= dy;
            for (auto& q : d.polys) if (q.g >= 0) for (auto& pt : q.pts) pt.second -= dy;
            for (auto& v : d.viewRefs) { v.o[1] -= dy; v.box[1] -= dy; v.box[3] -= dy; }
            for (auto& h : d.holeRefs) h.y -= dy;
            lo -= dy;
        }
    }
    const double dx = std::floor((fx1 - mx - (mn - 20)) / 2);
    if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "CENTRAR dx=%g lo=%g noteTop=%g noteX=%g mx=%g mn=%g bx0=%g\n", dx, lo, noteTop, noteX, mx, mn, bx0);
    if (dx < 2 || (lo < noteTop + 2 && mx + dx > noteX) || (lo < 10 + 36 + 2 && mx + dx > bx0)) return;
    for (auto& l : d.lines) if (l.g >= 0) { l.x1 += dx; l.x2 += dx; }
    for (auto& a : d.arcs) if (a.g >= 0) a.cx += dx;
    for (auto& t : d.texts) if (t.g >= 0) t.x += dx;
    for (auto& q : d.polys) if (q.g >= 0) for (auto& pt : q.pts) pt.first += dx;
    for (auto& v : d.viewRefs) { v.o[0] += dx; v.box[0] += dx; v.box[2] += dx; }
    for (auto& h : d.holeRefs) h.x += dx;
}
}  // namespace

bool preferPrism(const Profile& p) {
    if (!p.error.empty()) return p.error.rfind("No se encontró ninguna superficie de revolución", 0) == 0;
    size_t nu = 0;
    for (auto& kv : p.unsupported) nu += kv.second;
    double rmax = 0;
    for (auto& g : p.segs) rmax = std::max(rmax, std::max(g.r0, g.r1));
    if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "PREFER nu=%zu unsup=%.3f rShape=%.2f rmax=%.2f\n", nu, p.totArea > 0 ? p.unsupArea / p.totArea : 0.0, p.rShape, rmax);
    if (p.cuts.size() >= 3) {  // prisma regular coaxial (cabeza hexagonal, cuadrado): lo dibuja el motor de torneado
        bool reg = false;
        for (auto& g : p.segs) reg |= !g.inner && g.kind == Seg::Line;  // hace falta un cuerpo de revolución exterior (cilindro de caña, hombro…)
        for (auto& c : p.cuts) reg &= !c.slot && std::fabs(c.h - p.cuts[0].h) < 1e-4 && std::fabs(c.z0 - p.cuts[0].z0) < 1e-4 && std::fabs(c.z1 - p.cuts[0].z1) < 1e-4;
        if (reg && p.rShape <= p.cuts[0].h / std::cos(M_PI / p.cuts.size()) + 0.05) return false;
    }
    return p.rShape > 1.3 * rmax + 0.5;
}

// vistas diminutas: con más ordenadas de las que caben (4,4 mm de paso) se quitan las más pegadas a otra; devuelve cuántas
size_t pruneOrd(const Part& P, Group G[3][2], double s) {
    size_t n = 0;
    for (int v = 0; v < 3; v++)
        for (int o = 0; o < 2; o++) {
            auto& it = G[v][o].it;
            const double ext = (o == 0 ? (v == 2 ? P.D : P.W) : (v == 1 ? P.D : P.H)) * s;
            const size_t mx = std::max<size_t>(ext < 10 ? 1 : 2, (size_t)(ext / 5));
            while (it.size() > mx && it.size() > 1) {
                size_t k = 0;   // con 2 o menos se quita la primera; con más, la interior más pegada a otra
                double best = 1e18;
                for (size_t i = 1; i + 1 < it.size(); i++) {
                    const double g = std::min(it[i].p - it[i - 1].p, it[i + 1].p - it[i].p);
                    if (g < best) { best = g; k = i; }
                }
                it.erase(it.begin() + k);
                n++;
            }
        }
    return n;
}

Drawing layoutPrism(const std::string& path, const Meta& meta, std::string& err) {
    gLoc.lang = meta.lang; gLoc.imperial = meta.imperial;
    Part P; progress(8, 1);
    if (!analyze(path, P, err)) return Drawing();
    progress(30, 2);
    {   // perfil (G4): lista de cortes como notas sobre el cajetín
        Classification c = classifyStep(path);
        if (c.error.empty() && c.group == 4 && c.conf >= 0.6 && c.cut.ok) {
            const CutInfo& k = c.cut;
            static const char* kn[] = {"Sección constante", "Macizo rectangular", "Tubular hueco", "Perfil en L (ángulo)", "Perfil en I/H", "Perfil en U", "Perfil en T", "Tubo redondo"};
            std::string sec = T(kn[k.kind]) + (k.kind == 7 ? " Ø" + fmt(k.dOut) + "/Ø" + fmt(k.dIn) : " " + fmt(std::max(k.w, k.h)) + "×" + fmt(std::min(k.w, k.h)));
            auto ang = [&](int e) {
                double a = 90 - std::fabs(k.tilt[e][0]), b = 90 - std::fabs(k.tilt[e][1]);
                return fmt(a) + "°" + (std::fabs(k.tilt[e][1]) > 0.05 ? "/" + fmt(b) + "°" : std::string());
            };
            P.notes.push_back(Tf("Corte extremo 1: {0} · extremo 2: {1} · cant. 1", {ang(0), ang(1)}));
            P.notes.push_back(std::fabs(k.lenMax - k.lenMin) > 0.05 ? Tf("Largo {0} (máx.) / {1} (mín.)", {fmt(k.lenMax), fmt(k.lenMin)}) : Tf("Largo {0}", {fmt(k.lenMax)}));
            if (k.t1 > 0 && (k.kind == 2 || k.kind == 3 || k.kind == 4 || k.kind == 5 || k.kind == 6))
                P.notes.push_back((k.kind >= 4 && k.t2 - k.t1 > 0.05) ? Tf("Espesor alma {0} · ala {1}", {fmt(k.t1), fmt(k.t2)}) : Tf("Espesor {0}", {fmt(k.t1)}));
            P.notes.push_back(T("LISTA DE CORTES") + ": " + sec);
        }
    }
    {   // fundición / forja / inyección (G5): las caras con salida son el rasgo del grupo, no «no prismático»
        Classification c = classifyStep(path);
        if (c.error.empty() && c.group == 5) {
            P.g5 = true;
            P.unsupArea = std::max(0.0, P.unsupArea - P.inclArea);
            if (P.freeN > 0) {
                P.unsupArea = std::max(0.0, P.unsupArea - P.freeArea);
                P.unsup.erase("superficie curva compleja");
                P.notes.push_back(Tf("{0} superficies de acuerdo de forma libre: sin cotas de forma (ver el modelo 3D)", {std::to_string(P.freeN)}));
                // ISO 129-1 §8.5.1 (coordenadas cartesianas, origen indicado): extremos medidos de las mayores superficies libres
                std::sort(P.freeF.begin(), P.freeF.end(), [](auto& a, auto& b) { return a.second > b.second; });
                int nl = 0; size_t n0 = P.notes.size();
                for (auto& ff : P.freeF) {
                    if (nl >= 6 || ff.second < 0.01 * P.totArea) break;
                    BRepAdaptor_Surface su(ff.first); double u0, u1, v0, v1; BRepTools::UVBounds(ff.first, u0, u1, v0, v1);
                    double mn[3] = {1e300, 1e300, 1e300}, mx[3] = {-1e300, -1e300, -1e300};
                    for (int i = 0; i <= 16; i++) for (int j = 0; j <= 16; j++) { gp_Pnt q = su.Value(u0 + (u1 - u0) * i / 16, v0 + (v1 - v0) * j / 16); double c[3] = {q.X(), q.Y(), q.Z()}; for (int k = 0; k < 3; k++) { mn[k] = std::min(mn[k], c[k]); mx[k] = std::max(mx[k], c[k]); } }
                    auto r = [&](int k) { return fmt(std::round((mn[k] - P.org[k]) * 10) / 10) + ".." + fmt(std::round((mx[k] - P.org[k]) * 10) / 10); };
                    P.notes.push_back(Tf("Sup. libre {0} (≈{1} mm²): X {2} · Y {3} · Z {4}", {std::to_string(++nl), fmt(std::round(ff.second)), r(0), r(1), r(2)}));
                }
                if (P.notes.size() > n0) { std::reverse(P.notes.begin() + n0, P.notes.end()); P.notes.push_back(T("Extremos medidos desde la esquina mínima de la caja (ISO 129-1 8.5.1):")); }   // las notas se dibujan en orden inverso
            }
            if (!P.softCyl.empty()) {   // acuerdos con salida: radio medido, no acotados en las vistas
                double a = 0; for (auto& s : P.softCyl) a += s[3];
                P.unsupArea = std::max(0.0, P.unsupArea - a);
                P.unsup.erase("cilindro oblicuo");
                std::map<std::string, int> rr; for (auto& s : P.softCyl) rr[fmt(s[0])]++;
                for (auto& kv : rr) P.notes.push_back(Tf("Acuerdos con salida: {1}× R{0} (radio medido en la pieza, sin acotar en las vistas)", {kv.first, std::to_string(kv.second)}));
            }
            const char* ax[] = {"X", "Y", "Z"};
            if (P.dr.p >= 0) {
                for (size_t i = P.inclNote.size(); i-- > 0;) {   // las caras inclinadas que son la propia salida no se repiten como nota
                    double th = P.inclNote[i][1]; int ix = (int)P.inclNote[i][0];
                    if (std::fabs(th - P.dr.th) <= 0.15 && ix < (int)P.notes.size()) {
                        P.notes.erase(P.notes.begin() + ix);
                        const size_t fb = (size_t)P.inclNote[i][2], fe = std::min((size_t)P.inclNote[i][3], P.feats.size());   // sus cotas de posición sobran: salida + cotas globales las definen
                        if (fb < fe) P.feats.erase(P.feats.begin() + fb, P.feats.begin() + fe);
                    }
                }
                P.notes.push_back(P.dr.thMax - P.dr.thMin > 0.3 ? Tf("Salida de desmoldeo {0}°–{1}° (medida en {2} caras), eje {3}", {fmt(P.dr.thMin), fmt(P.dr.thMax), std::to_string(P.dr.n), ax[P.dr.p]})
                                                              : Tf("Salida de desmoldeo {0}° (medida, uniforme en {1} caras), eje {2}", {fmt(P.dr.th), std::to_string(P.dr.n), ax[P.dr.p]}));
                P.notes.push_back(P.dr.oneSide ? Tf("Plano de partición: cara extrema del eje {0}", {ax[P.dr.p]})
                                               : Tf("Plano de partición: perpendicular al eje {0}, a {1} del origen", {ax[P.dr.p], fmt(P.dr.zp)}));
            }
            if (P.dr.p >= 0 && !P.cornerF.empty()) {   // chaflanes de esquina con salida: ancho en el extremo ancho (proyección en planta) y ángulo respecto al primer eje del plano
                const char* axn = "XYZ"; std::map<std::pair<std::string, std::string>, int> cc; int nn = 0; double aa = 0;
                for (auto& c : P.cornerF) {
                    if ((int)c[0] != P.dr.p) continue;
                    const int a = (P.dr.p + 1) % 3;
                    cc[{fmt(std::round(c[1] * 2) / 2), std::fabs(c[2] - c[4]) < 0.05 ? fmt(c[2]) : fmt(std::max(c[2], c[4])) + " → " + fmt(std::min(c[2], c[4]))}]++; nn++; aa += c[3];
                    (void)a;
                }
                if (nn) {
                    P.unsupArea = std::max(0.0, P.unsupArea - aa);
                    auto it = P.unsup.find("cara oblicua");
                    if (it != P.unsup.end()) { it->second -= nn; if (it->second <= 0) P.unsup.erase(it); }
                    const int a = (P.dr.p + 1) % 3;
                    for (auto& kv : cc) P.notes.push_back((kv.second > 1 ? std::to_string(kv.second) + "× " : std::string()) + Tf("Chaflán de esquina con salida: cara a {0}° del eje {1} en planta, ancho {2}", {kv.first.first, std::string(1, axn[a]), kv.first.second}));
                }
            }
            {   // conos iguales (mismo ángulo y Ø) se agrupan: «12× …»
                std::vector<std::pair<std::string, int>> g;
                for (auto& s : P.softCones) {
                    const std::string t = Tf("Superficie cónica con salida {0}°: Ø{1} → Ø{2} en {3} de longitud", {fmt(s[0]), fmt(s[1]), fmt(s[2]), fmt(s[3])});
                    bool f = false; for (auto& e : g) if (e.first == t) { e.second++; f = true; break; }
                    if (!f) g.push_back({t, 1});
                }
                for (auto& e : g) P.notes.push_back((e.second > 1 ? std::to_string(e.second) + "× " : std::string()) + e.first);
            }
            P.notes.push_back(T("Sobreespesor de mecanizado y clase de tolerancia (ISO 8062-3): NO DEFINIDO (dato del usuario)"));
        }
    }
    static Group G0[3][2];
    {   // demasiadas cotas ilegibles: se mantienen los centros y los planos de mayor superficie; lo omitido se avisa
        const size_t kMaxPlanes = 20;
        std::vector<size_t> pl;
        for (size_t i = 0; i < P.feats.size(); i++) if (!P.feats[i].point) pl.push_back(i);
        if (pl.size() > kMaxPlanes) {
            std::sort(pl.begin(), pl.end(), [&](size_t x, size_t y) { return P.feats[x].area > P.feats[y].area || (P.feats[x].area == P.feats[y].area && x < y); });
            std::vector<bool> drop(P.feats.size(), false);
            for (size_t i = kMaxPlanes; i < pl.size(); i++) drop[pl[i]] = true;
            std::vector<Feat> kept;
            for (size_t i = 0; i < P.feats.size(); i++) if (!drop[i]) kept.push_back(P.feats[i]);
            P.feats = kept;
            P.notes.push_back(Tf("Sin acotar: {0} caras planas menores (ver el modelo 3D).", {std::to_string(pl.size() - kMaxPlanes)}));
        }
    }
    Group G[3][2];
    makeGroups(P, G);
    (void)G0;
    struct Cand { Drawing d; size_t ov; int si; };
    std::vector<Cand> cands;
    std::optional<Cand> hold;
    const int ns = sizeof(kSheets) / sizeof(*kSheets), nsc = sizeof(kScales) / sizeof(*kScales);
    for (int sp = 0; sp < (P.sec.on ? 2 : 1); sp++)
    for (int pass = 0; pass < 3; pass++)
        for (int i = 0; i < ns; i++) {
            if (pass == 2 && !cands.empty()) continue;   // escala ≤1:20 solo si en ningún formato cabe a 1:10 o mayor (un plano a 1:100 sin solapes aparentes es ilegible)
            if (!meta.sheet.empty() && meta.sheet != kSheets[i].name) continue;
            if (hold) {
                if ((int)i > hold->si + 1) { centrar(hold->d); mergeNearParallel(hold->d); return hold->d; }
                if ((int)i == hold->si) continue;
            }
            for (int k = 0; k < nsc; k++) {
                const double s = kScales[k];
                if (hold && (i == ns - 1 || s < 2 * hold->d.scale - 1e-9)) break;   // no se salta a A0 solo por doblar la escala (poco imprimible)
                if (pass == 0 && s < 0.5 && meta.sheet.empty()) continue;
                if (pass == 0 && i == ns - 1 && s < 1 && meta.sheet.empty()) continue;   // A0 a escala reducida solo si en ningún formato menor cabe (1:5 en A1 se lee y se imprime)
                if (pass == 1 && s < 0.1 && meta.sheet.empty()) continue;
                gZeroMarks = true; { static int nt = 0; if (sp == 0 && pass == 0 && i == 0 && k == 0) nt = 0; progress(30 + (int)(40 * (1 - std::exp(-(nt++) / 14.0))), 2); }
                Group Gs[3][2];
                for (int a = 0; a < 3; a++) for (int c = 0; c < 2; c++) Gs[a][c] = G[a][c];
                const size_t nd = pruneOrd(P, Gs, s);
                Part Pc = P;
                if (nd) {
                    size_t prev = 0;
                    for (auto& n : Pc.notes) if (n.rfind("Sin acotar: ", 0) == 0) { prev = std::strtoul(n.c_str() + 12, nullptr, 10); n.clear(); }
                    Pc.notes.erase(std::remove(Pc.notes.begin(), Pc.notes.end(), std::string()), Pc.notes.end());
                    Pc.notes.push_back(Tf("Sin acotar: {0} caras planas menores (ver el modelo 3D).", {std::to_string(prev + nd)}));
                }
                Built b = build(Pc, Gs, meta, kSheets[i], s, sp == 0);
                if (!b.fits) continue;
                size_t ov = findOverlaps(b.d).size();
                if (ov) {
                    gZeroMarks = false;
                    Built b2 = build(Pc, Gs, meta, kSheets[i], s, sp == 0);
                    const size_t ov2 = b2.fits ? findOverlaps(b2.d).size() : ov;
                    if (ov2 < ov) { b = std::move(b2); ov = ov2; }
                    gZeroMarks = true;
                }
                if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "CAND %s %g fits ov=%zu nd=%zu\n", kSheets[i].name, s, ov, nd); if (std::getenv("DIEDRO_DBG")) for (auto& o : findOverlaps(b.d)) fprintf(stderr, "  %s\n", o.c_str());
                if (ov == 0 && !hold && s < 1 && meta.sheet.empty() && sp == 0) { hold = Cand{std::move(b.d), 0, (int)i}; break; }
                if (ov == 0) {
                    // un único solape leve en una hoja ≥2 formatos menor vale más que saltar a un formato enorme
                    Cand* alt = nullptr;
                    for (auto& c : cands) if (c.ov <= 2 && c.si <= i - 2 && c.d.scale >= 1 && (!alt || c.d.scale > alt->d.scale || (c.d.scale == alt->d.scale && c.si < alt->si))) alt = &c;
                    if (alt) { alt->d.warnings.push_back(T("Zona muy densa: algunas cotas se solapan; amplía con el zoom para leerlas.")); centrar(alt->d); mergeNearParallel(alt->d); return alt->d; }
                    centrar(b.d); mergeNearParallel(b.d); return b.d;
                }
                cands.push_back({std::move(b.d), ov, i});
            }
        }
    if (hold) { centrar(hold->d); mergeNearParallel(hold->d); return hold->d; }
    if (cands.empty()) { err = "La pieza no cabe en ningún formato."; return Drawing(); }
    auto best = std::min_element(cands.begin(), cands.end(), [](const Cand& a, const Cand& b) { return a.ov < b.ov || (a.ov == b.ov && a.d.scale > b.d.scale); });
    best->d.warnings.push_back(T("Zona muy densa: algunas cotas se solapan; amplía con el zoom para leerlas."));
    centrar(best->d);
    mergeNearParallel(best->d);
    return best->d;
}
}  // namespace diedro
