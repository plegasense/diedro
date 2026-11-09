// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Importador de formatos B-rep (STEP, IGES, BREP) sobre Open CASCADE (XCAF).
#include "datum.h"

#include <algorithm>
#include <atomic>
#include <thread>
#include <Interface_Static.hxx>
#include <TColStd_HSequenceOfHAsciiString.hxx>
#include <cstdio>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include <BRepAdaptor_Curve.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <XCAFDimTolObjects_DatumObject.hxx>
#include <XCAFDimTolObjects_DimensionObject.hxx>
#include <XCAFDimTolObjects_GeomToleranceObject.hxx>
#include <XCAFDoc_Datum.hxx>
#include <XCAFDoc_Dimension.hxx>
#include <XCAFDoc_DimTolTool.hxx>
#include <XCAFDoc_GeomTolerance.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp.hxx>
#include <BRepLib.hxx>
#include <BRepLProp_SLProps.hxx>
#include <BRepTools.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <Geom2d_Curve.hxx>
#include <GeomAbs_CurveType.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <HeaderSection_FileName.hxx>
#include <HeaderSection_FileSchema.hxx>
#include <STEPControl_Reader.hxx>
#include <StepData_StepModel.hxx>
#include <TCollection_HAsciiString.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS_Edge.hxx>
#include <BinXCAFDrivers.hxx>
#include <PCDM_ReaderStatus.hxx>
#include <PCDM_StoreStatus.hxx>
#include <fstream>
#include <cstdio>
#include <XCAFDoc.hxx>
#include <XCAFDoc_MaterialTool.hxx>
#include <TDataStd_TreeNode.hxx>
#include <TCollection_HAsciiString.hxx>
#include <XCAFDoc_Area.hxx>
#include <XCAFDoc_Volume.hxx>
#include <BRepBndLib.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <IGESCAFControl_Reader.hxx>
#include <Poly_Triangulation.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <TCollection_AsciiString.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TDF_Label.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Trsf.hxx>

namespace {

thread_local std::string g_error;

struct FaceRec {
  bool done = false;
  double v[14] = {0};
};

struct Part {
  std::string name;
  std::vector<float> verts;
  unsigned color = 0;
  TopoDS_Shape shape;
  TDF_Label label;
  std::string matName;
  double matDensity = 0;  // g/cm³ según el archivo; 0 = sin dato
  std::vector<TopoDS_Face> faces;        // en el orden del teselado
  std::vector<int> faceOfTri;            // cara de cada triángulo
  std::vector<FaceRec> faceRecs;         // información de cada cara (bajo demanda)
  std::vector<TopoDS_Edge> edgeShapes;   // aristas vivas
  std::vector<std::array<double, 15>> edgeRecs;
  std::vector<float> edgeSegs;           // 6 floats por segmento
  std::vector<int> edgeOfSeg;            // arista de cada segmento
  bool propsDone = false;
  double props[8] = {0, 0, 0, 0, 0, 0, 0, 0};
};

struct Node {
  std::string name;
  int parent = -1;
  int part = -1;
  double m[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  unsigned color = 0;
};

std::string toUtf8(const TCollection_ExtendedString& s) {
  std::string out;
  const int n = s.Length();
  for (int i = 1; i <= n; ++i) {
    unsigned c = s.Value(i);
    if (c >= 0xD800 && c <= 0xDBFF && i < n) {
      const unsigned lo = s.Value(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
        ++i;
      }
    }
    if (c < 0x80) {
      out += static_cast<char>(c);
    } else if (c < 0x800) {
      out += static_cast<char>(0xC0 | (c >> 6));
      out += static_cast<char>(0x80 | (c & 0x3F));
    } else if (c < 0x10000) {
      out += static_cast<char>(0xE0 | (c >> 12));
      out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (c & 0x3F));
    } else {
      out += static_cast<char>(0xF0 | (c >> 18));
      out += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
      out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (c & 0x3F));
    }
  }
  return out;
}

std::string labelName(const TDF_Label& l) {
  Handle(TDataStd_Name) n;
  if (l.FindAttribute(TDataStd_Name::GetID(), n)) return toUtf8(n->Get());
  return {};
}

unsigned labelColor(const Handle(XCAFDoc_ColorTool) & ct, const TDF_Label& l) {
  Quantity_Color c;
  const XCAFDoc_ColorType kinds[] = {XCAFDoc_ColorSurf, XCAFDoc_ColorGen, XCAFDoc_ColorCurv};
  for (auto k : kinds) {
    if (ct->GetColor(l, k, c)) {
      auto b = [](double v) { return static_cast<unsigned>(std::lround(std::clamp(v, 0.0, 1.0) * 255.0)); };
      return 0xFF000000u | (b(c.Red()) << 16) | (b(c.Green()) << 8) | b(c.Blue());
    }
  }
  return 0;
}

}  // namespace

// Anotación del archivo (PMI): cota, tolerancia geométrica o referencia (datum).
struct PmiRec {
  int kind = 0;  // 0 cota, 1 tolerancia, 2 referencia
  int type = 0;
  double v[16] = {0};
  std::string text;
  std::vector<std::array<int, 3>> refs;  // pieza, 0 cara / 1 arista, índice
  std::vector<float> segs;               // presentación gráfica (6 floats por segmento)
};

