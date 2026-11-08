#include "assembly.hpp"
#include "iso.hpp"
#include <cctype>
#include <BRepAdaptor_Curve.hxx>
#include <BRepBndLib.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <gp_Pln.hxx>
#include <Bnd_Box.hxx>
#include <Bnd_OBB.hxx>
#include <GCPnts_QuasiUniformDeflection.hxx>
#include "cx.hpp"
#include <GeomAbs_CurveType.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Geom_BSplineSurface.hxx>
#include <BRep_Tool.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepTools.hxx>
#include <BRepTools_WireExplorer.hxx>
#include <BRepTools_ReShape.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <TopoDS.hxx>
#include <HLRAlgo_Projector.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_PolyAlgo.hxx>
#include <HLRBRep_PolyHLRToShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopExp.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <STEPControl_Writer.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Trsf.hxx>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <array>
#include <chrono>
#include <future>
#include <memory>
#include <thread>
#include <map>
#include <functional>
#include <queue>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <TopoDS_Vertex.hxx>
#include "analyze.hpp"
#include "classify.hpp"
#include "datum.h"
#include "font.hpp"
#include "projsym.hpp"
#include "i18n.hpp"
#include "prism.hpp"
#include "special.hpp"
#include "gear.hpp"

TopoDS_Shape datum_part_shape_cpp(const DatumScene* s, int part);

