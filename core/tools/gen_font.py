# Genera core/src/font_osifont.cpp desde osifont-gpl2fe.ttf: fuente incrustada + tabla Unicode -> glifo/ancho.
# Uso: python3 gen_font.py osifont-gpl2fe.ttf > ../src/font_osifont.cpp
import sys
from fontTools.ttLib import TTFont
p = sys.argv[1]
f = TTFont(p); cm = f.getBestCmap(); upm = f['head'].unitsPerEm; hm = f['hmtx']
data = open(p, 'rb').read()
gl = sorted((c, f.getGlyphID(n), round(hm[n][0] * 1000 / upm)) for c, n in cm.items() if c <= 0xFFFF)
bb = f['head']; asc = round(f['hhea'].ascent * 1000 / upm); dsc = round(f['hhea'].descent * 1000 / upm)
box = [round(v * 1000 / upm) for v in (bb.xMin, bb.yMin, bb.xMax, bb.yMax)]
print('// osifont-gpl2fe.ttf (GPL v2 con excepción de fuente; ver NOTICE). Generado por tools/gen_font.py, no editar.')
print('#include "font.hpp"\nnamespace diedro {')
print('const unsigned char kFontData[] = {' + ','.join(map(str, data)) + '};')
print('const unsigned kFontSize = %d;' % len(data))
print('const int kFontAscent = %d, kFontDescent = %d, kFontBBox[4] = {%d,%d,%d,%d};' % (asc, dsc, *box))
print('const Glyph kGlyphs[] = {' + ','.join('{%d,%d,%d}' % g for g in gl) + '};')
print('const unsigned kGlyphCount = %d;' % len(gl))
print('}')
