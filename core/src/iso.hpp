// Vista isométrica sombreada (solo ilustrativa, sin escala ni cotas) colocada en el mayor hueco libre de la hoja.
#pragma once
#include <string>
#include <array>
#include <vector>
#include <TopoDS_Shape.hxx>
#include "drawing.hpp"

namespace diedro {
struct IsoItem { TopoDS_Shape sh; int tone = 0; };  // tone: variación de gris para distinguir piezas contiguas
struct IsoResult { double box[4] = {0, 0, 0, 0}; std::vector<std::array<double, 4>> anchors; };  // caja de la isométrica en hoja; por pieza (tone): punto visible x, y y celdas visibles (tamaño en pantalla)
// obst: dibujo cuyo contenido cuenta como ocupado al buscar el hueco (por defecto d); margin: holgura mm entre la isométrica y el borde del hueco (globos)
bool addIso(Drawing& d, const std::vector<IsoItem>& items, double maxScale = 0, IsoResult* res = nullptr, const Drawing* obst = nullptr, double margin = 6);
bool addIsoStep(Drawing& d, const std::string& path);
}
