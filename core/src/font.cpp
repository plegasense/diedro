// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include "font.hpp"
namespace diedro {
const Glyph* findGlyph(unsigned cp) {
    unsigned lo = 0, hi = kGlyphCount;
    while (lo < hi) {
        unsigned m = (lo + hi) / 2;
        if (kGlyphs[m].cp < cp) lo = m + 1; else hi = m;
    }
    if (lo < kGlyphCount && kGlyphs[lo].cp == cp) return &kGlyphs[lo];
    // sin glifo: letra base (turco, centroeuropeo…) en vez de «?»
    static const struct { unsigned from, to; } kBase[] = {{0x130, 'I'}, {0x131, 'i'}, {0x15E, 'S'}, {0x15F, 's'}, {0x11E, 'G'}, {0x11F, 'g'}, {0x10C, 'C'}, {0x10D, 'c'}, {0x160, 'S'}, {0x161, 's'}, {0x17D, 'Z'}, {0x17E, 'z'}, {0x141, 'L'}, {0x142, 'l'}, {0x158, 'R'}, {0x159, 'r'}, {0x11A, 'E'}, {0x11B, 'e'}, {0x147, 'N'}, {0x148, 'n'}, {0x15A, 'S'}, {0x15B, 's'}, {0x179, 'Z'}, {0x17A, 'z'}, {0x17B, 'Z'}, {0x17C, 'z'}, {0x106, 'C'}, {0x107, 'c'}, {0x104, 'A'}, {0x105, 'a'}, {0x118, 'E'}, {0x119, 'e'}};
    for (auto& b : kBase) if (b.from == cp) return findGlyph(b.to);
    return nullptr;
}
unsigned nextCp(const std::string& s, size_t& i) {
    unsigned char c = s[i++];
    if (c < 0x80) return c;
    const int n = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1;
    bool ok = c >= 0xC2 && c < 0xF5 && i + n <= s.size();
    for (int k = 0; ok && k < n; k++) ok = (s[i + k] & 0xC0) == 0x80;
    if (!ok) {  // byte suelto no UTF-8 (STEP antiguos en Latin-1/CP1254): se lee como CP1254
        switch (c) { case 0xD0: return 0x11E; case 0xDD: return 0x130; case 0xDE: return 0x15E; case 0xF0: return 0x11F; case 0xFD: return 0x131; case 0xFE: return 0x15F; default: return c; }
    }
    unsigned cp = c & (0x3F >> n);
    for (int k = 0; k < n; k++) cp = (cp << 6) | (s[i++] & 0x3F);
    return cp;
}
}
