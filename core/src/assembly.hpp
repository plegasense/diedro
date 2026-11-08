// Conjuntos (G7): hoja de conjunto con globos y lista de piezas + una hoja por pieza única (cada una por clasificador y motor propio).
#pragma once
#include <string>
#include <vector>
#include "drawing.hpp"
#include "profile.hpp"

namespace diedro {
// tmpDir: carpeta de escritura para los STEP temporales de cada pieza. En error, err describe el motivo.
std::vector<Drawing> layoutAssembly(const std::string& path, const Meta& meta, const std::string& tmpDir, std::string& err, int knownParts = 0);
// Dibuja una pieza suelta (clasificador + motor). En error, err no queda vacío.
Drawing drawPart(const std::string& path, const Meta& meta, std::string& err);
}  // namespace diedro
