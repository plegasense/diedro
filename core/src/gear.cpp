// Ruedas dentadas: eje, nº de dientes, Ø de cabeza y de pie, hélice, agujero, chavetero y taladros se MIDEN en secciones del sólido.
// Módulo, ángulo de presión, Ø primitivo, calidad, etc. no están en la geometría de forma fiable: solo los da el usuario (clave de tolerancias).
#include "gear.hpp"
#include "special.hpp"
#include "stack.hpp"
#include "cx.hpp"
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <cmath>
#include <complex>
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepBndLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangulation.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS_Compound.hxx>
#include <array>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepGProp.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <GProp_GProps.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <STEPControl_Reader.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <gp_Ax3.hxx>
#include <gp_Pln.hxx>
#include <gp_Trsf.hxx>
#include "i18n.hpp"

namespace diedro {
namespace {
std::string gLang = "es";
std::string fmt(double v) {
    char b[32]; std::snprintf(b, sizeof b, "%.2f", v);
    std::string s = b;
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
    if (decimalComma(gLang)) { auto i = s.find('.'); if (i != std::string::npos) s[i] = ','; }
    return s;
}
const double kPi = 3.14159265358979323846;
const int kBins = 1440;

struct Pt2 { double x, y; };
struct Sec {
    std::vector<Pt2> pts;                       // muestras densas del contorno
    std::vector<double> R;                      // radio exterior por ángulo (kBins)
    double rmin = 0, rmax = 0;                  // R mínimo/máximo del contorno exterior
    double rin = 0;                             // menor radio del corte (agujero central), 0 si no hay
    struct Lin { Pt2 a, b; };
    std::vector<Lin> lines;
    struct Cir { double cx, cy, r; };
    std::vector<Cir> circles;
};

// Formas de flanco muy numerosas (hélices B-spline): sección analítica solo de las caras analíticas + corte de la malla de las demás (mucho más rápido)
static bool gHybrid = false;
static std::vector<double> gCylR;   // radios de cilindros coaxiales (Ø exactos)
static TopoDS_Shape gAn;
static std::vector<std::array<gp_Pnt, 3>> gTri;

Sec section(const TopoDS_Shape& sh, double z) {
    Sec s;
    BRepAlgoAPI_Section sec(gHybrid ? gAn : sh, gp_Pln(gp_Pnt(0, 0, z), gp_Dir(0, 0, 1)));
    sec.Approximation(false); sec.ComputePCurveOn1(false); sec.SetRunParallel(true); sec.SetNonDestructive(true);
    sec.Build();
    if (!sec.IsDone()) return s;
    for (TopExp_Explorer ex(sec.Shape(), TopAbs_EDGE); ex.More(); ex.Next()) {
        BRepAdaptor_Curve c(TopoDS::Edge(ex.Current()));
        const double u0 = c.FirstParameter(), u1 = c.LastParameter();
        if (c.GetType() == GeomAbs_Line) { s.lines.push_back({{c.Value(u0).X(), c.Value(u0).Y()}, {c.Value(u1).X(), c.Value(u1).Y()}}); }
        if (c.GetType() == GeomAbs_Circle) { gp_Circ ci = c.Circle(); s.circles.push_back({ci.Location().X(), ci.Location().Y(), ci.Radius()}); }
        GCPnts_QuasiUniformDeflection q(c, 0.02);
        std::vector<Pt2> e;
        if (q.IsDone()) for (int i = 1; i <= q.NbPoints(); i++) e.push_back({q.Value(i).X(), q.Value(i).Y()});
        else { e.push_back({c.Value(u0).X(), c.Value(u0).Y()}); e.push_back({c.Value(u1).X(), c.Value(u1).Y()}); }
        for (size_t i = 0; i < e.size(); i++) {
            s.pts.push_back(e[i]);
            if (i) {   // densifica segmentos largos para no dejar ángulos sin muestra
                const double L = std::hypot(e[i].x - e[i - 1].x, e[i].y - e[i - 1].y);
                const int n = (int)(L / 0.3);
                for (int k = 1; k <= n; k++) s.pts.push_back({e[i - 1].x + (e[i].x - e[i - 1].x) * k / (n + 1), e[i - 1].y + (e[i].y - e[i - 1].y) * k / (n + 1)});
            }
        }
    }
    if (gHybrid) for (auto& t : gTri) {
        double zl = std::min({t[0].Z(), t[1].Z(), t[2].Z()}), zh = std::max({t[0].Z(), t[1].Z(), t[2].Z()});
        if (z < zl || z > zh || zl == zh) continue;
        std::vector<Pt2> q;
        for (int i = 0; i < 3; i++) {
            const gp_Pnt &a = t[i], &b = t[(i + 1) % 3];
            if ((a.Z() - z) * (b.Z() - z) < 0) { double u = (z - a.Z()) / (b.Z() - a.Z()); q.push_back({a.X() + (b.X() - a.X()) * u, a.Y() + (b.Y() - a.Y()) * u}); }
        }
        if (q.size() != 2) continue;
        const double L = std::hypot(q[1].x - q[0].x, q[1].y - q[0].y);
        const int n = (int)(L / 0.3);
        for (int k = 0; k <= n + 1; k++) s.pts.push_back({q[0].x + (q[1].x - q[0].x) * k / (n + 1), q[0].y + (q[1].y - q[0].y) * k / (n + 1)});
    }
    if (s.pts.empty()) return s;
    s.R.assign(kBins, -1);
    s.rin = 1e18;
    for (auto& p : s.pts) {
        const double r = std::hypot(p.x, p.y);
        s.rin = std::min(s.rin, r);
        int b = (int)std::floor((std::atan2(p.y, p.x) + kPi) / (2 * kPi) * kBins) % kBins;
        if (b < 0) b += kBins;
        s.R[b] = std::max(s.R[b], r);
    }
    for (double cr : gCylR) if (cr <= s.rin * 1.01 && cr >= s.rin * 0.99) s.rin = cr;
    for (auto& c : s.circles) if (std::hypot(c.cx, c.cy) < 0.1 && c.r <= s.rin * 1.02 && c.r >= s.rin * 0.98) s.rin = c.r;   // Ø del agujero: radio exacto del arco, no el punto muestreado
    {   // contorno exterior sin muestra en algún ángulo (la sección pierde un arco): ese ángulo solo ve el agujero central -> se trata como hueco
        std::vector<double> t; for (double r : s.R) if (r >= 0) t.push_back(r);
        std::nth_element(t.begin(), t.begin() + t.size() / 2, t.end());
        for (auto& r : s.R) if (r < 0.6 * t[t.size() / 2]) r = -1;
    }
    for (int i = 0; i < kBins; i++) if (s.R[i] < 0) {   // hueco: interpola entre vecinos con dato
        int a = i, b = i;
        while (s.R[(a + kBins - 1) % kBins] < 0 && a > i - kBins) a--;
        while (s.R[(b + 1) % kBins] < 0 && b < i + kBins) b++;
        const double ra = s.R[((a - 1) % kBins + kBins) % kBins], rb = s.R[(b + 1) % kBins];
        s.R[i] = ra + (rb - ra) * (i - a + 1.0) / (b - a + 2.0);
    }
    if (std::getenv("DIEDRO_DBG2")) { std::fprintf(stderr, "SEC z=%g pts=%zu\n", z, s.pts.size()); for (int i = 0; i < 60; i++) std::fprintf(stderr, "%.2f ", s.R[i]); std::fprintf(stderr, "\n"); }
    s.rmax = *std::max_element(s.R.begin(), s.R.end());
    s.rmin = *std::min_element(s.R.begin(), s.R.end());
    return s;
}

// nº de dientes: cruces ascendentes de R por el punto medio (con histéresis)
int countTeeth(const Sec& s) {
    const double mid = 0.5 * (s.rmax + s.rmin), h = 0.15 * (s.rmax - s.rmin);
    int start = 0;
    for (int i = 0; i < kBins; i++) if (s.R[i] < mid - h) { start = i; break; }
    bool high = false; int n = 0;
    for (int k = 0; k < kBins; k++) {
        const double r = s.R[(start + k) % kBins];
        if (!high && r > mid + h) { high = true; n++; }
        else if (high && r < mid - h) high = false;
    }
    return n;
}
// fase angular de los dientes: argumento de la componente N de Fourier de R(θ)
double phase(const Sec& s, int N, double& amp) {
    std::complex<double> c = 0;
    for (int i = 0; i < kBins; i++) c += s.R[i] * std::exp(std::complex<double>(0, -N * (i + 0.5) / kBins * 2 * kPi));
    amp = std::abs(c) / kBins;
    return -std::arg(c) / N;   // R=cos(N(θ-θ0)) -> arg(c)=-Nθ0
}
}  // namespace

#define NO(m) do { if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "GEAR no: %s\n", m); return false; } while (0)
bool gManyFree = false;
bool layoutGear(const std::string& path, const Meta& meta, Profile& pf, Drawing& d) {
    gManyFree = false;
    TopoDS_Shape shape;
    if (!readShapeCached(path, shape)) NO("r1");
    // eje: normal de los planos con mayor área total (las dos caras frontales de la rueda)
    struct Nrm { gp_Dir n; double a = 0; };
    std::vector<Nrm> nr;
    for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face f = TopoDS::Face(ex.Current());
        BRepAdaptor_Surface su(f);
        if (su.GetType() != GeomAbs_Plane) continue;
        GProp_GProps g; BRepGProp::SurfaceProperties(f, g);
        gp_Dir n = su.Plane().Axis().Direction();
        bool found = false;
        for (auto& q : nr) if (std::fabs(q.n.Dot(n)) > 0.99999) { q.a += g.Mass(); found = true; break; }
        if (!found) nr.push_back({n, g.Mass()});
    }
    if (nr.empty()) NO("r3");
    gp_Dir ax = std::max_element(nr.begin(), nr.end(), [](const Nrm& a, const Nrm& b) { return a.a < b.a; })->n;
    GProp_GProps vp; BRepGProp::VolumeProperties(shape, vp);
    if (vp.Mass() <= 0) NO("r4");
    gp_Pnt org = vp.CentreOfMass();
    {   // el centro de masas se desplaza con chaveteros/taladros: si hay un cilindro coaxial (el agujero), su eje manda
        double best = 0; gp_Pnt cp; gCylR.clear();
        for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
            BRepAdaptor_Surface su(TopoDS::Face(ex.Current()));
            if (su.GetType() != GeomAbs_Cylinder || std::fabs(su.Cylinder().Axis().Direction().Dot(ax)) < 0.99999) continue;
            GProp_GProps g; BRepGProp::SurfaceProperties(TopoDS::Face(ex.Current()), g);
            gCylR.push_back(su.Cylinder().Radius());
            if (g.Mass() > best) { best = g.Mass(); cp = su.Cylinder().Location(); }
        }
        if (best > 0) {
            gp_Vec v(org, cp); v -= gp_Vec(ax) * v.Dot(gp_Vec(ax));
            if (v.Magnitude() < 2.0) org.Translate(v);
        }
    }
    gp_Trsf trs; trs.SetTransformation(gp_Ax3(org, ax));
    TopoDS_Shape S = BRepBuilderAPI_Transform(shape, trs, true).Shape();
    {   // ¿flancos B-spline numerosos?
        int nAn = 0, nFree = 0;
        for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
            const GeomAbs_SurfaceType t = BRepAdaptor_Surface(TopoDS::Face(ex.Current())).GetType();
            (t == GeomAbs_Plane || t == GeomAbs_Cylinder || t == GeomAbs_Cone ? nAn : nFree)++;
        }
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "GEAR free=%d poles=%d\n", nFree, splinePoles(S));
        gManyFree = nFree > 100;
        gHybrid = nFree > 100 || (nFree > 0 && splinePoles(S) > 3000);   // flancos B-spline: por número o por polos (engranajes cónicos espirales)
        if (gHybrid) {
            BRep_Builder bld; TopoDS_Compound cmp; bld.MakeCompound(cmp);
            gTri.clear();
            BRepMesh_IncrementalMesh mesh(S, 0.01, false, 0.1, true);
            for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
                const TopoDS_Face f = TopoDS::Face(ex.Current());
                const GeomAbs_SurfaceType t = BRepAdaptor_Surface(f).GetType();
                if (t == GeomAbs_Plane || t == GeomAbs_Cylinder || t == GeomAbs_Cone) { bld.Add(cmp, f); continue; }
                TopLoc_Location loc; Handle(Poly_Triangulation) tr_ = BRep_Tool::Triangulation(f, loc);
                if (tr_.IsNull()) continue;
                for (int k = 1; k <= tr_->NbTriangles(); k++) {
                    int a, b, c; tr_->Triangle(k).Get(a, b, c);
                    gTri.push_back({tr_->Node(a).Transformed(loc), tr_->Node(b).Transformed(loc), tr_->Node(c).Transformed(loc)});
                }
            }
            gAn = cmp;
        }
    }
    Bnd_Box bb; BRepBndLib::AddOptimal(S, bb, false, false);
    double x0, y0, z0, x1, y1, z1; bb.Get(x0, y0, z0, x1, y1, z1);
    const double L = z1 - z0;
    if (L <= 0.1 || std::max(x1 - x0, y1 - y0) < 2 * L * 0.02) NO("r5");
    // cortes en z de las caras planas perpendiculares al eje y extremos de conos
    std::vector<double> zs = {z0, z1};
    for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
        BRepAdaptor_Surface su(TopoDS::Face(ex.Current()));
        if (su.GetType() == GeomAbs_Plane && std::fabs(su.Plane().Axis().Direction().Z()) > 0.99999) zs.push_back(su.Plane().Location().Z());
        if (su.GetType() == GeomAbs_Cone) { Bnd_Box fb; BRepBndLib::AddOptimal(ex.Current(), fb, false, false); double a, b, c, e, f, g; fb.Get(a, b, c, e, f, g); zs.push_back(c); zs.push_back(g); }
    }
    std::sort(zs.begin(), zs.end());
    std::vector<double> zb;
    for (double z : zs) if (z >= z0 - 1e-6 && z <= z1 + 1e-6 && (zb.empty() || z - zb.back() > 1e-3)) zb.push_back(z);
    if (zb.size() < 2) NO("r6");
    // zona dentada: la de mayor Ø de cabeza con variación de R
    struct Zone { double a, b, rout0, rout1, rin0, rin1; bool teeth; Sec mid; };
    std::vector<Zone> zones;
    std::vector<char> lazy;   // zona sin cortes de borde (s0/s1) aún: solo se calculan si de verdad hay rueda dentada (cada corte cuesta ≈0,1 s en una rosca)
    auto finish = [&](Zone& z, const Sec& s0, const Sec& s1) {
        z.rout0 = s0.rmax; z.rout1 = s1.rmax; z.rin0 = s0.rin; z.rin1 = s1.rin;
        // extrapola a los bordes de la zona (conos); cilindros quedan iguales
        const double k = (z.b - z.a) > 0 ? 1.0 / 0.8 * 0.1 : 0;
        const double ro0 = s0.rmax - (s1.rmax - s0.rmax) * k, ro1 = s1.rmax + (s1.rmax - s0.rmax) * k;
        const double ri0 = s0.rin - (s1.rin - s0.rin) * k, ri1 = s1.rin + (s1.rin - s0.rin) * k;
        z.rout0 = ro0; z.rout1 = ro1; z.rin0 = std::max(0.0, ri0); z.rin1 = std::max(0.0, ri1);
    };
    for (size_t i = 0; i + 1 < zb.size(); i++) {
        const double a = zb[i], b = zb[i + 1], l = b - a;
        Sec sm = section(S, a + 0.5 * l);
        if (sm.pts.empty()) NO("r7");
        bool tooth = false, haveEnds = false;   // zona dentada válida: N>=8 dientes periódicos, amplitud sostenida a lo ancho (un Hirth o una polea con taladros no pasan)
        Sec s0, s1;
        const int Nz = countTeeth(sm);
        double am = 0, a0 = 0, a1 = 0;
        if (Nz >= 8 && sm.rmax - sm.rmin >= 0.04 * sm.rmax) {
            phase(sm, Nz, am);
            if (am >= 0.15 * (sm.rmax - sm.rmin) * 0.5) {
                s0 = section(S, a + 0.1 * l); s1 = section(S, a + 0.9 * l); haveEnds = true;
                if (s0.pts.empty() || s1.pts.empty()) NO("r7");
                phase(s0, Nz, a0); phase(s1, Nz, a1); tooth = std::min(a0, a1) >= 0.5 * am;
            }
        }
        Zone z{a, b, 0, 0, 0, 0, tooth, sm};
        if (haveEnds) finish(z, s0, s1);
        lazy.push_back(!haveEnds);
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "ZONA %g..%g rmax=%g rmin=%g rin=%g teeth=%d N=%d\n", a, b, sm.rmax, sm.rmin, sm.rin, (int)z.teeth, Nz);
        zones.push_back(z);
    }
    auto fillZones = [&]() -> bool {
        for (size_t i = 0; i < zones.size(); i++) if (lazy[i]) {
            const double l = zones[i].b - zones[i].a;
            Sec s0 = section(S, zones[i].a + 0.1 * l), s1 = section(S, zones[i].a + 0.9 * l);
            if (s0.pts.empty() || s1.pts.empty()) return false;
            finish(zones[i], s0, s1); lazy[i] = 0;
        }
        return true;
    };
    int tz = -1;
    for (size_t i = 0; i < zones.size(); i++) if (zones[i].teeth && (tz < 0 || zones[i].mid.rmax > zones[tz].mid.rmax)) tz = (int)i;
    { double rM = 0; for (auto& z : zones) rM = std::max(rM, z.mid.rmax); if (tz >= 0 && zones[tz].mid.rmax < 0.9 * rM) tz = -1; }   // la cabeza de los dientes es lo más ancho de la pieza (una jante con radios no es un engranaje)
    if (tz < 0) {   // ¿dentado frontal (Hirth)? planos de flanco oblicuos al eje, aristas de cresta radiales
        double zlo = 1e18, zhi = -1e18; int nobl = 0;
        for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
            BRepAdaptor_Surface su(TopoDS::Face(ex.Current()));
            if (su.GetType() != GeomAbs_Plane) continue;
            const double nz = std::fabs(su.Plane().Axis().Direction().Z());
            if (nz < 0.02 || nz > 0.98) continue;
            Bnd_Box fb; BRepBndLib::AddOptimal(ex.Current(), fb, false, false); double a_, b_, c_, e_, f_, g_; fb.Get(a_, b_, c_, e_, f_, g_);
            zlo = std::min(zlo, c_); zhi = std::max(zhi, g_); nobl++;
        }
        if (nobl < 12 || zhi - zlo < 0.02 * L) NO("r8");
        std::vector<std::pair<double, double>> ed;   // (ángulo, z medio) de las aristas radiales dentro de la banda dentada
        for (TopExp_Explorer ex(S, TopAbs_EDGE); ex.More(); ex.Next()) {
            BRepAdaptor_Curve c(TopoDS::Edge(ex.Current()));
            if (c.GetType() != GeomAbs_Line) continue;
            const gp_Pnt A = c.Value(c.FirstParameter()), B = c.Value(c.LastParameter());
            const double mx = 0.5 * (A.X() + B.X()), my = 0.5 * (A.Y() + B.Y()), mz = 0.5 * (A.Z() + B.Z()), rm = std::hypot(mx, my), len = std::hypot(B.X() - A.X(), B.Y() - A.Y());
            if (rm < 1e-6 || len < 0.3 || mz < zlo - 1e-3 || mz > zhi + 1e-3) continue;
            if (std::fabs((B.X() - A.X()) * my - (B.Y() - A.Y()) * mx) > 0.1 * len * rm) continue;   // no radial
            double an = std::atan2(my, mx); if (an < 0) an += 2 * kPi;
            bool dup = false; for (auto& q : ed) if (std::fabs(q.first - an) < 1e-3) { q.second = std::max(q.second, mz); dup = true; }
            if (!dup) ed.push_back({an, mz});
        }
        if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "HIRTH aristas radiales=%zu zlo=%g zhi=%g\n", ed.size(), zlo, zhi);
        std::sort(ed.begin(), ed.end());
        if (ed.size() < 12 || ed.size() % 2) NO("r8h");
        double ze = 0, zo = 0; for (size_t k = 0; k < ed.size(); k++) (k % 2 ? zo : ze) += ed[k].second;
        std::vector<double> crest;   // las aristas alternan cresta/valle: cresta = la paridad más alta
        for (size_t k = ze >= zo ? 0 : 1; k < ed.size(); k += 2) crest.push_back(ed[k].first);
        const int Nh = (int)crest.size();
        const double ang0 = *std::min_element(crest.begin(), crest.end());
        const double Ro = std::max({std::fabs(x0), std::fabs(x1), std::fabs(y0), std::fabs(y1)});
        const Sec sb = section(S, zlo > z0 + 0.1 * L ? 0.5 * (z0 + zlo) : zhi < z1 - 0.1 * L ? 0.5 * (zhi + z1) : 0.5 * (zlo + zhi));
        double Ri = sb.rin < 1e17 ? sb.rin : 0;
        for (double cr : gCylR) if (std::fabs(cr - Ri) < 0.01 * Ri) Ri = cr;
        Profile p; p.length = L; p.rShape = Ro; p.faceTeeth = Nh; p.faceAng0 = ang0; p.faceRi = Ri;
        auto seg = [&](Seg::Kind k, double za, double ra, double zb2, double rb, bool in) { Seg g; g.kind = k; g.inner = in; g.z0 = za - z0; g.z1 = zb2 - z0; g.r0 = ra; g.r1 = rb; p.segs.push_back(g); };
        seg(Seg::Line, z0, Ro, z1, Ro, false); seg(Seg::Plane, z0, Ri, z0, Ro, false); seg(Seg::Plane, z1, Ri, z1, Ro, false);
        if (Ri > 1e-3) seg(Seg::Line, z0, Ri, z1, Ri, true);
        gLang = meta.lang;
        p.extraNotes.push_back(tr("Dentado frontal (Hirth): representación convencional (sin dientes)", meta.lang));
        p.extraNotes.push_back(tr("Dientes frontales (contados)", meta.lang) + ": " + std::to_string(Nh) + "; " + tr("Altura del diente (medida)", meta.lang) + ": " + fmt(zhi - zlo));
        auto it = meta.tols.find("alfa");
        p.extraNotes.push_back(it == meta.tols.end() ? tr("No definidos en el STEP (indicar antes de fabricar)", meta.lang) + ": " + tr("Ángulo de flanco", meta.lang) : tr("Ángulo de flanco", meta.lang) + ": " + it->second);
        d = layout(p, meta); pf = p;
        return true;
    }
    if (!fillZones()) NO("r7");
    const Sec& tm = zones[tz].mid;
    const int N = countTeeth(tm);
    if (N < 8 || tm.rmax - tm.rmin < 0.04 * tm.rmax) NO("r9");
    double amp; phase(tm, N, amp);
    if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "GEAR N=%d amp=%g rmax=%g rmin=%g\n", N, amp, tm.rmax, tm.rmin);
    if (amp < 0.15 * (tm.rmax - tm.rmin) * 0.5) NO("r10");   // sin periodicidad real de N dientes
    // ¿tiene anillo agujero central? (bore): menor radio por debajo de 0.9 del pie
    // hélice: deriva de la fase de los dientes a lo largo de la zona dentada
    double twist = 0;
    {
        const double a = zones[tz].a, l = zones[tz].b - a;
        const int K = 8;
        double prev = 0, acc = 0, firstPh = 0;
        for (int k = 0; k <= K; k++) {
            Sec s = section(S, a + l * (0.1 + 0.8 * k / K));
            double am, ph = phase(s, N, am);
            if (k) { double dp = ph - prev; const double per = 2 * kPi / N; dp -= per * std::round(dp / per); acc += dp; }
            else firstPh = ph;
            prev = ph;
        }
        (void)firstPh;
        twist = acc / (0.8 * l) * l * 180 / kPi;   // grados de giro de los dientes en todo el ancho de la zona
        if (std::fabs(twist) < 0.2) twist = 0;
    }
    // ---- perfil de revolución equivalente (cabeza como cilindro lleno)
    Profile p;
    p.length = L;
    p.rShape = tm.rmax;
    p.rootR = tm.rmin; p.rootZ0 = zones[tz].a - z0; p.rootZ1 = zones[tz].b - z0;
    auto addPlane = [&](double z, double r0, double r1, bool inner) { if (r1 - r0 > 1e-4) { Seg g; g.kind = Seg::Plane; g.inner = inner; g.z0 = g.z1 = z - z0; g.r0 = r0; g.r1 = r1; p.segs.push_back(g); } };
    auto addLine = [&](double za, double ra, double zb2, double rb, bool inner) { Seg g; g.kind = Seg::Line; g.inner = inner; g.z0 = za - z0; g.z1 = zb2 - z0; g.r0 = ra; g.r1 = rb; p.segs.push_back(g); };
    for (size_t i = 0; i < zones.size(); i++) {
        const Zone& z = zones[i];
        const bool cyl = std::fabs(z.rout0 - z.rout1) < 0.002 * std::max(z.rout0, 1.0);
        const bool tipz = (int)i == tz;   // dentado: la sección convencional llega a la cabeza (no al chaflán de la cara)
        const double ro0 = tipz ? tm.rmax : cyl ? 0.5 * (z.rout0 + z.rout1) : z.rout0, ro1 = tipz ? tm.rmax : cyl ? ro0 : z.rout1;
        addLine(z.a, ro0, z.b, ro1, false);
        const bool icyl = std::fabs(z.rin0 - z.rin1) < 0.002 * std::max(z.rin0, 1.0);
        // agujero central: solo si es claramente menor que el cuerpo (no el pie del dentado)
        const bool hasIn = z.mid.rin < 0.9 * z.mid.rmin;
        auto snap = [](double r) { const double D = 2 * r, q = std::round(D * 20) / 20; return std::fabs(D - q) <= 0.015 ? 0.5 * q : r; };   // ruido de la malla en agujeros helicoidales (13,99 → 14)
        const double ri0 = hasIn ? snap(icyl ? 0.5 * (z.rin0 + z.rin1) : z.rin0) : 0, ri1 = hasIn ? (icyl ? ri0 : snap(z.rin1)) : 0;
        if (hasIn) addLine(z.a, ri0, z.b, ri1, true);
        // pasos entre zonas / caras extremas
        const double prevO = i ? zones[i - 1].rout1 : 0, prevI = (i && zones[i - 1].mid.rin < 0.9 * zones[i - 1].mid.rmin) ? zones[i - 1].rin1 : 0;
        if (!i) addPlane(z.a, ri0, ro0, false);
        else { addPlane(z.a, std::min(prevO, ro0), std::max(prevO, ro0), false); if (std::fabs(prevI - ri0) > 1e-3) addPlane(z.a, std::min(prevI, ri0), std::max(prevI, ri0), true); }
        if (i + 1 == zones.size()) addPlane(z.b, ri1, ro1, false);
    }
    // chavetero y taladros en la zona con agujero más larga
    int bz = -1;
    for (size_t i = 0; i < zones.size(); i++) if (zones[i].mid.rin < 0.9 * zones[i].mid.rmin && (bz < 0 || zones[i].b - zones[i].a > zones[bz].b - zones[bz].a)) bz = (int)i;
    double boreR = 0, keyW = 0, keyH = 0;
    if (bz >= 0) {
        const Zone& z = zones[bz];
        boreR = 0.5 * (z.rin0 + z.rin1);
        std::vector<Sec::Lin> c;
        for (auto& l : z.mid.lines) if (std::max(std::hypot(l.a.x, l.a.y), std::hypot(l.b.x, l.b.y)) < 0.9 * z.mid.rmin && std::hypot(l.b.x - l.a.x, l.b.y - l.a.y) > 0.2) c.push_back(l);
        for (size_t i = 0; i < c.size() && !keyW; i++) for (size_t j = i + 1; j < c.size() && !keyW; j++) {
            const double ux = c[i].b.x - c[i].a.x, uy = c[i].b.y - c[i].a.y, ul = std::hypot(ux, uy);
            const double vx = c[j].b.x - c[j].a.x, vy = c[j].b.y - c[j].a.y, vl = std::hypot(vx, vy);
            if (std::fabs(ux * vy - uy * vx) / (ul * vl) > 1e-4) continue;   // paredes paralelas
            const double w = std::fabs(((c[j].a.x - c[i].a.x) * uy - (c[j].a.y - c[i].a.y) * ux) / ul);
            if (w < 0.5) continue;
            for (auto& f : c) {   // suelo: perpendicular a las paredes, de longitud w
                const double fx = f.b.x - f.a.x, fy = f.b.y - f.a.y, fl = std::hypot(fx, fy);
                if (std::fabs(fl - w) > 0.02 * w || std::fabs(fx * ux + fy * uy) / (fl * ul) > 1e-3) continue;
                const double mx = 0.5 * (f.a.x + f.b.x), my = 0.5 * (f.a.y + f.b.y);
                Cut k; k.slot = true; k.w = w; k.h = std::fabs(mx * ux + my * uy) / ul; k.ang = std::atan2(uy, ux); k.rin = boreR;
                if (mx * ux + my * uy < 0) k.ang += kPi;
                k.z0 = z.a - z0; k.z1 = z.b - z0;
                p.cuts.push_back(k); keyW = w; keyH = k.h;
                break;
            }
        }
        for (auto& ci : z.mid.circles) {   // taladros fuera del eje
            if (std::hypot(ci.cx, ci.cy) < 1e-3 || ci.r > 0.5 * z.mid.rmin) continue;
            bool dup = false;
            for (auto& s : p.sites) if (std::hypot(s.x - ci.cx, s.y - ci.cy) < 1e-3) dup = true;
            if (dup) continue;
            HoleSite hs; hs.x = ci.cx; hs.y = ci.cy; hs.st.push_back({ci.r, z.a - z0, z.b - z0, false});
            p.sites.push_back(hs);
        }
    }
    {   // taladros radiales (p. ej. prisioneros del cubo): cilindros de eje perpendicular al eje de la rueda que lo cortan
        struct Rc { double z, ang, r, tn, tf; };
        std::vector<Rc> rcs;
        for (TopExp_Explorer ex(S, TopAbs_FACE); ex.More(); ex.Next()) {
            const TopoDS_Face f = TopoDS::Face(ex.Current());
            BRepAdaptor_Surface su(f);
            if (su.GetType() != GeomAbs_Cylinder) continue;
            const gp_Ax1 A = su.Cylinder().Axis();
            if (std::fabs(A.Direction().Z()) > 1e-6 || su.Cylinder().Radius() > 0.5 * tm.rmax) continue;
            const gp_Pnt L = A.Location();
            if (std::fabs(L.X() * A.Direction().Y() - L.Y() * A.Direction().X()) > 0.05) continue;   // el eje del taladro corta el de la rueda
            GProp_GProps g; BRepGProp::SurfaceProperties(f, g);
            const gp_Pnt c = g.CentreOfMass();
            double dx = c.X(), dy = c.Y();
            if (std::hypot(dx, dy) < 1e-3) { dx = A.Direction().X(); dy = A.Direction().Y(); }
            const double an = std::atan2(dy, dx), ux = std::cos(an), uy = std::sin(an);
            double tn = 1e18, tf = -1e18;
            for (TopExp_Explorer v(f, TopAbs_VERTEX); v.More(); v.Next()) { gp_Pnt q = BRep_Tool::Pnt(TopoDS::Vertex(v.Current())); const double t = q.X() * ux + q.Y() * uy; tn = std::min(tn, t); tf = std::max(tf, t); }
            rcs.push_back({L.Z() - z0, an, su.Cylinder().Radius(), tn, tf});
        }
        auto angEq = [](double a, double b) { double dd = std::fmod(std::fabs(a - b), 2 * kPi); return dd < 1e-3 || 2 * kPi - dd < 1e-3; };
        std::vector<char> used(rcs.size(), 0);
        for (size_t i = 0; i < rcs.size(); i++) {
            if (used[i]) continue;
            used[i] = 1;
            RadHole rh; rh.z = rcs[i].z; rh.ang = rcs[i].ang; rh.r = rcs[i].r;
            double tn = rcs[i].tn, tf = rcs[i].tf;
            for (size_t j = i + 1; j < rcs.size(); j++) {
                if (used[j] || std::fabs(rcs[j].z - rcs[i].z) > 1e-3 || std::fabs(rcs[j].r - rcs[i].r) > 1e-3) continue;
                if (angEq(rcs[j].ang, rcs[i].ang)) { used[j] = 1; tn = std::min(tn, rcs[j].tn); tf = std::max(tf, rcs[j].tf); }
                else if (angEq(rcs[j].ang, rcs[i].ang + kPi)) { used[j] = 1; rh.through = true; }
            }
            rh.depth = tf - tn;
            if (tn <= boreR + 0.01 && boreR > 0) rh.through = true;
            p.rholes.push_back(rh);
        }
    }
    // ---- datos de la rueda (notas del plano)
    gLang = meta.lang;
    const double tipD = 2 * tm.rmax, rootD = 2 * tm.rmin, W = zones[tz].b - zones[tz].a;
    p.extraNotes.push_back(tr("Rueda dentada: representación convencional (sin dientes)", meta.lang));
    p.extraNotes.push_back(tr("Dientes (contados)", meta.lang) + ": " + std::to_string(N) + "; " + tr("Ancho del dentado", meta.lang) + ": " + fmt(W));
    p.extraNotes.push_back(tr("Ø de cabeza (medido)", meta.lang) + ": " + fmt(tipD) + "; " + tr("Ø de pie (medido)", meta.lang) + ": " + fmt(rootD));
    if (twist != 0) {
        const double beta = std::atan(std::fabs(twist) * kPi / 180 * tm.rmax / W) * 180 / kPi;
        p.extraNotes.push_back(tr("Hélice", meta.lang) + ": " + tr(twist > 0 ? "dcha." : "izq.", meta.lang) + ", β " + tr("en Ø de cabeza", meta.lang) + " = " + fmt(beta) + "°");
    } else p.extraNotes.push_back(tr("Hélice", meta.lang) + ": " + tr("dientes rectos", meta.lang));
    (void)keyW; (void)keyH; (void)boreR;
    auto user = [&](const char* k) { auto it = meta.tols.find(k); return it == meta.tols.end() ? std::string() : it->second; };
    const char* want[][2] = {{"Módulo / paso", "mod"}, {"Ángulo de presión", "alfa"}, {"Ø primitivo", "dp"}, {"Calidad / tolerancia", "calidad"}};
    std::string line, missing;
    for (auto& w : want) { const std::string v = user(w[1]); if (v.empty()) missing += (missing.empty() ? "" : ", ") + tr(w[0], meta.lang); else line += (line.empty() ? "" : "; ") + tr(w[0], meta.lang) + ": " + v; }
    if (!line.empty()) p.extraNotes.push_back(line);
    if (!missing.empty()) p.extraNotes.push_back(tr("No definidos en el STEP (indicar antes de fabricar)", meta.lang) + ": " + missing);
    d = layout(p, meta);
    pf = p;
    return true;
}
}  // namespace diedro
