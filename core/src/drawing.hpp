// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Modelo de plano de Diedro: independiente de OCCT. Unidades: mm en coordenadas de hoja (origen abajo-izquierda).
#pragma once
#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

namespace diedro {

enum class LineType { Continuous, Hidden, Center };

struct Line { double x1, y1, x2, y2; LineType type = LineType::Continuous; double width = 0.35; int g = -1; };  // g: grupo editable (vista) o -1 = fijo
struct Arc { double cx, cy, r, a0, a1; LineType type = LineType::Continuous; double width = 0.35; int g = -1; };  // grados, antihorario
struct Text { double x, y, height; std::string s; double angle = 0; bool undefined = false; int g = -1; };       // undefined = marcador «NO DEFINIDO»

struct Poly { std::vector<std::pair<double, double>> pts; bool white = false; double gray = -1; int g = -1; double hatch = 0; int hdir = 1, hid = -1; };  // hatch>0: contorno de una zona rayada (no se dibuja: solo se exporta como HATCH al DXF); paso en mm, hdir +1 = 45°, -1 = 135°; mismo hid = mismo HATCH (varios contornos, par-impar)  // gray>=0: relleno gris (vista sombreada)  // relleno: negro (flechas) o blanco (máscara de texto)

// Registro semántico de cada cota generada (para pruebas y para editar): kind = length|diameter|radius|chamfer
struct DimInfo { std::string kind; double value; std::string text; std::string key = ""; int axis = -1; };  // key: clave canónica (mm, punto) para tolerancias de usuario

struct ViewRef { int v; double o[2], e[3][2], box[4]; };  // vista -> hoja: imagen del origen y de los ejes X,Y,Z del STEP; caja de la vista
struct HoleRef { double x, y, p[3], a[3], dia; int v = -1; };  // agujero: centro en la hoja (mm), punto y eje en coordenadas del STEP, diámetro

struct Pos { size_t l, a, t, p; };  // posición en las listas de primitivas (para etiquetar lo dibujado después)

struct Drawing {
    std::vector<std::string> groups;   // nombres de los grupos editables (vistas); el índice es el campo g de cada primitiva
    Pos pos() const { return {lines.size(), arcs.size(), texts.size(), polys.size()}; }
    void tag(Pos s, int g) {   // todo lo añadido desde s pasa al grupo g
        for (size_t i = s.l; i < lines.size(); i++) lines[i].g = g;
        for (size_t i = s.a; i < arcs.size(); i++) arcs[i].g = g;
        for (size_t i = s.t; i < texts.size(); i++) texts[i].g = g;
        for (size_t i = s.p; i < polys.size(); i++) polys[i].g = g;
    }
    std::vector<HoleRef> holeRefs;
    std::vector<ViewRef> viewRefs;
    double sheetW = 297, sheetH = 210;  // A4 apaisado por defecto
    std::string sheetName = "A4";
    double scale = 1;                   // hoja = modelo * scale
    std::vector<Line> lines;
    std::vector<Arc> arcs;
    std::vector<Text> texts;
    std::vector<Poly> polys;
    std::vector<DimInfo> dims;
    size_t symL0 = 0, symL1 = 0, symA0 = 0, symA1 = 0; double symXc = 0; bool thirdDone = false;   // símbolo del método de proyección (projsym.hpp) y si ya se pasó a tercer diedro
    std::vector<std::string> warnings;  // limitaciones visibles también en el plano
    std::string label, kind;            // rótulo de la hoja y tipo (asm, cut, prism, turn) para la lista de hojas de la app
};

// M4: segmentos ocultos horizontales/verticales superpuestos en la misma recta (de distintas operaciones) se funden en uno:
// si no, los trazos de cada copia se rellenan entre sí y la línea oculta parece continua. Las demás líneas no cambian.
inline void mergeHidden(std::vector<Line>& ls) {
    std::map<std::tuple<int, long, long>, std::vector<size_t>> grp;
    for (size_t i = 0; i < ls.size(); i++) {
        const Line& l = ls[i];
        if (l.type != LineType::Hidden) continue;
        bool hz = std::fabs(l.y1 - l.y2) < 1e-6, vt = std::fabs(l.x1 - l.x2) < 1e-6;
        if (hz == vt) continue;
        grp[{hz ? 0 : 1, std::lround((hz ? l.y1 : l.x1) * 1000), std::lround(l.width * 1000)}].push_back(i);
    }
    std::vector<char> del(ls.size(), 0);
    for (auto& kv : grp) {
        auto& ix = kv.second;
        if (ix.size() < 2) continue;
        const bool hz = std::get<0>(kv.first) == 0;
        auto lo = [&](const Line& l) { return hz ? std::min(l.x1, l.x2) : std::min(l.y1, l.y2); };
        auto hi = [&](const Line& l) { return hz ? std::max(l.x1, l.x2) : std::max(l.y1, l.y2); };
        std::sort(ix.begin(), ix.end(), [&](size_t a, size_t b) { return lo(ls[a]) < lo(ls[b]); });
        size_t cur = ix[0];
        for (size_t k = 1; k < ix.size(); k++) {
            Line& c = ls[cur]; const Line& n = ls[ix[k]];
            if (lo(n) <= hi(c) + 1e-6) {   // se tocan o se solapan: se alarga el actual
                if (hi(n) > hi(c)) { if (hz) { c.x1 = lo(c); c.x2 = hi(n); } else { c.y1 = lo(c); c.y2 = hi(n); } }
                del[ix[k]] = 1;
            } else cur = ix[k];
        }
    }
    std::vector<Line> out;
    for (size_t i = 0; i < ls.size(); i++) if (!del[i]) out.push_back(ls[i]);
    ls.swap(out);
}

// PDF vectorial determinista (mismas entradas -> mismos bytes). Devuelve los bytes del archivo.
std::string toPdf(const Drawing& d);
// PDF de varias hojas (una por Drawing, cada una con su tamaño).
std::string toPdfMulti(const std::vector<Drawing>& pages);

// DXF R2000 (ASCII, con grosores y HATCH) y SVG de una hoja (docs/NORMAS_G9.md).
std::string toDxf(const Drawing& d, bool shade = false);   // shade: incluye el isométrico sombreado (capa SOMBREADO)
std::string toDxfMulti(const std::vector<Drawing>& pages, bool shade = false);   // todas las hojas en un DXF, una junto a otra
std::string toSvg(const Drawing& d, bool embedFont = true);

// Solapes de texto detectados geométricamente (vacío = legible).
std::vector<std::string> findOverlaps(const Drawing& d);

// Líneas paralelas a menos de 0,7 mm (ISO 128-2 6.1).
std::vector<std::string> parallelGaps(const Drawing& d);

void mergeNearParallel(Drawing& d);
void balanceViews(Drawing& d);   // centra vistas+isométrico en la zona libre

// El rótulo d.texts[idx] no toca otros textos ni líneas (salvo ejes y rayado).
bool textClear(const Drawing& d, size_t idx);

// Ediciones de usuario (una orden por línea, campos separados por TAB; ver edit.cpp) aplicadas a una copia del plano de la página `page`.
void applyEdits(Drawing& d, int page, const std::string& ops);
// Información para el editor: GRUPO, TEXTO, AGUJERO y VISTA (coordenadas de hoja en mm, y hacia arriba) y PUNTO (vértices para imán).
std::string editInfo(const Drawing& d, int page);

// JSON versionado del modelo de plano (formato 1).
std::string toJson(const Drawing& d);

}  // namespace diedro
