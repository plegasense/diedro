# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) Plegasense
"""Genera core/src/notice_paths.cpp: avisos G15 en ja/ko/zh/tw/th/hi como contornos vectoriales ya modelados (HarfBuzz) con Noto Sans (OFL).
La fuente del PDF (Osifont) solo cubre latino/cirílico/griego. Uso: python3 gen_notice_paths.py i18n/strings.tsv core/src/notice_paths.cpp
Requiere hb-shape (brew harfbuzz) y fontTools; las fuentes se leen de NOTO (OFL 1.1, redistribuibles)."""
import sys, subprocess, json, math
from fontTools.ttLib import TTFont
from fontTools.pens.basePen import BasePen
import os
NOTO = os.environ.get('DIEDRO_NOTO_DIR', 'noto').rstrip('/') + '/'  # carpeta con las fuentes Noto Sans (OFL 1.1)
LANGS = [('ja', NOTO + 'NotoSansCJK-Regular.ttc', 0, 'ja', True), ('ko', NOTO + 'NotoSansCJK-Regular.ttc', 1, 'ko', True),
         ('zh', NOTO + 'NotoSansCJK-Regular.ttc', 2, 'zh-hans', True), ('tw', NOTO + 'NotoSansCJK-Regular.ttc', 3, 'zh-hant', True),
         ('th', NOTO + 'NotoSansThai-Regular.ttf', 0, 'th', False), ('hi', NOTO + 'NotoSansDevanagari-VF.ttf', 0, 'hi', False)]
cols = open(sys.argv[1], encoding='utf-8').readline().rstrip('\n').split('\t')
rows = {}
for l in open(sys.argv[1], encoding='utf-8').read().split('\n')[1:]:
    f = l.split('\t')
    if len(f) == 22 and f[0] == 'c': rows[f[1]] = dict(zip(cols[1:], f[1:]))
KEYS = [k for k in rows if k.startswith(('PIEZA FUERA', 'Archivo', 'No se pudo leer el archivo STEP', 'El archivo no contiene', 'Chapa plegada o l', 'Pieza embutida de pared', 'Forma libre u org', 'Conjunto con m', 'Vuelve a exportar', 'Cierra las superficies', 'Usa una herramienta de chapa', 'Se necesita plano de embuti', 'Usa el modelo 3D', 'Divide el conjunto', 'Diedro no inventa cotas'))]
assert len(KEYS) == 15, len(KEYS)
class P(BasePen):
    def __init__(s, gs): super().__init__(gs); s.cs = []; s.c = None
    def _moveTo(s, p): s.c = [p]
    def _lineTo(s, p): s.c.append(p)
    def _curveToOne(s, a, b, p):
        p0 = s.c[-1]
        for i in range(1, 7):
            t = i / 6; u = 1 - t
            s.c.append((u**3*p0[0]+3*u*u*t*a[0]+3*u*t*t*b[0]+t**3*p[0], u**3*p0[1]+3*u*u*t*a[1]+3*u*t*t*b[1]+t**3*p[1]))
    def _qCurveToOne(s, a, p):
        p0 = s.c[-1]
        for i in range(1, 5):
            t = i / 4; u = 1 - t
            s.c.append((u*u*p0[0]+2*u*t*a[0]+t*t*p[0], u*u*p0[1]+2*u*t*a[1]+t*t*p[1]))
    def _closePath(s):
        if s.c and len(s.c) > 1: s.cs.append(s.c)
        s.c = None
    _endPath = _closePath
def dp(pts, tol):
    if len(pts) < 3: return pts
    a, b = pts[0], pts[-1]; dx, dy = b[0]-a[0], b[1]-a[1]; L = math.hypot(dx, dy) or 1e-9
    m, k = 0, 0
    for i in range(1, len(pts)-1):
        d = abs(dy*(pts[i][0]-a[0]) - dx*(pts[i][1]-a[1])) / L
        if d > m: m, k = d, i
    if m <= tol: return [a, b]
    return dp(pts[:k+1], tol)[:-1] + dp(pts[k:], tol)
