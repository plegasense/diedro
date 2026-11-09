// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include "special.hpp"
#include "iso.hpp"
#include <BRepAdaptor_Curve.hxx>
#include <BRepBndLib.hxx>
#include <BRep_Tool.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include <GeomAbs_Shape.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS_Edge.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <TopAbs.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>

namespace diedro {
namespace {
struct V3 { double x, y, z; };
V3 sub(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
V3 crs(V3 a, V3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
V3 unit(V3 a) { double n = std::sqrt(dot(a, a)); return n > 0 ? V3{a.x / n, a.y / n, a.z / n} : a; }

struct Tri { int piece = 0; double depth, gray; double p[3][2]; double z[3]; };

const double kCell = 4;

// Mayor hueco libre alcanzable desde el borde (no el interior de una vista hueca): x0 y0 x1 y1
bool freeRect(const Drawing& d, double r[4]) {
    const double X0 = 26, Y0 = 16, X1 = d.sheetW - 16, Y1 = d.sheetH - 16;  // el marco queda fuera de la rejilla (si no, sus celdas bloqueadas impiden sembrar)
    const int nx = (int)((X1 - X0) / kCell), ny = (int)((Y1 - Y0) / kCell);
    if (nx < 4 || ny < 4) return false;
    std::vector<char> blk(nx * ny, 0);
    auto mark = [&](double x, double y) {
        int i = (int)std::floor((x - X0) / kCell), j = (int)std::floor((y - Y0) / kCell);
        for (int a = i - 1; a <= i + 1; a++) for (int b = j - 1; b <= j + 1; b++) if (a >= 0 && a < nx && b >= 0 && b < ny) blk[b * nx + a] = 1;
    };
    auto seg = [&](double x1, double y1, double x2, double y2) {
        int n = std::max(1, (int)(std::hypot(x2 - x1, y2 - y1) / 1.5));
        for (int k = 0; k <= n; k++) mark(x1 + (x2 - x1) * k / n, y1 + (y2 - y1) * k / n);
    };
    for (auto& l : d.lines) seg(l.x1, l.y1, l.x2, l.y2);
    for (auto& a : d.arcs) { const int na = std::max(8, (int)(std::fabs(a.a1 - a.a0) * M_PI / 180 * a.r / 1.5)); for (int k = 0; k < na; k++) { double t = (a.a0 + (a.a1 - a.a0) * k / (na - 1)) * M_PI / 180; mark(a.cx + a.r * std::cos(t), a.cy + a.r * std::sin(t)); } }
    for (auto& t : d.texts) {
        double w = t.s.size() * t.height * 0.6;
        seg(t.x, t.y, t.x + w, t.y); seg(t.x, t.y + t.height, t.x + w, t.y + t.height);
        seg(t.x, t.y, t.x, t.y + t.height); seg(t.x + w, t.y, t.x + w, t.y + t.height);
        if (t.g < 0 && t.height < 3.2) for (double k = 1; k <= 8; k += 1.5) seg(t.x - k, t.y, t.x - k, t.y + t.height);   // notas: hueco a su izquierda para el globo de inspección
    }
    for (auto& p : d.polys) if (p.hatch <= 0) for (size_t i = 0; i < p.pts.size(); i++) { auto& a = p.pts[i]; auto& b = p.pts[(i + 1) % p.pts.size()]; seg(a.first, a.second, b.first, b.second); }
    // alcanzable desde el borde de la zona
    std::vector<char> reach(nx * ny, 0);
    std::vector<int> st;
    for (int i = 0; i < nx; i++) for (int j : {0, ny - 1}) if (!blk[j * nx + i] && !reach[j * nx + i]) { reach[j * nx + i] = 1; st.push_back(j * nx + i); }
    for (int j = 0; j < ny; j++) for (int i : {0, nx - 1}) if (!blk[j * nx + i] && !reach[j * nx + i]) { reach[j * nx + i] = 1; st.push_back(j * nx + i); }
    while (!st.empty()) {
        int c = st.back(); st.pop_back();
        int i = c % nx, j = c / nx;
        const int di[4] = {1, -1, 0, 0}, dj[4] = {0, 0, 1, -1};
        for (int k = 0; k < 4; k++) {
            int a = i + di[k], b = j + dj[k];
            if (a < 0 || a >= nx || b < 0 || b >= ny) continue;
            int q = b * nx + a;
            if (!blk[q] && !reach[q]) { reach[q] = 1; st.push_back(q); }
        }
    }
    double best = 0; int bi = 0, bj = 0, bw = 0, bh = 0;
    for (int j0 = 0; j0 < ny; j0++) for (int i0 = 0; i0 < nx; i0++) {
        int hmax = ny - j0;
        for (int w = 1; i0 + w <= nx; w++) {
            int h = 0;
            while (h < hmax && reach[(j0 + h) * nx + i0 + w - 1] && (w == 1 || h < 1 || true)) h++;
            hmax = std::min(hmax, h);
            if (hmax == 0) break;
            double sc = std::min(w * kCell, hmax * kCell * 1.1);
            if (sc > best) { best = sc; bi = i0; bj = j0; bw = w; bh = hmax; }
        }
    }
    if (best < 22) return false;
    r[0] = X0 + bi * kCell + 1; r[1] = Y0 + bj * kCell + 1; r[2] = X0 + (bi + bw) * kCell - 1; r[3] = Y0 + (bj + bh) * kCell - 1;
    return true;
}
}  // namespace

bool addIso(Drawing& d, const std::vector<IsoItem>& items, double maxScale, IsoResult* res, const Drawing* obst, double margin) {
    double R[4];
    if (items.empty()) return false;
    if (!freeRect(obst ? *obst : d, R)) { if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "ISO sin hueco\n"); return false; }
    const Pos p0 = d.pos();
    const V3 e = unit({1, -1, 1}), right = unit({1, 1, 0}), up = unit(crs(e, right)), light = unit({0.2, -0.7, 1.0});
    const V3 light2 = unit({-0.8, -0.3, 0.2});
    std::vector<Tri> tris;
    Bnd_Box gb; int nf = 0;
    for (auto& it : items) if (!it.sh.IsNull()) { BRepBndLib::Add(it.sh, gb); for (TopExp_Explorer ex(it.sh, TopAbs_FACE); ex.More(); ex.Next()) nf++; }
    if (gb.IsVoid()) return false;
    double gx0, gy0, gz0, gx1, gy1, gz1; gb.Get(gx0, gy0, gz0, gx1, gy1, gz1);
    // malla y partición de triángulos relativas al conjunto entero: las piezas pequeñas no inflan el PDF
    const double diag = std::sqrt((gx1 - gx0) * (gx1 - gx0) + (gy1 - gy0) * (gy1 - gy0) + (gz1 - gz0) * (gz1 - gz0));
    const double defl = std::max((nf > 1500 ? 0.008 : nf > 300 ? 0.004 : 0.002) * diag, 1e-3);
    for (auto& it : items) {
        if (it.sh.IsNull()) continue;
        BRepMesh_IncrementalMesh(it.sh, defl, false, 0.5, false);
        for (TopExp_Explorer ex(it.sh, TopAbs_FACE); ex.More(); ex.Next()) {
            const TopoDS_Face f = TopoDS::Face(ex.Current());
            TopLoc_Location loc;
            Handle(Poly_Triangulation) tr = BRep_Tool::Triangulation(f, loc);
            if (tr.IsNull()) continue;
            const bool rev = f.Orientation() == TopAbs_REVERSED;
            for (int k = 1; k <= tr->NbTriangles(); k++) {
                int a, b, c; tr->Triangle(k).Get(a, b, c);
                if (rev) std::swap(b, c);
                gp_Pnt P[3] = {tr->Node(a).Transformed(loc), tr->Node(b).Transformed(loc), tr->Node(c).Transformed(loc)};
                V3 q[3] = {{P[0].X(), P[0].Y(), P[0].Z()}, {P[1].X(), P[1].Y(), P[1].Z()}, {P[2].X(), P[2].Y(), P[2].Z()}};
                V3 n = unit(crs(sub(q[1], q[0]), sub(q[2], q[0])));
                if (dot(n, e) <= 0) continue;  // cara trasera de un sólido
                const double s_ = 0.30 + 0.55 * std::max(0.0, dot(n, light)) + 0.20 * std::max(0.0, dot(n, light2));
                const double g = std::min(0.95, s_) - 0.04 * (it.tone % 3), maxE = diag / 8;
                // los triángulos largos se parten para que el orden por profundidad (algoritmo del pintor) no falle
                struct Rec { static void go(const V3* q, int lvl, double maxE, const V3& right, const V3& up, const V3& e, double g, std::vector<Tri>& out) {
                    double l01 = dot(sub(q[1], q[0]), sub(q[1], q[0])), l12 = dot(sub(q[2], q[1]), sub(q[2], q[1])), l20 = dot(sub(q[0], q[2]), sub(q[0], q[2]));
                    double mx = std::max({l01, l12, l20});
                    if (lvl < 12 && mx > maxE * maxE && out.size() < 120000) {
                        int i = l01 == mx ? 0 : l12 == mx ? 1 : 2, j = (i + 1) % 3, k = (i + 2) % 3;
                        V3 m = {(q[i].x + q[j].x) / 2, (q[i].y + q[j].y) / 2, (q[i].z + q[j].z) / 2};
                        V3 t1[3] = {q[i], m, q[k]}, t2[3] = {m, q[j], q[k]};
                        go(t1, lvl + 1, maxE, right, up, e, g, out); go(t2, lvl + 1, maxE, right, up, e, g, out);
                        return;
                    }
                    Tri t; t.depth = 0; t.gray = g;
                    for (int m = 0; m < 3; m++) { t.p[m][0] = dot(q[m], right); t.p[m][1] = dot(q[m], up); t.z[m] = dot(q[m], e); t.depth += t.z[m] / 3; }
                    out.push_back(t);
                } };
                const size_t n0 = tris.size();
                Rec::go(q, 0, maxE, right, up, e, g, tris);
                for (size_t z = n0; z < tris.size(); z++) tris[z].piece = it.tone;
            }
        }
    }
    if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "ISO triangulos %zu\n", tris.size());
    if (tris.empty()) return false;
    double lx = 1e30, ly = 1e30, hx = -1e30, hy = -1e30;
    for (auto& t : tris) for (auto& p : t.p) { lx = std::min(lx, p[0]); hx = std::max(hx, p[0]); ly = std::min(ly, p[1]); hy = std::max(hy, p[1]); }
    const double mg = maxScale > 0 ? margin : 0;  // conjuntos: margen respecto a vistas y lista, y nunca mayor que las vistas (la isométrica es ilustrativa)
    double s = std::min((R[2] - R[0] - 2 * mg) / (hx - lx), (R[3] - R[1] - 2 * mg) / (hy - ly));
    if (maxScale > 0) s = std::min(s, maxScale);
    const double ox = (R[0] + R[2]) / 2 - (lx + hx) / 2 * s, oy = (R[1] + R[3]) / 2 - (ly + hy) / 2 * s;
    std::stable_sort(tris.begin(), tris.end(), [](const Tri& a, const Tri& b) { return a.depth < b.depth; });  // lejos -> cerca
    for (auto& t : tris) {
        Poly p; p.gray = t.gray;
        for (auto& q : t.p) p.pts.push_back({ox + q[0] * s, oy + q[1] * s});
        d.polys.push_back(p);
    }

