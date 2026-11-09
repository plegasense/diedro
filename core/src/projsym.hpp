// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#pragma once
#include "drawing.hpp"
#include <algorithm>
#include <cmath>
namespace diedro {
// ISO 128-30 Anexo A / ISO 5456-2: símbolo del método de proyección del primer diedro (tronco de cono a la izquierda,
// circunferencias concéntricas a la derecha). (x,y) = esquina inferior izquierda; alto 7, ancho ≈ 21.
inline bool gThirdAngle = false;   // método de proyección pedido por el usuario (ASME / ISO 128-30 Anexo B); false = primer diedro (ISO, por defecto)
inline void projSymbol(Drawing& d, double x, double y) {
    d.symL0 = d.lines.size(); d.symA0 = d.arcs.size();
    const double R = 3.5, r = 1.75, L = 9, cy = y + R, cx = x + L + 5 + R, w = 0.25;
    auto ln = [&](double a, double b, double c, double e, LineType t = LineType::Continuous) { d.lines.push_back({a, b, c, e, t, w}); };
    ln(x, cy - R, x + L, cy - r); ln(x + L, cy - r, x + L, cy + r); ln(x + L, cy + r, x, cy + R); ln(x, cy + R, x, cy - R);
    d.arcs.push_back({cx, cy, R, 0, 360, LineType::Continuous, w}); d.arcs.push_back({cx, cy, r, 0, 360, LineType::Continuous, w});
    ln(x - 1.5, cy, cx + R + 1.5, cy, LineType::Center);
    d.symL1 = d.lines.size(); d.symA1 = d.arcs.size(); d.symXc = x + 10.5;
}
// Tercer diedro (ISO 128-30 Anexo B / ISO 5456-2; ASME Y14.3): la planta va ENCIMA del alzado y la vista desde la izquierda a la IZQUIERDA
// (la desde la derecha, a la derecha). Solo recoloca los grupos de vista ya dibujados (cada vista conserva su contenido y sus cotas) y refleja
// el símbolo del método (circunferencias a la izquierda, cono a la derecha). Solo mueve lo que está en la posición de primer diedro.
// front/top/side = índices de grupo (-1 = no hay); extra = grupo que acompaña al perfil (sección A-A). Devuelve true si cambió algo.
inline bool thirdAngle(Drawing& d, int front, int top, int side, int extra = -1) {
    if (!gThirdAngle || d.thirdDone || front < 0) return false;
    struct B { double x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9; bool ok() const { return x1 > x0; } };
    auto box = [&](int g) {
        B b; if (g < 0) return b;
        auto ext = [&](double xa, double xb, double ya, double yb) { b.x0 = std::min(b.x0, std::min(xa, xb)); b.x1 = std::max(b.x1, std::max(xa, xb)); b.y0 = std::min(b.y0, std::min(ya, yb)); b.y1 = std::max(b.y1, std::max(ya, yb)); };
        for (auto& l : d.lines) if (l.g == g) ext(l.x1, l.x2, l.y1, l.y2);
        for (auto& a : d.arcs) if (a.g == g) ext(a.cx - a.r, a.cx + a.r, a.cy - a.r, a.cy + a.r);
        for (auto& t : d.texts) if (t.g == g) { const double w = 0.55 * t.height * t.s.size() * 0.6 + 0.2 * t.height; const double c = std::cos(t.angle * M_PI / 180), sn = std::sin(t.angle * M_PI / 180); ext(t.x, t.x + w * c - t.height * sn, t.y, t.y + w * sn + t.height * c); }
        return b;
    };
    auto mv = [&](int g, double dx, double dy, double xmin = -1e18) {   // xmin: solo lo que empieza a la derecha de xmin
        auto in = [&](double x) { return x >= xmin; };
        if (g < 0) return;
        for (auto& l : d.lines) if (l.g == g && in(std::min(l.x1, l.x2))) { l.x1 += dx; l.x2 += dx; l.y1 += dy; l.y2 += dy; }
        for (auto& a : d.arcs) if (a.g == g && in(a.cx - a.r)) { a.cx += dx; a.cy += dy; }
        for (auto& t : d.texts) if (t.g == g && in(t.x)) { t.x += dx; t.y += dy; }
        for (auto& p : d.polys) if (p.g == g && !p.pts.empty() && in(p.pts[0].first)) for (auto& q : p.pts) { q.first += dx; q.second += dy; }
        for (auto& h : d.holeRefs) if (h.v == g) { h.x += dx; h.y += dy; }
        for (auto& v : d.viewRefs) if (v.v == g) { v.o[0] += dx; v.o[1] += dy; v.box[0] += dx; v.box[2] += dx; v.box[1] += dy; v.box[3] += dy; }
    };
    const B F = box(front), T = box(top), S = box(side);
    const bool mvT = F.ok() && T.ok() && T.y1 <= F.y0 + 1 && T.x1 > F.x0 && T.x0 < F.x1;        // planta bajo el alzado (primer diedro)
    const bool mvS = F.ok() && S.ok() && S.x0 >= F.x1 - 1 && S.y1 > F.y0 && S.y0 < F.y1;         // perfil a la derecha del alzado (primer diedro)
    const double gv = mvT ? std::max(10.0, F.y0 - T.y1) : 0, gh = mvS ? std::max(10.0, S.x0 - F.x1) : 0;
    const double dxF = mvS ? (S.x1 - S.x0) + gh : 0;                                  // el alzado cede sitio al perfil por la izquierda
    const double dyT = mvT ? (F.y1 + gv) - T.y0 : 0;                                  // planta justo encima del alzado
    // la pila ocupaba [T.y0, F.y1]; ahora [F.y0, T.y1+dyT]: se sube/baja toda para conservar el borde superior
    const double oldTop = F.y1, newTop = mvT ? T.y1 + dyT : F.y1, dyAll = oldTop - newTop;
    const double sdx = mvS ? F.x0 - S.x0 : 0;                                          // perfil al borde izquierdo que ocupaba el alzado
    if (mvT || mvS) {
        mv(front, dxF, dyAll);
        if (mvT) mv(top, dxF, dyT + dyAll);
        if (mvS) { mv(side, sdx, dyAll); mv(extra, sdx, dyAll, F.x1 - 1); }   // el extra solo acompaña al perfil si está a su lado (no si es la axonométrica)
    }
    if (d.symL1 > d.symL0 || d.symA1 > d.symA0) {   // símbolo reflejado respecto de su eje vertical
        const double c2 = 2 * d.symXc;
        for (size_t i = d.symL0; i < d.symL1; i++) { d.lines[i].x1 = c2 - d.lines[i].x1; d.lines[i].x2 = c2 - d.lines[i].x2; }
        for (size_t i = d.symA0; i < d.symA1; i++) d.arcs[i].cx = c2 - d.arcs[i].cx;
    }
    d.thirdDone = true;
    return true;
}
}
