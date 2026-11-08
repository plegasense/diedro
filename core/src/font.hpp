#pragma once
#include <string>
namespace diedro {
struct Glyph { unsigned short cp, gid; short w; };
extern const unsigned char kFontData[];
extern const unsigned kFontSize;
extern const int kFontAscent, kFontDescent, kFontBBox[4];
extern const Glyph kGlyphs[];
extern const unsigned kGlyphCount;
const Glyph* findGlyph(unsigned cp);                  // nullptr si la fuente no lo trae
unsigned nextCp(const std::string& s, size_t& i);     // siguiente punto de código de un UTF-8
}
