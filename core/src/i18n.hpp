// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#pragma once
#include <atomic>
#include <string>
#include <cstdio>
#include <cmath>
namespace diedro {
// Texto de partida en español; en otro idioma busca su traducción (si falta, el inglés, y si no, el español).
std::string tr(const std::string& es, const std::string& lang);
inline std::atomic<bool> gImperialUnits{false};   // M1: unidades imperiales -> punto decimal (ASME Y14.5 §1.4)
bool decimalComma(const std::string& lang);
// ASME Y14.5-2018 §4.3.2(a): en pulgadas no se escribe el cero antes del punto decimal si el valor es < 1 («.5», «-.25»).
inline std::string noLead0(std::string s) {
    size_t i = (!s.empty() && s[0] == '-') ? 1 : 0;
    if (s.compare(i, 2, "0.") == 0) s.erase(i, 1);
    return s;
}
// Idiomas cuyo glifos trae la fuente del PDF (latino, vietnamita, cirílico, griego); el resto sale en inglés.
std::string pdfLang(const std::string& lang);
// Longitud en pulgadas: 3 decimales fijos (ASME Y14.5-2018 §4.3.2(b): el nº de decimales no varía de una cota a otra), sin cero inicial, sin «-0».
inline std::string fmtIn(double mm) {
    char b[32]; std::snprintf(b, sizeof b, "%.3f", mm / 25.4);
    std::string s = noLead0(b);
    return (s == "-.000") ? ".000" : s;
}
}
