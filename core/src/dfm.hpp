// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// G12: revisión de fabricabilidad (DFM) para piezas fresadas. Solo avisos (medida y umbral); nunca toca el plano.
#pragma once
#include <string>
#include <vector>
namespace diedro {
std::vector<std::string> dfmCheck(const std::string& stepPath, const std::string& lang);
}