namespace diedro {
namespace {
struct Ln { double x1, y1, x2, y2; };
struct Inst { int part; std::vector<Ln> vis[2], hid[2]; };  // líneas visibles en alzado (0) y planta (1), en coordenadas de vista
struct PartInfo { int part; int pos; TopoDS_Shape shape; int qty = 0; std::string name, mat; double dim[3] = {0, 0, 0}; };

std::string trimNum(double v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.1f", v);
    std::string s = b;
    if (s.size() > 2 && s.substr(s.size() - 2) == ".0") s.resize(s.size() - 2);
    return s;
}
double textW(const std::string& s, double h) {
    double w = 0;
    for (size_t i = 0; i < s.size();) { const Glyph* g = findGlyph(nextCp(s, i)); w += g ? g->w : 500; }
    return w / 1000.0 * h;
}
std::string fit(const std::string& s, double h, double w) {  // recorta con «…» para que quepa en w mm
    if (textW(s, h) <= w) return s;
    std::string o = s;
    while (!o.empty()) {
        size_t i = o.size() - 1;
        while (i > 0 && (o[i] & 0xC0) == 0x80) i--;
        o.resize(i);
        if (textW(o + "…", h) <= w) return o + "…";
    }
    return "…";
}
void text(Drawing& d, double x, double y, double h, const std::string& s, bool undef = false) { d.texts.push_back({x, y, h, s, 0, undef}); }
void line(Drawing& d, double x1, double y1, double x2, double y2, double w = 0.25) { d.lines.push_back({x1, y1, x2, y2, LineType::Continuous, w}); }

void collect(const TopoDS_Shape& s, std::vector<Ln>& L) {
    if (s.IsNull()) return;
    for (TopExp_Explorer e(s, TopAbs_EDGE); e.More(); e.Next()) {
        BRepAdaptor_Curve c(TopoDS::Edge(e.Current()));
        if (c.GetType() == GeomAbs_Line) { gp_Pnt a = c.Value(c.FirstParameter()), b = c.Value(c.LastParameter()); L.push_back({a.X(), a.Y(), b.X(), b.Y()}); }
        else {
            GCPnts_QuasiUniformDeflection q(c, 0.05);
            if (!q.IsDone()) continue;
            for (int i = 1; i < q.NbPoints(); i++) { gp_Pnt a = q.Value(i), b = q.Value(i + 1); L.push_back({a.X(), a.Y(), b.X(), b.Y()}); }
        }
    }
}

struct Sheet { const char* name; double w, h; };
const Sheet kSheets[] = {{"A4", 297, 210}, {"A3", 420, 297}, {"A2", 594, 420}, {"A1", 841, 594}, {"A0", 1189, 841}};
const double kScales[] = {5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005};
const double kTitleH = 36, kTitleW = 180, kRowH = 6, kBalloonR = 5, kPitch = 12.5;
const double kColW[6] = {9, 32, 11, 22, 26, 30};
const double kTableW = 130, kGuard = 20.0;  // s: espera máxima por hoja de pieza (guarda contra cuelgues)
const long kMaxPoles = 3000;
const int kMaxPartFaces = 250, kFaceBudget = 1500;  // caras: por pieza y total entre las hojas de pieza

std::string scaleText(double s) {
    char b[24];
    if (s >= 1) std::snprintf(b, sizeof b, "%g:1", s); else std::snprintf(b, sizeof b, "1:%g", std::round(1 / s));
    return b;
}

bool isFastener(std::string n) {
    for (auto& c : n) c = (char)std::tolower((unsigned char)c);
    std::string tok;
    for (size_t i = 0; i <= n.size(); i++) {
        if (i < n.size() && std::isalnum((unsigned char)n[i])) { tok += n[i]; continue; }
        if (tok == "pin" || tok == "nut" || tok == "bolt" || tok == "screw" || tok == "washer" || tok == "rivet" || tok.rfind("screw", 0) == 0 || tok.rfind("tornillo", 0) == 0 || tok.rfind("tuerca", 0) == 0 || tok.rfind("arandela", 0) == 0 || tok.rfind("pasador", 0) == 0 || tok.rfind("remache", 0) == 0) return true;
        tok.clear();
    }
    return false;
}
// ISO 128-44: elemento macizo de revolución alargado (eje, pasador, tornillo) aunque no tenga nombre: todas las caras son planas/cilindros/conos/toros/esferas,
// hay un cilindro paralelo al lado mayor, largo ≥ 2,5·ancho y volumen ≥ 0,5·ancho²·largo (sin taladro grande)
bool isSolidRod(const TopoDS_Shape& sh) {
    Bnd_Box b; BRepBndLib::Add(sh, b); if (b.IsVoid()) return false;
    double m0, m1, m2, M0, M1, M2; b.Get(m0, m1, m2, M0, M1, M2);
    const double e[3] = {M0 - m0, M1 - m1, M2 - m2};
    int L = 0; for (int i = 1; i < 3; i++) if (e[i] > e[L]) L = i;
    const double w = std::max(e[(L + 1) % 3], e[(L + 2) % 3]);
    if (w <= 0 || e[L] < 2.5 * w) return false;
    bool cyl = false;
    for (TopExp_Explorer fe(sh, TopAbs_FACE); fe.More(); fe.Next()) {
        BRepAdaptor_Surface sf(TopoDS::Face(fe.Current()));
        const GeomAbs_SurfaceType t = sf.GetType();
        if (t == GeomAbs_Cylinder) { const gp_Dir d = sf.Cylinder().Axis().Direction(); const double c[3] = {d.X(), d.Y(), d.Z()}; if (std::fabs(c[L]) > 1 - 1e-6) cyl = true; }
        else if (t != GeomAbs_Plane && t != GeomAbs_Cone && t != GeomAbs_Torus && t != GeomAbs_Sphere) return false;
    }
    if (!cyl) return false;
    GProp_GProps g; BRepGProp::VolumeProperties(sh, g);
    return g.Mass() >= 0.5 * w * w * e[L];
}
std::string fmtMm(double v) {
    char b[32]; std::snprintf(b, sizeof b, std::fabs(v - std::round(v)) < 0.05 ? "%.0f" : "%.1f", v);
    std::string r = b; for (auto& c : r) if (c == '.') c = ',';
    return r;
}
// Cota total ISO 129-1 (flechas 3 mm, líneas de extensión con 1 mm de hueco y 2 de pasada): horizontal (hor) entre u0 y u1 a la altura c, o vertical a la abscisa c; ref = borde de la vista.
void overallDim(Drawing& d, bool hor, double u0, double u1, double c, double ref, const std::string& s) {
    const double dir = c >= ref ? 1 : -1;
    if (hor) {
        line(d, u0, ref + dir * 1, u0, c + dir * 2, 0.25); line(d, u1, ref + dir * 1, u1, c + dir * 2, 0.25);
        line(d, u0, c, u1, c, 0.25);
        Poly a, b; a.pts = {{u0, c}, {u0 + 3, c + 0.8}, {u0 + 3, c - 0.8}}; b.pts = {{u1, c}, {u1 - 3, c + 0.8}, {u1 - 3, c - 0.8}};
        d.polys.push_back(a); d.polys.push_back(b);
        text(d, (u0 + u1) / 2 - textW(s, 3.5) / 2, c + 1.2, 3.5, s);
    } else {
        line(d, ref + dir * 1, u0, c + dir * 2, u0, 0.25); line(d, ref + dir * 1, u1, c + dir * 2, u1, 0.25);
        line(d, c, u0, c, u1, 0.25);
        Poly a, b; a.pts = {{c, u0}, {c + 0.8, u0 + 3}, {c - 0.8, u0 + 3}}; b.pts = {{c, u1}, {c + 0.8, u1 - 3}, {c - 0.8, u1 - 3}};
        d.polys.push_back(a); d.polys.push_back(b);
        d.texts.push_back({c - 1.2, (u0 + u1) / 2 - textW(s, 3.5) / 2, 3.5, s, 90, false});
    }
}
struct Balloon { int pos; double ax, ay; int side; double bx, by; };  // anclaje en hoja; lado 0 arriba, 1 abajo, 2 izq, 3 der; centro del globo

void disc(Drawing& d, double x, double y, double r, bool white) {
    Poly p; p.white = white;
    for (int i = 0; i < 16; i++) p.pts.push_back({x + r * std::cos(i * M_PI / 8), y + r * std::sin(i * M_PI / 8)});
    d.polys.push_back(p);
}
}  // namespace

Drawing drawPart(const std::string& path, const Meta& meta, std::string& err) {
    Profile p = analyzeStep(path);
    Drawing d;
    { gCamStrict = true; const bool ok = layoutSpring(path, meta, d) || layoutCamshaft(path, meta, d) || layoutCam(path, meta, d); gCamStrict = false;   // muelles y levas sueltas dentro del conjunto: mismo motor que la pieza suelta
      if (ok) { addIsoStep(d, path); return d; } }
    d = Drawing();
    bool prism = false;
    if (chooseEnginePrism(path, p)) {
        std::string e;
        d = layoutPrism(path, meta, e);
        if (e.empty()) prism = true;
        else if (!p.error.empty()) { err = e; return d; }
    }
    if (!prism && !p.error.empty()) { err = p.error; return d; }
    if (!prism) d = layout(p, meta);
    addIsoStep(d, path); balanceViews(d);
    d.kind = prism ? "prism" : "turn";
    return d;
}

// volumen y área de un sólido, una sola vez por forma (la integración de superficies B-spline es lo más caro de la lectura)
static const std::array<double, 2>& massOf(const TopoDS_Shape& sh) {
    static thread_local std::map<const void*, std::array<double, 2>> cache;
    auto it = cache.find(sh.TShape().get());
    if (it != cache.end()) return it->second;
    GProp_GProps gv, gs; BRepGProp::VolumeProperties(sh, gv); BRepGProp::SurfaceProperties(sh, gs);
    return cache[sh.TShape().get()] = {gv.Mass(), gs.Mass()};
}

// Longitud del eje de una pieza esbelta y curva (cable): geodésica sobre la malla desde un extremo + centroides de bandas → polilínea del eje.
// ISO 129-1 §7.15 (longitud desarrollada); método = decisión propia. Devuelve 0 si no es esbelta.
static double axisLengthSlender(const TopoDS_Shape& sh, double dmin, std::array<std::array<double, 3>, 2>* ends = nullptr) {
    if (dmin <= 1e-6) return 0;
    BRepMesh_IncrementalMesh mesh(sh, std::max(0.05, 0.1 * dmin), false, 0.5, false);
    std::map<std::array<long long, 3>, int> id; std::vector<std::array<double, 3>> P; std::vector<std::vector<std::pair<int, double>>> adj;
    const double q = 0.02 * dmin;
    auto vid = [&](const gp_Pnt& p) { std::array<long long, 3> k = {std::llround(p.X() / q), std::llround(p.Y() / q), std::llround(p.Z() / q)};
        auto it = id.find(k); if (it != id.end()) return it->second; const int n = (int)P.size(); id[k] = n; P.push_back({p.X(), p.Y(), p.Z()}); adj.emplace_back(); return n; };
    for (TopExp_Explorer ex(sh, TopAbs_FACE); ex.More(); ex.Next()) {
        TopLoc_Location loc; Handle(Poly_Triangulation) tr = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
        if (tr.IsNull()) continue;
        std::vector<int> m(tr->NbNodes() + 1);
        for (int i = 1; i <= tr->NbNodes(); i++) m[i] = vid(tr->Node(i).Transformed(loc.Transformation()));
        for (int t = 1; t <= tr->NbTriangles(); t++) { int a, b, c; tr->Triangle(t).Get(a, b, c); const int v[3] = {m[a], m[b], m[c]};
            for (int k = 0; k < 3; k++) { const int u = v[k], w = v[(k + 1) % 3]; if (u == w) continue;
                const double d = std::sqrt(std::pow(P[u][0] - P[w][0], 2) + std::pow(P[u][1] - P[w][1], 2) + std::pow(P[u][2] - P[w][2], 2)); adj[u].push_back({w, d}); adj[w].push_back({u, d}); } }
    }
    const int N = (int)P.size(); if (N < 20) return 0;
    auto dijkstra = [&](int s0) { std::vector<double> dist(N, 1e300); dist[s0] = 0;
        std::priority_queue<std::pair<double, int>, std::vector<std::pair<double, int>>, std::greater<>> pq; pq.push({0, s0});
        while (!pq.empty()) { auto [d, u] = pq.top(); pq.pop(); if (d > dist[u]) continue; for (auto& e : adj[u]) if (d + e.second < dist[e.first]) { dist[e.first] = d + e.second; pq.push({dist[e.first], e.first}); } }
        return dist; };
    auto far = [&](const std::vector<double>& d) { int b = 0; for (int i = 0; i < N; i++) if (d[i] < 1e299 && d[i] > d[b]) b = i; return b; };
    const int A = far(dijkstra(0)); const std::vector<double> dA = dijkstra(A); const int B = far(dA);
    const double Lg = dA[B]; if (Lg < 1e-6) return 0;
    const double w = std::max(2.0 * dmin, Lg / 400); const int nb = (int)(Lg / w) + 1;
    std::vector<std::array<double, 4>> acc(nb, {0, 0, 0, 0});
    for (int i = 0; i < N; i++) if (dA[i] < 1e299) { auto& a = acc[std::min(nb - 1, (int)(dA[i] / w))]; a[0] += P[i][0]; a[1] += P[i][1]; a[2] += P[i][2]; a[3] += 1; }
    double L = 0; bool have = false; double px = 0, py = 0, pz = 0;
    for (auto& a : acc) { if (a[3] < 1) continue; const double x = a[0] / a[3], y = a[1] / a[3], z = a[2] / a[3];
        if (have) L += std::sqrt((x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz)); else if (ends) (*ends)[0] = {x, y, z};
        px = x; py = y; pz = z; have = true; }
    if (ends) (*ends)[1] = {px, py, pz};
    return L;
}

std::vector<Drawing> layoutAssembly(const std::string& path, const Meta& meta, const std::string& tmpDir, std::string& err, int knownParts) {
    std::vector<Drawing> out;
    if (knownParts > 400) { err = "Conjunto demasiado grande para esta versión (" + std::to_string(knownParts) + " piezas)."; return out; }  // antes de leer otra vez el STEP
    const auto t0 = std::chrono::steady_clock::now();
    auto secs = [&] { return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(); };
    const bool dbg = std::getenv("DIEDRO_DBG") != nullptr;
    const std::string lang = meta.lang;
    auto T = [&](const char* es) { return tr(es, lang); };
    datum_cad_set_nomesh(1);  // las vistas parten de la forma (HLR) y rehacen su malla
    DatumScene* sc = datum_cad_open(path.c_str(), 0.001);
    datum_cad_set_nomesh(0);
    if (!sc) { err = datum_last_error() ? datum_last_error() : "No se pudo leer el conjunto."; return out; }
    if (dbg) std::fprintf(stderr, "ASM datum_open %.1fs\n", secs());
    struct Guard { DatumScene* s; ~Guard() { datum_scene_free(s); } } guard{sc};

    // posiciones de mundo de cada nodo (las matrices del árbol son locales)
    const int nn = datum_node_count(sc);
    std::vector<gp_Trsf> W(nn);
    std::vector<PartInfo> infos;
    std::map<int, int> infoOf;  // pieza de Datum -> índice en infos
    struct InstRef { int info; TopoDS_Shape sh; };
    std::vector<InstRef> refs;
    for (int i = 0; i < nn; i++) {
        const double* m = datum_node_matrix(sc, i);
        gp_Trsf t;
        t.SetValues(m[0], m[4], m[8], m[12], m[1], m[5], m[9], m[13], m[2], m[6], m[10], m[14]);
        int par = datum_node_parent(sc, i);
        W[i] = par >= 0 ? W[par].Multiplied(t) : t;
        int part = datum_node_part(sc, i);
        if (part < 0) continue;
        if (!infoOf.count(part)) {
            PartInfo pi; pi.part = part; pi.pos = (int)infos.size() + 1;
            pi.name = datum_part_name(sc, part);
            if (pi.name == "Sin nombre" || pi.name.rfind("Open CASCADE STEP translator", 0) == 0) pi.name.clear();
            double dens = 0;
            pi.mat = datum_part_material(sc, part, &dens);
            TopoDS_Shape ps = datum_part_shape_cpp(sc, part);
            pi.shape = ps;
            if (!ps.IsNull()) {
                Bnd_OBB ob; BRepBndLib::AddOBB(ps, ob, false, false, false);
                double h[3] = {2 * ob.XHSize(), 2 * ob.YHSize(), 2 * ob.ZHSize()};
                std::sort(h, h + 3, [](double a, double b) { return a > b; });
                for (int k = 0; k < 3; k++) pi.dim[k] = h[k];
            }
            infoOf[part] = (int)infos.size();
            infos.push_back(pi);
        }
        int ii = infoOf[part];
        infos[ii].qty++;
        TopoDS_Shape ps = datum_part_shape_cpp(sc, part);
        if (!ps.IsNull()) refs.push_back({ii, ps.Moved(TopLoc_Location(W[i]))});
    }
    if (infos.size() == 1 && !refs.empty()) {  // compuesto plano sin árbol: cada sólido es una pieza; iguales (volumen, área y cajas) = misma pieza
        std::vector<PartInfo> flat;
        std::vector<InstRef> frefs;
        std::map<std::string, int> seen;
        const TopoDS_Shape whole = refs[0].sh;
        const std::string nm = infos[0].name;
        for (TopExp_Explorer e(whole, TopAbs_SOLID); e.More(); e.Next()) {
            const TopoDS_Shape so = e.Current();
            const std::array<double, 2>& ms = massOf(so);
            Bnd_OBB ob; BRepBndLib::AddOBB(so, ob, false, false, false);
            double h[3] = {2 * ob.XHSize(), 2 * ob.YHSize(), 2 * ob.ZHSize()};
            std::sort(h, h + 3);
            char key[160]; std::snprintf(key, sizeof key, "%.2f|%.1f|%.1f|%.1f|%.1f", ms[0], ms[1], h[0], h[1], h[2]);
            auto it = seen.find(key);
            int ii;
            if (it == seen.end()) {
                PartInfo pi; pi.part = -1; pi.pos = (int)flat.size() + 1; pi.shape = so;
                std::sort(h, h + 3, [](double a, double b) { return a > b; });
                for (int k = 0; k < 3; k++) pi.dim[k] = h[k];
                ii = (int)flat.size(); seen[key] = ii; flat.push_back(pi);
            } else ii = it->second;
            flat[ii].qty++;
            frefs.push_back({ii, so});
        }
        if (flat.size() > 1) { infos = flat; refs = frefs; }
    }
    {  // piezas iguales (mismo nombre, material, volumen, área y cajas) = una sola posición con cantidad
        std::map<std::string, int> seen;
        std::vector<PartInfo> merged;
        std::vector<int> remap(infos.size());
        auto base = [](const PartInfo& pi) { char b[96]; std::snprintf(b, sizeof b, "|%.1f|%.1f|%.1f", pi.dim[0], pi.dim[1], pi.dim[2]); return pi.name + "|" + pi.mat + b; };
        std::map<std::string, int> nBase;  // volumen y área solo si otra pieza tiene mismo nombre, material y cajas (integrar es lo caro)
        for (auto& pi : infos) nBase[base(pi)]++;
        for (size_t i = 0; i < infos.size(); i++) {
            const PartInfo& pi = infos[i];
            std::string key = base(pi);
            if (!pi.shape.IsNull() && nBase[key] > 1) {
                const std::array<double, 2>& ms = massOf(pi.shape);
                char b[96]; std::snprintf(b, sizeof b, "|%.2f|%.1f", ms[0], ms[1]);
                key += b;
            }
            auto it = seen.find(key);
            if (it == seen.end()) { seen[key] = (int)merged.size(); remap[i] = (int)merged.size(); merged.push_back(pi); merged.back().pos = (int)merged.size(); merged.back().qty = pi.qty; }
            else { remap[i] = it->second; merged[it->second].qty += pi.qty; }
        }
        if (merged.size() != infos.size()) { infos = merged; for (auto& r : refs) r.info = remap[r.info]; }
    }
    if (dbg) std::fprintf(stderr, "ASM tras_fusion %.1fs\n", secs());
    if (infos.empty()) { err = "El conjunto no contiene piezas."; return out; }
    std::vector<std::string> warns;
    const size_t kMaxInst = 400, kMaxParts = 40;
    if (refs.size() > kMaxInst) { err = "Conjunto demasiado grande para esta versión (" + std::to_string(refs.size()) + " piezas colocadas)."; return out; }

    if (dbg) std::fprintf(stderr, "ASM lectura %.1fs piezas=%zu inst=%zu\n", secs(), infos.size(), refs.size());
    // vistas con líneas visibles por instancia (HLR con todas las piezas: se ocultan entre sí)
    const gp_Dir NV[2] = {gp_Dir(0, -1, 0), gp_Dir(0, 0, 1)}, XV[2] = {gp_Dir(1, 0, 0), gp_Dir(1, 0, 0)};
    std::vector<Inst> inst(refs.size());
    for (size_t k = 0; k < refs.size(); k++) inst[k].part = refs[k].info;
    // HLR exacto; con muchas caras (roscas, mallas) el exacto tarda minutos: se usa HLR sobre malla, más rápido y suficiente para la vista de conjunto
    size_t nFaces = 0; long poles = 0;
    for (auto& r : refs) {
        TopTools_IndexedMapOfShape m; TopExp::MapShapes(r.sh, TopAbs_FACE, m); nFaces += m.Extent();
        poles += splinePoles(r.sh);
    }
    bool poly = (nFaces > 150 || poles > 1500 || std::getenv("DIEDRO_POLY")) && !std::getenv("DIEDRO_EXACT");
    if (poly) {
        Bnd_Box bb; for (auto& r : refs) BRepBndLib::Add(r.sh, bb);
        double x0, y0, z0, x1, y1, z1; bb.Get(x0, y0, z0, x1, y1, z1);
        const double diag = std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0));
        for (auto& r : refs) { BRepTools::Clean(r.sh); BRepMesh_IncrementalMesh(r.sh, diag * 0.002, false, 0.5, true); }  // Clean: la malla fina de Datum deja polígonos de aristas incoherentes
        // HLR sobre malla se cae si alguna cara no se pudo triangular (cara degenerada de un STEP malo): se quita esa cara de la vista
        for (auto& r : refs) {
            Handle(BRepTools_ReShape) rs = new BRepTools_ReShape(); bool any = false;
            for (TopExp_Explorer fe(r.sh, TopAbs_FACE); fe.More(); fe.Next()) {
                TopLoc_Location l;
                if (BRep_Tool::Triangulation(TopoDS::Face(fe.Current()), l).IsNull()) { rs->Remove(fe.Current()); any = true; }
            }
            if (any) { r.sh = rs->Apply(r.sh); if (dbg) std::fprintf(stderr, "ASM malla: cara sin triangulación quitada\n"); }
        }
    }
    auto hlrView = [&](int v) {
        const HLRAlgo_Projector proj(gp_Ax2(gp_Pnt(0, 0, 0), NV[v], XV[v]));
        if (poly) {
            Handle(HLRBRep_PolyAlgo) alg = new HLRBRep_PolyAlgo();
            for (auto& r : refs) alg->Load(r.sh);
            alg->Projector(proj);
            alg->Update();
            HLRBRep_PolyHLRToShape h;
            h.Update(alg);
            for (size_t k = 0; k < refs.size(); k++) {
                collect(h.VCompound(refs[k].sh), inst[k].vis[v]);
                collect(h.OutLineVCompound(refs[k].sh), inst[k].vis[v]);
                collect(h.HCompound(refs[k].sh), inst[k].hid[v]);
            }
            return;
        }
        Handle(HLRBRep_Algo) alg = new HLRBRep_Algo();
        for (auto& r : refs) alg->Add(r.sh);
        alg->Projector(proj);
        alg->Update();
        alg->Hide();
        HLRBRep_HLRToShape h(alg);
        for (size_t k = 0; k < refs.size(); k++) {
            collect(h.VCompound(refs[k].sh), inst[k].vis[v]);
            collect(h.OutLineVCompound(refs[k].sh), inst[k].vis[v]);
            collect(h.HCompound(refs[k].sh), inst[k].hid[v]);
        }
    };
    if (poly) { auto f1 = std::async(std::launch::async, hlrView, 1); hlrView(0); f1.get(); } else { hlrView(0); hlrView(1); }  // la malla ya está hecha: las dos vistas son independientes
    if (dbg) std::fprintf(stderr, "ASM HLR %.1fs poly=%d caras=%zu\n", secs(), (int)poly, nFaces);
    double lo[2][2] = {{1e300, 1e300}, {1e300, 1e300}}, hi[2][2] = {{-1e300, -1e300}, {-1e300, -1e300}};
    for (auto& in : inst) for (int v = 0; v < 2; v++) for (auto& l : in.vis[v]) {
        lo[v][0] = std::min({lo[v][0], l.x1, l.x2}); hi[v][0] = std::max({hi[v][0], l.x1, l.x2});
        lo[v][1] = std::min({lo[v][1], l.y1, l.y2}); hi[v][1] = std::max({hi[v][1], l.y1, l.y2});
    }
    if (lo[0][0] > hi[0][0]) { err = "No se pudo proyectar el conjunto."; return out; }
    const double Wf = hi[0][0] - lo[0][0], Hf = hi[0][1] - lo[0][1], Wp = hi[1][0] - lo[1][0], Hp = hi[1][1] - lo[1][1];

    // formato y escala: primera hoja donde cabe a escala ≥ 1:2 (la última, lo que quepa)
    const size_t rows = infos.size();
    int chosen = -1; double sc_ = 0; int nblk = 1; size_t perBlk = 0; bool wide = false;
    int forced = -1;  // formato elegido por el usuario: solo ese (si no cabe, se avisa y se elige solo)
    for (int si = 0; si < 5; si++) if (meta.sheet == kSheets[si].name) forced = si;
    for (int pass = 0; pass < 2 && chosen < 0; pass++) {
      if (pass == 1) { if (forced < 0) break; forced = -1; warns.push_back(T("El formato elegido es pequeño para esta pieza: el plano queda denso; elige un formato mayor o Automático.")); }
    for (int si = 0; si < 5 && chosen < 0; si++) {
        if (forced >= 0 && si != forced) continue;
        const Sheet& sh = kSheets[si];
        const double fh = sh.h - 20 - kTitleH - kRowH;  // alto útil de una columna de la lista (sobre el cajetín)
        perBlk = std::max<size_t>(1, (size_t)(fh / kRowH));
        nblk = (int)((rows + perBlk - 1) / perBlk);
        const double areaW = sh.w - 30 - std::max(nblk * kTableW, kTitleW) - 8 - 2 * (kBalloonR * 2 + 10), areaH = sh.h - 20 - 2 * (kBalloonR * 2 + 10) - 12;
        if (areaW < 50) continue;
        // disposición ancha: las vistas ocupan todo el ancho por encima de la lista y el cajetín (piezas esbeltas: escala mayor)
        const double listH = kTitleH + (std::min(rows, perBlk) + 1) * kRowH + 8;
        const double areaW2 = sh.w - 30 - 2 * (kBalloonR * 2 + 10), areaH2 = areaH - listH;
        double s1 = 0, s2 = 0;
        for (double s : kScales) if ((std::max(Wf, Wp)) * s <= areaW && (Hf + Hp) * s <= areaH) { s1 = s; break; }
        if (areaW2 > 50 && areaH2 > 40) for (double s : kScales) if ((std::max(Wf, Wp)) * s <= areaW2 && (Hf + Hp) * s <= areaH2) { s2 = s; break; }
        const double s = s2 > s1 ? s2 : s1;
        if (s > 0 && (s >= 0.5 || si == 4 || forced >= 0)) { chosen = si; sc_ = s; wide = s2 > s1; }
    }
    }
    if (chosen < 0) { err = "El conjunto no cabe en ningún formato estándar."; return out; }
    const Sheet& sh = kSheets[chosen];
    Drawing A;
    A.sheetW = sh.w; A.sheetH = sh.h; A.sheetName = sh.name; A.scale = sc_;
    A.groups = {"Alzado", "Planta"};
    const double fx0 = 20, fy0 = 10, fx1 = sh.w - 10, fy1 = sh.h - 10;
    line(A, fx0, fy0, fx1, fy0, 0.7); line(A, fx1, fy0, fx1, fy1, 0.7); line(A, fx1, fy1, fx0, fy1, 0.7); line(A, fx0, fy1, fx0, fy0, 0.7);

    // posición de las vistas dentro del área libre (a la izquierda de la lista)
    const double ax0 = fx0 + kBalloonR * 2 + 10, ax1 = fx1 - (wide ? 0 : std::max(nblk * kTableW, kTitleW) + 8) - (kBalloonR * 2 + 10);
    const double ay0 = fy0 + kBalloonR * 2 + 10 + (wide ? kTitleH + (std::min(rows, perBlk) + 1) * kRowH + 8 : 0), ay1 = fy1 - (kBalloonR * 2 + 10);
    const double totH = (Hf + Hp) * sc_ + 12, offY = wide ? ay1 - totH : ay0 + ((ay1 - ay0) - totH) / 2, offX = ax0 + ((ax1 - ax0) - std::max(Wf, Wp) * sc_) / 2;
    // sistema de hoja de cada vista: x = offX + (u - lo)*s ; planta debajo del alzado (primer diedro)
    const double oy[2] = {offY + Hp * sc_ + 12, offY};
    auto sx = [&](int v, double u) { return offX + (u - lo[v][0]) * sc_ + (std::max(Wf, Wp) - (v ? Wp : Wf)) * sc_ / 2; };
    auto sy = [&](int v, double w) { return oy[v] + (w - lo[v][1]) * sc_; };
    for (int v = 0; v < 2; v++) { const Pos p0 = A.pos(); for (auto& in : inst) for (auto& l : in.vis[v]) line(A, sx(v, l.x1), sy(v, l.y1), sx(v, l.x2), sy(v, l.y2), 0.35); A.tag(p0, v); }
    double vb[2][4];  // caja de cada vista en hoja: x0 y0 x1 y1
    for (int v = 0; v < 2; v++) { vb[v][0] = sx(v, lo[v][0]); vb[v][1] = sy(v, lo[v][1]); vb[v][2] = sx(v, hi[v][0]); vb[v][3] = sy(v, hi[v][1]); }

    // piezas sin ninguna línea visible (tapadas por otras): se dibujan a trazos y el globo se ancla ahí
    std::vector<char> hiddenOnly(infos.size() + 1, 1);
    for (auto& in : inst) if (!in.vis[0].empty() || !in.vis[1].empty()) hiddenOnly[infos[in.part].pos] = 0;
    std::vector<int> hiddenPos;
    for (auto& in : inst) {
        const int pos = infos[in.part].pos;
        if (!hiddenOnly[pos]) continue;
        for (int v = 0; v < 2; v++) for (auto& l : in.hid[v]) {
            A.lines.push_back({sx(v, l.x1), sy(v, l.y1), sx(v, l.x2), sy(v, l.y2), LineType::Hidden, 0.25, v});
            in.vis[v].push_back(l);
        }
        if (std::find(hiddenPos.begin(), hiddenPos.end(), pos) == hiddenPos.end()) hiddenPos.push_back(pos);
    }
    // globos: una por pieza, en la vista donde más se ve
    std::vector<Balloon> bl[3];  // alzado, planta, isométrica
    std::string notSeen, centered;
    for (auto& pi : infos) {
        int bestV = -1; double bestLen = 0, ax = 0, ay = 0;
        for (size_t k = 0; k < inst.size(); k++) {
            if (infos[inst[k].part].pos != pi.pos) continue;
            for (int v = 0; v < 2; v++) {
                const Ln* bl_ = nullptr; double bl_len = 0;
                for (auto& l : inst[k].vis[v]) { double len = std::hypot(l.x2 - l.x1, l.y2 - l.y1); if (len > bl_len) { bl_len = len; bl_ = &l; } }
                if (bl_ && bl_len * sc_ > bestLen) { bestLen = bl_len * sc_; bestV = v; ax = sx(v, (bl_->x1 + bl_->x2) / 2); ay = sy(v, (bl_->y1 + bl_->y2) / 2); }
            }
        }
        if (bestV < 0) {  // ni visible ni a trazos (p. ej. bolas dentro de una jaula): el globo apunta al centro de su volumen en el alzado
            for (size_t k = 0; k < inst.size() && bestV < 0; k++) {
                if (infos[inst[k].part].pos != pi.pos || refs[k].sh.IsNull()) continue;
                Bnd_Box bb; BRepBndLib::Add(refs[k].sh, bb);
                if (bb.IsVoid()) continue;
                double x0, y0, z0, x1, y1, z1; bb.Get(x0, y0, z0, x1, y1, z1);
                bestV = 0; ax = sx(0, (x0 + x1) / 2); ay = sy(0, (z0 + z1) / 2);
            }
            if (bestV < 0) { notSeen += (notSeen.empty() ? "" : ",") + std::to_string(pi.pos); continue; }
            centered += (centered.empty() ? "" : ",") + std::to_string(pi.pos);
        }
        bl[bestV].push_back({pi.pos, ax, ay, 0, 0, 0});
    }
    auto placeView = [&](int v, const double* b, const std::vector<int>& allowed) {
        std::vector<std::vector<Balloon*>> side(4);
        const double cap[4] = {(b[2] - b[0]) / kPitch + 1, (b[2] - b[0]) / kPitch + 1, (b[3] - b[1]) / kPitch + 1, (b[3] - b[1]) / kPitch + 1};
        for (auto& x : bl[v]) {
            double dist[4] = {b[3] - x.ay, x.ay - b[1], x.ax - b[0], b[2] - x.ax};
            int best = -1;
            for (int pass = 0; pass < 2 && best < 0; pass++)
                for (int a : allowed) if ((pass || side[a].size() < cap[a]) && (best < 0 || dist[a] < dist[best])) best = a;
            x.side = best; side[best].push_back(&x);
        }
        for (int sd = 0; sd < 4; sd++) {
            auto& L = side[sd];
            const bool horiz = sd < 2;  // arriba/abajo reparten por x
            std::sort(L.begin(), L.end(), [&](Balloon* p, Balloon* q) { return horiz ? p->ax < q->ax : p->ay < q->ay; });
            std::vector<double> c(L.size());
            for (size_t i = 0; i < L.size(); i++) { c[i] = horiz ? L[i]->ax : L[i]->ay; if (i && c[i] < c[i - 1] + kPitch) c[i] = c[i - 1] + kPitch; }
            if (!L.empty()) {  // recentrar el exceso
                double shift = 0; for (size_t i = 0; i < L.size(); i++) shift += (horiz ? L[i]->ax : L[i]->ay) - c[i];
                shift /= L.size();
                for (auto& x : c) x += shift;
                const double lo_ = horiz ? b[0] : b[1], hi_ = horiz ? b[2] : b[3];  // sin salirse de la caja de la vista: evita chocar con los globos del lado contiguo
                if (c.back() - c.front() <= hi_ - lo_) {
                    if (c.front() < lo_) { const double d = lo_ - c.front(); for (auto& x : c) x += d; }
                    if (c.back() > hi_) { const double d = c.back() - hi_; for (auto& x : c) x -= d; }
                }
            }
            for (size_t i = 0; i < L.size(); i++) {
                if (sd == 0) { L[i]->bx = c[i]; L[i]->by = b[3] + kBalloonR * 2 + 4; }
                else if (sd == 1) { L[i]->bx = c[i]; L[i]->by = b[1] - kBalloonR * 2 - 4; }
                else if (sd == 2) { L[i]->bx = b[0] - kBalloonR * 2 - 4; L[i]->by = c[i]; }
                else { L[i]->bx = b[2] + kBalloonR * 2 + 4; L[i]->by = c[i]; }
            }
        }
        // ISO 6433 4.4: las líneas de referencia no se cruzan; si dos se cortan, se intercambian sus globos (acorta ambas)
        auto cross = [](const Balloon& p, const Balloon& q) {
            auto o = [](double ax, double ay, double bx, double by, double cx, double cy) { return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax); };
            return o(p.ax, p.ay, p.bx, p.by, q.ax, q.ay) * o(p.ax, p.ay, p.bx, p.by, q.bx, q.by) < 0 && o(q.ax, q.ay, q.bx, q.by, p.ax, p.ay) * o(q.ax, q.ay, q.bx, q.by, p.bx, p.by) < 0;
        };
        for (int it = 0; it < 50; it++) {
            bool any = false;
            for (size_t i = 0; i < bl[v].size(); i++) for (size_t j = i + 1; j < bl[v].size(); j++)
                if (cross(bl[v][i], bl[v][j])) { std::swap(bl[v][i].bx, bl[v][j].bx); std::swap(bl[v][i].by, bl[v][j].by); std::swap(bl[v][i].side, bl[v][j].side); any = true; }
            if (!any) break;
        }
    };
    for (int v = 0; v < 2; v++) placeView(v, vb[v], {v == 0 ? 0 : 1, 2, 3});
    // las columnas laterales de las dos vistas comparten x: separar globos de distinto alzado/planta con el mismo paso (6433: círculos sin solaparse)
    double trY0 = 1e9, trY1 = -1e9;   // franja de la traza del corte en la planta (letra A y flecha): sin globos laterales encima
    auto separateLateral = [&]() {
    for (int sd = 2; sd < 4; sd++) {
        std::vector<Balloon*> L;
        for (int v = 0; v < 3; v++) for (auto& x : bl[v]) if (x.side == sd) L.push_back(&x);
        std::sort(L.begin(), L.end(), [](Balloon* p, Balloon* q) { return p->by < q->by; });
        for (size_t i = 0; i < L.size(); i++) for (int rep = 0; rep < 2; rep++) {
            for (size_t j = 0; j < i; j++) if (std::fabs(L[i]->bx - L[j]->bx) < kPitch && L[i]->by < L[j]->by + kPitch) L[i]->by = L[j]->by + kPitch;
            const bool inPlan = L[i] >= bl[1].data() && L[i] < bl[1].data() + bl[1].size();
            if (inPlan && L[i]->by > trY0 - kBalloonR && L[i]->by < trY1 + kBalloonR) L[i]->by = trY1 + kBalloonR; else break;
        }
    }
    };
    separateLateral();
    auto drawBalloons = [&](Drawing& A, int v) {
        const Pos pB = A.pos();
        for (auto& x : bl[v]) {
            const double dx = x.ax - x.bx, dy = x.ay - x.by, n = std::hypot(dx, dy);
            if (n > 1e-6) line(A, x.bx + dx / n * kBalloonR, x.by + dy / n * kBalloonR, x.ax, x.ay, 0.25);
            if (v < 2 && n > 1e-6) {  // ISO 128-22: en vistas ortogonales la llamada acaba sobre un contorno -> flecha rellena; en la isométrica (superficie) -> punto
                const double ux = -dx / n, uy = -dy / n;   // de la punta hacia el globo
                Poly ar; ar.pts = {{x.ax, x.ay}, {x.ax + ux * 3 - uy * 0.4, x.ay + uy * 3 + ux * 0.4}, {x.ax + ux * 3 + uy * 0.4, x.ay + uy * 3 - ux * 0.4}};
                A.polys.push_back(ar);
            } else disc(A, x.ax, x.ay, 0.8, false);
            disc(A, x.bx, x.by, kBalloonR, true);
            A.arcs.push_back({x.bx, x.by, kBalloonR, 0, 360, LineType::Continuous, 0.35});
            A.dims.push_back({"globo", (double)x.pos, std::to_string(infos[x.pos - 1].qty), std::to_string(x.bx) + "\t" + std::to_string(x.by) + "\t" + std::to_string(infos[x.pos - 1].part) + "\t" + infos[x.pos - 1].name});
            const std::string s = std::to_string(x.pos);
            text(A, x.bx - textW(s, 3.5) / 2, x.by - 1.25, 3.5, s);
            if (infos[x.pos - 1].qty > 1) {  // ISO 6433: piezas idénticas = un solo globo con «n×», en el lado opuesto a la llamada
                const std::string q = std::to_string(infos[x.pos - 1].qty) + "×";
                const double qx = dx < 0 ? x.bx + kBalloonR + 1 : x.bx - kBalloonR - 1 - textW(q, 3.5);
                if (x.side == 0 || x.side == 1) {   // columnas de globos en horizontal: «n×» fuera del globo (arriba/abajo), no entre vecinos
                    const double qy = x.side == 0 ? x.by + kBalloonR + 1.2 : x.by - kBalloonR - 1.2 - 3.5;
                    text(A, x.bx - textW(q, 3.5) / 2, qy, 3.5, q);
                } else if (qx < fx0 + 1.5 || qx + textW(q, 3.5) > fx1 - 1.5) text(A, x.bx - textW(q, 3.5) / 2, x.by + kBalloonR + 1.2, 3.5, q);  // pegado al marco: encima del globo
                else text(A, qx, x.by - 1.25, 3.5, q);
            }
        }
        A.tag(pB, v);
    };

    auto placed = [&](size_t ii) -> TopoDS_Shape { for (auto& r : refs) if ((size_t)r.info == ii) return r.sh; return infos[ii].shape; };   // forma colocada de la primera instancia
    // lista de piezas (ISO 7573): encabezado abajo, posiciones hacia arriba, bloques hacia la izquierda
    const double ty0 = fy0 + kTitleH;
    for (int bk = 0; bk < nblk; bk++) {
        const double x0 = fx1 - (bk + 1) * kTableW;
        const size_t i0 = bk * perBlk, i1 = std::min(rows, i0 + perBlk);
        const double top = ty0 + (1 + (i1 - i0)) * kRowH;
        double cx = x0; double xs[7];
        for (int c = 0; c < 6; c++) { xs[c] = cx; cx += kColW[c]; }
        xs[6] = cx;
        for (double y = ty0; y <= top + 1e-6; y += kRowH) line(A, x0, y, x0 + kTableW, y, y == ty0 + kRowH ? 0.5 : 0.25);
        for (int c = 0; c <= 6; c++) line(A, xs[c], ty0, xs[c], top, c == 0 || c == 6 ? 0.5 : 0.25);
        const char* hd[6] = {"Pos.", "Designación", "Cant.", "Material", "Medidas", "Observaciones"};
        for (int c = 0; c < 6; c++) text(A, xs[c] + 1, ty0 + 1.8, 2.5, fit(T(hd[c]), 2.5, kColW[c] - 2));
        for (size_t i = i0; i < i1; i++) {
            const PartInfo& pi = infos[i];
            const double y = ty0 + (1 + (i - i0)) * kRowH + 1.8;
            text(A, xs[0] + 1, y, 2.5, std::to_string(pi.pos));
            if (pi.name.empty()) text(A, xs[1] + 1, y, 2.5, T("NO DEFINIDO"), true); else text(A, xs[1] + 1, y, 2.5, fit(pi.name, 2.5, kColW[1] - 2));
            text(A, xs[2] + 1, y, 2.5, std::to_string(pi.qty));
            if (pi.mat.empty()) text(A, xs[3] + 1, y, 2.5, T("NO DEFINIDO"), true); else text(A, xs[3] + 1, y, 2.5, fit(pi.mat, 2.5, kColW[3] - 2));
            const double u = meta.imperial ? 1 / 25.4 : 1;
            auto f1 = [&](double v) { char b[24]; std::snprintf(b, sizeof b, meta.imperial ? "%.2f" : "%.1f", v * u); std::string s = b; if (!meta.imperial && s.size() > 2 && s.substr(s.size() - 2) == ".0") s.resize(s.size() - 2); return s; };
            text(A, xs[4] + 1, y, 2.5, fit(f1(pi.dim[0]) + "×" + f1(pi.dim[1]) + "×" + f1(pi.dim[2]), 2.5, kColW[4] - 2));
            {   // pieza esbelta y curva (cable/manguera): longitud del eje por geodésica de malla (ISO 129-1 §7.15; método = decisión propia)
                const double dmin = std::min({pi.dim[0], pi.dim[1], pi.dim[2]}), dmax = std::max({pi.dim[0], pi.dim[1], pi.dim[2]});
                if (dmin > 0 && dmax >= 8 * dmin && dmax >= 40) {
                    GProp_GProps gs; BRepGProp::SurfaceProperties(pi.shape, gs); const double Ar = gs.Mass(); double planar = 0;
                    for (TopExp_Explorer ex(pi.shape, TopAbs_FACE); ex.More(); ex.Next()) { BRepAdaptor_Surface bs(TopoDS::Face(ex.Current())); if (bs.GetType() == GeomAbs_Plane) { GProp_GProps gf; BRepGProp::SurfaceProperties(ex.Current(), gf); planar += gf.Mass(); } }
                    if (Ar > 1e-6 && planar < 0.05 * Ar) { std::array<std::array<double, 3>, 2> en; const double L = axisLengthSlender(placed(i), dmin, &en);
                        if (L >= 40) {   // extremos: pieza más cercana a cada punta del eje (pos.); «?» si ninguna llega (decisión propia, ver NORMAS_G14)
                            std::string ex[2];
                            for (int e = 0; e < 2; e++) { double best = std::max(3 * dmin, 3.0); ex[e] = "?"; TopoDS_Vertex v = BRepBuilderAPI_MakeVertex(gp_Pnt(en[e][0], en[e][1], en[e][2]));
                                for (size_t oi = 0; oi < infos.size(); oi++) { const PartInfo& o = infos[oi]; if (o.pos == pi.pos) continue; { const double mn = std::min({o.dim[0], o.dim[1], o.dim[2]}), mx = std::max({o.dim[0], o.dim[1], o.dim[2]}); if (mn > 0 && mx >= 8 * mn) continue; } BRepExtrema_DistShapeShape dss(v, placed(oi)); if (dss.IsDone() && dss.Value() < best) { best = dss.Value(); ex[e] = std::to_string(o.pos); } } }
                            text(A, xs[5] + 1, y, 2.5, fit(T("Cable") + " L≈" + f1(L) + " " + ex[0] + "-" + ex[1], 2.5, kColW[5] - 2)); }
                    }
                }
            }
        }
    }

    // cajetín
    const double bx0 = fx1 - kTitleW;
    line(A, bx0, fy0, bx0, fy0 + kTitleH, 0.7); line(A, bx0, fy0 + kTitleH, fx1, fy0 + kTitleH, 0.7);
    line(A, bx0, fy0 + 24, fx1, fy0 + 24); line(A, bx0, fy0 + 12, fx1, fy0 + 12);
    const double s1 = bx0 + kTitleW * 0.62, s2 = bx0 + kTitleW * 0.5, s3 = bx0 + kTitleW * 0.75;
    line(A, s1, fy0 + 24, s1, fy0 + kTitleH); line(A, s2, fy0, s2, fy0 + 24); line(A, s3, fy0, s3, fy0 + 12);
    auto field = [&](double x, double y, const std::string& n, const std::string& v) {
        text(A, x + 1.5, y + 7.8, 2.2, n);
        if (v.empty()) text(A, x + 1.5, y + 2, 3.5, T("NO DEFINIDO"), true); else text(A, x + 1.5, y + 2, 3.5, fit(v, 3.5, 60));
    };
    size_t total = 0; for (auto& pi : infos) total += pi.qty;
    field(bx0, fy0 + 24, T("Conjunto"), meta.title);
    field(s1, fy0 + 24, T("N.° de plano"), meta.partNo);
    field(bx0, fy0 + 12, T("Piezas"), std::to_string(infos.size()) + " / " + std::to_string(total));
    field(s2, fy0 + 12, T("Tolerancia general"), meta.generalTolerance);
    text(A, bx0 + 1.5, fy0 + 7.8, 2.2, T("Escala")); text(A, bx0 + 1.5, fy0 + 2, 3.5, scaleText(sc_));
    text(A, s2 + 1.5, fy0 + 7.8, 2.2, T("Formato")); text(A, s2 + 1.5, fy0 + 2, 3.5, A.sheetName);
    text(A, s3 + 1.5, fy0 + 7.8, 2.2, T("Unidades")); text(A, s3 + 1.5, fy0 + 2, 3.5, meta.imperial ? "in" : "mm");
    projSymbol(A, fx1 - 25, fy0 + 2.5);
    if (nblk < 2) text(A, bx0 + 1.5, fy0 + kTitleH + 1.5, 2.2, "Diedro");  // con 2+ bloques de lista, la cabecera del segundo ocupa ese sitio
    // corte A-A por el centro de las piezas tapadas: hoja aparte con las piezas cortadas y rayado (ISO 128-50: ángulo/paso distinto en piezas contiguas)
    Drawing B; bool haveB = false; double cutY = 0;
    if (!hiddenPos.empty() && nFaces <= 600 && poles <= kMaxPoles && !std::getenv("DIEDRO_NO_CUT")) {
        try {
            double scB = sc_;  // el corte va solo en su hoja: mayor escala normalizada que quepa
            for (double c : kScales) if (c >= sc_ && Wf * c <= fx1 - fx0 - 40 && Hf * c <= fy1 - fy0 - 50) { scB = c; break; }
            Bnd_Box all, hb;
            for (auto& r : refs) { BRepBndLib::Add(r.sh, all); if (hiddenOnly[infos[r.info].pos]) BRepBndLib::Add(r.sh, hb); }
            double a0, a1, a2, a3, a4, a5; all.Get(a0, a1, a2, a3, a4, a5);
            double h0, h1, h2, h3, h4, h5; hb.Get(h0, h1, h2, h3, h4, h5);
            const double yc = (h1 + h4) / 2; cutY = yc; const double mg = 1 + std::max({a3 - a0, a4 - a1, a5 - a2});
            TopoDS_Shape box = BRepPrimAPI_MakeBox(gp_Pnt(a0 - mg, a1 - mg, a2 - mg), gp_Pnt(a3 + mg, yc, a5 + mg)).Shape();
            std::vector<TopoDS_Shape> cs; std::vector<int> cpos;
            for (auto& r : refs) {
                BRepAlgoAPI_Cut c(r.sh, box);
                if (!c.IsDone() || c.Shape().IsNull() || !TopExp_Explorer(c.Shape(), TopAbs_FACE).More()) continue;
                cs.push_back(c.Shape()); cpos.push_back(infos[r.info].pos);
            }
            if (!cs.empty()) {
                Handle(HLRBRep_Algo) alg = new HLRBRep_Algo();
                for (auto& x : cs) alg->Add(x);
                alg->Projector(HLRAlgo_Projector(gp_Ax2(gp_Pnt(0, 0, 0), NV[0], XV[0])));
                alg->Update(); alg->Hide();
                HLRBRep_HLRToShape h(alg);
                B.sheetW = sh.w; B.sheetH = sh.h; B.sheetName = sh.name; B.scale = scB;
                line(B, fx0, fy0, fx1, fy0, 0.7); line(B, fx1, fy0, fx1, fy1, 0.7); line(B, fx1, fy1, fx0, fy1, 0.7); line(B, fx0, fy1, fx0, fy0, 0.7);
                const double ox = (fx0 + fx1) / 2 - Wf * scB / 2, oy2 = (fy0 + fy1) / 2 - Hf * scB / 2 + 4;
                auto bxs = [&](double u) { return ox + (u - lo[0][0]) * scB; };
                auto bys = [&](double w) { return oy2 + (w - lo[0][1]) * scB; };
                std::vector<Ln> L;
                for (auto& x : cs) { L.clear(); collect(h.VCompound(x), L); collect(h.OutLineVCompound(x), L); for (auto& l : L) line(B, bxs(l.x1), bys(l.y1), bxs(l.x2), bys(l.y2), 0.35); }
                std::map<int, double> bestA; std::map<int, std::pair<double, double>> lab;
                int nHatch = 0;
                // ISO 128-50: el paso del rayado es proporcional al tamaño del área rayada (mín. 0,7 mm); aquí ≈1/10 de la raíz del área mayor de la pieza, entre 1,5 y 5 mm en hoja
                std::map<int, double> cutArea;
                for (size_t k = 0; k < cs.size(); k++)
                    for (TopExp_Explorer fe(cs[k], TopAbs_FACE); fe.More(); fe.Next()) {
                        const TopoDS_Face f = TopoDS::Face(fe.Current());
                        BRepAdaptor_Surface sf(f);
                        if (sf.GetType() != GeomAbs_Plane) continue;
                        const gp_Pln pl = sf.Plane();
                        if (std::abs(std::abs(pl.Axis().Direction().Y()) - 1) > 1e-6 || std::abs(pl.Location().Y() - yc) > 1e-4 * mg) continue;
                        GProp_GProps g0; BRepGProp::SurfaceProperties(f, g0);
                        cutArea[cpos[k]] = std::max(cutArea[cpos[k]], g0.Mass() * scB * scB);
                    }
                for (size_t k = 0; k < cs.size() && nHatch < 6000; k++) {
                    const int pos = cpos[k], pat = pos % 3;
                    if (isFastener(infos[pos - 1].name) || isSolidRod(infos[pos - 1].shape)) continue;  // ISO 128-44: tornillos, tuercas, arandelas y pasadores cortados longitudinalmente no se rayan
                    const double sgn = pat == 1 ? -1 : 1, base = std::min(5.0, std::max(1.5, 0.1 * std::sqrt(cutArea[pos]))), spacing = base * (pat == 2 ? 1.6 : 1.0) / scB;
                    for (TopExp_Explorer fe(cs[k], TopAbs_FACE); fe.More(); fe.Next()) {
                        const TopoDS_Face f = TopoDS::Face(fe.Current());
                        BRepAdaptor_Surface sf(f);
                        if (sf.GetType() != GeomAbs_Plane) continue;
                        const gp_Pln pl = sf.Plane();
                        if (std::abs(std::abs(pl.Axis().Direction().Y()) - 1) > 1e-6 || std::abs(pl.Location().Y() - yc) > 1e-4 * mg) continue;
                        Bnd_Box fb; BRepBndLib::Add(f, fb);
                        double f0, f1, f2, f3, f4, f5; fb.Get(f0, f1, f2, f3, f4, f5);
                        const double q[4] = {f0 + sgn * f2, f0 + sgn * f5, f3 + sgn * f2, f3 + sgn * f5}, c0 = *std::min_element(q, q + 4), c1 = *std::max_element(q, q + 4);
                        double bestLen = 0, bestX = 0, bestY = 0;  // etiqueta: punto medio del trazo de rayado más largo (siempre dentro de la cara)
                        double sp = spacing; while ((c1 - c0) / sp > 250) sp *= 2;
                        for (double c = c0 + sp / 2; c < c1; c += sp) {
                            BRepAlgoAPI_Section sec(f, gp_Pln(gp_Pnt(c, yc, 0), gp_Dir(1, 0, sgn)));
                            if (!sec.IsDone()) continue;
                            for (TopExp_Explorer ee(sec.Shape(), TopAbs_EDGE); ee.More(); ee.Next()) {
                                BRepAdaptor_Curve cu(TopoDS::Edge(ee.Current()));
                                if (cu.GetType() != GeomAbs_Line) continue;
                                const gp_Pnt p1 = cu.Value(cu.FirstParameter()), p2 = cu.Value(cu.LastParameter());
                                B.lines.push_back({bxs(p1.X()), bys(p1.Z()), bxs(p2.X()), bys(p2.Z()), LineType::Continuous, 0.18}); nHatch++;
                                const double ln = p1.Distance(p2); if (ln > bestLen) { bestLen = ln; bestX = bxs((p1.X() + p2.X()) / 2); bestY = bys((p1.Z() + p2.Z()) / 2); }
                            }
                        }
                        {   // contorno(s) de la cara para el HATCH del DXF: exterior y huecos, polígonos de la hoja
                            const int hid = (int)B.polys.size();
                            for (TopExp_Explorer we(f, TopAbs_WIRE); we.More(); we.Next()) {
                                Poly h; h.hatch = sp * scB / std::sqrt(2.0); h.hdir = -(int)sgn; h.hid = hid;
                                for (BRepTools_WireExplorer ex(TopoDS::Wire(we.Current()), f); ex.More(); ex.Next()) {
                                    BRepAdaptor_Curve cu(ex.Current()); const double a = cu.FirstParameter(), b = cu.LastParameter();
                                    const int n = cu.GetType() == GeomAbs_Line ? 1 : 24; const bool rev = ex.Current().Orientation() == TopAbs_REVERSED;
                                    for (int i = 0; i < n; i++) { const gp_Pnt q = cu.Value(rev ? b - (b - a) * i / n : a + (b - a) * i / n); h.pts.push_back({bxs(q.X()), bys(q.Z())}); }
                                }
                                if (h.pts.size() >= 3) B.polys.push_back(h);
                            }
                        }
                        GProp_GProps gp; BRepGProp::SurfaceProperties(f, gp);
                        if (gp.Mass() > bestA[pos] && bestLen > 0) { bestA[pos] = gp.Mass(); lab[pos] = {bestX, bestY}; }
                    }
                }
                if (nHatch > 0) {
                    // números de pieza fuera del corte, a la derecha, con línea de referencia al rayado (6433: sin tapar el dibujo ni entre sí)
                    double bmax = -1e300; for (auto& l : B.lines) if (std::max(l.x1, l.x2) < fx1 - 1 && std::min(l.x1, l.x2) > fx0 + 1) bmax = std::max(bmax, std::max(l.x1, l.x2)); for (auto& c : B.arcs) bmax = std::max(bmax, c.cx + c.r);
                    std::vector<std::pair<int, std::pair<double, double>>> L(lab.begin(), lab.end());
                    std::sort(L.begin(), L.end(), [](auto& p, auto& q) { return p.second.second < q.second.second; });
                    std::vector<double> ly(L.size());
                    for (size_t i = 0; i < L.size(); i++) { ly[i] = L[i].second.second; if (i && ly[i] < ly[i - 1] + 8) ly[i] = ly[i - 1] + 8; }
                    const double lx = bmax + 12;
                    for (size_t i = 0; i < L.size(); i++) {
                        const double ax_ = L[i].second.first, ay_ = L[i].second.second, dx_ = ax_ - lx, dy_ = ay_ - ly[i], n_ = std::hypot(dx_, dy_);
                        line(B, lx + dx_ / n_ * 3.2, ly[i] + dy_ / n_ * 3.2, ax_, ay_, 0.25);
                        disc(B, ax_, ay_, 0.6, false); disc(B, lx, ly[i], 3.2, true);
                        const std::string n = std::to_string(L[i].first); text(B, lx - textW(n, 3.5) / 2, ly[i] - 1.25, 3.5, n);
                    }
                    text(B, fx0 + 5, fy1 - 10, 5, T("Corte") + " A-A");
                    text(B, fx0 + 5, fy1 - 16, 3, T("Escala") + " " + scaleText(scB));
                    haveB = true;
                }
            }
        } catch (...) { haveB = false; }
    }
    if (haveB) {  // traza del plano de corte en la planta, mirando hacia +Y (arriba en la hoja)
        const Pos pCut = A.pos();
        const double yy = sy(1, cutY), xa = vb[1][0] - 7, xb = vb[1][2] + 7;
        A.lines.push_back({xa, yy, xb, yy, LineType::Center, 0.35});
        for (double x : {xa, xb}) {
            line(A, x, yy, x, yy + 7, 0.7); line(A, x, yy + 7, x - 1.2, yy + 4.5, 0.5); line(A, x, yy + 7, x + 1.2, yy + 4.5, 0.5);
            text(A, x - 1.3, yy + 8.5, 3.5, "A");
        }
        A.tag(pCut, 1);
    }
    double wy = fy0 + 3;
    int nWarnDrawn = 0, nWarnHidden = 0;  // en la hoja caben 2 avisos + el resumen bajo la vista; el resto va solo a la lista de avisos de la app
    auto warn = [&](const std::string& w) {
        A.warnings.push_back(w);
        if (nWarnDrawn < 2) { text(A, fx0 + 3, wy, 3.0, fit(w, 3.0, fx1 - kTitleW - fx0 - 8), true); wy += 4.5; nWarnDrawn++; } else nWarnHidden++;
    };
    if (!hiddenPos.empty()) { std::string h; for (int q : hiddenPos) h += (h.empty() ? "" : ",") + std::to_string(q); warn(T("Pos.") + " " + h + ": " + T(haveB ? "tapadas por otras piezas (trazo discontinuo); ver el corte A-A" : "tapadas por otras piezas (trazo discontinuo); se necesita un corte")); }
    if (!centered.empty()) warn(T("Pos.") + " " + centered + ": " + T("sin contorno visible; el globo señala el centro de la pieza"));
    if (!notSeen.empty()) warn(T("Pos.") + " " + notSeen + ": " + T("sin línea visible en estas vistas; sin globo"));
    for (auto& w : warns) warn(w);
    if (nWarnHidden) text(A, fx0 + 3, wy, 3.0, "+" + std::to_string(nWarnHidden) + " " + T("avisos más (ver lista de avisos)"), true);
    {
        std::vector<IsoItem> its;
        for (auto& r : refs) its.push_back({r.sh, infos[r.info].pos});
        if (meta.explode && its.size() > 1) {   // capas por centro a lo largo de Z (o de X/Y si tienen más capas), separadas proporcionalmente
            const int n = (int)its.size();
            std::vector<std::array<double, 3>> c(n);
            double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
            for (int i = 0; i < n; i++) {
                Bnd_Box bb; BRepBndLib::Add(its[i].sh, bb);
                double b[6]; bb.Get(b[0], b[1], b[2], b[3], b[4], b[5]);
                for (int k = 0; k < 3; k++) { c[i][k] = (b[k] + b[k + 3]) / 2; lo[k] = std::min(lo[k], b[k]); hi[k] = std::max(hi[k], b[k + 3]); }
            }
            auto layers = [&](int k) {
                std::vector<double> v; for (auto& q : c) v.push_back(q[k]);
                std::sort(v.begin(), v.end());
                std::vector<double> L; const double tol = 0.05 * (hi[k] - lo[k]) + 1e-6;
                for (double x : v) if (L.empty() || x - L.back() > tol) L.push_back(x);
                return L;
            };
            int ax = 2; auto L = layers(2);
            for (int k : {0, 1}) { auto Lk = layers(k); if (Lk.size() > L.size()) { ax = k; L = Lk; } }
            if (L.size() > 1) {
                const double step = 0.6 * (hi[ax] - lo[ax]) / (L.size() - 1);
                for (int i = 0; i < n; i++) {
                    size_t j = 0; while (j + 1 < L.size() && c[i][ax] - L[j] > 0.05 * (hi[ax] - lo[ax]) + 1e-6) j++;
                    gp_Vec v(0, 0, 0); v.SetCoord(ax + 1, j * step);
                    gp_Trsf t; t.SetTranslation(v);
                    its[i].sh = its[i].sh.Moved(TopLoc_Location(t));
                }
            }
        }
        // los globos van sobre la isométrica sombreada (donde las piezas se distinguen mejor) si la pieza se ve en ella; el resto, en las vistas
        if (haveB) { trY0 = sy(1, cutY); trY1 = trY0 + 12; separateLateral(); }
        Drawing S = A;
        for (int v = 0; v < 2; v++) drawBalloons(S, v);   // la isométrica busca su hueco esquivando también los globos de las vistas
        IsoResult ir;
        const double isoMg = 6 + kBalloonR * 3 + 5;
        if (addIso(A, its, sc_, &ir, &S, isoMg) && !std::getenv("DIEDRO_BALLOON_ORTHO")) {
            // el perímetro de la isométrica admite un número limitado de globos: las piezas que más se ven van en ella, el resto sigue en las vistas
            const size_t capIso = (size_t)(2 * ((ir.box[2] - ir.box[0]) / kPitch + 1) + 2 * ((ir.box[3] - ir.box[1]) / kPitch + 1));
            std::stable_sort(ir.anchors.begin(), ir.anchors.end(), [](const std::array<double, 4>& p, const std::array<double, 4>& q) { return p[3] > q[3]; });
            if (ir.anchors.size() > capIso) ir.anchors.resize(capIso);
            for (auto& an : ir.anchors) {
                const int pos = (int)an[0];
                int from = -1;
                for (int v = 0; v < 2; v++) for (size_t i = 0; i < bl[v].size(); i++) if (bl[v][i].pos == pos) { from = v; bl[v].erase(bl[v].begin() + i); break; }
                if (from >= 0) bl[2].push_back({pos, an[1], an[2], 0, 0, 0});
            }
            if (!bl[2].empty()) { placeView(2, ir.box, {0, 1, 2, 3}); separateLateral(); }
        }
        for (int v = 0; v < 3; v++) drawBalloons(A, v);
        {   // cotas totales (ISO 129-1): ancho y alto en el alzado, fondo en la planta; cada una en el primer lado donde no tropiece con textos
            struct Try { bool hor; double u0, u1, lo, hi; std::string s; };   // lo/hi = bordes de la vista en la dirección de la cota
            const Try tr[3] = {{true, vb[0][0], vb[0][2], vb[0][1], vb[0][3], fmtMm(Wf)}, {false, vb[0][1], vb[0][3], vb[0][0], vb[0][2], fmtMm(Hf)}, {false, vb[1][1], vb[1][3], vb[1][0], vb[1][2], fmtMm(Hp)}};
            for (int ti = 0; ti < 3; ti++) {
                const Try& t = tr[ti];
                for (double off : {9.0, -9.0, 15.0, -15.0, 21.0, -21.0}) {
                    const double ref = off > 0 ? t.hi : t.lo, c = ref + off;
                    if (t.hor ? (c < fy0 + 2 || c > fy1 - 2) : (c < fx0 + 2 || c > fx1 - 2)) continue;
                    Drawing T = A;
                    const Pos pd = T.pos();
                    overallDim(T, t.hor, t.u0, t.u1, c, ref, t.s);
                    T.tag(pd, ti == 2 ? 1 : 0);
                    if (findOverlaps(T).size() > findOverlaps(A).size()) continue;
                    A = std::move(T); break;
                }
            }
        }
        if (dbg) std::fprintf(stderr, "ASM iso %.1fs\n", secs());
    }
    A.label = "Conjunto"; A.kind = "asm"; B.label = "Corte A-A"; B.kind = "cut";
    thirdAngle(A, 0, 1, -1);
    balanceViews(A);
    out.push_back(A);
    if (haveB) out.push_back(B);

    // una hoja por pieza única: STEP temporal -> clasificador -> motor
    std::vector<const PartInfo*> order;
    for (auto& pi : infos) order.push_back(&pi);
    std::stable_sort(order.begin(), order.end(), [](const PartInfo* a, const PartInfo* b) { return a->dim[0] * a->dim[1] * a->dim[2] > b->dim[0] * b->dim[1] * b->dim[2]; });
    std::vector<Drawing> sheets(infos.size());
    std::vector<char> made(infos.size(), 0);
    size_t nMade = 0; int facesDone = 0;
    for (const PartInfo* pp : order) {
        const PartInfo& pi = *pp;
        if (nMade >= kMaxParts) continue;
        bool camOnly = false;
        {  // presupuesto por complejidad (no por tiempo: mismo STEP, mismo plano). Roscas modeladas y mallas hacen que el motor de pieza tarde minutos
            TopTools_IndexedMapOfShape fm; TopExp::MapShapes(pi.shape, TopAbs_FACE, fm);
            const long poles = splinePoles(pi.shape);  // superficies libres con muchos polos: el motor de pieza tarda decenas de segundos
            if (std::getenv("DIEDRO_DBG")) fprintf(stderr, "ASM presup pos %d caras=%d polos=%ld\n", pi.pos, (int)fm.Extent(), poles);
            if (fm.Extent() > kMaxPartFaces || poles > kMaxPoles || facesDone + fm.Extent() > kFaceBudget) { camOnly = true; }   // pieza pesada (p. ej. árbol de levas con piñón): solo el motor de árbol de levas, que no usa HLR
            else facesDone += fm.Extent();
        }
        Meta pm = meta;
        pm.title = std::to_string(pi.pos) + " · " + (pi.name.empty() ? std::string("Pieza ") + std::to_string(pi.pos) : pi.name);  // sin el nombre del conjunto: el campo del cajetín es corto
        if (pm.title.size() > 34) { size_t k = 31; while (k > 0 && (static_cast<unsigned char>(pm.title[k]) & 0xC0) == 0x80) k--; pm.title = pm.title.substr(0, k) + "..."; }
        pm.partNo.clear();
        pm.material = pi.mat;
        const std::string f = tmpDir + "/diedro_pos" + std::to_string(pi.pos) + ".step";
        // la hoja se dibuja en un hilo con límite de tiempo: si el motor de pieza tarda, se abandona y se avisa
        struct Res { Drawing d; std::string e; };
        auto pr = std::make_shared<std::promise<Res>>();
        auto fu = pr->get_future();
        std::thread([pr, shape = pi.shape, f, pm, camOnly] {
            Res r;
            bool ok = false;
            if (!shape.IsNull()) {
                auto t0 = std::chrono::steady_clock::now();
                STEPControl_Writer w; bool tr = w.Transfer(shape, STEPControl_AsIs) == IFSelect_RetDone;
                auto t1 = std::chrono::steady_clock::now();
                ok = tr && w.Write(f.c_str()) == IFSelect_RetDone;
                if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "ASM escribir %s transfer %.1fs write %.1fs\n", f.c_str(), std::chrono::duration<double>(t1 - t0).count(), std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count());
            }
            Classification dcl; if (ok) dcl = classifyStep(f);
            if (!ok) r.e = "No se pudo extraer la pieza.";
            else if (dcl.error.empty() && dcl.discard >= 3 && dcl.discard <= 5) { { std::string nm = pm.title; std::replace(nm.begin(), nm.end(), '/', '-'); r.d = layoutDiscard(dcl, pm, nm); } r.d.warnings.push_back(dcl.reason); }   // G15: solo esta pieza se descarta; el resto del conjunto se dibuja
            else if (camOnly) { const auto tc = std::chrono::steady_clock::now(); Profile gp; const Classification cl = classifyStep(f); bool okc = cl.error.empty() && (cl.group == 6 || cl.group == 0) && layoutGear(f, pm, gp, r.d); if (!okc) { gCamshaftMinLobes = 1; okc = layoutCamshaft(f, pm, r.d); gCamshaftMinLobes = 2; } if (!okc) r.d = drawPart(f, pm, r.e); if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "ASM pesada %s ok=%d %.1fs\n", f.c_str(), (int)okc, std::chrono::duration<double>(std::chrono::steady_clock::now() - tc).count()); }
            else { auto t0 = std::chrono::steady_clock::now(); r.d = drawPart(f, pm, r.e); if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "ASM drawPart %s %.1fs\n", f.c_str(), std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count()); }
            if (!std::getenv("DIEDRO_KEEP")) std::remove(f.c_str());
            pr->set_value(std::move(r));
        }).detach();
        if (fu.wait_for(std::chrono::duration<double>(kGuard)) != std::future_status::ready) continue;  // solo guarda contra cuelgues
        Res rr = fu.get();
        if (rr.e == "~skip") continue;
        Drawing d = rr.d;
        std::string e = rr.e;
        if (!e.empty()) {
            d = Drawing();
            text(d, 25, 100, 5, pm.title);
            text(d, 25, 90, 4, e, true);
            d.warnings.push_back(e);
        }
        if (dbg) { TopTools_IndexedMapOfShape fm; TopExp::MapShapes(pi.shape, TopAbs_FACE, fm); std::fprintf(stderr, "ASM pieza %d caras=%d t=%.1fs\n", pi.pos, (int)fm.Extent(), secs()); }
        d.label = pm.title;
        sheets[pi.pos - 1] = d; made[pi.pos - 1] = 1; nMade++;
    }
    for (size_t i = 0; i < infos.size(); i++) if (made[i]) out.push_back(sheets[i]);
    if (nMade < infos.size()) {  // el aviso va en la hoja del conjunto (ya en out[0])
        std::string h;
        for (size_t i = 0; i < infos.size(); i++) if (!made[i]) h += (h.empty() ? "" : ",") + std::to_string(i + 1);
        const std::string w = std::to_string(nMade) + " / " + std::to_string(infos.size()) + " " + T("piezas con plano propio") + "; " + T("Pos.") + " " + h + " " + T("sin hoja (límite de tiempo, piezas o complejidad)");
        out[0].warnings.push_back(w);
        text(out[0], fx0 + 3, wy, 3.0, fit(w, 3.0, sh.w - kTitleW - 80), true);
    }
    return out;
}
}  // namespace diedro
