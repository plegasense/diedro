// Lectura de cotas con tolerancia (PMI) del STEP. Solo se devuelve lo que el archivo declara.
#include <STEPCAFControl_Reader.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_Dimension.hxx>
#include <XCAFDoc_DimTolTool.hxx>
#include <XCAFDoc_GeomTolerance.hxx>
#include <XCAFDimTolObjects_GeomToleranceObject.hxx>
#include <XCAFDimTolObjects_GeomToleranceType.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <gp_Pln.hxx>
#include <gp_Cylinder.hxx>
#include <XCAFDimTolObjects_DimensionObject.hxx>
#include <TDF_LabelSequence.hxx>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <map>
#include <sstream>
#include <TCollection_HAsciiString.hxx>
#include "analyze.hpp"

namespace diedro {

// OCCT 7.9.3 devuelve 0 como valor de las tolerancias geométricas: se lee del texto del STEP (LENGTH_MEASURE de la magnitud), en mm.
static std::map<int, std::vector<double>> gdtValuesFromText(const std::string& path) {
    std::map<int, std::vector<double>> out;
    std::ifstream f(path, std::ios::binary);
    if (!f) return out;
    std::stringstream ss;
    ss << f.rdbuf();
    const std::string all = ss.str();
    static const char* kinds[] = {"", "ANGULARITY", "CIRCULAR_RUNOUT", "ROUNDNESS", "COAXIALITY", "CONCENTRICITY", "CYLINDRICITY", "FLATNESS", "PARALLELISM", "PERPENDICULARITY", "POSITION", "LINE_PROFILE", "SURFACE_PROFILE", "STRAIGHTNESS", "SYMMETRY", "TOTAL_RUNOUT"};
    std::map<int, std::string> st;
    size_t i = 0;
    while (i < all.size()) {
        size_t e = all.find(';', i);
        if (e == std::string::npos) break;
        std::string t = all.substr(i, e - i);
        i = e + 1;
        size_t h = t.find('#');
        if (h == std::string::npos) continue;
        if (t.find("_TOLERANCE(") == std::string::npos && t.find("MEASURE_WITH_UNIT(") == std::string::npos && t.find("SI_UNIT(") == std::string::npos) continue;
        std::string c;
        for (char ch : t) if (ch != '\n' && ch != '\r') c += ch;
        h = c.find('#');
        size_t q = c.find('=', h);
        if (q == std::string::npos) continue;
        st[std::atoi(c.c_str() + h + 1)] = c.substr(q + 1);
    }
    auto num = [&](const std::string& s, size_t pos) { return std::atof(s.c_str() + pos); };
    for (auto& kv : st) {
        const std::string& t = kv.second;
        int kind = 0;
        size_t g = t.find("GEOMETRIC_TOLERANCE(");
        for (int k = 1; k <= 15; k++) if (t.find(std::string(kinds[k]) + "_TOLERANCE(") != std::string::npos) kind = k;
        if (!kind) continue;
        if (g == std::string::npos) g = t.find(std::string(kinds[kind]) + "_TOLERANCE(");  // forma simple AP242
        size_t a = t.find(",#", g);
        if (a == std::string::npos) continue;
        auto m = st.find(std::atoi(t.c_str() + a + 2));
        if (m == st.end()) continue;
        const std::string& ms = m->second;
        size_t l = ms.find("LENGTH_MEASURE(");
        size_t u = ms.find(",#", l == std::string::npos ? 0 : l);
        if (l == std::string::npos || u == std::string::npos) { out[kind].push_back(0); continue; }
        auto un = st.find(std::atoi(ms.c_str() + u + 2));
        double f2 = 0;
        if (un != st.end() && un->second.find(".METRE.") != std::string::npos)
            f2 = un->second.find(".MILLI.") != std::string::npos ? 1.0 : (un->second.find(".CENTI.") != std::string::npos ? 10.0 : (un->second.find(".MICRO.") != std::string::npos ? 0.001 : (un->second.find(".$.") != std::string::npos || un->second.find("*,.METRE.") != std::string::npos ? 1000.0 : 0)));
        out[kind].push_back(f2 > 0 ? num(ms, l + 15) * f2 : 0);
    }
    return out;
}

std::vector<PmiDim> readPmi(const std::string& path, std::vector<GdtTol>* gdt) {
    std::vector<PmiDim> out;
    try {
        Handle(TDocStd_Document) doc = new TDocStd_Document("MDTV-XCAF");
        XCAFApp_Application::GetApplication()->InitDocument(doc);
        STEPCAFControl_Reader rd;
        rd.SetGDTMode(true);
        if (rd.ReadFile(path.c_str()) != IFSelect_RetDone || !rd.Transfer(doc)) return out;
        Handle(XCAFDoc_DimTolTool) tool = XCAFDoc_DocumentTool::DimTolTool(doc->Main());
        TDF_LabelSequence ls;
        tool->GetDimensionLabels(ls);
        for (int i = 1; i <= ls.Length(); i++) {
            Handle(XCAFDoc_Dimension) a;
            if (!ls.Value(i).FindAttribute(XCAFDoc_Dimension::GetID(), a)) continue;
            Handle(XCAFDimTolObjects_DimensionObject) o = a->GetObject();
            if (o.IsNull()) continue;
            PmiDim d;
            auto t = o->GetType();
            d.diameter = t == XCAFDimTolObjects_DimensionType_Size_Diameter;
            d.radius = t == XCAFDimTolObjects_DimensionType_Size_Radius;
            d.value = o->GetValue();
            if (o->IsDimWithRange()) {  // límites declarados (p. ej. 19,98 / 20,00): se pasan a desviaciones sobre el nominal
                d.upper = o->GetUpperBound() - d.value;
                d.lower = d.value - o->GetLowerBound();   // misma convención que GetLowerTolValue: magnitud hacia abajo
                if (std::fabs(d.upper) > d.value || std::fabs(d.lower) > d.value) continue;
            } else {
                d.upper = o->GetUpperTolValue();
                d.lower = o->GetLowerTolValue();
            }
            if (d.value <= 0 || (d.upper == 0 && d.lower == 0)) continue;
            out.push_back(d);
        }
        if (gdt) {
            TDF_LabelSequence gs;
            tool->GetGeomToleranceLabels(gs);
            for (int i = 1; i <= gs.Length(); i++) {
                Handle(XCAFDoc_GeomTolerance) a;
                if (!gs.Value(i).FindAttribute(XCAFDoc_GeomTolerance::GetID(), a)) continue;
                Handle(XCAFDimTolObjects_GeomToleranceObject) o = a->GetObject();
                if (o.IsNull()) continue;
                GdtTol g;
                g.type = static_cast<int>(o->GetType());
                g.value = o->GetValue();
                TDF_LabelSequence ds;
                if (XCAFDoc_DimTolTool::GetDatumOfTolerLabels(gs.Value(i), ds))
                    for (int k = 1; k <= ds.Length(); k++) {
                        Handle(TCollection_HAsciiString) n, d, id;
                        if (tool->GetDatum(ds.Value(k), n, d, id)) {
                            const char* nm = !id.IsNull() && id->Length() > 0 ? id->ToCString() : (!n.IsNull() ? n->ToCString() : "");
                            if (nm[0]) g.datums += std::string(g.datums.empty() ? "" : " | ") + nm;
                        }
                    }
                TDF_LabelSequence f1, f2;
                if (XCAFDoc_DimTolTool::GetRefShapeLabel(gs.Value(i), f1, f2) && f1.Length() > 0) {
                    TopoDS_Shape sh = XCAFDoc_ShapeTool::GetShape(f1.Value(1));
                    for (TopExp_Explorer e(sh, TopAbs_FACE); e.More(); e.Next()) {   // primera cara referida por la tolerancia
                        TopoDS_Face fc = TopoDS::Face(e.Current());
                        GProp_GProps gp; BRepGProp::SurfaceProperties(fc, gp);
                        gp_Pnt c = gp.CentreOfMass();
                        g.hasPt = true; g.pt[0] = c.X(); g.pt[1] = c.Y(); g.pt[2] = c.Z();
                        BRepAdaptor_Surface su(fc);
                        gp_Dir dr;
                        if (su.GetType() == GeomAbs_Plane) { dr = su.Plane().Axis().Direction(); g.hasDir = true; }
                        else if (su.GetType() == GeomAbs_Cylinder) { dr = su.Cylinder().Axis().Direction(); g.hasDir = true; }
                        if (g.hasDir) { g.dir[0] = dr.X(); g.dir[1] = dr.Y(); g.dir[2] = dr.Z(); }
                        break;
                    }
                }
                gdt->push_back(g);
            }
            auto tv = gdtValuesFromText(path);
            std::map<int, size_t> used;
            for (auto& g : *gdt) {
                auto it = tv.find(g.type);
                if (it == tv.end()) continue;
                size_t& n = used[g.type];
                // mismo número de tolerancias del tipo en el texto y en OCCT: se asignan por orden
                if (it->second.size() == (size_t)std::count_if(gdt->begin(), gdt->end(), [&](const GdtTol& x) { return x.type == g.type; }) && n < it->second.size())
                    g.value = it->second[n];
                n++;
            }
        }
    } catch (...) { out.clear(); }
    return out;
}

}  // namespace diedro
