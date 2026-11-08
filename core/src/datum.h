// API en C del núcleo de Datum. Estable y mínima: la consume Dart por FFI.
#ifndef DATUM_H
#define DATUM_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define DATUM_API __declspec(dllexport)
#else
#define DATUM_API __attribute__((visibility("default"))) __attribute__((used))
#endif

typedef struct DatumScene DatumScene;

// Abre un STEP (o IGES/BREP) y lo tesela. Devuelve NULL si falla; entonces
// datum_last_error() describe el motivo.
// rel_deflection: error de teselado relativo al tamaño del modelo (p. ej. 0.001).
/* Milisegundos de la última lectura: lectura, conversión, árbol, teselado, anotaciones. */
DATUM_API void datum_cad_timing(double* out5);
/* Lectura ligera: sin capas, propiedades, materiales ni anotaciones (más rápida). */
DATUM_API void datum_cad_set_lean(int lean);
DATUM_API void datum_cad_set_nomesh(int nomesh);  // no tesela ni lee anotaciones: solo formas, árbol, nombres y materiales
/* Archivo de caché del documento convertido para la próxima apertura (solo la llamada siguiente). */
DATUM_API void datum_cad_set_cache_file(const char* path);
DATUM_API DatumScene* datum_cad_open(const char* path, double rel_deflection);
DATUM_API const char* datum_last_error(void);
DATUM_API void datum_scene_free(DatumScene* s);

// Piezas únicas (geometría teselada, vértices intercalados: x y z nx ny nz).
DATUM_API int datum_part_count(const DatumScene* s);
DATUM_API const char* datum_part_name(const DatumScene* s, int part);
/* Material declarado en el archivo: nombre ('' si no hay) y densidad en g/cm³ (0 = sin dato). */
DATUM_API const char* datum_part_material(const DatumScene* s, int part, double* density_g_cm3);
DATUM_API long long datum_part_vertex_count(const DatumScene* s, int part);
DATUM_API const float* datum_part_vertices(const DatumScene* s, int part);
DATUM_API unsigned int datum_part_color(const DatumScene* s, int part);  // 0xAARRGGBB, 0 = sin color

// Árbol de ensamblaje, en orden de recorrido (el padre siempre va antes que el hijo).
DATUM_API int datum_node_count(const DatumScene* s);
DATUM_API const char* datum_node_name(const DatumScene* s, int node);
DATUM_API int datum_node_parent(const DatumScene* s, int node);  // -1 = raíz
DATUM_API int datum_node_part(const DatumScene* s, int node);    // -1 = grupo
DATUM_API const double* datum_node_matrix(const DatumScene* s, int node);  // 16, column-major
DATUM_API unsigned int datum_node_color(const DatumScene* s, int node);

// Diedro: guarda la pieza única (B-rep en su sistema local) como STEP. 1 si va bien.
DATUM_API int datum_part_export_step(const DatumScene* s, int part, const char* path);

// Unidad de longitud que declara el archivo ("MM", "INCH", "METRE"…) y datos de cabecera.
// La geometría siempre llega en milímetros.
DATUM_API const char* datum_file_unit(const DatumScene* s);
DATUM_API const char* datum_file_origin(const DatumScene* s);
DATUM_API const char* datum_file_schema(const DatumScene* s);

// Caras de cada pieza: cara a la que pertenece cada triángulo y su descripción.
// face_info (14 valores): tipo (0 otra, 1 plano, 2 cilindro, 3 cono, 4 esfera, 5 toro), área, radio,
// radio menor o semiángulo, punto (3), eje (3), longitud, barrido angular, cóncava (1 = agujero).
DATUM_API int datum_part_face_count(const DatumScene* s, int part);
DATUM_API const int* datum_part_face_of_triangle(const DatumScene* s, int part);
DATUM_API void datum_part_face_info(DatumScene* s, int part, int face, double* out14);