struct DatumScene {
  std::vector<PmiRec> pmi;
  std::vector<Part> parts;
  std::vector<Node> nodes;
  Handle(TDocStd_Document) doc;
  std::string unit = "MM";
  std::string origin;
  std::string schema;
};

namespace {

struct Ctx {
  DatumScene* scene;
  double relDeflection;
  Handle(XCAFDoc_ShapeTool) shapes;
  Handle(XCAFDoc_ColorTool) colors;
  std::map<int, int> partOfLabel;  // etiqueta (tag) -> índice de pieza
};

// ¿La arista une dos caras casi tangentes? Entonces no es una arista viva.
bool isSmoothEdge(const TopoDS_Edge& e, const TopoDS_Face& f1, const TopoDS_Face& f2) {
  try {
    double a, b, c, d;
    Handle(Geom2d_Curve) c1 = BRep_Tool::CurveOnSurface(e, f1, a, b);
    Handle(Geom2d_Curve) c2 = BRep_Tool::CurveOnSurface(e, f2, c, d);
    if (c1.IsNull() || c2.IsNull()) return false;
    const gp_Pnt2d q1 = c1->Value((a + b) / 2), q2 = c2->Value((c + d) / 2);
    BRepAdaptor_Surface s1(f1), s2(f2);
    BRepLProp_SLProps p1(s1, q1.X(), q1.Y(), 1, 1e-6), p2(s2, q2.X(), q2.Y(), 1, 1e-6);
    if (!p1.IsNormalDefined() || !p2.IsNormalDefined()) return false;
    gp_Dir n1 = p1.Normal(), n2 = p2.Normal();
    if (f1.Orientation() == TopAbs_REVERSED) n1.Reverse();
    if (f2.Orientation() == TopAbs_REVERSED) n2.Reverse();
    return n1.Dot(n2) > 0.985;  // menos de ~10 grados
  } catch (...) {
    return false;
  }
}

void buildEdges(Part& part, double lin) {
  // Algunos exportadores dejan aristas solo con curvas 2D sobre la superficie: se reconstruye la curva 3D.
  try {
    BRepLib::BuildCurves3d(part.shape);
  } catch (...) {
  }
  TopTools_IndexedDataMapOfShapeListOfShape map;
  TopExp::MapShapesAndAncestors(part.shape, TopAbs_EDGE, TopAbs_FACE, map);
  for (int i = 1; i <= map.Extent(); ++i) {
    const TopoDS_Edge e = TopoDS::Edge(map.FindKey(i));
    if (BRep_Tool::Degenerated(e)) continue;
    const TopTools_ListOfShape& fl = map.FindFromIndex(i);
    if (fl.Extent() == 2) {
      const TopoDS_Face f1 = TopoDS::Face(fl.First()), f2 = TopoDS::Face(fl.Last());
      if (f1.IsSame(f2)) continue;  // costura
      if (isSmoothEdge(e, f1, f2)) continue;
    }
    try {
      BRepAdaptor_Curve ac(e);
      GCPnts_TangentialDeflection td(ac, 0.12, lin);
      const int n = td.NbPoints();
      if (n < 2) continue;
      std::array<double, 15> rec{};
      rec[1] = GCPnts_AbscissaPoint::Length(ac);
      const double first = ac.FirstParameter(), last = ac.LastParameter();
      switch (ac.GetType()) {
        case GeomAbs_Line: rec[0] = 1; break;
        case GeomAbs_Circle: {
          const gp_Circ c = ac.Circle();
          rec[0] = (std::abs(last - first) >= 2 * M_PI - 1e-6) ? 2 : 3;
          rec[2] = c.Radius();
          rec[3] = c.Location().X(); rec[4] = c.Location().Y(); rec[5] = c.Location().Z();
          rec[6] = c.Axis().Direction().X(); rec[7] = c.Axis().Direction().Y(); rec[8] = c.Axis().Direction().Z();
          break;
        }
        default: rec[0] = 0;
      }
      const gp_Pnt p0 = ac.Value(first), p1 = ac.Value(last);
      rec[9] = p0.X(); rec[10] = p0.Y(); rec[11] = p0.Z();
      rec[12] = p1.X(); rec[13] = p1.Y(); rec[14] = p1.Z();
      const int id = static_cast<int>(part.edgeRecs.size());
      part.edgeRecs.push_back(rec);
      part.edgeShapes.push_back(e);
      for (int k = 1; k < n; ++k) {
        const gp_Pnt a = td.Value(k), b = td.Value(k + 1);
        const float seg[6] = {float(a.X()), float(a.Y()), float(a.Z()), float(b.X()), float(b.Y()), float(b.Z())};
        part.edgeSegs.insert(part.edgeSegs.end(), seg, seg + 6);
        part.edgeOfSeg.push_back(id);
      }
    } catch (...) {
    }
  }
}

void computeFace(Part& p, int fi) {
  FaceRec& r = p.faceRecs[fi];
  if (r.done) return;
  r.done = true;
  double* v = r.v;
  const TopoDS_Face& f = p.faces[fi];
  try {
    BRepAdaptor_Surface s(f);
    GProp_GProps g;
    BRepGProp::SurfaceProperties(f, g);
    v[1] = g.Mass();
    double u0, u1, v0, v1;
    BRepTools::UVBounds(f, u0, u1, v0, v1);
    const bool rev = f.Orientation() == TopAbs_REVERSED;
    switch (s.GetType()) {
      case GeomAbs_Plane: {
        const gp_Pln pl = s.Plane();
        gp_Dir n = pl.Axis().Direction();
        if (rev) n.Reverse();
        v[0] = 1;
        v[4] = pl.Location().X(); v[5] = pl.Location().Y(); v[6] = pl.Location().Z();
        v[7] = n.X(); v[8] = n.Y(); v[9] = n.Z();
        break;
      }
      case GeomAbs_Cylinder: {
        const gp_Cylinder c = s.Cylinder();
        v[0] = 2;
        v[2] = c.Radius();
        const gp_Dir a = c.Axis().Direction();
        const gp_Pnt st = c.Location().Translated(gp_Vec(a) * v0);
        v[4] = st.X(); v[5] = st.Y(); v[6] = st.Z();
        v[7] = a.X(); v[8] = a.Y(); v[9] = a.Z();
        v[10] = v1 - v0;
        v[11] = u1 - u0;
        v[12] = rev ? 1 : 0;  // cóncava = agujero
        break;
      }
      case GeomAbs_Cone: {
        const gp_Cone c = s.Cone();
        v[0] = 3;
        v[2] = c.RefRadius();
        v[3] = c.SemiAngle();
        v[4] = c.Location().X(); v[5] = c.Location().Y(); v[6] = c.Location().Z();
        v[7] = c.Axis().Direction().X(); v[8] = c.Axis().Direction().Y(); v[9] = c.Axis().Direction().Z();
        v[10] = v1 - v0;
        v[11] = u1 - u0;
        v[12] = rev ? 1 : 0;
        break;
      }
      case GeomAbs_Sphere: {
        const gp_Sphere c = s.Sphere();
        v[0] = 4;
        v[2] = c.Radius();
        v[4] = c.Location().X(); v[5] = c.Location().Y(); v[6] = c.Location().Z();
        v[12] = rev ? 1 : 0;
        break;
      }
      case GeomAbs_Torus: {
        const gp_Torus c = s.Torus();
        v[0] = 5;
        v[2] = c.MajorRadius();
        v[3] = c.MinorRadius();
        v[4] = c.Location().X(); v[5] = c.Location().Y(); v[6] = c.Location().Z();
        v[7] = c.Axis().Direction().X(); v[8] = c.Axis().Direction().Y(); v[9] = c.Axis().Direction().Z();
        break;
      }
      default: v[0] = 0;
    }
  } catch (...) {
  }
}

// Registra una pieza única; el teselado y las aristas se calculan después, en paralelo.
int tessellate(Ctx& cx, const TDF_Label& ref) {
  const int key = ref.Tag();
  auto it = cx.partOfLabel.find(key);
  if (it != cx.partOfLabel.end()) return it->second;

  Part part;
  part.name = labelName(ref);
  part.color = labelColor(cx.colors, ref);
  part.shape = XCAFDoc_ShapeTool::GetShape(ref);
  part.label = ref;
  // Material declarado en el archivo (nombre y densidad), si lo hay.
  try {
    Handle(TDataStd_TreeNode) node;
    TDF_Label cand[2] = {ref, TDF_Label()};
    for (const TDF_Label& l : cand) {
      if (l.IsNull()) continue;
      if (l.FindAttribute(XCAFDoc::MaterialRefGUID(), node) && node->HasFather()) {
        Handle(TCollection_HAsciiString) nm, ds, dn, dv;
        double dens = 0;
        if (XCAFDoc_MaterialTool::GetMaterial(node->Father()->Label(), nm, ds, dens, dn, dv)) {
          if (!nm.IsNull()) part.matName = nm->ToCString();
          part.matDensity = dens;
          break;
        }
      }
    }
  } catch (...) {
  }
  cx.scene->parts.push_back(std::move(part));
  const int idx = static_cast<int>(cx.scene->parts.size()) - 1;
  cx.partOfLabel[key] = idx;
  return idx;
}

// Tesela una pieza y reúne sus caras y aristas vivas. Cada pieza es independiente: se puede llamar desde varios hilos.
void meshPart(Part& part, double relDeflection) {
  const TopoDS_Shape shape = part.shape;
  Bnd_Box box;
  BRepBndLib::Add(shape, box);
  double diag = 1.0;
  if (!box.IsVoid()) {
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    diag = std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0));
  }
  const double lin = std::max(diag * relDeflection, 1e-4);
  BRepMesh_IncrementalMesh mesher(shape, lin, false, 0.5, false);

  for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
    const TopoDS_Face face = TopoDS::Face(ex.Current());
    const int faceIndex = static_cast<int>(part.faces.size());
    part.faces.push_back(face);
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
    if (tri.IsNull()) continue;
    BRepLib_ToolTriangulatedShape::ComputeNormals(face, tri);
    const gp_Trsf t = loc.Transformation();
    const bool reversed = face.Orientation() == TopAbs_REVERSED;
    const bool hasNormals = tri->HasNormals();
    const int nt = tri->NbTriangles();
    for (int i = 1; i <= nt; ++i) {
      part.faceOfTri.push_back(faceIndex);
      int a, b, c;
      tri->Triangle(i).Get(a, b, c);
      if (reversed) std::swap(b, c);
      const int idx[3] = {a, b, c};
      gp_Pnt p[3];
      gp_Vec n[3];
      for (int k = 0; k < 3; ++k) {
        p[k] = tri->Node(idx[k]).Transformed(t);
        if (hasNormals) {
          gp_Dir d = tri->Normal(idx[k]);
          d.Transform(t);
          n[k] = gp_Vec(d);
          if (reversed) n[k].Reverse();
        }
      }
      if (!hasNormals) {
        gp_Vec fn = gp_Vec(p[0], p[1]) ^ gp_Vec(p[0], p[2]);
        if (fn.Magnitude() > 1e-20) fn.Normalize();
        for (int k = 0; k < 3; ++k) n[k] = fn;
      }
      for (int k = 0; k < 3; ++k) {
        part.verts.push_back(static_cast<float>(p[k].X()));
        part.verts.push_back(static_cast<float>(p[k].Y()));
        part.verts.push_back(static_cast<float>(p[k].Z()));
        part.verts.push_back(static_cast<float>(n[k].X()));
        part.verts.push_back(static_cast<float>(n[k].Y()));
        part.verts.push_back(static_cast<float>(n[k].Z()));
      }
    }
  }
  part.faceRecs.resize(part.faces.size());
  buildEdges(part, lin);
}

