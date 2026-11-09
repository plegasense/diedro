// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#pragma once
#include <string>
namespace diedro {
// Texto de partida en español; en otro idioma busca su traducción (si falta, el inglés, y si no, el español).
std::string tr(const std::string& es, const std::string& lang);
bool decimalComma(const std::string& lang);
// Idiomas cuyo glifos trae la fuente del PDF (latino, vietnamita, cirílico, griego); el resto sale en inglés.
std::string pdfLang(const std::string& lang);
}
