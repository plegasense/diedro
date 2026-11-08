#pragma once
#include <string>
#include "profile.hpp"

namespace diedro {
// Lee un STEP y extrae el perfil de revolución dominante. En error, Profile::error describe el motivo.
Profile analyzeStep(const std::string& path);
std::vector<PmiDim> readPmi(const std::string& path, std::vector<GdtTol>* gdt = nullptr);
}