void walk(Ctx& cx, const TDF_Label& label, int parent, int depth) {
  if (depth > 64) return;
  TDF_Label ref = label;
  const bool isRef = XCAFDoc_ShapeTool::IsReference(label);
  if (isRef) XCAFDoc_ShapeTool::GetReferredShape(label, ref);

  Node node;
  // Los exportadores (p. ej. SolidWorks) nombran las instancias "NAUO12"; el nombre útil es el del producto.
  node.name = labelName(label);
  const std::string refName = labelName(ref);
  const bool genericName = node.name.empty() || (node.name.rfind("NAUO", 0) == 0);
  if (genericName && !refName.empty()) node.name = refName;
  if (node.name.empty()) node.name = "Sin nombre";
  node.parent = parent;
  node.color = labelColor(cx.colors, label);
  if (isRef) {
    const gp_Trsf t = XCAFDoc_ShapeTool::GetLocation(label).Transformation();
    for (int c = 0; c < 4; ++c)
      for (int r = 0; r < 3; ++r) node.m[c * 4 + r] = t.Value(r + 1, c + 1);
    node.m[3] = node.m[7] = node.m[11] = 0;
    node.m[15] = 1;
  }

  if (XCAFDoc_ShapeTool::IsAssembly(ref)) {
    cx.scene->nodes.push_back(node);
    const int me = static_cast<int>(cx.scene->nodes.size()) - 1;
    TDF_LabelSequence comps;
    XCAFDoc_ShapeTool::GetComponents(ref, comps);
    for (int i = 1; i <= comps.Length(); ++i) walk(cx, comps.Value(i), me, depth + 1);
  } else if (XCAFDoc_ShapeTool::IsSimpleShape(ref)) {
    node.part = tessellate(cx, ref);
    cx.scene->nodes.push_back(node);
  }
}

}  // namespace

