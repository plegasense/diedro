// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Perfil de revolución de una pieza torneada: semiplano (z axial, r radial >= 0). Independiente de OCCT.
#pragma once
#include <map>
#include <string>
#include <vector>
#include "drawing.hpp"

namespace diedro {

struct Seg {
    enum Kind { Line, Arc, Plane } kind = Line;  // Line = cilindro o cono; Plane = cara perpendicular al eje
    bool inner = false;                          // true = superficie interior (taladro)
    bool brk = false;                            // solo vistas de detalle: borde de corte (línea fina), no una cara real
    double z0 = 0, r0 = 0, z1 = 0, r1 = 0;       // extremos (z0 <= z1; en Plane r0 < r1)
    double cz = 0, cr = 0, rad = 0, mz = 0, mr = 0;  // solo Arc: centro, radio y punto medio
};

// Taladro paralelo al eje (no coaxial): etapas escalonadas (avellanado/alojamiento) en la misma posición.
struct HoleStage { double r = 0, z0 = 0, z1 = 0; bool blind = false; };
struct HoleSite { double x = 0, y = 0; std::vector<HoleStage> st; };  // x,y: posición respecto al eje en la vista desde +z

// Taladro radial (eje perpendicular al eje de la pieza y concurrente con él). ang: dirección de apertura en el plano de la sección.
struct RadHole { double z = 0, ang = 0, r = 0, depth = 0; bool through = false; };
// Plano paralelo al eje (plano de llave) o chavetero/ranura (slot=true: dos paredes y suelo). h: distancia del suelo al eje; w: ancho.
struct HexSocket { double af = 0, z0 = 0, z1 = 0; };   // hueco hexagonal coaxial: llave af (entre caras), z0..z1
struct Cut { bool slot = false; double ang = 0, h = 0, w = 0, z0 = 0, z1 = 0, rin = 0; };  // rin>0: chavetero del agujero (radio del agujero); h = distancia del eje al fondo

// Cota con tolerancia declarada en el PMI del STEP (desviaciones en mm; lower normalmente negativo)
struct GdtTol { int type = 0; double value = 0; std::string datums; bool hasPt = false, hasDir = false; double pt[3] = {0, 0, 0}, dir[3] = {0, 0, 0}; };  // pt/dir: cara referida en coordenadas globales del STEP   // tolerancia geométrica declarada en el STEP
struct PmiDim { bool diameter = false, radius = false; double value = 0, upper = 0, lower = 0; };

struct Profile {
    std::vector<RadHole> rholes;
    std::vector<Cut> cuts;
    std::vector<std::string> extraNotes;         // notas ya redactadas (p. ej. datos de la rueda dentada), se añaden a las notas del plano
    std::vector<HexSocket> hexes;
    std::vector<HoleSite> sites;
    std::vector<Seg> segs;
    double rootR = 0, rootZ0 = 0, rootZ1 = 0;     // rueda dentada: radio de pie medido y zona dentada (línea fina del pie, ISO 128-24; decisión propia al faltar ISO 2203)
    int faceTeeth = 0; double faceAng0 = 0, faceRi = 0;   // dentado frontal (Hirth): nº de dientes, ángulo de una cresta y radio interior de las aristas radiales (vista del extremo)
    double length = 0;                           // z va de 0 a length (cara de referencia en z=0)
    std::map<std::string, int> unsupported;     // rasgos no de revolución detectados (texto -> nº de caras)
    bool thread = false;
    double threadExtD = 0;   // Ø de cresta de una rosca exterior helicoidal no modelada (0 = no hay)                         // rosca helicoidal interior no modelada (superficies B-spline coaxiales)
    double unsupArea = 0, totArea = 0, rShape = 0;           // área de caras no de revolución y total (mm²)
    std::vector<GdtTol> gdt;                      // tolerancias geométricas (forma/posición) que trae el STEP
    std::vector<PmiDim> pmi;                     // tolerancias que trae el propio archivo; nunca se infieren
    std::string error;                           // vacío si el análisis fue correcto
};

// Datos de cajetín que el STEP no trae. Vacío = «NO DEFINIDO» visible.
struct Meta {
    std::string title, partNo, material, generalTolerance;
    std::map<std::string, std::string> tols;  // tolerancia introducida por el usuario por cota (clave canónica en mm con punto, p. ej. "Ø30")
    std::string langUi = "";                  // idioma pedido sin reducir (ja, th... que el PDF no tiene en fuente)
    std::string lang = "es";                  // idioma del texto del plano (código de i18n/strings.tsv)
    std::string sheet;                        // formato elegido ("A4"…"A0"); vacío = automático
    bool imperial = false;                    // cotas en pulgadas (el modelo sigue en mm)
    bool inspect = false;                     // G8: globos numerados + tabla de inspección (AS9102)
    std::map<std::string, char> cls;          // G8: clase marcada por el usuario por cota: 'C' crítica, 'M' mayor, 'K' clave (sufijo !C/!M/!K de la tolerancia)
    bool explode = false;                     // conjuntos: la isométrica sale explosionada (capas separadas a lo largo de un eje)
};

Drawing layout(const Profile& p, const Meta& m);

}  // namespace diedro
