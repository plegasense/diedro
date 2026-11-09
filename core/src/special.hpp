// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Muelles helicoidales (ISO 2162-1) y levas planas: motores propios; devuelven false si la pieza no encaja (no tocan d).
#pragma once
#include <TopoDS_Shape.hxx>
#include <string>
#include "profile.hpp"

namespace diedro {
struct Classification;
std::vector<std::string> discardText(const Classification& c, const Meta& meta);   // texto del aviso de descarte (app)
Drawing layoutDiscard(const Classification& c, const Meta& meta, const std::string& path);   // G15: hoja de aviso
bool readShapeCached(const std::string& path, TopoDS_Shape& S);   // lectura STEP con caché de un fichero
bool layoutSpring(const std::string& path, const Meta& meta, Drawing& d);
extern bool gCamStrict;
extern int gCamshaftMinLobes;
extern double gCamMinH;
bool layoutCam(const std::string& path, const Meta& meta, Drawing& d);
bool layoutCamshaft(const std::string& path, const Meta& meta, Drawing& d);
bool layoutHarness(const std::string& path, const Meta& meta, Drawing& d);   // G14: mazo ramificado
bool layoutPipe(const std::string& path, const Meta& meta, Drawing& d, bool cable = false);   // G13: tubo curvado
bool layoutCam3D(const std::string& path, const Meta& meta, Drawing& d);
}