namespace {

// Localiza una cara o arista de una pieza a partir de la forma a la que apunta una anotación.
bool locateShape(DatumScene* sc, const TopoDS_Shape& sh, std::array<int, 3>& out) {
  for (size_t pi = 0; pi < sc->parts.size(); ++pi) {
    Part& p = sc->parts[pi];
    if (sh.ShapeType() == TopAbs_FACE) {
      for (size_t f = 0; f < p.faces.size(); ++f) {
        if (p.faces[f].IsSame(sh)) {
          out = {static_cast<int>(pi), 0, static_cast<int>(f)};
          return true;
        }
      }
    } else if (sh.ShapeType() == TopAbs_EDGE) {
      for (size_t e = 0; e < p.edgeShapes.size(); ++e) {
        if (p.edgeShapes[e].IsSame(sh)) {
          out = {static_cast<int>(pi), 1, static_cast<int>(e)};
          return true;
        }
      }
    }
  }
  return false;
}

void addRefs(DatumScene* sc, const TDF_Label& lab, PmiRec& r) {
  NCollection_Sequence<TDF_Label> a, b;
  if (!XCAFDoc_DimTolTool::GetRefShapeLabel(lab, a, b)) return;
  auto add = [&](NCollection_Sequence<TDF_Label>& seq) {
    for (int i = 1; i <= seq.Length(); ++i) {
      const TopoDS_Shape sh = XCAFDoc_ShapeTool::GetShape(seq.Value(i));
      if (sh.IsNull()) continue;
      std::array<int, 3> ref;
      if (sh.ShapeType() == TopAbs_FACE || sh.ShapeType() == TopAbs_EDGE) {
        if (locateShape(sc, sh, ref)) r.refs.push_back(ref);
      } else {
        // Sólido, cáscara o pieza completa: se marcan todas sus caras.
        for (TopExp_Explorer ex(sh, TopAbs_FACE); ex.More(); ex.Next()) {
          if (locateShape(sc, ex.Current(), ref)) r.refs.push_back(ref);
        }
      }
    }
  };
  add(a);
  add(b);
}

// Líneas de la representación gráfica de la anotación (texto, líneas de cota y flechas).
void addPresentation(const TopoDS_Shape& pres, PmiRec& r) {
  if (pres.IsNull()) return;
  Bnd_Box box;
  BRepBndLib::Add(pres, box);
  if (box.IsVoid()) return;
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  const double diag = std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0));
  const double lin = std::max(diag * 0.002, 1e-5);
  for (TopExp_Explorer ex(pres, TopAbs_EDGE); ex.More(); ex.Next()) {
    try {
      BRepAdaptor_Curve ac(TopoDS::Edge(ex.Current()));
      GCPnts_TangentialDeflection td(ac, 0.2, lin);
      for (int k = 1; k < td.NbPoints(); ++k) {
        const gp_Pnt a = td.Value(k), b = td.Value(k + 1);
        const float seg[6] = {float(a.X()), float(a.Y()), float(a.Z()), float(b.X()), float(b.Y()), float(b.Z())};
        r.segs.insert(r.segs.end(), seg, seg + 6);
      }
    } catch (...) {
    }
  }
}

