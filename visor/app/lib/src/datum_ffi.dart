// Enlace FFI con el núcleo C++ (core/include/datum.h). El hook de compilación
// genera la biblioteca y la registra con el identificador de este archivo.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Void Function(Pointer<Double>)>(symbol: 'datum_cad_timing')
external void datumCadTiming(Pointer<Double> out5);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'datum_cad_set_cache_file')
external void datumCadSetCacheFile(Pointer<Utf8> path);

@Native<Void Function(Int32)>(symbol: 'datum_cad_set_lean')
external void datumCadSetLean(int lean);

@Native<Pointer<Void> Function(Pointer<Utf8>, Double)>(symbol: 'datum_cad_open')
external Pointer<Void> datumCadOpen(Pointer<Utf8> path, double relDeflection);

@Native<Pointer<Utf8> Function()>(symbol: 'datum_last_error')
external Pointer<Utf8> datumLastError();

@Native<Void Function(Pointer<Void>)>(symbol: 'datum_scene_free')
external void datumSceneFree(Pointer<Void> scene);

@Native<Int Function(Pointer<Void>)>(symbol: 'datum_part_count')
external int datumPartCount(Pointer<Void> scene);

@Native<Pointer<Utf8> Function(Pointer<Void>, Int)>(symbol: 'datum_part_name')
external Pointer<Utf8> datumPartName(Pointer<Void> scene, int part);

@Native<LongLong Function(Pointer<Void>, Int)>(
  symbol: 'datum_part_vertex_count',
)
external int datumPartVertexCount(Pointer<Void> scene, int part);

@Native<Pointer<Float> Function(Pointer<Void>, Int)>(
  symbol: 'datum_part_vertices',
)
external Pointer<Float> datumPartVertices(Pointer<Void> scene, int part);

@Native<Pointer<Utf8> Function(Pointer<Void>, Int, Pointer<Double>)>(
  symbol: 'datum_part_material',
)
external Pointer<Utf8> datumPartMaterial(
  Pointer<Void> scene,
  int part,
  Pointer<Double> density,
);

@Native<UnsignedInt Function(Pointer<Void>, Int)>(symbol: 'datum_part_color')
external int datumPartColor(Pointer<Void> scene, int part);

@Native<Int Function(Pointer<Void>)>(symbol: 'datum_node_count')
external int datumNodeCount(Pointer<Void> scene);

@Native<Pointer<Utf8> Function(Pointer<Void>, Int)>(symbol: 'datum_node_name')
external Pointer<Utf8> datumNodeName(Pointer<Void> scene, int node);

@Native<Int Function(Pointer<Void>, Int)>(symbol: 'datum_node_parent')
external int datumNodeParent(Pointer<Void> scene, int node);

@Native<Int Function(Pointer<Void>, Int)>(symbol: 'datum_node_part')
external int datumNodePart(Pointer<Void> scene, int node);

@Native<Pointer<Double> Function(Pointer<Void>, Int)>(
  symbol: 'datum_node_matrix',
)
external Pointer<Double> datumNodeMatrix(Pointer<Void> scene, int node);

@Native<UnsignedInt Function(Pointer<Void>, Int)>(symbol: 'datum_node_color')
external int datumNodeColor(Pointer<Void> scene, int node);

@Native<Pointer<Utf8> Function(Pointer<Void>)>(symbol: 'datum_file_unit')
external Pointer<Utf8> datumFileUnit(Pointer<Void> scene);

@Native<Pointer<Utf8> Function(Pointer<Void>)>(symbol: 'datum_file_origin')
external Pointer<Utf8> datumFileOrigin(Pointer<Void> scene);

@Native<Pointer<Utf8> Function(Pointer<Void>)>(symbol: 'datum_file_schema')
external Pointer<Utf8> datumFileSchema(Pointer<Void> scene);

@Native<Int Function(Pointer<Void>, Int)>(symbol: 'datum_part_face_count')
external int datumPartFaceCount(Pointer<Void> scene, int part);

@Native<Pointer<Int32> Function(Pointer<Void>, Int)>(
  symbol: 'datum_part_face_of_triangle',
)
external Pointer<Int32> datumPartFaceOfTriangle(Pointer<Void> scene, int part);

@Native<Void Function(Pointer<Void>, Int, Int, Pointer<Double>)>(
  symbol: 'datum_part_face_info',
)
external void datumPartFaceInfo(
  Pointer<Void> scene,
  int part,
  int face,
  Pointer<Double> out,
);

@Native<LongLong Function(Pointer<Void>, Int)>(
  symbol: 'datum_part_edge_segment_count',
)
external int datumPartEdgeSegmentCount(Pointer<Void> scene, int part);

@Native<Pointer<Float> Function(Pointer<Void>, Int)>(
  symbol: 'datum_part_edge_segments',
)
external Pointer<Float> datumPartEdgeSegments(Pointer<Void> scene, int part);

@Native<Pointer<Int32> Function(Pointer<Void>, Int)>(
  symbol: 'datum_part_edge_of_segment',
)
external Pointer<Int32> datumPartEdgeOfSegment(Pointer<Void> scene, int part);

