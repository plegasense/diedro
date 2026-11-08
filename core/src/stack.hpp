#pragma once
// ISO 129-1 6.2: desviaciones límite en dos líneas (superior sobre inferior, marcadores decimales alineados).
// Cadena apilada = base + \x1f + superior + \x1f + inferior; text() la reparte en tres textos.
#include <cmath>
#include <string>
#include "drawing.hpp"
#include "font.hpp"
namespace diedro {
constexpr char kStk = '\x1f';
constexpr double kStkH = 0.65;   // altura relativa de las desviaciones
inline double textWraw(const std::string& s, double h) {
    double w = 0;
    for (size_t i = 0; i < s.size();) {
        const Glyph* g = findGlyph(nextCp(s, i));
        w += g ? g->w : 500;
    }
    return w / 1000.0 * h;
}
struct Stk { std::string b, u, l; double wb, ou, ol, w; };
inline bool stkSplit(const std::string& s, double h, Stk& k) {
    size_t a = s.find(kStk);
    if (a == std::string::npos) return false;
    size_t b = s.find(kStk, a + 1);
    k.b = s.substr(0, a); k.u = s.substr(a + 1, b - a - 1); k.l = s.substr(b + 1);
    const double hs = h * kStkH;
    auto pre = [&](const std::string& t) { size_t c = t.find_first_of(".,"); return textWraw(c == std::string::npos ? t : t.substr(0, c), hs); };
    k.wb = textWraw(k.b, h) + 0.4 * h;
    const double pu = pre(k.u), pl = pre(k.l), pm = std::max(pu, pl);
    k.ou = k.wb + (pm - pu); k.ol = k.wb + (pm - pl);
    k.w = std::max(k.ou + textWraw(k.u, hs), k.ol + textWraw(k.l, hs));
    return true;
}
inline void text(Drawing& d, double x, double y, double h, const std::string& s, double ang = 0, bool undef = false) {
    Stk k;
    if (!stkSplit(s, h, k)) { d.texts.push_back({x, y, h, s, ang, undef}); return; }
    const double r = ang * 3.14159265358979 / 180, c = std::cos(r), sn = std::sin(r), hs = h * kStkH;
    d.texts.push_back({x, y, h, k.b, ang, undef});
    d.texts.push_back({x + c * k.ou - sn * 0.42 * h, y + sn * k.ou + c * 0.42 * h, hs, k.u, ang, undef});
    d.texts.push_back({x + c * k.ol + sn * 0.12 * h, y + sn * k.ol - c * 0.12 * h, hs, k.l, ang, undef});
}
inline double textW(const std::string& s, double h) {
    Stk k;
    return stkSplit(s, h, k) ? k.w : textWraw(s, h);
}
// tolerancia del usuario «+0.02/-0.01» → apilada; otra («H7») → en línea
inline std::string stackTol(const std::string& base, const std::string& t, std::string (*dec)(std::string)) {
    size_t sl = t.find('/');
    const bool dev = sl != std::string::npos && sl > 0 && (t[0] == '+' || t[0] == '-' || t[0] == '0') && t.find_first_not_of("+-0123456789.,/") == std::string::npos;
    return dev ? base + kStk + dec(t.substr(0, sl)) + kStk + dec(t.substr(sl + 1)) : base + " " + t;
}
}