void readPmi(DatumScene* sc) {
  try {
    Handle(XCAFDoc_DimTolTool) dt = XCAFDoc_DocumentTool::DimTolTool(sc->doc->Main());
    if (dt.IsNull()) return;
    NCollection_Sequence<TDF_Label> labs;

    dt->GetDimensionLabels(labs);
    for (int i = 1; i <= labs.Length(); ++i) {
      Handle(XCAFDoc_Dimension) a;
      if (!labs.Value(i).FindAttribute(XCAFDoc_Dimension::GetID(), a)) continue;
      Handle(XCAFDimTolObjects_DimensionObject) o = a->GetObject();
      if (o.IsNull()) continue;
      PmiRec r;
      r.kind = 0;
      r.type = static_cast<int>(o->GetType());
      r.v[0] = o->GetValue();
      if (o->IsDimWithPlusMinusTolerance()) {
        r.v[1] = o->GetUpperTolValue();
        r.v[2] = o->GetLowerTolValue();
        r.v[5] = 1;
      } else if (o->IsDimWithRange()) {
        r.v[1] = o->GetUpperBound();
        r.v[2] = o->GetLowerBound();
        r.v[5] = 2;
      }
      r.v[6] = o->HasQualifier() ? static_cast<int>(o->GetQualifier()) : 0;
      r.v[10] = o->GetPointTextAttach().X();
      r.v[11] = o->GetPointTextAttach().Y();
      r.v[12] = o->GetPointTextAttach().Z();
      Handle(TCollection_HAsciiString) sn = o->GetSemanticName();
      if (!sn.IsNull()) r.text = sn->ToCString();
      addRefs(sc, labs.Value(i), r);
      addPresentation(o->GetPresentation(), r);
      sc->pmi.push_back(std::move(r));
    }

    labs.Clear();
    dt->GetGeomToleranceLabels(labs);
    for (int i = 1; i <= labs.Length(); ++i) {
      Handle(XCAFDoc_GeomTolerance) a;
      if (!labs.Value(i).FindAttribute(XCAFDoc_GeomTolerance::GetID(), a)) continue;
      Handle(XCAFDimTolObjects_GeomToleranceObject) o = a->GetObject();
      if (o.IsNull()) continue;
      PmiRec r;
      r.kind = 1;
      r.type = static_cast<int>(o->GetType());
      r.v[0] = o->GetValue();
      r.v[7] = static_cast<int>(o->GetTypeOfValue());
      r.v[8] = static_cast<int>(o->GetMaterialRequirementModifier());
      r.v[9] = static_cast<int>(o->GetZoneModifier());
      r.v[10] = o->GetPointTextAttach().X();
      r.v[11] = o->GetPointTextAttach().Y();
      r.v[12] = o->GetPointTextAttach().Z();
      NCollection_Sequence<TDF_Label> datums;
      if (XCAFDoc_DimTolTool::GetDatumOfTolerLabels(labs.Value(i), datums)) {
        for (int k = 1; k <= datums.Length(); ++k) {
          Handle(TCollection_HAsciiString) n, d, id;
          if (dt->GetDatum(datums.Value(k), n, d, id)) {
            const char* nm = !id.IsNull() && id->Length() > 0 ? id->ToCString() : (!n.IsNull() ? n->ToCString() : "");
            if (nm[0] != 0) {
              if (!r.text.empty()) r.text += "|";
              r.text += nm;
            }
          }
        }
      }
      addRefs(sc, labs.Value(i), r);
      addPresentation(o->GetPresentation(), r);
      sc->pmi.push_back(std::move(r));
    }

    labs.Clear();
    dt->GetDatumLabels(labs);
    for (int i = 1; i <= labs.Length(); ++i) {
      PmiRec r;
      r.kind = 2;
      Handle(TCollection_HAsciiString) n, d, id;
      if (dt->GetDatum(labs.Value(i), n, d, id)) {
        if (!id.IsNull() && id->Length() > 0) r.text = id->ToCString();
        else if (!n.IsNull()) r.text = n->ToCString();
      }
      Handle(XCAFDoc_Datum) a;
      if (labs.Value(i).FindAttribute(XCAFDoc_Datum::GetID(), a)) {
        Handle(XCAFDimTolObjects_DatumObject) o = a->GetObject();
        if (!o.IsNull()) addPresentation(o->GetPresentation(), r);
      }
      addRefs(sc, labs.Value(i), r);
      sc->pmi.push_back(std::move(r));
    }
  } catch (...) {
  }
}

}  // namespace