FB = ('fb', NOTO + 'NotoSansCJK-Regular.ttc', 0, 'en', True)  # respaldo para caracteres que la fuente principal no cubre (latín, signos)
def run(lang, text):
    path, idx, hl, cjk = lang[1], lang[2], lang[3], lang[4]
    out = subprocess.run(['hb-shape', '--font-file=' + path, '--face-index=%d' % idx, '--language=' + hl, '--output-format=json', '--no-glyph-names', '--font-size=1000', '--unicodes=' + ','.join('U+%04X' % ord(ch) for ch in text)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)
def build(lang, text, limit):
    path, idx, cjk = lang[1], lang[2], lang[4]
    fonts = {}
    def F(l):
        if l[1:3] not in fonts:
            f = TTFont(l[1], fontNumber=l[2]); fonts[l[1:3]] = (f, f.getGlyphSet(), f.getGlyphOrder(), 1000.0 / f['head'].unitsPerEm, f.getBestCmap())
        return fonts[l[1:3]]
    cm = F(lang)[4]; cover = [ord(ch) in cm or ch == ' ' for ch in text]
    g = []; i = 0
    while i < len(text):
        j = i
        while j < len(text) and cover[j] == cover[i]: j += 1
        l2 = lang if cover[i] else FB
        for e in run(l2, text[i:j]): e['cl'] += i; e['f'] = l2; g.append(e)
        i = j
    # candidatos a corte: antes del glifo cuyo cluster empieza un carácter tras espacio (siempre) o cualquier carácter (CJK)
    x = 0; items = []
    for e in g:
        items.append((e['g'], x + e.get('dx', 0), e.get('dy', 0), e['ax'], e['cl'], e['f'])); x += e['ax']
    lines = []; start = 0
    def space_cl(cl): return text[cl] == ' '
    i = 0
    while start < len(items):
        j = start; last = None
        while j < len(items) and items[j][1] + items[j][3] - items[start][1] <= limit * 1000:
            if j + 1 < len(items) and (cjk or text[items[j+1][4]] == ' ' or text[items[j][4]] == ' ') and items[j+1][4] != items[j][4]: last = j + 1
            j += 1
        if j >= len(items): end = len(items)
        else: end = last if last and last > start else max(j, start + 1)
        lines.append(items[start:end]); start = end
    res = []
    for ln in lines:
        x0 = ln[0][1]; cs = []; w = 0
        for gid, x, dy, ax, cl, fl in ln:
            if text[cl] == ' ': continue
            _, gs, order, sc, _ = F(fl)
            p = P(gs); gs[order[gid]].draw(p)
            for c in p.cs:
                pts = [(int(round(((q[0]*sc) + x - x0))), int(round(q[1]*sc + dy))) for q in c]
                k = max(range(len(pts)), key=lambda i: (pts[i][0]-pts[0][0])**2 + (pts[i][1]-pts[0][1])**2)
                pts = dp(pts[:k+1], 4)[:-1] + dp(pts[k:] + [pts[0]], 4)[:-1]
                if len(pts) >= 3: cs.append(pts)
        w = max([p[0] for c in cs for p in c] or [0])
        res.append((w, cs))
    return res
out = ['// GENERADO por core/tools/gen_notice_paths.py (HarfBuzz + Noto Sans, OFL 1.1). No editar a mano.', '#include "notice_paths.hpp"', 'namespace diedro {']
tab = []
for li, lang in enumerate(LANGS):
    for si, key in enumerate(KEYS):
        text = rows[key][lang[0]]
        lim = 27 if si == 0 else (80 if si == 14 else 50)
        ls = build(lang, text, lim)
        names = []
        for k, (w, cs) in enumerate(ls):
            flat = []
            for c in cs: flat += [len(c)] + [v for p in c for v in p]
            nm = 'd%d_%d_%d' % (li, si, k)
            out.append('static const int %s[] = {%s};' % (nm, ','.join(map(str, flat))))
            names.append('{%s, %d, %d}' % (nm, len(flat), w))
        out.append('static const NoticeLine L%d_%d[] = {%s};' % (li, si, ','.join(names)))
        tab.append('{L%d_%d, %d}' % (li, si, len(ls)))
out.append('static const char* const kLangs[6] = {%s};' % ','.join('"%s"' % l[0] for l in LANGS))
out.append('static const char* const kKeys[15] = {%s};' % ','.join('"%s"' % k.replace('"', '\\"') for k in KEYS))
out.append('static const NoticeText kTab[6][15] = {%s};' % ','.join('{' + ','.join(tab[i*15:(i+1)*15]) + '}' for i in range(6)))
out.append('''const NoticeText* noticeText(const std::string& lang, const std::string& es) {
    for (int l = 0; l < 6; l++) if (lang == kLangs[l]) for (int k = 0; k < 15; k++) if (es == kKeys[k]) return &kTab[l][k];
    return nullptr;
}
}  // namespace diedro''')
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
print('ok', sum(len(o) for o in out) // 1024, 'KB')
