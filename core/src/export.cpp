// Exportación a DXF (R2000, ASCII, grosores y HATCH) y SVG de un plano. Reglas y decisiones en docs/NORMAS_G9.md.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <sstream>
#include "drawing.hpp"
#include "font.hpp"
#include "dxf_skel.inc"

namespace diedro {
namespace {
std::string f(double v) { char b[40]; std::snprintf(b, sizeof b, "%.4f", v); return b; }

// ---- DXF ----
const double kHid = 9 / 72.0 * 25.4, kHidGap = 2.8 / 72.0 * 25.4;   // mismos trazos que el PDF (mm)
const double kCen = 28 / 72.0 * 25.4, kCenGap = 3.5 / 72.0 * 25.4;

struct Dxf {
    std::ostringstream o; unsigned h = 0x100;
    void g(int code, const std::string& v) { o << code << "\n" << v << "\n"; }
    void g(int code, double v) { g(code, f(v)); }
    std::string hex() { char b[16]; std::snprintf(b, sizeof b, "%X", h++); return b; }
    // cabecera común de una entidad R2000: handle, propietario (*Model_Space), capa y grosor de línea (centésimas de mm)
    void ent(const char* t, const char* layer, int lw = -1) { g(0, t); g(5, hex()); g(330, "17"); g(100, "AcDbEntity"); g(8, layer); if (lw >= 0) g(370, std::to_string(lw)); }
};

// grosores admitidos por el DXF (centésimas de mm) y el más cercano al ancho de la línea
int lweight(double mm) {
    static const int w[] = {5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211};
    int best = w[0]; for (int v : w) if (std::fabs(v - mm * 100) < std::fabs(best - mm * 100)) best = v;
    return best;
}
// rayado de sección (fino y a 45°, como en inspect.cpp): capa propia, para apagarlo o sustituirlo por un HATCH en el CAD
bool isHatch(const Line& l) {
    const double dx = l.x2 - l.x1, dy = l.y2 - l.y1;
    return l.type == LineType::Continuous && l.width < 0.3 && std::fabs(std::fabs(dx) - std::fabs(dy)) < 1e-3 * (std::fabs(dx) + 1);
}
const char* layerOf(LineType t, double w) {
    if (t == LineType::Hidden) return "OCULTA";
    if (t == LineType::Center) return "EJES";
    return w >= 0.5 ? "CONTORNO" : "FINA";
}

// Símbolos habituales en planos (griego, flechas, signos) -> ASCII, porque un DXF R12 no garantiza la secuencia \U+XXXX
const char* ascii(unsigned cp) {
    switch (cp) {
        case 0x2013: case 0x2014: case 0x2212: return "-";
        case 0x21A7: return "prof. "; case 0x2192: return "->"; case 0x2190: return "<-"; case 0x2264: return "<="; case 0x2265: return ">="; case 0x2248: return "~";
        case 0x2026: return "..."; case 0x2018: case 0x2019: return "'"; case 0x201C: case 0x201D: return "\"";
        case 0x03B1: return "alfa"; case 0x03B2: return "beta"; case 0x03B3: return "gamma"; case 0x03B4: return "delta"; case 0x03B8: return "theta";
        case 0x03BB: return "lambda"; case 0x03BC: return "mu"; case 0x03C0: return "pi"; case 0x03C6: return "phi"; case 0x03C9: return "omega";
        case 0x0394: return "Delta"; case 0x03A9: return "Omega"; case 0x03A6: return "Phi";
        default: return nullptr;
    }
}

// UTF-8 -> texto DXF R12: ASCII con %%c (Ø) %%d (°) %%p (±); el resto como \U+XXXX
std::string dxfText(const std::string& s) {
    std::string r;
    for (size_t i = 0; i < s.size();) {
        unsigned cp = nextCp(s, i);
        if (cp == 0x00D8 || cp == 0x2205 || cp == 0x2300) r += "%%c";
        else if (cp == 0x00B0) r += "%%d";
        else if (cp == 0x00B1) r += "%%p";
        else if (cp == 0x00D7) r += 'x';   // × -> x: algunos lectores no combinan \\U+ con %%d (1×45°)
        else if (cp >= 32 && cp < 127) { if (cp == '%') r += "%%%"; else r += (char)cp; }
        else if (cp == '\t') r += ' ';
        else if (const char* a = ascii(cp)) r += a;   // R12 no define \U+: lo habitual se pasa a ASCII legible
        else if (cp >= 0xA0 && cp <= 0xFF) r += (char)cp;   // Latin-1 = cp1252: byte directo (cabecera $DWGCODEPAGE ANSI_1252)
        else if (cp >= 128) { char b[16]; std::snprintf(b, sizeof b, "\\U+%04X", cp); r += b; }
    }
    return r;
}


void ltype(Dxf& d, const char* name, const char* desc, std::initializer_list<double> pat) {
    double tot = 0; for (double p : pat) tot += std::fabs(p);
    d.g(0, "LTYPE"); d.g(5, d.hex()); d.g(330, "2"); d.g(100, "AcDbSymbolTableRecord"); d.g(100, "AcDbLinetypeTableRecord");
    d.g(2, name); d.g(70, "0"); d.g(3, desc); d.g(72, "65"); d.g(73, std::to_string(pat.size())); d.g(40, tot);
    for (double p : pat) { d.g(49, p); d.g(74, "0"); }
}
void layer(Dxf& d, const char* name, int color, const char* lt, int lw) {
    d.g(0, "LAYER"); d.g(5, d.hex()); d.g(330, "1"); d.g(100, "AcDbSymbolTableRecord"); d.g(100, "AcDbLayerTableRecord");
    d.g(2, name); d.g(70, "0"); d.g(62, std::to_string(color)); d.g(6, lt); d.g(370, std::to_string(lw)); d.g(390, "13");
}

void solid(Dxf& d, const char* ly, const std::vector<std::pair<double, double>>& p) {
    d.ent("SOLID", ly); d.g(100, "AcDbTrace");
    // orden de vértices de SOLID: 1,2,4,3
    const size_t ord[4] = {0, 1, 3, 2};
    for (int k = 0; k < 4; k++) { size_t i = ord[k] < p.size() ? ord[k] : p.size() - 1; if (p.size() == 3 && k == 2) i = 2; if (p.size() == 3 && k == 3) i = 2; d.g(10 + k, p[i].first); d.g(20 + k, p[i].second); d.g(30 + k, 0.0); }
}
// LWPOLYLINE; plinegen (128): el patrón de trazos corre seguido por todos los vértices
void polyline(Dxf& d, const char* ly, int lw, const std::vector<std::pair<double, double>>& p, bool closed) {
    d.ent("LWPOLYLINE", ly, lw); d.g(100, "AcDbPolyline"); d.g(90, std::to_string(p.size())); d.g(70, std::to_string(128 | (closed ? 1 : 0)));
    for (auto& v : p) { d.g(10, v.first); d.g(20, v.second); }
}

// ¿(x,y) cae dentro de alguna zona rayada? (par-impar entre los contornos de un mismo HATCH)
struct HatchSet {
    std::vector<std::vector<const Poly*>> groups;
    explicit HatchSet(const Drawing& dr) {
        std::vector<int> ids;
        for (const Poly& p : dr.polys) if (p.hatch > 0 && p.pts.size() >= 3) {
            size_t k = 0; while (k < ids.size() && ids[k] != p.hid) k++;
            if (k == ids.size()) { ids.push_back(p.hid); groups.emplace_back(); }
            groups[k].push_back(&p);
        }
    }
    bool inside(double x, double y) const {
        for (auto& gr : groups) {
            int c = 0;
            for (const Poly* p : gr) for (size_t i = 0; i < p->pts.size(); i++) {
                auto a = p->pts[i], b = p->pts[(i + 1) % p->pts.size()];
                if ((a.second > y) != (b.second > y) && x < a.first + (y - a.second) / (b.second - a.second) * (b.first - a.first)) c++;
            }
            if (c & 1) return true;
        }
        return false;
    }
};

void hatchEnt(Dxf& d, const std::vector<const Poly*>& loops) {
    // ANSI31 (45°; con rotación 90° = 135°), escala = paso / 3,175 mm; contornos como polilíneas, par-impar
    d.ent("HATCH", "RAYADO", 13); d.g(100, "AcDbHatch");
    d.g(10, 0.0); d.g(20, 0.0); d.g(30, 0.0); d.g(210, 0.0); d.g(220, 0.0); d.g(230, 1.0);
    d.g(2, "ANSI31"); d.g(70, "0"); d.g(71, "0"); d.g(91, std::to_string(loops.size()));
    for (size_t k = 0; k < loops.size(); k++) {
        d.g(92, k == 0 ? "7" : "2"); d.g(72, "0"); d.g(73, "1"); d.g(93, std::to_string(loops[k]->pts.size()));
        for (auto& v : loops[k]->pts) { d.g(10, v.first); d.g(20, v.second); }
        d.g(97, "0");
    }
    d.g(75, "0"); d.g(76, "1"); d.g(52, loops[0]->hdir < 0 ? 90.0 : 0.0); d.g(41, loops[0]->hatch / 3.175); d.g(77, "0");
    d.g(78, "1"); d.g(53, 45.0); d.g(43, 0.0); d.g(44, 0.0); d.g(45, -2.2450640303); d.g(46, 2.2450640303); d.g(79, "0"); d.g(98, "0");
}
}  // namespace

std::string toDxf(const Drawing& dr, bool shade) {
    Dxf d;
    // tablas propias (LTYPE, LAYER) con los handles siguientes a los del esqueleto
    ltype(d, "HIDDEN", "Hidden __ __ __", {kHid, -kHidGap});
    ltype(d, "CENTER", "Center ____ _ ____ _", {kCen, -kCenGap, kCenGap, -kCenGap});
    const std::string lt = d.o.str(); d.o.str("");
    layer(d, "CONTORNO", 7, "Continuous", 50); layer(d, "FINA", 3, "Continuous", 25); layer(d, "OCULTA", 5, "HIDDEN", 25); layer(d, "EJES", 1, "CENTER", 18);
    layer(d, "TEXTO", 7, "Continuous", 18); layer(d, "FLECHAS", 7, "Continuous", 25); layer(d, "SOMBREADO", -8, "Continuous", 5); layer(d, "RAYADO", 8, "Continuous", 13);
    const std::string ly = d.o.str(); d.o.str("");
    const HatchSet hs(dr);
    // líneas: los segmentos encadenados a trazos (círculos teselados) van en una sola polilínea para que el patrón no se reinicie
    for (size_t i = 0; i < dr.lines.size();) {
        const Line& l = dr.lines[i];
        if (l.type == LineType::Hidden || l.type == LineType::Center) {
            std::vector<std::pair<double, double>> pts{{l.x1, l.y1}, {l.x2, l.y2}};
            size_t j = i + 1;
            while (j < dr.lines.size() && dr.lines[j].type == l.type && dr.lines[j].width == l.width && std::fabs(dr.lines[j].x1 - pts.back().first) < 1e-6 && std::fabs(dr.lines[j].y1 - pts.back().second) < 1e-6) { pts.push_back({dr.lines[j].x2, dr.lines[j].y2}); j++; }
            if (pts.size() > 2) { polyline(d, layerOf(l.type, l.width), lweight(l.width), pts, false); i = j; continue; }
        }
        i++;
        if (isHatch(l) && hs.inside((l.x1 + l.x2) / 2, (l.y1 + l.y2) / 2)) continue;   // ya lo da el HATCH
        d.ent("LINE", layerOf(l.type, l.width), lweight(l.width)); d.g(100, "AcDbLine"); d.g(10, l.x1); d.g(20, l.y1); d.g(30, 0.0); d.g(11, l.x2); d.g(21, l.y2); d.g(31, 0.0);
    }
    for (const auto& a : dr.arcs) {
        double span = a.a1 - a.a0; while (span <= 0) span += 360;
        d.ent(span >= 359.99 ? "CIRCLE" : "ARC", layerOf(a.type, a.width), lweight(a.width)); d.g(100, "AcDbCircle"); d.g(10, a.cx); d.g(20, a.cy); d.g(30, 0.0); d.g(40, a.r);
        if (span < 359.99) { d.g(100, "AcDbArc"); d.g(50, std::fmod(std::fmod(a.a0, 360) + 360, 360)); d.g(51, std::fmod(std::fmod(a.a1, 360) + 360, 360)); }
    }
    for (const auto& g : hs.groups) hatchEnt(d, g);
    for (const auto& p : dr.polys) {
        if (p.pts.size() < 3 || p.white || p.hatch > 0) continue;   // las máscaras blancas solo tapan líneas en el PDF
        if (p.gray >= 0 && !shade) continue;   // el isométrico sombreado son miles de SOLID: solo si se pide
        const char* ln = p.gray >= 0 ? "SOMBREADO" : "FLECHAS";
        if (p.pts.size() <= 4) solid(d, ln, p.pts); else polyline(d, ln, 5, p.pts, true);
    }
    for (const auto& t : dr.texts) {
        if (t.s.empty()) continue;
        d.ent("TEXT", "TEXTO"); if (t.undefined) d.g(62, "1");
        d.g(100, "AcDbText"); d.g(10, t.x); d.g(20, t.y); d.g(30, 0.0); d.g(40, t.height); d.g(1, dxfText(t.s)); if (t.angle != 0) d.g(50, t.angle); d.g(7, "Standard"); d.g(100, "AcDbText");
    }
    std::string r = kDxfSkel;
    auto rep = [&](const char* k, const std::string& v) { for (size_t p; (p = r.find(k)) != std::string::npos;) r.replace(p, std::strlen(k), v); };
    rep("@X0@", "0.0"); rep("@Y0@", "0.0"); rep("@X1@", f(dr.sheetW)); rep("@Y1@", f(dr.sheetH));
    char hb[16]; std::snprintf(hb, sizeof hb, "%X", d.h + 1);
    rep("@HS@", hb); rep("@NL@", "10"); rep("@LTYPES@", lt); rep("@LAYERS@", ly); rep("@ENTS@", d.o.str());
    return r;
}

// Varias hojas en un solo DXF: una al lado de otra, separadas 50 mm.
std::string toDxfMulti(const std::vector<Drawing>& pages, bool shade) {
    Drawing all; all.sheetW = 0; all.sheetH = 0; double ox = 0; int k = 0;
    for (const Drawing& d : pages) {
        for (Line l : d.lines) { l.x1 += ox; l.x2 += ox; all.lines.push_back(l); }
        for (Arc a : d.arcs) { a.cx += ox; all.arcs.push_back(a); }
        for (Text t : d.texts) { t.x += ox; all.texts.push_back(t); }
        for (Poly p : d.polys) { for (auto& v : p.pts) v.first += ox; if (p.hatch > 0) p.hid += k * 1000000; all.polys.push_back(p); }
        all.sheetH = std::max(all.sheetH, d.sheetH); ox += d.sheetW + 50; all.sheetW = ox - 50; k++;
    }
    return toDxf(all, shade);
}

// ---- SVG ----
namespace {
std::string esc(const std::string& s) {
    std::string r;
    for (char c : s) { if (c == '&') r += "&amp;"; else if (c == '<') r += "&lt;"; else if (c == '>') r += "&gt;"; else if (c == '"') r += "&quot;"; else r += c; }
    return r;
}
std::string dashOf(LineType t) {
    if (t == LineType::Hidden) return " stroke-dasharray=\"" + f(kHid) + " " + f(kHidGap) + "\"";
    if (t == LineType::Center) return " stroke-dasharray=\"" + f(kCen) + " " + f(kCenGap) + " " + f(kCenGap) + " " + f(kCenGap) + "\"";
    return "";
}
double tw(const std::string& s, double h) { double w = 0; for (size_t i = 0; i < s.size();) { const Glyph* g = findGlyph(nextCp(s, i)); w += g ? g->w : 500; } return w / 1000.0 * h; }
std::string b64(const unsigned char* p, size_t n) {
    static const char* T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string r; r.reserve(n * 4 / 3 + 4);
    for (size_t i = 0; i < n; i += 3) {
        unsigned v = p[i] << 16 | (i + 1 < n ? p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        r += T[v >> 18 & 63]; r += T[v >> 12 & 63]; r += i + 1 < n ? T[v >> 6 & 63] : '='; r += i + 2 < n ? T[v & 63] : '=';
    }
    return r;
}
}  // namespace

std::string toSvg(const Drawing& dr, bool embedFont) {
    std::ostringstream o;
    const double H = dr.sheetH;
    o << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" << f(dr.sheetW) << "mm\" height=\"" << f(H) << "mm\" viewBox=\"0 0 " << f(dr.sheetW) << " " << f(H) << "\">\n";
    o << "<title>" << esc(dr.label.empty() ? dr.sheetName : dr.label) << "</title>\n";
    o << "<style>";
    if (embedFont) o << "@font-face{font-family:'Osifont';src:url(data:font/ttf;base64," << b64(kFontData, kFontSize) << ") format('truetype');}";
    o << "text{font-family:'Osifont','ISOCPEUR',sans-serif;fill:#000}.u{fill:#f00}</style>\n";
    o << "<rect width=\"100%\" height=\"100%\" fill=\"#fff\"/>\n<g fill=\"none\" stroke=\"#000\" stroke-linecap=\"butt\" stroke-linejoin=\"round\">\n";
    for (size_t i = 0; i < dr.lines.size();) {
        const Line& l = dr.lines[i];
        if (l.type == LineType::Hidden) {   // trazos encadenados: un solo trazado
            std::string dpath = "M" + f(l.x1) + " " + f(H - l.y1) + "L" + f(l.x2) + " " + f(H - l.y2);
            double ex = l.x2, ey = l.y2; size_t j = i + 1;
            while (j < dr.lines.size() && dr.lines[j].type == l.type && dr.lines[j].width == l.width && std::fabs(dr.lines[j].x1 - ex) < 1e-6 && std::fabs(dr.lines[j].y1 - ey) < 1e-6) { ex = dr.lines[j].x2; ey = dr.lines[j].y2; dpath += "L" + f(ex) + " " + f(H - ey); j++; }
            o << "<path d=\"" << dpath << "\" stroke-width=\"" << f(l.width) << "\"" << dashOf(l.type) << "/>\n"; i = j; continue;
        }
        o << "<path d=\"M" << f(l.x1) << " " << f(H - l.y1) << "L" << f(l.x2) << " " << f(H - l.y2) << "\" stroke-width=\"" << f(l.width) << "\"" << dashOf(l.type) << "/>\n";
        i++;
    }
    for (const auto& a : dr.arcs) {
        double span = a.a1 - a.a0; while (span <= 0) span += 360;
        auto pt = [&](double deg) { double r = deg * M_PI / 180; return f(a.cx + a.r * std::cos(r)) + " " + f(H - (a.cy + a.r * std::sin(r))); };
        std::string r = f(a.r) + " " + f(a.r);
        std::string dp;
        if (span >= 359.99) dp = "M" + pt(a.a0) + "A" + r + " 0 1 0 " + pt(a.a0 + 180) + "A" + r + " 0 1 0 " + pt(a.a0);
        else dp = "M" + pt(a.a0) + "A" + r + " 0 " + (span > 180 ? "1" : "0") + " 0 " + pt(a.a0 + span);
        o << "<path d=\"" << dp << "\" stroke-width=\"" << f(a.width) << "\"" << dashOf(a.type) << "/>\n";
    }
    o << "</g>\n";
    for (const auto& p : dr.polys) {
        if (p.pts.size() < 3 || p.hatch > 0) continue;
        std::string dp;
        for (size_t i = 0; i < p.pts.size(); i++) dp += (i ? "L" : "M") + f(p.pts[i].first) + " " + f(H - p.pts[i].second);
        char gc[16]; std::snprintf(gc, sizeof gc, "#%02x%02x%02x", (int)(p.gray * 255 + .5), (int)(p.gray * 255 + .5), (int)(p.gray * 255 + .5));
        if (p.gray >= 0) o << "<path d=\"" << dp << "Z\" fill=\"" << gc << "\" stroke=\"" << gc << "\" stroke-width=\"0.2\"/>\n";
        else o << "<path d=\"" << dp << "Z\" fill=\"" << (p.white ? "#fff" : "#000") << "\"/>\n";
    }
    for (const auto& t : dr.texts) {
        if (t.s.empty()) continue;
        o << "<text" << (t.undefined ? " class=\"u\"" : "") << " font-size=\"" << f(t.height) << "\" textLength=\"" << f(tw(t.s, t.height)) << "\" lengthAdjust=\"spacingAndGlyphs\" xml:space=\"preserve\" transform=\"translate(" << f(t.x) << " " << f(H - t.y) << ")" << (t.angle != 0 ? " rotate(" + f(-t.angle) + ")" : "") << "\">" << esc(t.s) << "</text>\n";
    }
    o << "</svg>\n";
    return o.str();
}
}  // namespace diedro
