// Piezas prismáticas (fresadas): tres vistas ISO (primer diedro), líneas ocultas, acotado por ordenadas desde la esquina de referencia.
#pragma once
#include <string>
#include "profile.hpp"

namespace diedro {
// ¿conviene el camino prismático? (el análisis de torneado falló o la pieza está dominada por rasgos que no son de revolución)
bool preferPrism(const Profile& p);
// Plano de una pieza prismática. En error, err describe el motivo y el dibujo viene vacío.
Drawing layoutPrism(const std::string& path, const Meta& meta, std::string& err);
}  // namespace diedro
