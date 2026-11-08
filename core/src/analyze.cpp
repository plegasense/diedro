#include "special.hpp"
#include "analyze.hpp"
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepGProp.hxx>
#include <BRepTools.hxx>
#include <GProp_GProps.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <fstream>
#include <iterator>
#include <STEPControl_Reader.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <BRep_Tool.hxx>
#include <TopoDS_Vertex.hxx>
#include <gp_Lin.hxx>
#include <gp_Vec.hxx>
#include <algorithm>
#include <cmath>
#include <vector>

namespace diedro {
namespace {
struct Axis { gp_Pnt o; gp_Dir d; };

bool revolutionAxis(const BRepAdaptor_Surface& su, gp_Ax1& ax) {
    switch (su.GetType()) {
        case GeomAbs_Cylinder: ax = su.Cylinder().Axis(); return true;
        case GeomAbs_Cone: ax = su.Cone().Axis(); return true;
        case GeomAbs_Sphere: ax = su.Sphere().Position().Axis(); return true;
        case GeomAbs_Torus: ax = su.Torus().Axis(); return true;
        case GeomAbs_SurfaceOfRevolution: {   // solo si la generatriz es un arco o una recta (en el plano meridiano) → equivale a toro/cono
            GeomAbs_CurveType ct = su.BasisCurve()->GetType();
            if (ct != GeomAbs_Circle && ct != GeomAbs_Line) return false;
            ax = su.AxeOfRevolution(); return true;
        }
        default: return false;
    }
}
bool coaxial(const gp_Ax1& a, const Axis& m, bool needDir = true) {
    gp_Lin l(gp_Ax1(m.o, m.d));
    if (l.Distance(a.Location()) > 1e-5) return false;
    return !needDir || a.Direction().IsParallel(m.d, 1e-7);
}
std::string fmt(double v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.2f", v);
    std::string s = b;
    while (s.back() == '0') s.pop_back();
    if (s.back() == '.') s.pop_back();
    return s;
}
}  // namespace

Profile analyzeStep(const std::string& path) {
    Profile out;
    TopoDS_Shape shape;
    if (!readShapeCached(path, shape)) { out.error = "No se pudo leer el archivo STEP."; return out; }
    if (shape.IsNull()) { out.error = "El STEP no contiene ninguna forma sólida."; return out; }

    std::vector<TopoDS_Face> faces;
    for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next()) faces.push_back(TopoDS::Face(e.Current()));
    if (faces.empty()) { out.error = "El STEP no contiene caras."; return out; }

    // eje: el candidato (eje de cilindro/cono) con mayor área de superficies de revolución coaxiales
    std::vector<double> area(faces.size());
    std::vector<gp_Ax1> fax(faces.size());
    std::vector<char> isRev(faces.size(), 0);
    for (size_t i = 0; i < faces.size(); i++) {
        GProp_GProps gp;
        BRepGProp::SurfaceProperties(faces[i], gp);
        area[i] = gp.Mass();
        BRepAdaptor_Surface su(faces[i]);
        isRev[i] = revolutionAxis(su, fax[i]);
    }
    int best = -1;
    double bestA = 0;
    for (size_t i = 0; i < faces.size(); i++) {
        BRepAdaptor_Surface su(faces[i]);
        if (su.GetType() != GeomAbs_Cylinder && su.GetType() != GeomAbs_Cone) continue;
        Axis m{fax[i].Location(), fax[i].Direction()};
        double sum = 0;
        for (size_t j = 0; j < faces.size(); j++) {
            if (!isRev[j]) continue;
            BRepAdaptor_Surface sj(faces[j]);
            if (coaxial(fax[j], m, sj.GetType() != GeomAbs_Sphere)) sum += area[j];
        }
        if (sum > bestA + 1e-9) { bestA = sum; best = (int)i; }
    }
    for (double a : area) out.totArea += a;
    if (best < 0) { out.error = "No se encontró ninguna superficie de revolución: no es una pieza torneada."; return out; }
    Axis ax{fax[best].Location(), fax[best].Direction()};
    gp_Dir D = ax.d;

    auto zOf = [&](const gp_Pnt& p) { return gp_Vec(ax.o, p).Dot(gp_Vec(D)); };
    auto rOf = [&](const gp_Pnt& p) {
        gp_Vec v(ax.o, p);
        return (v - gp_Vec(D) * v.Dot(gp_Vec(D))).Magnitude();
    };
    for (TopExp_Explorer e(shape, TopAbs_VERTEX); e.More(); e.Next()) out.rShape = std::max(out.rShape, rOf(BRep_Tool::Pnt(TopoDS::Vertex(e.Current()))));

