// G8: inspección con globos (estilo AS9102 Forma 3): un globo numerado por cota + tabla de características exportable.
#pragma once
#include <string>
#include <vector>
#include "drawing.hpp"
#include "profile.hpp"
namespace diedro {
struct InspRow { int n = 0; std::string kind, req, tol, view; int qty = 1; char cls = 0; double x = 0, y = 0; bool placed = false, tolUndef = false; };
// Añade a d un globo por cada cota (junto a su texto, fuera de otras primitivas) y devuelve las filas numeradas.
std::vector<InspRow> addBalloons(Drawing& d, const Meta& m);
// Hojas A4 con la tabla de características (Nº, requisito, tolerancia, vista, y columnas en blanco para resultados).
std::vector<Drawing> inspectionSheets(const Drawing& d, const std::vector<InspRow>& rows, const Meta& m);
// Tabla exportable (CSV con «;», UTF-8).
// Guarda la tolerancia de usuario quitando el sufijo de clase (!C/!M/!K) y anotándolo en m.cls
void setUserTol(Meta& m, const std::string& key, std::string v);
// Plano con globos + hojas de tabla; escribe el CSV en csvPath (si no está vacío)
std::vector<Drawing> withInspection(Drawing d, const Meta& m, const std::string& csvPath);
std::string inspectionCsv(const std::vector<InspRow>& rows, const std::string& lang);
}  // namespace diedro
