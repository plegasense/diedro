#include "dfm.hpp"
#include "classify.hpp"
#include "special.hpp"
#include "i18n.hpp"
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepTools.hxx>
#include <IntCurvesFace_ShapeIntersector.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopoDS.hxx>
#include <gp_Lin.hxx>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <map>
#include <set>
namespace diedro {
namespace {
// Umbrales (decisión propia, docs/NORMAS_G12.md): práctica común de fresado en metal, no hay norma ISO que los fije.
const double kMinRadius = 1.0;    // mm: radio interior menor que el de la fresa más pequeña habitual (Ø2)
const double kMaxPocket = 10.0;   // profundidad / Ø de fresa (Ø = 2·radio de esquina)
const double kMaxHole = 10.0;     // profundidad / Ø de taladro
const double kMinWall = 0.8;      // mm de pared
const double kSliver = 0.3;       // mm: por debajo no es una pared fresable sino lámina/artefacto del modelo
const double kMinSize = 15.0, kMaxSize = 500.0;   // mm: tamaño de pieza (mayor dimensión) donde un taller fresa; fuera, es electrónica/edificación
const double kArtefactR = 0.1;    // mm: radios menores son redondeos de modelado, no una operación
std::string num(double v, const std::string& lang) { char b[32]; std::snprintf(b, sizeof b, "%.2f", v); std::string s = b; while (s.back() == '0') s.pop_back(); if (s.back() == '.') s.pop_back(); if (decimalComma(lang)) for (auto& ch : s) if (ch == '.') ch = ','; return s; }
std::string Tf(const char* es, const std::string& lang, std::initializer_list<std::string> a) {
    std::string s = tr(es, lang); int i = 0;
    for (auto& v : a) { std::string k = "{" + std::to_string(i++) + "}"; for (size_t p; (p = s.find(k)) != std::string::npos;) s.replace(p, k.size(), v); }
    return s;
}
gp_Dir faceNormal(const TopoDS_Face& f, double u, double v) {
    BRepAdaptor_Surface s(f); gp_Pnt p; gp_Vec du, dv; s.D1(u, v, p, du, dv);
    gp_Vec n = du.Crossed(dv); if (n.Magnitude() < 1e-12) return gp_Dir(0, 0, 1);
    if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
    return gp_Dir(n);
}
void mid(const TopoDS_Face& f, double& u, double& v) { double a, b, c, d; BRepTools::UVBounds(f, a, b, c, d); u = (a + b) / 2; v = (c + d) / 2; }
}  // namespace

std::vector<std::string> dfmCheck(const std::string& path, const std::string& lang) {
    std::vector<std::string> out;
    Classification c = classifyStep(path);
    if (!c.error.empty() || c.group != 2 || c.nParts > 1) return out;   // solo fresadas prismáticas de una pieza
    TopoDS_Shape S; if (!readShapeCached(path, S) || S.IsNull()) return out;
    TopTools_IndexedDataMapOfShapeListOfShape em; TopExp::MapShapesAndAncestors(S, TopAbs_EDGE, TopAbs_FACE, em);
    { Bnd_Box bb; BRepBndLib::Add(S, bb); double x0, y0, z0, x1, y1, z1; bb.Get(x0, y0, z0, x1, y1, z1); double mx = std::max({x1 - x0, y1 - y0, z1 - z0}); if (mx < kMinSize || mx > kMaxSize) return out; }
    int nF = 0; for (TopExp_Explorer e(S, TopAbs_FACE); e.More(); e.Next()) nF++;
    if (nF > 600) return out;
    {   // pieza de catálogo/moldeada: >20 % de caras diminutas (<4 mm²) = detalle que un taller no mecaniza (decisión propia)
        int small = 0; for (TopExp_Explorer fe(S, TopAbs_FACE); fe.More(); fe.Next()) { GProp_GProps g; BRepGProp::SurfaceProperties(fe.Current(), g); if (g.Mass() < 4.0) small++; }
        if (small >= 10 && small > 0.2 * nF) return out;
    }
    IntCurvesFace_ShapeIntersector inter; inter.Load(S, 1e-6);
    // 1) esquinas interiores: arista cóncava plano-plano paralela a la normal de un plano que la cierra (fondo o cara superior) = arista en el eje de la fresa
    double sharpLen = 0; int nSharp = 0; std::set<const void*> seen;
    // 2) radios de esquina: cilindro cóncavo parcial con eje paralelo a la arista
    double minR = 1e9, minRLen = 0; double worstRatio = 0, worstRatioR = 0, worstRatioL = 0;
    // 3) taladros profundos: cilindro cóncavo completo
    double worstHole = 0, worstHoleD = 0, worstHoleL = 0;
    for (TopExp_Explorer fe(S, TopAbs_FACE); fe.More(); fe.Next()) {
        TopoDS_Face f = TopoDS::Face(fe.Current()); BRepAdaptor_Surface s(f);
        if (s.GetType() == GeomAbs_Plane) {
            for (TopExp_Explorer ee(f, TopAbs_EDGE); ee.More(); ee.Next()) {
                TopoDS_Edge e = TopoDS::Edge(ee.Current()); BRepAdaptor_Curve cu(e);
                if (cu.GetType() != GeomAbs_Line) continue;
                const TopTools_ListOfShape& L = em.FindFromKey(e); if (L.Extent() != 2) continue;
                TopoDS_Face g = TopoDS::Face(L.First().IsSame(f) ? L.Last() : L.First()); if (g.IsSame(f)) continue;
                BRepAdaptor_Surface sg(g); if (sg.GetType() != GeomAbs_Plane) continue;
                double a = cu.FirstParameter(), b = cu.LastParameter(), len = b - a; if (len < 2.0) continue;
                gp_Pnt P; gp_Vec t; cu.D1((a + b) / 2, P, t); if (e.Orientation() == TopAbs_REVERSED) t.Reverse();
                if (t.Magnitude() < 1e-12) continue; gp_Dir td(t);
                double u1, v1, u2, v2; mid(f, u1, v1); mid(g, u2, v2);
                gp_Dir n1 = faceNormal(f, u1, v1), n2 = faceNormal(g, u2, v2);
                gp_Vec d1 = gp_Vec(n1).Crossed(gp_Vec(td));
                if (gp_Vec(n2).Dot(d1) <= 1e-6) continue;   // convexa
                if (std::fabs(n1.Dot(n2)) > 0.2) continue;   // solo esquinas hacia 90° (60°–120°)
                // la esquina solo es inevitable si ninguna de sus dos caras es accesible como «fondo» (rayo libre hacia fuera por su normal): con eje de fresa en la arista queda el radio de la fresa
                auto freeAlong = [&](const gp_Dir& nn, const gp_Vec& into) {
                    gp_Pnt Q = P.Translated(into * 0.3 + gp_Vec(nn) * 1e-3);
                    inter.Perform(gp_Lin(Q, nn), 0, 1e6); return inter.NbPnt() == 0; };
                gp_Vec d2 = gp_Vec(n2).Crossed(gp_Vec(td)).Reversed();   // hacia dentro de g (en g la arista se recorre en sentido contrario)
                if (freeAlong(n1, d1) || freeAlong(n2, d2)) continue;
                if (!seen.insert(e.TShape().get()).second) continue;
                nSharp++; sharpLen = std::max(sharpLen, len);
            }
        } else if (s.GetType() == GeomAbs_Cylinder) {
            double u, v; mid(f, u, v); gp_Dir n = faceNormal(f, u, v);
            gp_Pnt P = s.Value(u, v); gp_Ax3 ax = s.Cylinder().Position(); gp_Vec rad(ax.Location(), P);
            double ax_c = rad.Dot(gp_Vec(ax.Direction())); gp_Vec r2 = rad - gp_Vec(ax.Direction()) * ax_c;
            if (gp_Vec(n).Dot(r2) >= 0) continue;   // convexa (material dentro del cilindro)
            double r = s.Cylinder().Radius(), a0, a1, v0, v1; BRepTools::UVBounds(f, a0, a1, v0, v1);
            double ang = a1 - a0, L = v1 - v0;
            if (ang > 5.0) { double ratio = L / (2 * r); if (ratio > worstHole) { worstHole = ratio; worstHoleD = 2 * r; worstHoleL = L; } }   // ≥ ~290°: taladro
            else if (ang > 0.5 && ang < 3.3) {
                if (L < 2.0 || r < kArtefactR) continue;
                bool through = false;   // radio abierto por ambos extremos (recorre la pieza): no es fondo de cajera, se fresa de costado
                { gp_Pnt Q = P.Translated(gp_Vec(n) * std::min(0.5 * r, 0.5)); gp_Dir ad = ax.Direction();
                  inter.Perform(gp_Lin(Q, ad), 0, 1e6); bool a1f = inter.NbPnt() == 0;
                  inter.Perform(gp_Lin(Q, ad.Reversed()), 0, 1e6); through = a1f && inter.NbPnt() == 0; }
                if (!through) { if (r < minR) { minR = r; minRLen = L; }
                double ratio = L / (2 * r); if (ratio > worstRatio) { worstRatio = ratio; worstRatioR = r; worstRatioL = L; } }
                else if (r < minR) { minR = r; minRLen = L; }
            }
        }
    }
    if (nSharp) out.push_back(Tf("DFM: esquina interior sin radio (arista de {0} mm, {1} aristas): una fresa redonda no la deja viva.", lang, {num(sharpLen, lang), std::to_string(nSharp)}));
    if (minR < kMinRadius) out.push_back(Tf("DFM: radio interior de {0} mm menor que {1} mm (fresa mínima Ø{2} mm).", lang, {num(minR, lang), num(kMinRadius, lang), num(2 * kMinRadius, lang)}));
    if (worstRatio > kMaxPocket ) out.push_back(Tf("DFM: cajera profunda: {0} mm con esquina de radio {1} mm = {2}×Ø de fresa (máx. {3}×).", lang, {num(worstRatioL, lang), num(worstRatioR, lang), num(worstRatio, lang), num(kMaxPocket, lang)}));
    if (worstHole > kMaxHole) out.push_back(Tf("DFM: taladro profundo: Ø{0} × {1} mm = {2}×Ø (máx. {3}×Ø).", lang, {num(worstHoleD, lang), num(worstHoleL, lang), num(worstHole, lang), num(kMaxHole, lang)}));
    // 4) paredes finas: recorrido del material desde cada cara plana hacia dentro
    std::map<int, int> thin; double thinMin = 1e9;
    for (TopExp_Explorer fe(S, TopAbs_FACE); fe.More(); fe.Next()) {
        TopoDS_Face f = TopoDS::Face(fe.Current()); BRepAdaptor_Surface s(f); if (s.GetType() != GeomAbs_Plane) continue;
        double a0, a1, b0, b1; BRepTools::UVBounds(f, a0, a1, b0, b1);
        for (double fu : {0.5, 0.25, 0.75}) { bool done = false;
            for (double fv : {0.5, 0.25, 0.75}) {
                double u = a0 + (a1 - a0) * fu, v = b0 + (b1 - b0) * fv;
                BRepClass_FaceClassifier fc(f, gp_Pnt2d(u, v), 1e-6); if (fc.State() != TopAbs_IN) continue;
                gp_Dir n = faceNormal(f, u, v); gp_Pnt P = s.Value(u, v);
                inter.Perform(gp_Lin(P.Translated(gp_Vec(n) * -1e-4), n.Reversed()), 0, 1e6);
                double dmin = 1e9; int bi = 0; for (int i = 1; i <= inter.NbPnt(); i++) if (inter.WParameter(i) < dmin) { dmin = inter.WParameter(i); bi = i; }
                if (bi) {   // pared = la cara de salida es un plano paralelo (si no, es un chaflán, rosca o curva)
                    BRepAdaptor_Surface so(inter.Face(bi));
                    if (so.GetType() == GeomAbs_Plane) {
                        double uo, vo; mid(inter.Face(bi), uo, vo); gp_Dir no = faceNormal(inter.Face(bi), uo, vo);
                        double d = dmin + 1e-4;
                        if (std::fabs(no.Dot(n)) > 0.999 && d < kMinWall && d >= kSliver) { thin[(int)std::lround(d * 100)]++; thinMin = std::min(thinMin, d); }
                    }
                }
                done = true; break;
            }
            if (done) break; }
    }
    if (!thin.empty()) { int n = 0; for (auto& kv : thin) n += kv.second; out.push_back(Tf("DFM: pared fina de {0} mm (menor que {1} mm; {2} caras).", lang, {num(thinMin, lang), num(kMinWall, lang), std::to_string(n)})); }
    return out;
}
}  // namespace diedro
