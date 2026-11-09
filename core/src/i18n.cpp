// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include "i18n.hpp"
#include <cstring>
#include "i18n_table.hpp"
namespace diedro {
std::string tr(const std::string& es, const std::string& lang) {
    if (lang == "es") return es;
    int col = -1;
    for (int i = 0; i < kLangCount; i++) if (lang == kLangs[i]) col = i;
    if (col < 0) col = 0;  // inglés
    for (unsigned i = 0; i < kRowCount; i++)
        if (es == kRows[i][0]) { const char* t = kRows[i][1 + col]; if (!*t) t = kRows[i][1]; return *t ? t : es; }
    return es;
}
bool decimalComma(const std::string&) { return true; }   // ISO 129-1 4.? : marcador decimal siempre coma, en cualquier idioma
std::string pdfLang(const std::string& l) {
    static const char* nopdf[] = {"ja", "ko", "zh", "tw", "th", "hi"};
    for (auto d : nopdf) if (l == d) return "en";
    return l;
}
}