// Aristas vivas: segmentos (6 floats) y a qué arista pertenece cada uno.
// edge_info (15): tipo (0 otra, 1 recta, 2 círculo, 3 arco), longitud, radio, centro (3), eje (3), inicio (3), fin (3).
DATUM_API long long datum_part_edge_segment_count(const DatumScene* s, int part);
DATUM_API const float* datum_part_edge_segments(const DatumScene* s, int part);
DATUM_API const int* datum_part_edge_of_segment(const DatumScene* s, int part);
DATUM_API int datum_part_edge_count(const DatumScene* s, int part);
DATUM_API void datum_part_edge_info(const DatumScene* s, int part, int edge, double* out15);

// Volumen, área, centro de masas y, si el archivo los trae, volumen y área de validación.
DATUM_API void datum_part_props(DatumScene* s, int part, double* out8);

// Distancia mínima entre dos entidades (kind 0 = cara, 1 = arista) colocadas con sus matrices (16, columnas).
DATUM_API int datum_distance(const DatumScene* s, int part_a, int kind_a, int idx_a, const double* m_a, int part_b,
                             int kind_b, int idx_b, const double* m_b, double* out7);

// Anotaciones del archivo (PMI semántico y gráfico).
// pmi_info (16): clase (0 cota, 1 tolerancia, 2 referencia), tipo (enumeración de OCCT), valor,
// tolerancia superior / límite superior, inferior, indicador (1 ± , 2 rango), calificador,
// tipo de valor de la tolerancia, modificador de material, modificador de zona, punto del texto (3), 4 libres.
// pmi_text: letras de las referencias de una tolerancia (A|B|C), nombre de una referencia o nombre semántico.
DATUM_API int datum_pmi_count(const DatumScene* s);
DATUM_API void datum_pmi_info(const DatumScene* s, int i, double* out16);
DATUM_API const char* datum_pmi_text(const DatumScene* s, int i);
DATUM_API int datum_pmi_ref_count(const DatumScene* s, int i);
DATUM_API void datum_pmi_ref(const DatumScene* s, int i, int k, int* out3);  // pieza, 0 cara / 1 arista, índice
DATUM_API long long datum_pmi_segment_count(const DatumScene* s, int i);
DATUM_API const float* datum_pmi_segments(const DatumScene* s, int i);

// Mallas Draco (glTF KHR_draco_mesh_compression). Devuelve null si no se puede descomprimir
// (datum_draco_error da el motivo).
typedef struct DatumDraco DatumDraco;
DATUM_API DatumDraco* datum_draco_decode(const unsigned char* data, unsigned long size);
DATUM_API const char* datum_draco_error(void);
DATUM_API int datum_draco_points(const DatumDraco* d);
DATUM_API int datum_draco_faces(const DatumDraco* d);
/* 3 índices por cara (puntos de Draco). */
DATUM_API void datum_draco_indices(const DatumDraco* d, unsigned int* out);
DATUM_API int datum_draco_attr_components(const DatumDraco* d, int unique_id);
/* Valores del atributo por punto como float (puntos × componentes); devuelve las componentes o 0. */
DATUM_API int datum_draco_attr(const DatumDraco* d, int unique_id, float* out);
DATUM_API void datum_draco_free(DatumDraco* d);

// Lectura de LAZ (LAS comprimido) con LASzip (Apache-2.0). Devuelve null si falla (datum_laz_error
// da el motivo). Cada registro sale en formato LAS sin comprimir, con la longitud de la cabecera.
typedef struct DatumLaz DatumLaz;
DATUM_API DatumLaz* datum_laz_open(const char* path);
DATUM_API const char* datum_laz_error(void);
DATUM_API long long datum_laz_count(const DatumLaz* h);
/* Lee hasta n registros en out (n × longitud de registro); devuelve los leídos. */
DATUM_API int datum_laz_read(DatumLaz* h, unsigned char* out, int n);
DATUM_API void datum_laz_free(DatumLaz* h);

#ifdef __cplusplus
}
#endif
#endif
