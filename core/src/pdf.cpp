// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include <cmath>
#include <cstdio>
#include <map>
#include <sstream>
#include "drawing.hpp"
#include "font.hpp"

namespace diedro {
namespace {
const double kMmToPt = 72.0 / 25.4;

std::string num(double v) {
    char b[48];
    std::snprintf(b, sizeof b, "%.3f", v);
    return b;
}

std::string dash(LineType t) {
    switch (t) {
        case LineType::Hidden: return "[9 2.8] 0 d ";             // trazos (puntos PDF)
        case LineType::Center: return "[28 3.5 3.5 3.5] 0 d ";    // trazo-punto
        default: return "[] 0 d ";
    }
}

// UTF-8 -> cadena hexadecimal de glifos (Identity-H); registra los usados para /W
std::string hexGlyphs(const std::string& s, std::map<unsigned, std::pair<int, unsigned>>& used) {
    std::string o = "<";
    for (size_t i = 0; i < s.size();) {
        const Glyph* g = findGlyph(nextCp(s, i));
        if (!g) g = findGlyph('?');
        used[g->gid] = {g->w, g->cp};
        char b[8];
        std::snprintf(b, sizeof b, "%04X", g->gid);
        o += b;
    }
    return o + ">";
}

void arcPath(std::ostringstream& c, const Arc& a) {
    // Bézier cúbicas por tramos de <=90°
    double span = a.a1 - a.a0;
    while (span <= 0) span += 360;
    int n = (int)std::ceil(span / 90.0);
    double step = span / n * M_PI / 180.0, a0 = a.a0 * M_PI / 180.0;
    double k = 4.0 / 3.0 * std::tan(step / 4.0);
    for (int i = 0; i < n; i++) {
        double s = a0 + i * step, e = s + step;
        double x0 = a.cx + a.r * std::cos(s), y0 = a.cy + a.r * std::sin(s);
        double x3 = a.cx + a.r * std::cos(e), y3 = a.cy + a.r * std::sin(e);
        double x1 = x0 - k * a.r * std::sin(s), y1 = y0 + k * a.r * std::cos(s);
        double x2 = x3 + k * a.r * std::sin(e), y2 = y3 - k * a.r * std::cos(e);
        if (i == 0) c << num(x0 * kMmToPt) << ' ' << num(y0 * kMmToPt) << " m ";
        c << num(x1 * kMmToPt) << ' ' << num(y1 * kMmToPt) << ' ' << num(x2 * kMmToPt) << ' ' << num(y2 * kMmToPt) << ' '
          << num(x3 * kMmToPt) << ' ' << num(y3 * kMmToPt) << " c ";
    }
}
}  // namespace

std::string toPdf(const Drawing& d) { return toPdfMulti({d}); }

std::string toPdfMulti(const std::vector<Drawing>& pages) {
    std::map<unsigned, std::pair<int, unsigned>> used;
    std::vector<std::string> contents;
    for (const Drawing& d : pages) {
    std::ostringstream c;
    {   // a trazos: los segmentos encadenados (círculos teselados) van en un solo trazado para que el patrón no se reinicie en cada uno
        bool open = false; double ex = 0, ey = 0, ew = 0;
        for (const auto& l : d.lines) {
            const bool chain = open && l.type == LineType::Hidden && l.width == ew && std::fabs(l.x1 - ex) < 1e-6 && std::fabs(l.y1 - ey) < 1e-6;
            if (!chain) {
                if (open) c << "S\n";
                std::string dsh = dash(l.type);
                if (l.type == LineType::Hidden) {   // ISO 128-2 6.2.1: el trazado a trazos empieza y termina en trazo (no en hueco): se ajusta el paso al largo total
                    double len = 0, px = l.x1, py = l.y1;
                    for (size_t k = &l - &d.lines[0]; k < d.lines.size(); k++) {
                        const auto& m = d.lines[k];
                        if (k > (size_t)(&l - &d.lines[0]) && !(m.type == LineType::Hidden && m.width == l.width && std::fabs(m.x1 - px) < 1e-6 && std::fabs(m.y1 - py) < 1e-6)) break;
                        len += std::hypot(m.x2 - m.x1, m.y2 - m.y1); px = m.x2; py = m.y2;
                    }
                    len *= kMmToPt;
                    if (len > 11.8) {
                        const double n = std::max(1.0, std::round((len + 2.8) / 11.8)), sc = len / (11.8 * n - 2.8);
                        char b[64]; std::snprintf(b, sizeof b, "[%.3f %.3f] 0 d ", 9 * sc, 2.8 * sc); dsh = b;
                    }
                }
                c << num(l.width * kMmToPt) << " w " << dsh << num(l.x1 * kMmToPt) << ' ' << num(l.y1 * kMmToPt) << " m ";
            }
            c << num(l.x2 * kMmToPt) << ' ' << num(l.y2 * kMmToPt) << " l ";
            open = l.type == LineType::Hidden; ex = l.x2; ey = l.y2; ew = l.width;
            if (!open) c << "S\n";
        }
        if (open) c << "S\n";
    }
    for (const auto& a : d.arcs) {
        c << num(a.width * kMmToPt) << " w " << dash(a.type);
        arcPath(c, a);
        c << "S\n";
    }
    for (const auto& p : d.polys) {
        if (p.pts.size() < 3 || p.hatch > 0) continue;
        if (p.gray >= 0) c << num(p.gray) << " g " << num(p.gray) << " G 0.2 w ";
        else c << (p.white ? "1 g " : "0 g ");
        for (size_t i = 0; i < p.pts.size(); i++)
            c << num(p.pts[i].first * kMmToPt) << ' ' << num(p.pts[i].second * kMmToPt) << (i ? " l " : " m ");
        c << (p.gray >= 0 ? "b 0 g 0 G\n" : "f 0 g\n");
    }
    for (const auto& t : d.texts) {
        double pt = t.height * kMmToPt, r = t.angle * M_PI / 180.0;
        if (t.undefined) c << "1 0 0 rg ";  // rojo: dato no definido
        c << "BT /F1 " << num(pt) << " Tf " << num(std::cos(r)) << ' ' << num(std::sin(r)) << ' ' << num(-std::sin(r)) << ' '
          << num(std::cos(r)) << ' ' << num(t.x * kMmToPt) << ' ' << num(t.y * kMmToPt) << " Tm " << hexGlyphs(t.s, used) << " Tj ET";
        if (t.undefined) c << " 0 g";
        c << "\n";
    }
    contents.push_back(c.str());
    }

    // objetos: 1 catálogo, 2 páginas, 3-7 fuente, luego (página, contenido) por hoja
    const size_t np = pages.size();
    std::vector<std::string> obj(7 + 2 * np);
    std::string kids;
    for (size_t i = 0; i < np; i++) kids += std::to_string(8 + 2 * i) + " 0 R ";
    obj[0] = "<< /Type /Catalog /Pages 2 0 R >>";
    obj[1] = "<< /Type /Pages /Kids [" + kids + "] /Count " + std::to_string(np) + " >>";
    for (size_t i = 0; i < np; i++) {
        obj[7 + 2 * i] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + num(pages[i].sheetW * kMmToPt) + " " + num(pages[i].sheetH * kMmToPt) +
                         "] /Contents " + std::to_string(9 + 2 * i) + " 0 R /Resources << /Font << /F1 3 0 R >> >> >>";
        obj[8 + 2 * i] = "<< /Length " + std::to_string(contents[i].size()) + " >>\nstream\n" + contents[i] + "endstream";
    }
    std::string widths;
    std::string cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Adobe-Identity-UCS def /CMapType 2 def "
                       "1 begincodespacerange <0000> <FFFF> endcodespacerange\n" + std::to_string(used.size()) + " beginbfchar\n";
    for (auto& kv : used) {
        widths += std::to_string(kv.first) + " [" + std::to_string(kv.second.first) + "] ";
        char b[24];
        std::snprintf(b, sizeof b, "<%04X> <%04X>\n", kv.first, kv.second.second);
        cmap += b;
    }
    cmap += "endbfchar endcmap CMapName currentdict /CMap defineresource pop end end";
    obj[6] = "<< /Length " + std::to_string(cmap.size()) + " >>\nstream\n" + cmap + "\nendstream";
    obj[2] = "<< /Type /Font /Subtype /Type0 /BaseFont /Osifont /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>";
    obj[5] = "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Osifont /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
             "/FontDescriptor 4 0 R /CIDToGIDMap /Identity /DW 500 /W [" + widths + "] >>";
    obj[3] = "<< /Type /FontDescriptor /FontName /Osifont /Flags 4 /FontBBox [" + std::to_string(kFontBBox[0]) + " " + std::to_string(kFontBBox[1]) + " " +
             std::to_string(kFontBBox[2]) + " " + std::to_string(kFontBBox[3]) + "] /ItalicAngle 0 /Ascent " + std::to_string(kFontAscent) + " /Descent " +
             std::to_string(kFontDescent) + " /CapHeight 700 /StemV 80 /FontFile2 5 0 R >>";
    obj[4] = "<< /Length " + std::to_string(kFontSize) + " /Length1 " + std::to_string(kFontSize) + " >>\nstream\n" +
             std::string(reinterpret_cast<const char*>(kFontData), kFontSize) + "\nendstream";

    std::string out = "%PDF-1.4\n";
    std::vector<size_t> off;
    for (size_t i = 0; i < obj.size(); i++) {
        off.push_back(out.size());
        out += std::to_string(i + 1) + " 0 obj\n" + obj[i] + "\nendobj\n";
    }
    size_t xref = out.size();
    out += "xref\n0 " + std::to_string(obj.size() + 1) + "\n0000000000 65535 f \n";
    for (size_t o : off) {
        char b[24];
        std::snprintf(b, sizeof b, "%010zu 00000 n \n", o);
        out += b;
    }
    out += "trailer\n<< /Size " + std::to_string(obj.size() + 1) + " /Root 1 0 R >>\nstartxref\n" + std::to_string(xref) + "\n%%EOF\n";
    return out;
}
}  // namespace diedro
