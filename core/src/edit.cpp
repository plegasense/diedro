// Edición de planos: órdenes de usuario (una por línea, campos con TAB) aplicadas sobre el plano generado.
// El generador no cambia: las ediciones se guardan en el proyecto y se reaplican tras cada generación (los índices
// de grupo y de texto son estables porque la generación es determinista).
//   M p g dx dy      mover el grupo g (mm)            S p g k          escalar el grupo g respecto a su centro
//   H p g            ocultar el grupo g               T p i texto      cambiar el texto i
//   TM p i dx dy     mover el texto i                 TD p i           borrar el texto i
//   AT p x y h txt   añadir texto                     AL p x1 y1 x2 y2 tipo   añadir línea (tipo 0 continua, 1 oculta, 2 eje)
//   AA p x1 y1 x2 y2 txt   nota con flecha en (x1,y1)  AD p x1 y1 x2 y2 off txt   cota alineada con desplazamiento off
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <sstream>
#include "drawing.hpp"
#include "font.hpp"

namespace diedro {
namespace {
std::vector<std::string> split(const std::string& s) {
    std::vector<std::string> r;
    size_t a = 0;
    for (;;) {
        size_t b = s.find('\t', a);
        r.push_back(s.substr(a, b == std::string::npos ? b : b - a));
        if (b == std::string::npos) break;
        a = b + 1;
    }
    return r;
}
double num(const std::vector<std::string>& f, size_t i) {   // valores de un .diedro ajeno: sin NaN/inf ni magnitudes absurdas
    if (i >= f.size()) return 0;
    const double v = std::atof(f[i].c_str());
    return std::isfinite(v) ? std::max(-1e6, std::min(1e6, v)) : 0;
}

double tw(const std::string& s, double h) {
    double w = 0;
    for (size_t i = 0; i < s.size();) { const Glyph* g = findGlyph(nextCp(s, i)); w += g ? g->w : 500; }
    return w / 1000.0 * h;
}

struct Box {
    double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
    bool ok() const { return x1 >= x0; }
    void add(double x, double y) { x0 = std::min(x0, x); y0 = std::min(y0, y); x1 = std::max(x1, x); y1 = std::max(y1, y); }
};

void textBox(const Text& t, Box& b) {
    const double w = tw(t.s, t.height), c = std::cos(t.angle * M_PI / 180), s = std::sin(t.angle * M_PI / 180);
    b.add(t.x, t.y); b.add(t.x + w * c, t.y + w * s);
    b.add(t.x - t.height * s, t.y + t.height * c); b.add(t.x + w * c - t.height * s, t.y + w * s + t.height * c);
}

bool visibleText(const Text& t) { return !t.s.empty(); }

Box groupBox(const Drawing& d, int g) {
    Box b;
    for (auto& l : d.lines) if (l.g == g) { b.add(l.x1, l.y1); b.add(l.x2, l.y2); }
    for (auto& a : d.arcs) if (a.g == g) { b.add(a.cx - a.r, a.cy - a.r); b.add(a.cx + a.r, a.cy + a.r); }
    for (auto& t : d.texts) if (t.g == g && visibleText(t)) textBox(t, b);
    for (auto& p : d.polys) if (p.g == g) for (auto& q : p.pts) b.add(q.first, q.second);
    return b;
}

void arrowAt(Drawing& d, int g, double x, double y, double dx, double dy) {   // punta en (x,y), cuerpo hacia (dx,dy)
    const double n = std::hypot(dx, dy);
    if (n < 1e-9) return;
    dx /= n; dy /= n;
    const double L = 3.0, W = 0.6;
    Poly p;
    p.pts = {{x, y}, {x + dx * L - dy * W, y + dy * L + dx * W}, {x + dx * L + dy * W, y + dy * L - dx * W}};
    p.g = g;
    d.polys.push_back(p);
}

void addLine(Drawing& d, int g, double x1, double y1, double x2, double y2, double w, LineType t) {
    Line l{x1, y1, x2, y2, t, w};
    l.g = g;
    d.lines.push_back(l);
}

int newGroup(Drawing& d, const char* name) { d.groups.push_back(name); return (int)d.groups.size() - 1; }

void textAlong(Drawing& d, int g, double mx, double my, double ang, double h, const std::string& s) {   // centrado sobre (mx,my), por encima
    while (ang > 90) ang -= 180;
    while (ang <= -90) ang += 180;
    const double c = std::cos(ang * M_PI / 180), sn = std::sin(ang * M_PI / 180), w = tw(s, h);
    Text t{0, 0, h, s, ang, false};
    t.x = mx - w / 2 * c + (-sn) * 1.0;
    t.y = my - w / 2 * sn + c * 1.0;
    t.g = g;
    d.texts.push_back(t);
}

void moveGroup(Drawing& d, int g, double dx, double dy) {
    for (auto& l : d.lines) if (l.g == g) { l.x1 += dx; l.x2 += dx; l.y1 += dy; l.y2 += dy; }
    for (auto& a : d.arcs) if (a.g == g) { a.cx += dx; a.cy += dy; }
    for (auto& t : d.texts) if (t.g == g) { t.x += dx; t.y += dy; }
    for (auto& p : d.polys) if (p.g == g) for (auto& q : p.pts) { q.first += dx; q.second += dy; }
    for (auto& h : d.holeRefs) if (h.v == g) { h.x += dx; h.y += dy; }
    for (auto& v : d.viewRefs) if (v.v == g) { v.o[0] += dx; v.o[1] += dy; v.box[0] += dx; v.box[2] += dx; v.box[1] += dy; v.box[3] += dy; }
}

}  // namespace
// Composición: coloca los bloques de vistas (grupos editables; la isométrica por separado) maximizando la métrica K de ocupación
// (hueco vacío mayor, caja envolvente y equilibrio de masa; pruebas/verifica_espacio.py) sin tocar lo fijo ni solapar bloques.
void balanceViews(Drawing& d) {
    const double W = d.sheetW, H = d.sheetH, CS = 5;
    struct R { double x0, y0, x1, y1; };
    typedef std::vector<std::pair<double, double>> Pts;
    const double INF = 1e9;
    const int ng = (int)d.groups.size();
    if (ng == 0) return;
    const int iso = d.groups.back() == "Isométrica" ? ng - 1 : -1;
    std::vector<int> blk(ng, 0);
    if (iso >= 0) blk[iso] = 1;
    const int nb = iso >= 0 ? 2 : 1;
    std::vector<R> bb(nb, R{INF, INF, -INF, -INF});
    std::vector<Pts> pm(nb);
    Pts pf;
    std::vector<R> obst;
    auto grow = [](R& r, double x, double y) { r.x0 = std::min(r.x0, x); r.x1 = std::max(r.x1, x); r.y0 = std::min(r.y0, y); r.y1 = std::max(r.y1, y); };
    auto samp = [&](Pts& v, double x1, double y1, double x2, double y2) {
        int n = std::max(1, (int)(std::hypot(x2 - x1, y2 - y1) / 2));
        for (int i = 0; i <= n; i++) v.push_back({x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n});
    };
    auto P = [&](int g) -> Pts& { return g >= 0 ? pm[blk[std::min(g, ng - 1)]] : pf; };
    auto B = [&](int g) -> R& { return bb[blk[std::min(g, ng - 1)]]; };
    for (auto& l : d.lines) {
        if (l.g >= 0) { grow(B(l.g), l.x1, l.y1); grow(B(l.g), l.x2, l.y2); samp(P(l.g), l.x1, l.y1, l.x2, l.y2); continue; }
        R r{std::min(l.x1, l.x2), std::min(l.y1, l.y2), std::max(l.x1, l.x2), std::max(l.y1, l.y2)};
        if (r.x1 - r.x0 > 0.6 * W || r.y1 - r.y0 > 0.6 * H) continue;   // marco
        obst.push_back(r); samp(pf, l.x1, l.y1, l.x2, l.y2);
    }
    for (auto& a : d.arcs) {
        const int n = std::max(8, (int)(a.r * 0.6));
        for (int i = 0; i < n; i++) { double t = (a.a0 + (a.a1 - a.a0) * i / n) * M_PI / 180; P(a.g).push_back({a.cx + a.r * std::cos(t), a.cy + a.r * std::sin(t)}); }
        if (a.g >= 0) { grow(B(a.g), a.cx - a.r, a.cy - a.r); grow(B(a.g), a.cx + a.r, a.cy + a.r); }
    }
    for (auto& t : d.texts) {
        const double w = t.s.size() * t.height * 0.7, ca = std::cos(t.angle * M_PI / 180), sa = std::sin(t.angle * M_PI / 180);
        R r{INF, INF, -INF, -INF};
        for (double u : {-1.0, w + 1}) for (double v : {-1.0, t.height + 1}) grow(r, t.x + u * ca - v * sa, t.y + u * sa + v * ca);
        if (t.g >= 0) { grow(B(t.g), r.x0, r.y0); grow(B(t.g), r.x1, r.y1); } else { if (t.height < 3.2 && t.angle == 0) r.x0 -= 13; obst.push_back(r); }   // notas: hueco a su izquierda para el globo de inspección
        samp(P(t.g), t.x, t.y + t.height / 2, t.x + w * 0.85 * ca, t.y + t.height / 2 + w * 0.85 * sa);
    }
    for (auto& p : d.polys) if (p.g >= 0 && !p.pts.empty()) {
        double x0 = INF, y0 = INF, x1 = -INF, y1 = -INF;
        for (auto& q : p.pts) { grow(B(p.g), q.first, q.second); x0 = std::min(x0, q.first); x1 = std::max(x1, q.first); y0 = std::min(y0, q.second); y1 = std::max(y1, q.second); }
        if (p.gray >= 0) for (double x = x0; x <= x1; x += CS) for (double y = y0; y <= y1; y += CS) P(p.g).push_back({x, y});
    }
    for (auto& r : bb) if (r.x1 < r.x0) return;
    const double fx0 = 23, fx1 = W - 13, fy0 = 13, fy1 = H - 13, tx0 = W - 10 - 180, ty1 = 10 + 36;
    const int nx = (int)((fx1 - fx0) / CS), ny = (int)((fy1 - fy0) / CS);
    auto freeCell = [&](int i, int j) { return !(fx0 + (i + .5) * CS > tx0 && fy0 + (j + .5) * CS < ty1); };
    int nfree = 0; double sfx = 0, sfy = 0;
    for (int i = 0; i < nx; i++) for (int j = 0; j < ny; j++) if (freeCell(i, j)) { nfree++; sfx += i; sfy += j; }
    sfx /= nfree; sfy /= nfree;
    std::vector<double> dxs(nb, 0), dys(nb, 0);
    auto score = [&]() {   // K/10 con las mismas fórmulas que verifica_espacio.py
        std::vector<char> ink(nx * ny, 0);
        auto put = [&](const Pts& v, double dx, double dy) {
            for (auto& q : v) {
                double x = q.first + dx, y = q.second + dy;
                if (x < fx0 || x >= fx0 + nx * CS || y < fy0 || y >= fy0 + ny * CS) continue;
                int i = (int)((x - fx0) / CS), j = (int)((y - fy0) / CS);
                if (freeCell(i, j)) ink[i * ny + j] = 1;
            }
        };
        put(pf, 0, 0);
        for (int k = 0; k < nb; k++) put(pm[k], dxs[k], dys[k]);
        double mx = 0, my = 0; int n = 0, i0 = nx, i1 = -1, j0 = ny, j1 = -1;
        for (int i = 0; i < nx; i++) for (int j = 0; j < ny; j++) if (ink[i * ny + j]) { mx += i; my += j; n++; i0 = std::min(i0, i); i1 = std::max(i1, i); j0 = std::min(j0, j); j1 = std::max(j1, j); }
        if (!n) return 0.0;
        mx /= n; my /= n;
        // mayor rectángulo vacío (celdas libres sin tinta)
        std::vector<int> h(nx, 0); int best = 0;
        for (int j = 0; j < ny; j++) {
            for (int i = 0; i < nx; i++) h[i] = (freeCell(i, j) && !ink[i * ny + j]) ? h[i] + 1 : 0;
            std::vector<std::pair<int, int>> st;
            for (int i = 0; i <= nx; i++) {
                int cur = i < nx ? h[i] : 0, s0 = i;
                while (!st.empty() && st.back().second >= cur) { s0 = st.back().first; best = std::max(best, st.back().second * (i - s0)); st.pop_back(); }
                st.push_back({s0, cur});
            }
        }
        const double e = (double)best / nfree, bx = (double)(i1 - i0 + 1) * (j1 - j0 + 1) / nfree;
        const double off = std::max(std::abs(mx - sfx) / (nx / 2.0), std::abs(my - sfy) / (ny / 2.0));
        auto cl = [](double v) { return std::max(0.0, std::min(1.0, v)); };
        return 0.5 * cl(1 - (e - .15) / .35) + 0.3 * cl((bx - .35) / .40) + 0.2 * cl(1 - off / .25);
    };
    auto okBlk = [&](int k, double dx, double dy) {
        R n{bb[k].x0 + dx, bb[k].y0 + dy, bb[k].x1 + dx, bb[k].y1 + dy};
        if (n.x0 < fx0 || n.x1 > fx1 || n.y0 < fy0 || n.y1 > fy1) return false;
        if (n.x1 > tx0 && n.y0 < ty1 + 3) return false;
        for (auto& o : obst) if (n.x0 < o.x1 && n.x1 > o.x0 && n.y0 < o.y1 && n.y1 > o.y0) return false;
        for (int q = 0; q < nb; q++) if (q != k) {
            R m{bb[q].x0 + dxs[q] - 3, bb[q].y0 + dys[q] - 3, bb[q].x1 + dxs[q] + 3, bb[q].y1 + dys[q] + 3};
            if (n.x0 < m.x1 && n.x1 > m.x0 && n.y0 < m.y1 && n.y1 > m.y0) return false;
        }
        return true;
    };
    double cur = score();
    for (int pass = 0; pass < 3; pass++)
        for (int k = 0; k < nb; k++) {
            double bx = dxs[k], by = dys[k], bs = cur;
            {   // búsqueda gruesa por toda la hoja (vistas largas que no llegan al óptimo con un desplazamiento corto)
                const double cx0 = dxs[k], cy0 = dys[k];
                for (double dx = -W; dx <= W; dx += 40) for (double dy = -H; dy <= H; dy += 40) {
                    if (!okBlk(k, cx0 + dx, cy0 + dy)) continue;
                    dxs[k] = cx0 + dx; dys[k] = cy0 + dy;
                    const double sc = score();
                    if (sc > bs + 1e-9) { bs = sc; bx = cx0 + dx; by = cy0 + dy; }
                }
                dxs[k] = bx; dys[k] = by;
            }
            const double ox = dxs[k], oy = dys[k];
            for (double dx = -100; dx <= 100; dx += CS / 2) for (double dy = -80; dy <= 80; dy += CS / 2) {
                if (!okBlk(k, ox + dx, oy + dy)) continue;
                dxs[k] = ox + dx; dys[k] = oy + dy;
                const double sc = score();
                if (sc > bs + 1e-9 || (std::abs(sc - bs) <= 1e-9 && std::hypot(dx, dy) < std::hypot(bx - ox, by - oy))) { bs = sc; bx = ox + dx; by = oy + dy; }
            }
            dxs[k] = bx; dys[k] = by; cur = bs;
        }
    for (int g = 0; g < ng; g++) { const int k = blk[g]; if (std::abs(dxs[k]) > 0.5 || std::abs(dys[k]) > 0.5) moveGroup(d, g, dxs[k], dys[k]); }
}
namespace {
void scaleGroup(Drawing& d, int g, double k) {
    const Box b = groupBox(d, g);
    if (!b.ok() || k <= 0) return;
    const double cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2;
    auto px = [&](double x) { return cx + (x - cx) * k; };
    auto py = [&](double y) { return cy + (y - cy) * k; };
    for (auto& l : d.lines) if (l.g == g) { l.x1 = px(l.x1); l.x2 = px(l.x2); l.y1 = py(l.y1); l.y2 = py(l.y2); }
    for (auto& a : d.arcs) if (a.g == g) { a.cx = px(a.cx); a.cy = py(a.cy); a.r *= k; }
    for (auto& t : d.texts) if (t.g == g) { t.x = px(t.x); t.y = py(t.y); }
    for (auto& p : d.polys) if (p.g == g) {
        if (p.gray >= 0 || p.hatch > 0) { for (auto& q : p.pts) { q.first = px(q.first); q.second = py(q.second); } p.hatch *= p.hatch > 0 ? k : 1; }
        else {   // flechas y máscaras: conservan su tamaño, solo cambia su posición
            double mx = 0, my = 0;
            for (auto& q : p.pts) { mx += q.first; my += q.second; }
            mx /= p.pts.size(); my /= p.pts.size();
            for (auto& q : p.pts) { q.first += px(mx) - mx; q.second += py(my) - my; }
        }
    }
    for (auto& h : d.holeRefs) if (h.v == g) { h.x = px(h.x); h.y = py(h.y); }
    for (auto& v : d.viewRefs) if (v.v == g) {
        v.o[0] = px(v.o[0]); v.o[1] = py(v.o[1]);
        for (int i = 0; i < 3; i++) { v.e[i][0] *= k; v.e[i][1] *= k; }
        v.box[0] = px(v.box[0]); v.box[2] = px(v.box[2]); v.box[1] = py(v.box[1]); v.box[3] = py(v.box[3]);
    }
}

void hideGroup(Drawing& d, int g) {
    d.lines.erase(std::remove_if(d.lines.begin(), d.lines.end(), [&](const Line& l) { return l.g == g; }), d.lines.end());
    d.arcs.erase(std::remove_if(d.arcs.begin(), d.arcs.end(), [&](const Arc& a) { return a.g == g; }), d.arcs.end());
    d.polys.erase(std::remove_if(d.polys.begin(), d.polys.end(), [&](const Poly& p) { return p.g == g; }), d.polys.end());
    for (auto& t : d.texts) if (t.g == g) t.s.clear();   // los textos se vacían (no se borran) para no cambiar los índices
    d.holeRefs.erase(std::remove_if(d.holeRefs.begin(), d.holeRefs.end(), [&](const HoleRef& h) { return h.v == g; }), d.holeRefs.end());
    d.viewRefs.erase(std::remove_if(d.viewRefs.begin(), d.viewRefs.end(), [&](const ViewRef& v) { return v.v == g; }), d.viewRefs.end());
}

std::string ratioText(double s) {
    auto tr = [](double v) { char b[32]; std::snprintf(b, sizeof b, "%.2f", v); std::string r = b; while (!r.empty() && r.back() == '0') r.pop_back(); if (!r.empty() && r.back() == '.') r.pop_back(); return r; };
    return s >= 1 ? tr(s) + ":1" : "1:" + tr(1 / s);
}
}  // namespace

void applyEdits(Drawing& d, int page, const std::string& ops) {
    std::map<int, double> kk;   // escala acumulada de cada grupo
    std::set<int> hidden;
    std::istringstream in(ops);
    std::string ln;
    while (std::getline(in, ln)) {
        auto f = split(ln);
        if (f.size() < 3 || (int)num(f, 1) != page) continue;
        const std::string& c = f[0];
        if (c == "M" && f.size() >= 5) moveGroup(d, (int)num(f, 2), num(f, 3), num(f, 4));
        else if (c == "S" && f.size() >= 4) {
            const int g = (int)num(f, 2);
            const double k = num(f, 3);
            if (k > 0.05 && k < 20) { scaleGroup(d, g, k); kk[g] = (kk.count(g) ? kk[g] : 1.0) * k; }
        }
        else if (c == "H") { const int g = (int)num(f, 2); hideGroup(d, g); hidden.insert(g); }
        else if (c == "T" && f.size() >= 4) { size_t i = (size_t)num(f, 2); if (i < d.texts.size()) d.texts[i].s = f[3]; }
        else if (c == "TM" && f.size() >= 5) { size_t i = (size_t)num(f, 2); if (i < d.texts.size()) { d.texts[i].x += num(f, 3); d.texts[i].y += num(f, 4); } }
        else if (c == "TD") { size_t i = (size_t)num(f, 2); if (i < d.texts.size()) d.texts[i].s.clear(); }
        else if (c == "AT" && f.size() >= 6) { Text t{num(f, 2), num(f, 3), std::max(1.0, num(f, 4)), f[5], 0, false}; d.texts.push_back(t); }
        else if (c == "AL" && f.size() >= 7) {
            const int t = (int)num(f, 6);
            addLine(d, newGroup(d, "Línea"), num(f, 2), num(f, 3), num(f, 4), num(f, 5), t == 0 ? 0.35 : 0.25, t == 1 ? LineType::Hidden : t == 2 ? LineType::Center : LineType::Continuous);
        }
        else if (c == "AA" && f.size() >= 7) {
            const int g = newGroup(d, "Flecha");
            const double x1 = num(f, 2), y1 = num(f, 3), x2 = num(f, 4), y2 = num(f, 5);
            addLine(d, g, x1, y1, x2, y2, 0.25, LineType::Continuous);
            arrowAt(d, g, x1, y1, x2 - x1, y2 - y1);
            Text t{x2 + (x2 >= x1 ? 1.0 : -1.0 - tw(f[6], 3.5)), y2 + 0.5, 3.5, f[6], 0, false};
            t.g = g;
            d.texts.push_back(t);
        }
        else if (c == "AD" && f.size() >= 8) {
            const int g = newGroup(d, "Cota");
            const double x1 = num(f, 2), y1 = num(f, 3), x2 = num(f, 4), y2 = num(f, 5), off = num(f, 6);
            const double L = std::hypot(x2 - x1, y2 - y1);
            if (L < 0.5) continue;
            const double ux = (x2 - x1) / L, uy = (y2 - y1) / L, nx = -uy, ny = ux, sg = off >= 0 ? 1 : -1;
            const double ax = x1 + nx * off, ay = y1 + ny * off, bx = x2 + nx * off, by = y2 + ny * off;
            addLine(d, g, x1 + nx * sg, y1 + ny * sg, ax + nx * sg * 1.5, ay + ny * sg * 1.5, 0.25, LineType::Continuous);
            addLine(d, g, x2 + nx * sg, y2 + ny * sg, bx + nx * sg * 1.5, by + ny * sg * 1.5, 0.25, LineType::Continuous);
            addLine(d, g, ax, ay, bx, by, 0.25, LineType::Continuous);
            arrowAt(d, g, ax, ay, ux, uy);
            arrowAt(d, g, bx, by, -ux, -uy);
            textAlong(d, g, (ax + bx) / 2, (ay + by) / 2, std::atan2(uy, ux) * 180 / M_PI, 3.5, f[7]);
        }
    }
    for (auto& e : kk) {   // vista con escala propia: rótulo con su escala real bajo la vista
        if (hidden.count(e.first) || std::fabs(e.second - 1) < 1e-6) continue;
        const Box b = groupBox(d, e.first);
        if (!b.ok()) continue;
        Text t{(b.x0 + b.x1) / 2 - tw(ratioText(d.scale * e.second), 3.0) / 2, b.y0 - 4.5, 3.0, ratioText(d.scale * e.second), 0, false};
        t.g = e.first;
        d.texts.push_back(t);
    }
}

std::string editInfo(const Drawing& d, int page) {
    std::ostringstream o;
    o << "PAGINA\t" << page << "\t" << d.sheetW << "\t" << d.sheetH << "\t" << d.scale << "\n";
    for (size_t g = 0; g < d.groups.size(); g++) {
        const Box b = groupBox(d, (int)g);
        if (b.ok()) o << "GRUPO\t" << page << "\t" << g << "\t" << d.groups[g] << "\t" << b.x0 << "\t" << b.y0 << "\t" << b.x1 << "\t" << b.y1 << "\n";
    }
    for (size_t i = 0; i < d.texts.size(); i++) {
        const Text& t = d.texts[i];
        if (!visibleText(t)) continue;
        o << "TEXTO\t" << page << "\t" << i << "\t" << t.g << "\t" << t.x << "\t" << t.y << "\t" << t.height << "\t" << t.angle << "\t" << tw(t.s, t.height) << "\t" << t.s << "\n";
    }
    for (auto& x : d.dims) if (x.kind == "globo") {   // globos de conjunto en su posición actual (tocables en el visor)
        const std::string n = std::to_string((int)x.value);
        for (auto& t : d.texts) if (t.g >= 0 && t.s == n && visibleText(t)) {
            const size_t a = x.key.find('\t'), b = x.key.find('\t', a + 1);
            o << "PIEZA\t" << n << "\t" << t.x + tw(t.s, t.height) / 2 << "\t" << t.y + 1.25 << "\t" << x.key.substr(b + 1) << "\t" << d.sheetW << "\t" << d.sheetH << "\n";
            break;
        }
    }
    for (auto& h : d.holeRefs) o << "AGUJERO\t" << h.x << "\t" << h.y << "\t" << h.p[0] << "\t" << h.p[1] << "\t" << h.p[2] << "\t" << h.a[0] << "\t" << h.a[1] << "\t" << h.a[2] << "\t" << h.dia << "\t" << d.sheetW << "\t" << d.sheetH << "\n";
    for (auto& r : d.viewRefs) o << "VISTA\t" << r.v << "\t" << r.o[0] << "\t" << r.o[1] << "\t" << r.e[0][0] << "\t" << r.e[0][1] << "\t" << r.e[1][0] << "\t" << r.e[1][1] << "\t" << r.e[2][0] << "\t" << r.e[2][1] << "\t" << r.box[0] << "\t" << r.box[1] << "\t" << r.box[2] << "\t" << r.box[3] << "\t" << d.sheetW << "\t" << d.sheetH << "\n";
    // vértices para el imán (extremos de línea, centros de arco), sin duplicados a 0,05 mm
    std::set<std::pair<long, long>> seen;
    std::ostringstream pts;
    size_t n = 0;
    auto add = [&](double x, double y) {
        if (n >= 40000 || !seen.insert({std::lround(x * 20), std::lround(y * 20)}).second) return;
        pts << "\t" << std::lround(x * 100) / 100.0 << "\t" << std::lround(y * 100) / 100.0;
        n++;
    };
    for (auto& l : d.lines) { add(l.x1, l.y1); add(l.x2, l.y2); }
    for (auto& a : d.arcs) { add(a.cx, a.cy); for (int q = 0; q < 4; q++) add(a.cx + a.r * std::cos(q * M_PI / 2), a.cy + a.r * std::sin(q * M_PI / 2)); }
    o << "PUNTOS" << pts.str() << "\n";
    return o.str();
}
}  // namespace diedro
