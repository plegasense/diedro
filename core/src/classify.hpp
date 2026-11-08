#pragma once
#include <string>
#include <utility>
#include <vector>
#include "profile.hpp"

namespace diedro {
// Grupo al que pertenece una pieza (numeración de docs/COBERTURA.md). 0 = sin clasificar.
// Datos de corte de un perfil (sección constante): solo se rellenan si ok
struct CutInfo {
    bool ok = false;
    double lenMax = 0, lenMin = 0;   // largo total (fibra más larga) y fibra más corta, mm
    double tilt[2][2] = {{0, 0}, {0, 0}};  // por extremo: inclinación (grados) del plano de corte respecto a la perpendicular, en los dos ejes de la sección
    double w = 0, h = 0;             // sección: ancho y alto envolventes, mm
    int planes = 0, wires = 0;       // caras planas laterales y contornos del extremo (2+ = hueco)
    bool round = false;              // sección redonda (tubo)
    double dOut = 0, dIn = 0;        // tubo redondo: Ø exterior e interior
    int kind = 0;                    // 0 constante, 1 macizo rectangular, 2 tubular, 3 L, 4 I/H, 5 U, 6 T, 7 redondo hueco
    double t1 = 0, t2 = 0;           // espesor menor (alma/pared) y mayor (ala), mm; 0 si no aplica
};
struct Classification {
    int group = 0;
    int alt = 0;          // grupo alternativo cuando la geometría no basta para decidir (0 = ninguno)
    double conf = 0;      // 0..1, margen respecto a los umbrales de la regla que decide
    std::string reason;   // por qué (medidas que activaron la regla)
    std::string error;
    CutInfo cut;
    int discard = 0;      // G15: 0 = se dibuja; 1 ilegible, 2 sin sólido, 3 chapa/lámina, 4 embutida (lata), 5 forma libre, 6 conjunto >400 piezas
    int nParts = 0;       // piezas independientes (solo se calcula si hay varios sólidos)
    std::vector<std::pair<std::string, double>> feat;  // características medidas, para revisar
};
const char* groupName(int g);
Classification classifyStep(const std::string& path);
// Motor de dibujo según el grupo (interno, el usuario no lo ve). Con confianza baja o grupo sin motor propio decide preferPrism.
bool chooseEnginePrism(const std::string& path, const Profile& p);
}