    gp_Dir U = gp_Ax2(ax.o, D).XDirection(), V = D.Crossed(U);
    auto xyOf = [&](const gp_Pnt& p, double& x, double& y) { gp_Vec v(ax.o, p); x = v.Dot(gp_Vec(U)); y = v.Dot(gp_Vec(V)); };
    struct HC { double x, y, r, z0, z1; };
    std::vector<HC> hc;
    struct Circ { double x, y, r; };
    struct Pend { size_t i; double z, rmin, rmax; std::vector<Circ> circ; double x, y; bool cone; };
    std::vector<Pend> pend;
    std::vector<size_t> radCyl, radCone, plNorm;
    struct Partial { size_t i; double z; };
    std::vector<Partial> partial;
    double bsArea = 0, bsRmax = 0, bsRmin = 1e18;
    auto addUnsup = [&](const TopoDS_Face& f) {
        BRepAdaptor_Surface su(f);
        GeomAbs_SurfaceType t = su.GetType();
        std::string k;
        if (t == GeomAbs_Cylinder) {
            gp_Ax1 a = su.Cylinder().Axis();
            if (a.Direction().IsNormal(D, 1e-6)) k = "cilindro radial Ø" + fmt(2 * su.Cylinder().Radius()) + " (taladro/resalte)";
            else k = "cilindro no coaxial Ø" + fmt(2 * su.Cylinder().Radius());
        } else if (t == GeomAbs_Plane) {
            k = su.Plane().Axis().Direction().IsNormal(D, 1e-6) ? "plano paralelo al eje (plano/chavetero/ranura)"
              : su.Plane().Axis().Direction().IsParallel(D, 1e-7) ? "plano parcial perpendicular al eje (pared de chavetero/ranura)" : "plano oblicuo";
        } else {
            k = "superficie " + std::to_string((int)t);
        }
        out.unsupported[k]++;
        GProp_GProps ug; BRepGProp::SurfaceProperties(f, ug);
        out.unsupArea += ug.Mass();
        if (t == GeomAbs_BSplineSurface) {
            bsArea += ug.Mass();
            double u0, u1, v0, v1; BRepTools::UVBounds(f, u0, u1, v0, v1);
            for (int a = 0; a <= 4; a++) for (int b = 0; b <= 4; b++) { double rr = rOf(su.Value(u0 + (u1 - u0) * a / 4, v0 + (v1 - v0) * b / 4)); bsRmax = std::max(bsRmax, rr); bsRmin = std::min(bsRmin, rr); }
        }
    };

