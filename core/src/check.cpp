// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include <cstdlib>
// Prueba geométrica de legibilidad: texto contra texto y texto contra líneas (salvo bajo su máscara blanca, ejes y rayado).
#include <algorithm>
#include <cmath>
#include <string>
#include <unordered_map>
#include "drawing.hpp"
#include "font.hpp"

namespace diedro {
namespace {
struct Box { double x0, y0, x1, y1; };
double textWidth(const std::string& s, double h) {
    static thread_local std::unordered_map<std::string, double> memo;   // anchura por milésima de altura: la búsqueda de glifos dominaba el tiempo de la prueba de solapes
    auto it = memo.find(s);
    if (it == memo.end()) {
        double w = 0;
        for (size_t i = 0; i < s.size();) { const Glyph* g = findGlyph(nextCp(s, i)); w += g ? g->w : 500; }
        if (memo.size() > 20000) memo.clear();
        it = memo.emplace(s, w).first;
    }
    return it->second / 1000.0 * h;
}
Box boxOf(const Text& t) {
    double w = textWidth(t.s, t.height), h = 0.72 * t.height;
    if (std::fabs(t.angle - 90) < 1) return {t.x - h, t.y, t.x, t.y + w};
    return {t.x, t.y, t.x + w, t.y + h};
}
bool segHitsBox(double ax, double ay, double bx, double by, const Box& b) {  // Liang–Barsky
    if (std::max(ax, bx) < b.x0 || std::min(ax, bx) > b.x1 || std::max(ay, by) < b.y0 || std::min(ay, by) > b.y1) return false;   // descarte rápido por caja
    double t0 = 0, t1 = 1, dx = bx - ax, dy = by - ay;
    double p[4] = {-dx, dx, -dy, dy}, q[4] = {ax - b.x0, b.x1 - ax, ay - b.y0, b.y1 - ay};
    for (int i = 0; i < 4; i++) {
        if (std::fabs(p[i]) < 1e-12) { if (q[i] < 0) return false; continue; }
        double r = q[i] / p[i];
        if (p[i] < 0) { if (r > t1) return false; t0 = std::max(t0, r); } else { if (r < t0) return false; t1 = std::min(t1, r); }
    }
    return t0 <= t1;
}
}  // namespace

std::vector<std::string> findOverlaps(const Drawing& d) {
    std::vector<std::string> out;
    std::vector<Box> bx;
    for (auto& t : d.texts) {
        Box b = boxOf(t);
        const double m = 0.25;  // holgura: el rótulo real es algo menor que la caja
        bx.push_back({b.x0 + m, b.y0 + m, b.x1 - m, b.y1 - m});
    }
    auto name = [&](size_t i) { return "«" + d.texts[i].s + "»"; };
    for (size_t i = 0; i < bx.size(); i++)
        for (size_t j = i + 1; j < bx.size(); j++)
            if (bx[i].x0 < bx[j].x1 && bx[j].x0 < bx[i].x1 && bx[i].y0 < bx[j].y1 && bx[j].y0 < bx[i].y1) out.push_back("texto-texto " + name(i) + " con " + name(j));
    for (size_t i = 0; i < bx.size(); i++) {
        bool masked = false;
        for (auto& p : d.polys) {
            if (!p.white || p.pts.size() != 4) continue;
            double x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
            for (auto& q : p.pts) { x0 = std::min(x0, q.first); x1 = std::max(x1, q.first); y0 = std::min(y0, q.second); y1 = std::max(y1, q.second); }
            masked |= x0 <= bx[i].x0 + 0.5 && y0 <= bx[i].y0 + 0.5 && x1 >= bx[i].x1 - 0.5 && y1 >= bx[i].y1 - 0.5;
        }
        if (masked) continue;
        for (auto& l : d.lines) {
            if (l.type == LineType::Center) continue;
            double dx = l.x2 - l.x1, dy = l.y2 - l.y1;
            if (std::fabs(std::fabs(dx) - std::fabs(dy)) < 1e-3 * (std::fabs(dx) + 1) && l.width < 0.3) continue;  // rayado a 45°
            const double ang = d.texts[i].angle; bool hit;
            if (std::fabs(ang) > 1 && std::fabs(ang - 90) > 1) {   // texto inclinado (cotas alineadas): se prueba contra su rectángulo girado, no contra la caja horizontal
                const double c = std::cos(-ang * M_PI / 180), sn = std::sin(-ang * M_PI / 180), ox = d.texts[i].x, oy = d.texts[i].y;
                auto rx = [&](double x, double y) { return c * (x - ox) - sn * (y - oy); }; auto ry = [&](double x, double y) { return sn * (x - ox) + c * (y - oy); };
                hit = segHitsBox(rx(l.x1, l.y1), ry(l.x1, l.y1), rx(l.x2, l.y2), ry(l.x2, l.y2), Box{0.25, 0.25, textWidth(d.texts[i].s, d.texts[i].height) - 0.25, 0.72 * d.texts[i].height - 0.25});
            } else hit = segHitsBox(l.x1, l.y1, l.x2, l.y2, bx[i]);
            if (hit) { out.push_back("texto-línea " + name(i) + (std::getenv("DIEDRO_DBG") ? " @" + std::to_string((int)d.texts[i].x) + "," + std::to_string((int)d.texts[i].y) + " ang" + std::to_string((int)d.texts[i].angle) : "")); break; }
        }
    }
    return out;
}

// ISO 128-2 6.1: líneas paralelas (visibles/ocultas, solapadas en proyección) a menos de 0,7 mm sin ser la misma línea.
std::vector<std::string> parallelGaps(const Drawing& d) {
    std::vector<std::string> out;
    const auto& L = d.lines;
    for (size_t i = 0; i < L.size(); i++) {
        if (L[i].type == LineType::Center) continue;
        double ax = L[i].x2 - L[i].x1, ay = L[i].y2 - L[i].y1, la = std::hypot(ax, ay);
        if (la < 1.0) continue;
        for (size_t j = i + 1; j < L.size(); j++) {
            if (L[j].type == LineType::Center) continue;
            double bx = L[j].x2 - L[j].x1, by = L[j].y2 - L[j].y1, lb = std::hypot(bx, by);
            if (lb < 1.0 || std::fabs(ax * by - ay * bx) > 1e-3 * la * lb) continue;
            if (std::fabs(std::fabs(ax) - std::fabs(ay)) < 1e-3 * (la) && (L[i].width < 0.3 || L[j].width < 0.3)) continue;  // rayado
            double ux = ax / la, uy = ay / la;
            double dist = std::fabs((L[j].x1 - L[i].x1) * -uy + (L[j].y1 - L[i].y1) * ux);
            if (dist < 0.05 || dist >= 0.7) continue;
            double t0 = (L[j].x1 - L[i].x1) * ux + (L[j].y1 - L[i].y1) * uy, t1 = (L[j].x2 - L[i].x1) * ux + (L[j].y2 - L[i].y1) * uy;
            double lo = std::max(0.0, std::min(t0, t1)), hi = std::min(la, std::max(t0, t1));
            if (hi - lo > 1.0) out.push_back("paralelas w" + std::to_string(L[i].width).substr(0, 4) + "/" + std::to_string(L[j].width).substr(0, 4) + " t" + std::to_string(int(L[i].type)) + std::to_string(int(L[j].type)) + " " + std::to_string(dist).substr(0, 4) + " mm en (" + std::to_string(int(L[i].x1)) + "," + std::to_string(int(L[i].y1)) + ")");
        }
    }
    return out;
}

// Quita, de cada par de líneas paralelas a menos de 0,7 mm, la de menor prioridad (oculta bajo visible; si son iguales, la más corta): p. ej. chaflán de 0,5 mm a 1:1, que la nota del plano declara.
void mergeNearParallel(Drawing& d) {
    auto& L = d.lines;
    std::vector<bool> kill(L.size(), false);
    for (size_t i = 0; i < L.size(); i++) {
        if (L[i].type == LineType::Center || kill[i]) continue;
        double ax = L[i].x2 - L[i].x1, ay = L[i].y2 - L[i].y1, la = std::hypot(ax, ay);
        if (la < 1.0) continue;
        for (size_t j = i + 1; j < L.size(); j++) {
            if (L[j].type == LineType::Center || kill[j] || kill[i]) continue;
            const bool hi = L[i].type == LineType::Hidden, hj = L[j].type == LineType::Hidden;
            const bool same = hi == hj && std::fabs(L[j].width - L[i].width) < 0.05 && (hi || L[i].width >= 0.2);
            const bool thinVsThick = hi == hj && !hi && std::fabs(L[j].width - L[i].width) >= 0.05 && std::min(L[i].width, L[j].width) < 0.3 && std::max(L[i].width, L[j].width) >= 0.4;
            if (!same && hi == hj && !thinVsThick) continue;  // cotas y líneas finas entre sí no se tocan
            double bx = L[j].x2 - L[j].x1, by = L[j].y2 - L[j].y1, lb = std::hypot(bx, by);
            if (lb < 1.0 || std::fabs(ax * by - ay * bx) > 1e-3 * la * lb) continue;
            double ux = ax / la, uy = ay / la;
            double dist = std::fabs((L[j].x1 - L[i].x1) * -uy + (L[j].y1 - L[i].y1) * ux);
            if (dist < 0.05 || dist >= 0.7) continue;
            double t0 = (L[j].x1 - L[i].x1) * ux + (L[j].y1 - L[i].y1) * uy, t1 = (L[j].x2 - L[i].x1) * ux + (L[j].y2 - L[i].y1) * uy;
            double ov = std::min(la, std::max(t0, t1)) - std::max(0.0, std::min(t0, t1));
            if (ov < 0.5 * std::min(la, lb)) continue;
            kill[hi != hj ? (hi ? i : j) : thinVsThick ? (L[i].width < L[j].width ? i : j) : (la < lb ? i : j)] = true;
        }
    }
    size_t k = 0;
    for (size_t i = 0; i < L.size(); i++) if (!kill[i]) L[k++] = L[i];
    L.resize(k);
}

bool textClear(const Drawing& d, size_t idx) {
    Box a = boxOf(d.texts[idx]);
    const double m = 0.25;
    a = {a.x0 + m, a.y0 + m, a.x1 - m, a.y1 - m};
    for (size_t j = 0; j < d.texts.size(); j++) {
        if (j == idx) continue;
        Box b = boxOf(d.texts[j]);
        if (a.x0 < b.x1 - m && b.x0 + m < a.x1 && a.y0 < b.y1 - m && b.y0 + m < a.y1) return false;
    }
    for (auto& l : d.lines) {
        if (l.type == LineType::Center) continue;
        double dx = l.x2 - l.x1, dy = l.y2 - l.y1;
        if (std::fabs(std::fabs(dx) - std::fabs(dy)) < 1e-3 * (std::fabs(dx) + 1) && l.width < 0.3) continue;
        if (segHitsBox(l.x1, l.y1, l.x2, l.y2, a)) return false;
    }
    return true;
}

}  // namespace diedro
