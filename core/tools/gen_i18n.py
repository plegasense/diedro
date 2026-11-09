#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) Plegasense
# Uso: gen_i18n.py i18n/strings.tsv  -> escribe core/src/i18n_table.{hpp,cpp} (filas scope=c)
import sys, csv
rows = list(csv.reader(open(sys.argv[1], encoding='utf8'), delimiter='\t'))
langs = rows[0][2:]  # sin scope ni es
core = [r for r in rows[1:] if r[0] == 'c']
q = lambda s: '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
base = sys.argv[0].rsplit('/', 2)[0] + '/src/'
open(base + 'i18n_table.hpp', 'w').write('#pragma once\nnamespace diedro {\nextern const char* const kLangs[];\nextern const int kLangCount;\nextern const char* const kRows[][%d];\nextern const unsigned kRowCount;\n}\n' % (len(langs) + 1))
with open(base + 'i18n_table.cpp', 'w', encoding='utf8') as f:
    f.write('// Generado por tools/gen_i18n.py desde i18n/strings.tsv; no editar.\n#include "i18n_table.hpp"\nnamespace diedro {\n')
    f.write('const char* const kLangs[] = {%s};\nconst int kLangCount = %d;\n' % (','.join(q(l) for l in langs), len(langs)))
    f.write('const char* const kRows[][%d] = {\n' % (len(langs) + 1))
    for r in core: f.write('{' + ','.join(q(c) for c in [r[1]] + r[2:]) + '},\n')
    f.write('};\nconst unsigned kRowCount = %d;\n}\n' % len(core))