    // aristas marcadas como en el visor: aristas del B-rep (no las tangentes ni las costuras), solo los tramos vistos según un z-buffer de los mismos triángulos
    const double kPx = 4;  // celdas por mm de hoja
    const int gw = (int)((R[2] - R[0]) * kPx) + 3, gh = (int)((R[3] - R[1]) * kPx) + 3;
    std::vector<float> zb((size_t)gw * gh, -1e30f);
    std::vector<int> ib(res ? (size_t)gw * gh : 0, -1);   // pieza que se ve en cada celda
    auto gx = [&](double x) { return (x - (R[0] - 1)) * kPx; };
    auto gy = [&](double y) { return (y - (R[1] - 1)) * kPx; };
    for (auto& t : tris) {
        double X[3], Y[3];
        for (int m = 0; m < 3; m++) { X[m] = gx(ox + t.p[m][0] * s); Y[m] = gy(oy + t.p[m][1] * s); }
        double den = (Y[1] - Y[2]) * (X[0] - X[2]) + (X[2] - X[1]) * (Y[0] - Y[2]);
        if (std::fabs(den) < 1e-12) continue;
        int i0 = std::max(0, (int)std::floor(std::min({X[0], X[1], X[2]}))), i1 = std::min(gw - 1, (int)std::ceil(std::max({X[0], X[1], X[2]})));
        int j0 = std::max(0, (int)std::floor(std::min({Y[0], Y[1], Y[2]}))), j1 = std::min(gh - 1, (int)std::ceil(std::max({Y[0], Y[1], Y[2]})));
        for (int j = j0; j <= j1; j++) for (int i = i0; i <= i1; i++) {
            double px = i + 0.5, py = j + 0.5;
            double a = ((Y[1] - Y[2]) * (px - X[2]) + (X[2] - X[1]) * (py - Y[2])) / den;
            double b = ((Y[2] - Y[0]) * (px - X[2]) + (X[0] - X[2]) * (py - Y[2])) / den;
            double c = 1 - a - b;
            const double eps = -0.02;
            if (a < eps || b < eps || c < eps) continue;
            float z = (float)(a * t.z[0] + b * t.z[1] + c * t.z[2]);
            float& cell = zb[(size_t)j * gw + i];
            if (z > cell) { cell = z; if (res) ib[(size_t)j * gw + i] = t.piece; }
        }
    }
    if (res) {
        res->box[0] = ox + lx * s; res->box[1] = oy + ly * s; res->box[2] = ox + hx * s; res->box[3] = oy + hy * s;
        std::map<int, std::vector<int>> cells;
        for (size_t c = 0; c < ib.size(); c++) if (ib[c] >= 0) cells[ib[c]].push_back((int)c);
        for (auto& kv : cells) {
            if (kv.second.size() < 16) continue;   // menos de ~1 mm² visible: el globo irá en las vistas
            double cx = 0, cy = 0;
            for (int c : kv.second) { cx += c % gw; cy += c / gw; }
            cx /= kv.second.size(); cy /= kv.second.size();
            double bestSc = -1e30; int bi = 0, bj = 0;
            for (int c : kv.second) {   // punto más interior (vecinos de la misma pieza en 5x5), a igualdad el más cercano al centro de lo visible
                const int i = c % gw, j = c / gw;
                if ((i & 1) || (j & 1)) continue;
                int cnt = 0;
                for (int dj = -2; dj <= 2; dj++) for (int di = -2; di <= 2; di++) { int a = i + di, b = j + dj; if (a >= 0 && b >= 0 && a < gw && b < gh && ib[(size_t)b * gw + a] == kv.first) cnt++; }
                const double sc = cnt * 1e4 - ((i - cx) * (i - cx) + (j - cy) * (j - cy));
                if (sc > bestSc) { bestSc = sc; bi = i; bj = j; }
            }
            res->anchors.push_back({(double)kv.first, R[0] - 1 + (bi + 0.5) / kPx, R[1] - 1 + (bj + 0.5) / kPx, (double)kv.second.size()});
        }
    }
    const double tolZ = diag * 0.002 + 2.5 / kPx / s;
    auto visible = [&](V3 P) {
        double X = gx(ox + dot(P, right) * s), Y = gy(oy + dot(P, up) * s);
        int i = (int)X, j = (int)Y;
        if (i < 0 || j < 0 || i >= gw || j >= gh) return false;
        double zz = dot(P, e), best = -1e30;
        for (int dj = -1; dj <= 1; dj++) for (int di = -1; di <= 1; di++) {   // el vecino más cercano: la arista cae entre celdas
            int a = i + di, b = j + dj;
            if (a >= 0 && b >= 0 && a < gw && b < gh) best = std::max(best, (double)zb[(size_t)b * gw + a]);
        }
        return zz >= best - tolZ;
    };
    size_t nEdgePoly = 0;
    for (auto& it : items) {
        if (it.sh.IsNull()) continue;
        TopTools_IndexedDataMapOfShapeListOfShape em;
        TopExp::MapShapesAndAncestors(it.sh, TopAbs_EDGE, TopAbs_FACE, em);
        const bool hasSolid = TopExp_Explorer(it.sh, TopAbs_SOLID).More();
        for (int k = 1; k <= em.Extent() && nEdgePoly < 60000; k++) {
            const TopoDS_Edge ed = TopoDS::Edge(em.FindKey(k));
            if (BRep_Tool::Degenerated(ed)) continue;
            const TopTools_ListOfShape& fl = em.FindFromIndex(k);
            if (fl.Extent() == 0) continue;   // arista suelta (croquis del STEP), no pertenece a ninguna cara
            if (fl.Extent() == 2) {
                const TopoDS_Face f1 = TopoDS::Face(fl.First()), f2 = TopoDS::Face(fl.Last());
                if (f1.IsSame(f2)) continue;   // costura de una superficie cerrada
                if (BRep_Tool::Continuity(ed, f1, f2) >= GeomAbs_G1) continue;   // empalme tangente
            } else if (fl.Extent() == 1 && (hasSolid || BRep_Tool::IsClosed(ed, TopoDS::Face(fl.First())))) continue;   // borde libre: en un sólido es una cara suelta del STEP, no contorno
            BRepAdaptor_Curve cv(ed);
            GCPnts_QuasiUniformDeflection ud(cv, std::max(defl, 1e-4));
            std::vector<V3> pts;
            if (ud.IsDone()) for (int q = 1; q <= ud.NbPoints(); q++) { gp_Pnt g = ud.Value(q); pts.push_back({g.X(), g.Y(), g.Z()}); }
            if (pts.size() < 2) continue;
            for (size_t q = 0; q + 1 < pts.size(); q++) {
                const V3 A = pts[q], B = pts[q + 1];
                const double ax = ox + dot(A, right) * s, ay = oy + dot(A, up) * s, bx = ox + dot(B, right) * s, by = oy + dot(B, up) * s;
                const double len = std::hypot(bx - ax, by - ay);
                if (len < 1e-6) continue;
                const int n = std::max(1, (int)std::ceil(len / 0.5));
                int start = -1;
                for (int m = 0; m <= n + 1; m++) {
                    bool vis = false;
                    if (m <= n) { double f = (double)m / n; vis = visible({A.x + (B.x - A.x) * f, A.y + (B.y - A.y) * f, A.z + (B.z - A.z) * f}); }
                    if (vis && start < 0) start = m;
                    if ((!vis || m == n) && start >= 0) {
                        int end = vis ? m : m - 1;
                        double f0 = (double)start / n, f1 = (double)end / n;
                        double x0 = ax + (bx - ax) * f0, y0 = ay + (by - ay) * f0, x1 = ax + (bx - ax) * f1, y1 = ay + (by - ay) * f1;
                        double dx = (x1 - x0), dy = (y1 - y0), L = std::hypot(dx, dy);
                        if (L < 1e-6) { dx = (bx - ax) / len; dy = (by - ay) / len; L = 1; }
                        const double hw = 0.07, nx = -dy / L * hw, ny = dx / L * hw, ex = dx / L * hw, ey = dy / L * hw;
                        Poly e2; e2.gray = 0.12;
                        e2.pts = {{x0 - ex + nx, y0 - ey + ny}, {x1 + ex + nx, y1 + ey + ny}, {x1 + ex - nx, y1 + ey - ny}, {x0 - ex - nx, y0 - ey - ny}};
                        d.polys.push_back(e2);
                        nEdgePoly++;
                        start = -1;
                    }
                }
            }
        }
    }
    d.groups.push_back("Isométrica");
    d.tag(p0, (int)d.groups.size() - 1);
    return true;
}

bool addIsoStep(Drawing& d, const std::string& path) {
    TopoDS_Shape sh;
    if (!readShapeCached(path, sh)) return false;
    return addIso(d, {{sh, 0}}, d.scale > 0 ? 1.5 * d.scale : 0);   // ilustrativa: nunca mayor que las vistas acotadas
}
}  // namespace diedro