    struct RevSeg { Seg s; double span; size_t face; };
    std::vector<RevSeg> revSegs;
    for (size_t i = 0; i < faces.size(); i++) {
        const TopoDS_Face& f = faces[i];
        BRepAdaptor_Surface su(f);
        GeomAbs_SurfaceType t = su.GetType();
        bool coax = isRev[i] && coaxial(fax[i], ax, t != GeomAbs_Sphere);
        if (coax) {
            double u0, u1, v0, v1;
            BRepTools::UVBounds(f, u0, u1, v0, v1);
            double vm = 0.5 * (v0 + v1);
            gp_Pnt pa = su.Value(u0, v0), pb = su.Value(u0, v1), pm = su.Value(u0, vm);
            Seg s;
            s.z0 = zOf(pa); s.r0 = rOf(pa); s.z1 = zOf(pb); s.r1 = rOf(pb);
            s.mz = zOf(pm); s.mr = rOf(pm);
            gp_Pnt P; gp_Vec du, dv;
            su.D1(u0, vm, P, du, dv);
            gp_Vec n = du.Crossed(dv);
            if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
            gp_Vec rad = gp_Vec(ax.o, P) - gp_Vec(D) * gp_Vec(ax.o, P).Dot(gp_Vec(D));
            s.inner = n.Dot(rad) < 0;
            if (t == GeomAbs_Cylinder || t == GeomAbs_Cone || (t == GeomAbs_SurfaceOfRevolution && su.BasisCurve()->GetType() == GeomAbs_Line)) {
                s.kind = Seg::Line;
            } else {  // arco por tres puntos en (z, r)
                s.kind = Seg::Arc;
                double ax_ = s.z0, ay = s.r0, bx = s.mz, by = s.mr, cx = s.z1, cy = s.r1;
                double dd = 2 * (ax_ * (by - cy) + bx * (cy - ay) + cx * (ay - by));
                if (std::fabs(dd) < 1e-12) { s.kind = Seg::Line; }
                else {
                    s.cz = ((ax_ * ax_ + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / dd;
                    s.cr = ((ax_ * ax_ + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax_ - cx) + (cx * cx + cy * cy) * (bx - ax_)) / dd;
                    s.rad = std::hypot(ax_ - s.cz, ay - s.cr);
                }
            }
            if (s.z0 > s.z1) { std::swap(s.z0, s.z1); std::swap(s.r0, s.r1); }
            revSegs.push_back({s, u1 - u0, i});
            continue;
        }
        if (t == GeomAbs_Cylinder && su.Cylinder().Axis().Direction().IsParallel(D, 1e-7)) {  // taladro/resalte axial no coaxial
            double u0, u1, v0, v1;
            BRepTools::UVBounds(f, u0, u1, v0, v1);
            gp_Pnt P; gp_Vec du, dv;
            su.D1(u0, 0.5 * (v0 + v1), P, du, dv);
            gp_Vec n = du.Crossed(dv);
            if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
            gp_Pnt loc = su.Cylinder().Axis().Location();
            gp_Vec rad = gp_Vec(loc, P);
            rad -= gp_Vec(D) * rad.Dot(gp_Vec(D));
            if (n.Dot(rad) < 0) {
                HC h;
                xyOf(loc, h.x, h.y);
                h.r = su.Cylinder().Radius();
                double za = zOf(su.Value(u0, v0)), zb = zOf(su.Value(u0, v1));
                h.z0 = std::min(za, zb); h.z1 = std::max(za, zb);
                hc.push_back(h);
                continue;
            }
        }
        if (t == GeomAbs_Cone && su.Cone().Axis().Direction().IsParallel(D, 1e-7)) {
            Pend pd{i, 0, 0, 0, {}, 0, 0, true};
            xyOf(su.Cone().Axis().Location(), pd.x, pd.y);
            pend.push_back(pd);
            continue;
        }
        if (t == GeomAbs_Plane && su.Plane().Axis().Direction().IsParallel(D, 1e-7)) {
            Pend pd{i, zOf(su.Plane().Location()), 1e18, -1, {}, 0, 0, false};
            for (TopExp_Explorer e(f, TopAbs_EDGE); e.More(); e.Next()) {
                BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
                if (c.GetType() != GeomAbs_Circle) continue;
                gp_Circ ci = c.Circle();
                if (gp_Lin(gp_Ax1(ax.o, D)).Distance(ci.Location()) <= 1e-5) {
                    pd.rmin = std::min(pd.rmin, ci.Radius());
                    pd.rmax = std::max(pd.rmax, ci.Radius());
                } else {
                    Circ cc; xyOf(ci.Location(), cc.x, cc.y); cc.r = ci.Radius();
                    pd.circ.push_back(cc);
                }
            }
            pend.push_back(pd);
            continue;
        }
        if (t == GeomAbs_Cylinder && su.Cylinder().Axis().Direction().IsNormal(D, 1e-6)) { radCyl.push_back(i); continue; }
        if (t == GeomAbs_Cone && su.Cone().Axis().Direction().IsNormal(D, 1e-6)) { radCone.push_back(i); continue; }
        if (t == GeomAbs_Plane && su.Plane().Axis().Direction().IsNormal(D, 1e-6)) { plNorm.push_back(i); continue; }
        addUnsup(f);
    }

    // superficies de revolución coaxiales: caras con el mismo perfil se unen (semicaras); si son ≥3 y no cierran la vuelta
    // son dientes/estrías repetidos, no una superficie torneada
    {
        auto same = [](const Seg& a, const Seg& b) {
            auto e = [](double x, double y) { return std::fabs(x - y) < 1e-4; };
            return a.kind == b.kind && a.inner == b.inner && e(a.z0, b.z0) && e(a.z1, b.z1) && e(a.r0, b.r0) && e(a.r1, b.r1) && e(a.mz, b.mz) && e(a.mr, b.mr);
        };
        std::vector<char> used(revSegs.size(), 0);
        for (size_t i = 0; i < revSegs.size(); i++) {
            if (used[i]) continue;
            double sum = 0; int cnt = 0;
            for (size_t j = i; j < revSegs.size(); j++) if (!used[j] && same(revSegs[i].s, revSegs[j].s)) { sum += revSegs[j].span; cnt++; }
            bool teeth = cnt >= 3 && sum < 2 * M_PI * 0.6;  // con planos paralelos al eje (llaves) la superficie sigue siendo torneada: se conserva si queda >60% de la vuelta
            for (size_t j = i; j < revSegs.size(); j++)
                if (!used[j] && same(revSegs[i].s, revSegs[j].s)) { used[j] = 1; if (teeth) addUnsup(faces[revSegs[j].face]); }
            if (!teeth) out.segs.push_back(revSegs[i].s);
        }
    }

    // taladros: unir semicilindros y etapas con la misma posición
    auto eq = [](double a, double b) { return std::fabs(a - b) < 1e-4; };
    for (auto& h : hc) {
        HoleSite* site = nullptr;
        for (auto& s : out.sites) if (eq(s.x, h.x) && eq(s.y, h.y)) site = &s;
        if (!site) { out.sites.push_back({h.x, h.y, {}}); site = &out.sites.back(); }
        HoleStage* stg = nullptr;
        for (auto& g : site->st) if (eq(g.r, h.r) && eq(g.z0, h.z0) && eq(g.z1, h.z1)) stg = &g;
        if (!stg) site->st.push_back({h.r, h.z0, h.z1, false});
    }
    auto siteAt = [&](double x, double y) { for (auto& s : out.sites) if (eq(s.x, x) && eq(s.y, y)) return true; return false; };
    for (auto& pd : pend) {
        const TopoDS_Face& f = faces[pd.i];
        if (pd.cone) { if (!siteAt(pd.x, pd.y)) addUnsup(f); continue; }
        if (pd.rmax > 0) {
            double exp = M_PI * (pd.rmax * pd.rmax - (pd.rmin == pd.rmax ? 0 : pd.rmin * pd.rmin));
            for (auto& s : out.sites) {
                double dist = std::hypot(s.x, s.y);
                if (dist < (pd.rmin == pd.rmax ? 0 : pd.rmin) - 1e-6 || dist > pd.rmax + 1e-6) continue;
                for (auto& g : s.st) if (eq(g.z0, pd.z) || eq(g.z1, pd.z)) exp -= M_PI * g.r * g.r;
            }
            if (std::fabs(area[pd.i] - exp) <= 0.02 * std::fabs(exp) + 1e-6) {
                Seg s;
                s.kind = Seg::Plane; s.z0 = s.z1 = pd.z;
                s.r0 = pd.rmin == pd.rmax ? 0 : pd.rmin; s.r1 = pd.rmax;
                out.segs.push_back(s);
                continue;
            }
        } else if (!pd.circ.empty()) {  // fondo de taladro / suelo de alojamiento
            bool all = true;
            for (auto& c : pd.circ) all &= siteAt(c.x, c.y);
            if (all) {
                for (auto& c : pd.circ) {
                    double mx = 0;
                    for (auto& o : pd.circ) if (eq(o.x, c.x) && eq(o.y, c.y)) mx = std::max(mx, o.r);
                    if (c.r < mx - 1e-6) continue;
                    for (auto& s : out.sites) if (eq(s.x, c.x) && eq(s.y, c.y))
                        for (auto& g : s.st) if (eq(g.r, c.r) && (eq(g.z0, pd.z) || eq(g.z1, pd.z))) g.blind = true;
                }
                continue;
            }
        }
        if (pd.rmax > 0) { partial.push_back({pd.i, pd.z}); continue; }
        addUnsup(f);
    }

    // ---- rasgos radiales: taladros radiales, planos y chaveteros
    auto outwardN = [&](const TopoDS_Face& f, const BRepAdaptor_Surface& su) {
        gp_Vec n(su.Plane().Axis().Direction());
        if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
        return n;
    };
    auto centroid = [&](size_t i) { GProp_GProps g; BRepGProp::SurfaceProperties(faces[i], g); return g.CentreOfMass(); };
    struct RC { double z, ang, r, tn, tf; gp_Pnt loc; gp_Dir A; };
    std::vector<RC> rcs;
    for (size_t i : radCyl) {
        BRepAdaptor_Surface su(faces[i]);
        gp_Ax1 ca = su.Cylinder().Axis();
        gp_Dir A = ca.Direction();
        gp_Pnt loc = ca.Location();
        gp_Vec cr = gp_Vec(D).Crossed(gp_Vec(A));
        double offs = std::fabs(gp_Vec(ax.o, loc).Dot(cr)) / std::max(cr.Magnitude(), 1e-12);
        double u0, u1, v0, v1;
        BRepTools::UVBounds(faces[i], u0, u1, v0, v1);
        gp_Pnt P; gp_Vec du, dv;
        su.D1(u0, 0.5 * (v0 + v1), P, du, dv);
        gp_Vec n = du.Crossed(dv);
        if (faces[i].Orientation() == TopAbs_REVERSED) n.Reverse();
        gp_Vec rad(loc, P);
        rad -= gp_Vec(A) * rad.Dot(gp_Vec(A));
        if (n.Dot(rad) >= 0 || offs > 1e-4) { addUnsup(faces[i]); continue; }
        double zl = zOf(loc);
        gp_Pnt X(ax.o.XYZ() + D.XYZ() * zl);
        gp_Pnt c = centroid(i);
        double sg = gp_Vec(loc, c).Dot(gp_Vec(A)) >= 0 ? 1 : -1;
        double tn = 1e18, tf = -1e18;
        for (TopExp_Explorer e(faces[i], TopAbs_VERTEX); e.More(); e.Next()) {
            double tt = sg * gp_Vec(X, BRep_Tool::Pnt(TopoDS::Vertex(e.Current()))).Dot(gp_Vec(A));
            tn = std::min(tn, tt); tf = std::max(tf, tt);
        }
        gp_Vec dA = gp_Vec(A) * sg;
        RC rc{zl, std::atan2(dA.Dot(gp_Vec(V)), dA.Dot(gp_Vec(U))), su.Cylinder().Radius(), tn, tf, loc, gp_Dir(dA)};
        rcs.push_back(rc);
    }
    auto angEq = [](double a, double b) { double d = std::fmod(std::fabs(a - b), 2 * M_PI); return d < 1e-3 || 2 * M_PI - d < 1e-3; };
    std::vector<RC> hs;  // fusionar caras del mismo lado
    for (auto& rc : rcs) {
        bool f = false;
        for (auto& h : hs) if (eq(h.z, rc.z) && eq(h.r, rc.r) && angEq(h.ang, rc.ang)) { h.tn = std::min(h.tn, rc.tn); h.tf = std::max(h.tf, rc.tf); f = true; }
        if (!f) hs.push_back(rc);
    }
    std::vector<char> used(hs.size(), 0);
    std::vector<RC> holeLines;  // línea de eje de cada taladro para absorber fondos
    for (size_t i = 0; i < hs.size(); i++) {
        if (used[i]) continue;
        used[i] = 1;
        RadHole rh;
        rh.z = hs[i].z; rh.ang = hs[i].ang; rh.r = hs[i].r;
        for (size_t j = i + 1; j < hs.size(); j++)
            if (!used[j] && eq(hs[j].z, hs[i].z) && eq(hs[j].r, hs[i].r) && angEq(hs[j].ang, hs[i].ang + M_PI)) { used[j] = 1; rh.through = true; }
        rh.depth = hs[i].tf - hs[i].tn;
        if (hs[i].tn < -1e-6) rh.through = true;
        out.rholes.push_back(rh);
        holeLines.push_back(hs[i]);
    }
    auto onHoleLine = [&](const gp_Pnt& p, const gp_Dir& dirn, double r) {
        for (auto& h : holeLines) {
            if (!h.A.IsParallel(dirn, 1e-6)) continue;
            if (gp_Lin(h.loc, h.A).Distance(p) < 1e-4 && std::fabs(h.r - r) < 1e-4) return true;
        }
        return false;
    };
    for (size_t i : radCone) {
        BRepAdaptor_Surface su(faces[i]);
        if (!onHoleLine(su.Cone().Axis().Location(), su.Cone().Axis().Direction(), su.Cone().RefRadius())) {
            bool any = false;
            for (auto& h : holeLines) any |= h.A.IsParallel(su.Cone().Axis().Direction(), 1e-6) && gp_Lin(h.loc, h.A).Distance(su.Cone().Axis().Location()) < 1e-4;
            if (!any) addUnsup(faces[i]);
        }
    }
    struct PL { size_t i; gp_Vec n; double h, z0, z1, tw; double cosv; };
    std::vector<PL> floors, walls, hexc;
    for (size_t i : plNorm) {
        BRepAdaptor_Surface su(faces[i]);
        gp_Vec n = outwardN(faces[i], su);
        bool bottom = false;
        for (TopExp_Explorer e(faces[i], TopAbs_EDGE); e.More(); e.Next()) {
            BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
            if (c.GetType() == GeomAbs_Circle && onHoleLine(c.Circle().Location(), gp_Dir(n), c.Circle().Radius())) bottom = true;
        }
        if (bottom) continue;
        gp_Pnt c = centroid(i);
        gp_Vec cv(ax.o, c);
        cv -= gp_Vec(D) * cv.Dot(gp_Vec(D));
        double h = gp_Vec(ax.o, su.Plane().Location()).Dot(n);
        double cosv = cv.Magnitude() > 1e-9 ? n.Dot(cv) / cv.Magnitude() : 0;
        PL pl{i, n, h, 1e18, -1e18, 0, cosv};
        gp_Vec T = gp_Vec(D).Crossed(n);
        double tmin = 1e18, tmax = -1e18;
        for (TopExp_Explorer e(faces[i], TopAbs_VERTEX); e.More(); e.Next()) {
            gp_Pnt q = BRep_Tool::Pnt(TopoDS::Vertex(e.Current()));
            pl.z0 = std::min(pl.z0, zOf(q)); pl.z1 = std::max(pl.z1, zOf(q));
            double tt = gp_Vec(ax.o, q).Dot(T);
            tmin = std::min(tmin, tt); tmax = std::max(tmax, tt);
        }
        pl.tw = tmax - tmin;
        if (h < -1e-6 && cosv < -0.95) hexc.push_back(pl);   // pared hacia el eje: candidata a hueco hexagonal
        else if (h > 1e-6 && cosv > 0.95) floors.push_back(pl);
        else if (std::fabs(cosv) < 0.6) walls.push_back(pl);
        else addUnsup(faces[i]);
    }
    {   // hueco hexagonal (tornillo/macho): 6 paredes iguales a 60°, misma altura; se acota «s» entre caras y profundidad
        bool hex = hexc.size() == 6;
        for (size_t k = 1; hex && k < hexc.size(); k++)
            hex = std::fabs(hexc[k].h - hexc[0].h) < 1e-3 && eq(hexc[k].z0, hexc[0].z0) && eq(hexc[k].z1, hexc[0].z1);
        if (hex) {
            int cnt[6] = {0, 0, 0, 0, 0, 0};
            for (auto& a : hexc) {
                double ang = std::atan2(a.n.Dot(gp_Vec(V)), a.n.Dot(gp_Vec(U))) * 180 / M_PI;
                cnt[((int)std::floor((ang + 360) / 60.0 + 1e-3)) % 6]++;
            }
            for (int k = 0; k < 6; k++) hex &= cnt[k] == 1;
        }
        if (hex) { out.hexes.push_back({-2 * hexc[0].h, hexc[0].z0, hexc[0].z1}); }
        else for (auto& a : hexc) addUnsup(faces[a.i]);
    }
    std::vector<char> wUsed(walls.size(), 0);
    for (auto& fl : floors) {
        Cut ct;
        ct.ang = std::atan2(fl.n.Dot(gp_Vec(V)), fl.n.Dot(gp_Vec(U)));
        ct.h = fl.h; ct.w = fl.tw; ct.z0 = fl.z0; ct.z1 = fl.z1;
        int found[2] = {-1, -1}, nf = 0;
        for (size_t k = 0; k < walls.size() && nf < 2; k++)
            if (!wUsed[k] && std::fabs(walls[k].n.Dot(fl.n)) < 1e-3 && eq(walls[k].z0, fl.z0) && eq(walls[k].z1, fl.z1)) found[nf++] = (int)k;
        if (nf == 2 && walls[found[0]].n.Dot(walls[found[1]].n) < -0.99) {
            ct.slot = true;
            wUsed[found[0]] = wUsed[found[1]] = 1;
        }
        out.cuts.push_back(ct);
    }
    for (size_t k = 0; k < walls.size(); k++) if (!wUsed[k]) addUnsup(faces[walls[k].i]);
    bool regPoly = out.cuts.size() >= 3 && out.cuts.size() <= 12;   // prisma regular exterior (cabeza hexagonal, cuadrado): mismas z, misma altura, ángulos equiespaciados
    if (regPoly) {
        const size_t n = out.cuts.size();
        std::vector<double> an;
        for (auto& c : out.cuts) {
            regPoly &= !c.slot && std::fabs(c.h - out.cuts[0].h) < 1e-3 && eq(c.z0, out.cuts[0].z0) && eq(c.z1, out.cuts[0].z1);
            an.push_back(std::fmod(c.ang - out.cuts[0].ang + 4 * M_PI, 2 * M_PI));
        }
        std::sort(an.begin(), an.end());
        for (size_t k = 0; regPoly && k < n; k++) regPoly &= std::fabs(an[k] - 2 * M_PI * k / n) < 1e-2;
    }
    if (out.cuts.size() > 4 && !regPoly) {  // no es un prisma regular: no se interpreta como planos de llave
        for (auto& f : floors) addUnsup(faces[f.i]);
        for (size_t k = 0; k < walls.size(); k++) if (wUsed[k]) addUnsup(faces[walls[k].i]);
        out.cuts.clear();
    }
    for (auto& pt : partial) {
        bool ok = false;
        for (auto& c : out.cuts) ok |= eq(c.z0, pt.z) || eq(c.z1, pt.z);
        for (auto& sg : out.segs) ok |= sg.kind == Seg::Plane && eq(sg.z0, pt.z);
        if (!ok) {   // cara anular con taladros (brida): escalón entre dos cilindros exteriores → se completa como cara plana del perfil
            double ra = -1, rb = -1;
            for (auto& sg : out.segs) if (!sg.inner && sg.kind == Seg::Line) {
                if (eq(sg.z1, pt.z)) ra = std::max(sg.r0, sg.r1);
                if (eq(sg.z0, pt.z)) rb = std::max(sg.r0, sg.r1);
            }
            if (ra > 0 && rb > 0 && std::fabs(ra - rb) > 1e-4) {
                Seg w; w.kind = Seg::Plane; w.z0 = w.z1 = pt.z; w.r0 = std::min(ra, rb); w.r1 = std::max(ra, rb);
                out.segs.push_back(w); ok = true;
            }
        }
        if (!ok && !out.hexes.empty()) {   // cara de cabeza con hueco hexagonal: anillo entre el círculo de vértices del hexágono y el borde exterior
            double ro = 0;
            for (auto& sg : out.segs) if (!sg.inner && sg.kind != Seg::Plane && (eq(sg.z0, pt.z) || eq(sg.z1, pt.z))) ro = std::max({ro, sg.r0, sg.r1});
            double rh = out.hexes[0].af / std::sqrt(3.0);
            if (ro > rh + 1e-4) {
                Seg w; w.kind = Seg::Plane; w.z0 = w.z1 = pt.z; w.r0 = rh; w.r1 = ro;
                out.segs.push_back(w); ok = true;
                const HexSocket& hx = out.hexes[0];
                double zf = eq(hx.z0, pt.z) ? hx.z1 : hx.z0;   // suelo del hueco: pared (r = vértices) y fondo plano hasta el eje
                if (eq(hx.z0, pt.z) || eq(hx.z1, pt.z)) {
                    Seg a; a.kind = Seg::Line; a.inner = true; a.z0 = pt.z; a.z1 = zf; a.r0 = a.r1 = rh;
                    Seg b; b.kind = Seg::Plane; b.inner = true; b.z0 = b.z1 = zf; b.r0 = 0; b.r1 = rh;
                    if (zf < pt.z) std::swap(a.z0, a.z1);
                    out.segs.push_back(a); out.segs.push_back(b);
                }
            }
        }
        if (!ok) addUnsup(faces[pt.i]);
    }
    if (!out.hexes.empty()) {   // el suelo del hueco hexagonal (plano o B-spline) es del propio hueco
        double rh = out.hexes[0].af / std::sqrt(3.0), ah = 1.5 * std::sqrt(3.0) * rh * rh;
        for (const char* k : {"plano parcial perpendicular al eje (pared de chavetero/ranura)", "superficie 6"}) {
            auto it = out.unsupported.find(k);
            if (it != out.unsupported.end() && it->second == 1) { out.unsupported.erase(it); out.unsupArea -= ah; }
        }
    }
    {   // ≥8 caras B-spline y un taladro interior de revolución: rosca helicoidal (no es un rasgo fresado)
        auto it = out.unsupported.find("superficie 6");
        double ri = 0;   // la rosca debe quedar dentro del mayor radio de taladro (más holgura de cresta)
        for (auto& s : out.segs) if (s.inner) ri = std::max({ri, s.r0, s.r1});
        if (it != out.unsupported.end() && it->second >= 8 && ri > 0 && bsRmax <= ri + 0.3) { out.unsupported.erase(it); out.unsupArea -= bsArea; out.thread = true; }
        else if (it != out.unsupported.end() && it->second >= 8) {   // rosca exterior: los flancos B-spline montan sobre un cilindro exterior (núcleo) y no pasan de ~1,35× su radio
            for (auto& s : out.segs) if (!s.inner && s.kind == Seg::Line && std::fabs(s.r0 - s.r1) < 1e-6 && s.r0 > 0 && bsRmin >= s.r0 - 0.3 && bsRmax <= s.r0 * 1.35 && bsRmax > s.r0 + 1e-3) {
                out.unsupported.erase(it); out.unsupArea -= bsArea; out.threadExtD = 2 * bsRmax;
                auto pw = out.unsupported.find("plano paralelo al eje (plano/chavetero/ranura)");   // los planos axiales pequeños del arranque/salida de la rosca son de la rosca
                int nw = 0; double aw = 0;
                for (size_t k = 0; k < walls.size(); k++) if (!wUsed[k] && std::fabs(walls[k].h) < 1e-6 && walls[k].tw < 2 * (bsRmax - bsRmin) + 0.2) { nw++; aw += walls[k].tw * (walls[k].z1 - walls[k].z0); }
                if (pw != out.unsupported.end() && nw > 0) { pw->second -= nw; out.unsupArea -= aw; if (pw->second <= 0) out.unsupported.erase(pw); }
                break;
            }
        }
    }
    if (out.segs.empty()) { out.error = "No se pudo construir el perfil."; return out; }

    // normalizar: z desde 0 y cara de referencia a la izquierda (extremo de mayor radio exterior)
    double zmin = 1e18, zmax = -1e18;
    for (auto& s : out.segs) { zmin = std::min({zmin, s.z0, s.z1}); zmax = std::max({zmax, s.z0, s.z1}); }
    auto outerAt = [&](double z) {
        double r = 0;
        for (auto& s : out.segs) if (!s.inner && ((std::fabs(s.z0 - z) < 1e-4) || std::fabs(s.z1 - z) < 1e-4)) r = std::max({r, s.r0, s.r1});
        return r;
    };
    for (auto& c : out.cuts) if (c.z1 - c.z0 > 1e-4) { zmin = std::min(zmin, c.z0); zmax = std::max(zmax, c.z1); }  // un extremo de prisma (cuadrado, hexágono) no es de revolución pero alarga la pieza
    bool flip = outerAt(zmax) > outerAt(zmin) + 1e-6;
    for (auto& s : out.segs) {
        auto tr = [&](double z) { return flip ? zmax - z : z - zmin; };
        s.z0 = tr(s.z0); s.z1 = tr(s.z1); s.cz = tr(s.cz); s.mz = tr(s.mz);
        if (s.z0 > s.z1) { std::swap(s.z0, s.z1); std::swap(s.r0, s.r1); }
    }
    auto trz = [&](double z) { return flip ? zmax - z : z - zmin; };
    for (auto& h : out.rholes) { h.z = trz(h.z); if (flip) h.ang = -h.ang; }
    for (auto& c : out.cuts) {
        double a0 = trz(c.z0), a1 = trz(c.z1);
        c.z0 = std::min(a0, a1); c.z1 = std::max(a0, a1);
        if (flip) c.ang = -c.ang;
    }
    for (auto& st : out.sites) {
        if (flip) st.y = -st.y;
        for (auto& g : st.st) {
            double a0 = flip ? zmax - g.z1 : g.z0 - zmin, a1 = flip ? zmax - g.z0 : g.z1 - zmin;
            g.z0 = a0; g.z1 = a1;
        }
    }
    out.length = zmax - zmin;
    // redondeo a 1e-6 para evitar ruido numérico en cotas
    auto rd6 = [](double& v) { v = std::round(v * 1e6) / 1e6; };
    for (auto& s : out.segs) { rd6(s.z0); rd6(s.z1); rd6(s.r0); rd6(s.r1); rd6(s.cz); rd6(s.cr); rd6(s.rad); rd6(s.mz); rd6(s.mr); }
    {   // tramos colineales y solapados (rosca helicoidal troceada, chaflanes repetidos): se funden en uno
        auto& v = out.segs;
        for (bool again = true; again;) {
            again = false;
            for (size_t i = 0; i < v.size() && !again; i++) for (size_t j = i + 1; j < v.size() && !again; j++) {
                Seg &a = v[i], &b = v[j];
                if (a.kind != Seg::Line || b.kind != Seg::Line || a.inner != b.inner || a.z1 - a.z0 < 1e-6 || b.z1 - b.z0 < 1e-6) continue;
                double ma = (a.r1 - a.r0) / (a.z1 - a.z0), mb = (b.r1 - b.r0) / (b.z1 - b.z0);
                if (std::fabs(ma - mb) > 1e-6 || std::fabs(a.r0 + ma * (b.z0 - a.z0) - b.r0) > 1e-6 || b.z0 > a.z1 + 1e-6 || a.z0 > b.z1 + 1e-6) continue;
                double z0 = std::min(a.z0, b.z0), z1 = std::max(a.z1, b.z1), r0 = a.r0 + ma * (z0 - a.z0), r1 = a.r0 + ma * (z1 - a.z0);
                a.z0 = z0; a.z1 = z1; a.r0 = r0; a.r1 = r1;
                v.erase(v.begin() + j); again = true;
            }
        }
    }
    for (auto& st : out.sites) { rd6(st.x); rd6(st.y); for (auto& g : st.st) { rd6(g.r); rd6(g.z0); rd6(g.z1); } }
    for (auto& h : out.rholes) { rd6(h.z); rd6(h.r); rd6(h.depth); }
    for (auto& hx : out.hexes) {   // los 6 cilindros de los vértices del hexágono son del propio hueco: no son rasgo aparte
        const std::string pre = "cilindro no coaxial Ø";
        for (auto it = out.unsupported.begin(); it != out.unsupported.end(); ++it)
            if (it->first.rfind(pre, 0) == 0 && it->second == 6 && std::fabs(std::atof(it->first.c_str() + pre.size()) - hx.af * 2 / std::sqrt(3.0)) < 0.1) { out.unsupported.erase(it); break; }
    }
    for (auto& c : out.cuts) { rd6(c.h); rd6(c.w); rd6(c.z0); rd6(c.z1); }
    rd6(out.length);
    {   // PMI: solo si el archivo declara tolerancias (evita una segunda lectura costosa)
        std::ifstream f(path, std::ios::binary);
        std::string all((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        if (all.find("TOLERANCE") != std::string::npos || all.find("LIMITS_AND_FITS") != std::string::npos) out.pmi = readPmi(path, &out.gdt);
    }
    return out;
}
}  // namespace diedro
