// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Ruedas dentadas (engranajes, piñones de cadena, poleas dentadas): el dentado se mide en una sección perpendicular al eje y se dibuja
// como representación convencional (cuerpo hasta el Ø de cabeza, sin dientes); los datos de la rueda salen en una tabla.
#pragma once
#include <string>
#include "profile.hpp"

namespace diedro {
// true si la pieza es una rueda dentada (≥ 8 dientes periódicos); en ese caso p y d vienen rellenados. Si no, no toca nada.
extern bool gManyFree;   // la última pieza probada en layoutGear tenía >100 caras de forma libre (rosca)
bool layoutGear(const std::string& path, const Meta& meta, Profile& p, Drawing& d);
}