#ifdef __ANDROID__
#include <android/log.h>
#endif
#include <chrono>

static double nowMs() {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
static bool g_lean = false;
static std::string g_cacheFile;
static double g_timing[5] = {0, 0, 0, 0, 0};  // lectura, conversión, árbol, teselado, anotaciones

extern "C" {

static bool g_noMesh = false;
DATUM_API void datum_cad_set_lean(int lean) { g_lean = lean != 0; }
DATUM_API void datum_cad_set_nomesh(int nomesh) { g_noMesh = nomesh != 0; }

DATUM_API void datum_cad_set_cache_file(const char* path) { g_cacheFile = path ? path : ""; }

DATUM_API void datum_cad_timing(double* out5) {
  for (int i = 0; i < 5; ++i) out5[i] = g_timing[i];
}

DatumScene* datum_cad_open(const char* path, double rel_deflection) {
  g_error.clear();
  try {
    Handle(XCAFApp_Application) app = XCAFApp_Application::GetApplication();
    Handle(TDocStd_Document) doc;
    const std::string cacheFile = g_cacheFile;
    g_cacheFile.clear();
    for (double& t : g_timing) t = 0;
    const double tStart = nowMs();
    bool fromCache = false;
    std::string fileUnit = "MM", fileOrigin, fileSchema;
    if (!cacheFile.empty()) {
      // Documento ya convertido en una apertura anterior: evita leer y convertir el STEP.
      std::ifstream meta(cacheFile + ".meta");
      if (meta.good()) {
        try {
          BinXCAFDrivers::DefineFormat(app);
          const double t0c = nowMs();
          if (app->Open(TCollection_ExtendedString(cacheFile.c_str()), doc) == PCDM_RS_OK && !doc.IsNull()) {
            std::getline(meta, fileUnit);
            std::getline(meta, fileOrigin);
            std::getline(meta, fileSchema);
            fromCache = true;
            g_timing[0] = nowMs() - t0c;
          }
        } catch (...) {
          fromCache = false;
        }
      }
    }
    if (!fromCache) app->NewDocument("MDTV-XCAF", doc);

    std::string p(path);
    std::string ext;
    const auto dot = p.find_last_of('.');
    if (dot != std::string::npos) {
      ext = p.substr(dot + 1);
      std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
    }
    double t0 = nowMs();
    bool ok = fromCache;
    if (fromCache) {
      // sin lectura
    } else if (ext == "igs" || ext == "iges") {
      IGESCAFControl_Reader r;
      r.SetColorMode(true);
      r.SetNameMode(true);
      ok = r.ReadFile(path) == IFSelect_RetDone && r.Transfer(doc);
    } else {
      STEPCAFControl_Reader r;
      r.SetColorMode(true);
      r.SetNameMode(true);
      const bool lean = g_lean;
      r.SetLayerMode(!lean);
      r.SetPropsMode(!lean);
      r.SetMatMode(!lean);
      r.SetGDTMode(!lean);
      ok = r.ReadFile(path) == IFSelect_RetDone;
      g_timing[0] = nowMs() - t0;
      t0 = nowMs();
      if (ok) {
        try {
          NCollection_Sequence<TCollection_AsciiString> ul, ua, us;
          r.ChangeReader().FileUnits(ul, ua, us);
          if (ul.Length() > 0) fileUnit = ul.Value(1).ToCString();
          Handle(StepData_StepModel) model = r.ChangeReader().StepModel();
          if (!model.IsNull()) {
            Handle(HeaderSection_FileName) fn =
                Handle(HeaderSection_FileName)::DownCast(model->HeaderEntity(STANDARD_TYPE(HeaderSection_FileName)));
            if (!fn.IsNull() && !fn->OriginatingSystem().IsNull()) fileOrigin = fn->OriginatingSystem()->ToCString();
            Handle(HeaderSection_FileSchema) fs =
                Handle(HeaderSection_FileSchema)::DownCast(model->HeaderEntity(STANDARD_TYPE(HeaderSection_FileSchema)));
            if (!fs.IsNull() && fs->NbSchemaIdentifiers() > 0) fileSchema = fs->SchemaIdentifiersValue(1)->ToCString();
          }
        } catch (...) {
        }
        t0 = nowMs();
        ok = r.Transfer(doc);
        g_timing[1] = nowMs() - t0;
      }
    }
    t0 = nowMs();
    if (!ok) {
      g_error = "No se pudo leer el archivo (formato inválido o no soportado)";
      return nullptr;
    }

    auto* scene = new DatumScene();
    scene->doc = doc;
    scene->unit = fileUnit;
    scene->origin = fileOrigin;
    scene->schema = fileSchema;
    Ctx cx{scene, rel_deflection > 0 ? rel_deflection : 0.001, XCAFDoc_DocumentTool::ShapeTool(doc->Main()),
           XCAFDoc_DocumentTool::ColorTool(doc->Main()), {}};
    TDF_LabelSequence roots;
    cx.shapes->GetFreeShapes(roots);
    for (int i = 1; i <= roots.Length(); ++i) walk(cx, roots.Value(i), -1, 0);
    g_timing[2] = nowMs() - t0;
    t0 = nowMs();
    // Teselado y aristas de todas las piezas, repartidos entre los núcleos disponibles.
    {
      const size_t n = g_noMesh ? 0 : scene->parts.size();
      std::atomic<size_t> next{0};
      auto work = [&]() {
        for (;;) {
          const size_t i = next.fetch_add(1);
          if (i >= n) break;
          try {
            meshPart(scene->parts[i], cx.relDeflection);
          } catch (...) {
          }
        }
      };
      unsigned workers = std::max(1u, std::min(8u, std::thread::hardware_concurrency()));
      if (n < 4) workers = 1;
      std::vector<std::thread> pool;
      for (unsigned w = 1; w < workers; ++w) pool.emplace_back(work);
      work();
      for (auto& t : pool) t.join();
    }
    g_timing[3] = nowMs() - t0;
    t0 = nowMs();
    if (!g_noMesh) readPmi(scene);
    g_timing[4] = nowMs() - t0;
    // Si abrir costó, se guarda el documento convertido (binario) para la próxima vez.
    if (!fromCache && !cacheFile.empty() && (nowMs() - tStart > 2500 || std::getenv("DATUM_CACHE_ALWAYS"))) {
      const double ts = nowMs();
      try {
        BinXCAFDrivers::DefineFormat(app);
        doc->ChangeStorageFormat("BinXCAF");
        const std::string tmp = cacheFile.substr(0, cacheFile.size() - 4) + "_tmp.xbf";
        if (app->SaveAs(doc, TCollection_ExtendedString(tmp.c_str())) == PCDM_SS_OK) {
          std::rename(tmp.c_str(), cacheFile.c_str());
          std::ofstream meta(cacheFile + ".meta");
          meta << fileUnit << "\n" << fileOrigin << "\n" << fileSchema << "\n";
        } else {
          std::remove(tmp.c_str());
        }
      } catch (...) {
      }
#ifdef __ANDROID__
      __android_log_print(ANDROID_LOG_INFO, "datum", "caché guardada en %.0f ms", nowMs() - ts);
#endif
    }
#ifdef __ANDROID__
    __android_log_print(ANDROID_LOG_INFO, "datum", "lectura %.0f ms, conversión %.0f ms, árbol %.0f ms, teselado %.0f ms, anotaciones %.0f ms (núcleos %u)", g_timing[0], g_timing[1], g_timing[2], g_timing[3], g_timing[4], std::thread::hardware_concurrency());
#endif
    if (scene->parts.empty()) {
      g_error = "El archivo no contiene geometría";
      delete scene;
      return nullptr;
    }
    return scene;
  } catch (const Standard_Failure& e) {
    g_error = std::string("Error de Open CASCADE: ") + e.GetMessageString();
  } catch (const std::exception& e) {
    g_error = e.what();
  } catch (...) {
    g_error = "Error desconocido al leer el archivo";
  }
  return nullptr;
}

const char* datum_last_error(void) { return g_error.c_str(); }
void datum_scene_free(DatumScene* s) {
  if (s == nullptr) return;
  Handle(TDocStd_Document) doc = s->doc;
  delete s;
  if (!doc.IsNull()) {
    try {
      XCAFApp_Application::GetApplication()->Close(doc);
    } catch (...) {
    }
  }
}

int datum_part_count(const DatumScene* s) { return static_cast<int>(s->parts.size()); }
const char* datum_part_name(const DatumScene* s, int i) { return s->parts[i].name.c_str(); }
const char* datum_part_material(const DatumScene* s, int i, double* density_g_cm3) {
  *density_g_cm3 = s->parts[i].matDensity;
  return s->parts[i].matName.c_str();
}
long long datum_part_vertex_count(const DatumScene* s, int i) {
  return static_cast<long long>(s->parts[i].verts.size() / 6);
}
const float* datum_part_vertices(const DatumScene* s, int i) { return s->parts[i].verts.data(); }
unsigned int datum_part_color(const DatumScene* s, int i) { return s->parts[i].color; }

const char* datum_file_unit(const DatumScene* s) { return s->unit.c_str(); }
const char* datum_file_origin(const DatumScene* s) { return s->origin.c_str(); }
const char* datum_file_schema(const DatumScene* s) { return s->schema.c_str(); }

int datum_part_face_count(const DatumScene* s, int part) { return static_cast<int>(s->parts[part].faces.size()); }
const int* datum_part_face_of_triangle(const DatumScene* s, int part) { return s->parts[part].faceOfTri.data(); }
void datum_part_face_info(DatumScene* s, int part, int face, double* out) {
  Part& p = s->parts[part];
  computeFace(p, face);
  for (int i = 0; i < 14; ++i) out[i] = p.faceRecs[face].v[i];
}

long long datum_part_edge_segment_count(const DatumScene* s, int part) {
  return static_cast<long long>(s->parts[part].edgeOfSeg.size());
}
const float* datum_part_edge_segments(const DatumScene* s, int part) { return s->parts[part].edgeSegs.data(); }
const int* datum_part_edge_of_segment(const DatumScene* s, int part) { return s->parts[part].edgeOfSeg.data(); }
int datum_part_edge_count(const DatumScene* s, int part) { return static_cast<int>(s->parts[part].edgeRecs.size()); }
void datum_part_edge_info(const DatumScene* s, int part, int edge, double* out) {
  const auto& r = s->parts[part].edgeRecs[edge];
  for (int i = 0; i < 15; ++i) out[i] = r[i];
}

// out: volumen, área, centro (x y z), volumen del archivo, área del archivo, ¿trae datos del archivo?
void datum_part_props(DatumScene* s, int part, double* out) {
  Part& p = s->parts[part];
  if (!p.propsDone) {
    p.propsDone = true;
    try {
      GProp_GProps gv, ga;
      BRepGProp::VolumeProperties(p.shape, gv);
      BRepGProp::SurfaceProperties(p.shape, ga);
      p.props[0] = gv.Mass();
      p.props[1] = ga.Mass();
      const gp_Pnt c = gv.CentreOfMass();
      p.props[2] = c.X(); p.props[3] = c.Y(); p.props[4] = c.Z();
      Handle(XCAFDoc_Volume) vol;
      Handle(XCAFDoc_Area) area;
      if (p.label.FindAttribute(XCAFDoc_Volume::GetID(), vol)) {
        p.props[5] = vol->Get();
        p.props[7] = 1;
      }
      if (p.label.FindAttribute(XCAFDoc_Area::GetID(), area)) {
        p.props[6] = area->Get();
        p.props[7] = 1;
      }
    } catch (...) {
    }
  }
  for (int i = 0; i < 8; ++i) out[i] = p.props[i];
}

static TopoDS_Shape placed(const DatumScene* s, int part, int kind, int idx, const double* m) {
  const Part& p = s->parts[part];
  TopoDS_Shape sh = kind == 0 ? static_cast<TopoDS_Shape>(p.faces[idx]) : static_cast<TopoDS_Shape>(p.edgeShapes[idx]);
  gp_Trsf t;
  t.SetValues(m[0], m[4], m[8], m[12], m[1], m[5], m[9], m[13], m[2], m[6], m[10], m[14]);
  return BRepBuilderAPI_Transform(sh, t, true).Shape();
}

// Distancia mínima entre dos caras/aristas (kind: 0 cara, 1 arista) ya colocadas en el mundo.
// out: distancia, punto en A (3), punto en B (3). Devuelve 1 si hay resultado.
int datum_distance(const DatumScene* s, int partA, int kindA, int idxA, const double* mA, int partB, int kindB,
                   int idxB, const double* mB, double* out) {
  try {
    BRepExtrema_DistShapeShape d(placed(s, partA, kindA, idxA, mA), placed(s, partB, kindB, idxB, mB));
    if (!d.IsDone() || d.NbSolution() < 1) return 0;
    out[0] = d.Value();
    const gp_Pnt a = d.PointOnShape1(1), b = d.PointOnShape2(1);
    out[1] = a.X(); out[2] = a.Y(); out[3] = a.Z();
    out[4] = b.X(); out[5] = b.Y(); out[6] = b.Z();
    return 1;
  } catch (...) {
    return 0;
  }
}

int datum_pmi_count(const DatumScene* s) { return static_cast<int>(s->pmi.size()); }
void datum_pmi_info(const DatumScene* s, int i, double* out16) {
  const PmiRec& r = s->pmi[i];
  out16[0] = r.kind;
  out16[1] = r.type;
  for (int k = 0; k < 14; ++k) out16[2 + k] = r.v[k];
}
const char* datum_pmi_text(const DatumScene* s, int i) { return s->pmi[i].text.c_str(); }
int datum_pmi_ref_count(const DatumScene* s, int i) { return static_cast<int>(s->pmi[i].refs.size()); }
void datum_pmi_ref(const DatumScene* s, int i, int k, int* out3) {
  for (int j = 0; j < 3; ++j) out3[j] = s->pmi[i].refs[k][j];
}
long long datum_pmi_segment_count(const DatumScene* s, int i) {
  return static_cast<long long>(s->pmi[i].segs.size() / 6);
}
const float* datum_pmi_segments(const DatumScene* s, int i) { return s->pmi[i].segs.data(); }

int datum_node_count(const DatumScene* s) { return static_cast<int>(s->nodes.size()); }
const char* datum_node_name(const DatumScene* s, int i) { return s->nodes[i].name.c_str(); }
int datum_node_parent(const DatumScene* s, int i) { return s->nodes[i].parent; }
int datum_node_part(const DatumScene* s, int i) { return s->nodes[i].part; }
const double* datum_node_matrix(const DatumScene* s, int i) { return s->nodes[i].m; }
unsigned int datum_node_color(const DatumScene* s, int i) { return s->nodes[i].color; }

}  // extern "C"

#include <STEPControl_Writer.hxx>
extern "C" int datum_part_export_step(const DatumScene* s, int part, const char* path) {
  if (!s || part < 0 || part >= (int)s->parts.size() || s->parts[part].shape.IsNull()) return 0;
  STEPControl_Writer w;
  return w.Transfer(s->parts[part].shape, STEPControl_AsIs) == IFSelect_RetDone && w.Write(path) == IFSelect_RetDone;
}

TopoDS_Shape datum_part_shape_cpp(const DatumScene* s, int part) {
  return (s && part >= 0 && part < (int)s->parts.size()) ? s->parts[part].shape : TopoDS_Shape();
}