@Native<Int Function(Pointer<Void>, Int)>(symbol: 'datum_part_edge_count')
external int datumPartEdgeCount(Pointer<Void> scene, int part);

@Native<Void Function(Pointer<Void>, Int, Int, Pointer<Double>)>(
  symbol: 'datum_part_edge_info',
)
external void datumPartEdgeInfo(
  Pointer<Void> scene,
  int part,
  int edge,
  Pointer<Double> out,
);

@Native<Void Function(Pointer<Void>, Int, Pointer<Double>)>(
  symbol: 'datum_part_props',
)
external void datumPartProps(
  Pointer<Void> scene,
  int part,
  Pointer<Double> out,
);

@Native<
  Int Function(
    Pointer<Void>,
    Int,
    Int,
    Int,
    Pointer<Double>,
    Int,
    Int,
    Int,
    Pointer<Double>,
    Pointer<Double>,
  )
>(symbol: 'datum_distance')
external int datumDistance(
  Pointer<Void> scene,
  int partA,
  int kindA,
  int idxA,
  Pointer<Double> mA,
  int partB,
  int kindB,
  int idxB,
  Pointer<Double> mB,
  Pointer<Double> out,
);

@Native<Int Function(Pointer<Void>)>(symbol: 'datum_pmi_count')
external int datumPmiCount(Pointer<Void> scene);

@Native<Void Function(Pointer<Void>, Int, Pointer<Double>)>(
  symbol: 'datum_pmi_info',
)
external void datumPmiInfo(Pointer<Void> scene, int i, Pointer<Double> out);

@Native<Pointer<Utf8> Function(Pointer<Void>, Int)>(symbol: 'datum_pmi_text')
external Pointer<Utf8> datumPmiText(Pointer<Void> scene, int i);

@Native<Int Function(Pointer<Void>, Int)>(symbol: 'datum_pmi_ref_count')
external int datumPmiRefCount(Pointer<Void> scene, int i);

@Native<Void Function(Pointer<Void>, Int, Int, Pointer<Int32>)>(
  symbol: 'datum_pmi_ref',
)
external void datumPmiRef(
  Pointer<Void> scene,
  int i,
  int k,
  Pointer<Int32> out3,
);

@Native<LongLong Function(Pointer<Void>, Int)>(
  symbol: 'datum_pmi_segment_count',
)
external int datumPmiSegmentCount(Pointer<Void> scene, int i);

@Native<Pointer<Float> Function(Pointer<Void>, Int)>(
  symbol: 'datum_pmi_segments',
)
external Pointer<Float> datumPmiSegments(Pointer<Void> scene, int i);

// ---- Draco (glTF KHR_draco_mesh_compression)

@Native<Pointer<Void> Function(Pointer<Uint8>, UnsignedLong)>(symbol: 'datum_draco_decode')
external Pointer<Void> datumDracoDecode(Pointer<Uint8> data, int size);

@Native<Pointer<Utf8> Function()>(symbol: 'datum_draco_error')
external Pointer<Utf8> datumDracoError();

@Native<Int Function(Pointer<Void>)>(symbol: 'datum_draco_points')
external int datumDracoPoints(Pointer<Void> d);

@Native<Int Function(Pointer<Void>)>(symbol: 'datum_draco_faces')
external int datumDracoFaces(Pointer<Void> d);

@Native<Void Function(Pointer<Void>, Pointer<Uint32>)>(symbol: 'datum_draco_indices')
external void datumDracoIndices(Pointer<Void> d, Pointer<Uint32> out);

@Native<Int Function(Pointer<Void>, Int)>(symbol: 'datum_draco_attr_components')
external int datumDracoAttrComponents(Pointer<Void> d, int uniqueId);

@Native<Int Function(Pointer<Void>, Int, Pointer<Float>)>(symbol: 'datum_draco_attr')
external int datumDracoAttr(Pointer<Void> d, int uniqueId, Pointer<Float> out);

@Native<Void Function(Pointer<Void>)>(symbol: 'datum_draco_free')
external void datumDracoFree(Pointer<Void> d);

// ---- LAZ (LASzip)
@Native<Pointer<Void> Function(Pointer<Utf8>)>(symbol: 'datum_laz_open')
external Pointer<Void> datumLazOpen(Pointer<Utf8> path);

@Native<Pointer<Utf8> Function()>(symbol: 'datum_laz_error')
external Pointer<Utf8> datumLazError();

@Native<LongLong Function(Pointer<Void>)>(symbol: 'datum_laz_count')
external int datumLazCount(Pointer<Void> h);

@Native<Int Function(Pointer<Void>, Pointer<Uint8>, Int)>(symbol: 'datum_laz_read')
external int datumLazRead(Pointer<Void> h, Pointer<Uint8> out, int n);

@Native<Void Function(Pointer<Void>)>(symbol: 'datum_laz_free')
external void datumLazFree(Pointer<Void> h);
