// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Datos de un proyecto 3MF que no son geometría: piezas, placas, filamentos y ajustes.
// Solo tipos simples para poder viajar entre isolates.

/// Un filamento (o material) del proyecto, 1-based.
class TmfFilament {
  TmfFilament(this.slot, this.color, {this.type = '', this.profile = ''});
  final int slot;
  final int color; // ARGB
  String type;
  String profile; // «Generic PLA @BBL A1M»
  double density = 0; // g/cm³ (0 = sin dato)
  double diameter = 1.75;
  int nozzleTemp = 0, bedTemp = 0;
  double cost = 0; // por kg
}

/// Rol de un volumen dentro de una pieza.
enum TmfRole {
  normal,
  modifier, // cambia ajustes en su zona
  negative, // vacía material
  blocker, // prohíbe soportes
  enforcer, // fuerza soportes
  other, // tipo «other»/«support» del núcleo 3MF
}

class TmfPartInfo {
  TmfPartInfo(this.name, this.role, this.extruder, this.triangles);
  final String name;
  final TmfRole role;
  final int extruder; // 0 = el de la pieza
  final int triangles;
  double volumeMm3 = 0;
}

/// Una pieza (objeto) del proyecto, con sus volúmenes y ajustes propios.
class TmfObjectInfo {
  TmfObjectInfo(this.index, this.name);
  final int index;
  String name;
  String id = '';
  int plate = -1; // índice de placa (0-based) o -1
  int extruder = 1;
  bool printable = true;
  String? partNumber;
  final parts = <TmfPartInfo>[];
  final overrides = <String, String>{};

  /// Caja envolvente en el espacio del proyecto (mm).
  List<double> min = [0, 0, 0], max = [0, 0, 0];

  /// Volumen por filamento (mm³, índice = slot, 0 = sin asignar).
  final volumeBySlot = <int, double>{};
  int triangles = 0;

  /// Índice del grupo en la lista de nodos de la escena.
  int node = -1;
  double get volumeMm3 => volumeBySlot.values.fold(0.0, (a, b) => a + b);
}

/// Consumo de un filamento en una placa laminada.
class TmfUse {
  TmfUse(this.slot, this.type, this.color, this.grams, this.meters);
  final int slot;
  final String type;
  final int color;
  final double grams, meters;
}

class TmfPlate {
  TmfPlate(this.index) : number = index + 1;
  int index; // posición en la lista (0-based)
  int number; // número que le da el programa («Placa 3»)
  String name = '';
  String? thumbnail; // ruta dentro del ZIP
  String? topView;
  String? gcodeEntry;
  final objects = <int>[]; // índices de TmfObjectInfo

  /// Origen de la placa en el espacio del proyecto (mm).
  double originX = 0, originY = 0;

  // Resultado del laminado (solo en proyectos laminados).
  bool sliced = false;
  double seconds = 0, grams = 0;
  bool supportUsed = false;
  bool outside = false;
  final uses = <TmfUse>[];
  int colorChanges = -1;
  int pauses = 0;
  double nozzle = 0;
  String? slicedLayers;
}

class ThreeMfProject {
  String application = '';
  String generator = ''; // «Bambu Studio», «PrusaSlicer»…
  String title = '', designer = '', description = '', license = '', copyright = '';
  String created = '', modified = '';
  String unit = 'millimeter';
  double unitToMm = 1;

  final filaments = <TmfFilament>[];
  final objects = <TmfObjectInfo>[];
  final plates = <TmfPlate>[];

  /// Ajustes legibles del proceso: clave → valor, ya traducidos al vocabulario del oficio.
  final settings = <String, String>{};
  String printer = '';
  String processName = '';
  double bedX = 0, bedY = 0, bedZ = 0; // 0 = sin dato
  double nozzle = 0;

  /// Fotos de portada, perfil y modelo (rutas en el ZIP).
  final pictures = <String>[];

  /// Extensiones y casos que se avisan al usuario.
  final notes = <String>[];
  final extensions = <String>{};
  bool hasGcode = false;

  /// Cambios de color manuales por altura (M600): altura mm.
  final colorChangeZ = <double>[];

  int get filamentsUsed => {
    for (final o in objects)
      for (final e in o.volumeBySlot.entries)
        if (e.key > 0 && e.value > 0) e.key,
  }.length;
  bool get sliced => plates.any((p) => p.sliced);
}

/// Proyecto 3MF de una escena abierta (clave: la escena).
final threeMfOf = Expando<ThreeMfProject>();
