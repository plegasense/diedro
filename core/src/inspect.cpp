#include "progress.hpp"
#include "inspect.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include "i18n.hpp"
#include "stack.hpp"
namespace diedro {
namespace {
struct Box { double x0, y0, x1, y1; };
Box tbox(const Text& t) {
    const double w = textW(t.s, t.height), h = t.height;
    return t.angle > 45 ? Box{t.x - h, t.y, t.x, t.y + w} : Box{t.x, t.y, t.x + w, t.y + h};
}
bool hatchLn(const Line& l) {   // rayado de sección: fino y a 45° (ISO 128-50); un globo puede taparlo con fondo blanco
    const double dx = std::fabs(l.x2 - l.x1), dy = std::fabs(l.y2 - l.y1); return l.type == LineType::Continuous && l.width <= 0.3 && std::fabs(dx - dy) < 0.03 * (dx + dy);
}
double segDist(double px, double py, const Line& l) {
    const double dx = l.x2 - l.x1, dy = l.y2 - l.y1, L = dx * dx + dy * dy;
    double u = L > 0 ? ((px - l.x1) * dx + (py - l.y1) * dy) / L : 0; u = std::max(0.0, std::min(1.0, u));
    return std::hypot(px - (l.x1 + u * dx), py - (l.y1 + u * dy));
}
static std::vector<Box> g_tb;   // cajas de texto en caché (medir glifos en cada candidato dominaba el tiempo); se vacía al empezar addBalloons
const Box& tboxC(const Drawing& d, size_t i) { while (g_tb.size() < d.texts.size()) g_tb.push_back(tbox(d.texts[g_tb.size()])); return g_tb[i]; }
int segCross(const Drawing& d, double ax, double ay, double bx, double by, size_t own) {   // la guía no cruza textos ni líneas
    const double L = std::hypot(bx - ax, by - ay); const int n = std::max(2, (int)(L / 0.4)); int cnt = 0;
    for (size_t i = 0; i < d.texts.size(); i++) {
        if (i == own || d.texts[i].s.empty()) continue; const Box& b = tboxC(d, i);
        if (std::max(ax, bx) < b.x0 - 0.3 || std::min(ax, bx) > b.x1 + 0.3 || std::max(ay, by) < b.y0 - 0.3 || std::min(ay, by) > b.y1 + 0.3) continue;
        for (int k = 1; k < n; k++) { const double x = ax + (bx - ax) * k / n, y = ay + (by - ay) * k / n; if (x > b.x0 - 0.3 && x < b.x1 + 0.3 && y > b.y0 - 0.3 && y < b.y1 + 0.3) return 1000; }
    }
    const double sx0 = std::min(ax, bx), sx1 = std::max(ax, bx), sy0 = std::min(ay, by), sy1 = std::max(ay, by);
    for (const Line& l : d.lines) {
        if (std::max(l.x1, l.x2) < sx0 || std::min(l.x1, l.x2) > sx1 || std::max(l.y1, l.y2) < sy0 || std::min(l.y1, l.y2) > sy1) continue;
        if (hatchLn(l)) continue;
        const double dx = l.x2 - l.x1, dy = l.y2 - l.y1, ex = bx - ax, ey = by - ay, den = ex * dy - ey * dx; if (std::fabs(den) < 1e-9) continue;
        const double t = ((l.x1 - ax) * dy - (l.y1 - ay) * dx) / den, u = ((l.x1 - ax) * ey - (l.y1 - ay) * ex) / den;   // a + t·e = l1 + u·d
        if (t > 0.02 && t < 0.98 && u > 0 && u < 1) cnt++;
    }
    return cnt;
}
static double g_fl = -1; static double g_iso[4]; static bool g_hasIso = false;   // caja del isométrico sombreado: los globos no se ponen encima (quedaban tapados por el relleno)   // caché por llamada de addBalloons (recorrer todas las líneas por cada candidato era lo más caro)
double frameLeft(const Drawing& d) {
    if (g_fl >= 0) return g_fl;   // borde izquierdo del marco del plano (20 mm con margen de encuadernación, 10 sin él)
    double x = 10; for (const Line& l : d.lines) if (std::fabs(l.x1 - l.x2) < 0.01 && std::fabs(l.y1 - l.y2) > 0.9 * (d.sheetH - 20) && l.x1 < d.sheetW / 2) x = std::max(x, l.x1);
    return g_fl = x;
}
bool freeSpot(const Drawing& d, double cx, double cy, double r, size_t own, double lc = 1.0) {
    if (g_hasIso && cx + r > g_iso[0] && cx - r < g_iso[2] && cy + r > g_iso[1] && cy - r < g_iso[3]) return false;
    if (cx - r < frameLeft(d) + 0.5 || cx + r > d.sheetW - 12 || cy - r < 12 || cy + r > d.sheetH - 12) return false;
    for (const Line& l : d.lines) { const double m = r + lc; if (cx < std::min(l.x1, l.x2) - m || cx > std::max(l.x1, l.x2) + m || cy < std::min(l.y1, l.y2) - m || cy > std::max(l.y1, l.y2) + m) continue; if (!hatchLn(l) && segDist(cx, cy, l) < m) return false; }
    for (const Arc& a : d.arcs) if (std::fabs(std::hypot(cx - a.cx, cy - a.cy) - a.r) < r + 0.6 || (std::hypot(cx - a.cx, cy - a.cy) < a.r && a.r < r + 0.6)) return false;
    for (size_t i = 0; i < d.texts.size(); i++) {
        if (i == own || d.texts[i].s.empty()) continue;
        const Box& b = tboxC(d, i);
        const double nx = std::max(b.x0, std::min(cx, b.x1)), ny = std::max(b.y0, std::min(cy, b.y1));
        if (std::hypot(cx - nx, cy - ny) < r + 0.6) return false;
    }
    return true;
}
int qtyOf(const std::string& s) {   // «4× Ø6» -> 4
    size_t p = s.find("×"); if (p == std::string::npos) return 1;
    size_t b = p; while (b > 0 && std::isdigit((unsigned char)s[b - 1])) b--;
    if (b == p || (b > 0 && s[b - 1] != ' ' && s[b - 1] != ':') || (p + 2 < s.size() && std::isdigit((unsigned char)s[p + 2]))) return 1;   // «80×10» es una medida, no una cantidad
    return std::max(1, std::atoi(s.substr(b, p - b).c_str()));
}
double num(std::string t) { for (auto& c : t) if (c == ',') c = '.'; return std::atof(t.c_str()); }
// ISO 286-1 tabla 1: IT3..IT12 (µm) por tramo de tamaño nominal (≤3, 3-6, 6-10, 10-18, 18-30, 30-50, 50-80, 80-120, 120-180, 180-250, 250-315, 315-400, 400-500)
double itBand(double nom, int g) {
    static const double lim[] = {3, 6, 10, 18, 30, 50, 80, 120, 180, 250, 315, 400, 500};
    static const double T[10][13] = {
        {2, 2.5, 2.5, 3, 4, 4, 5, 6, 8, 10, 12, 13, 15}, {3, 4, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20},
        {4, 5, 6, 8, 9, 11, 13, 15, 18, 20, 23, 25, 27}, {6, 8, 9, 11, 13, 16, 19, 22, 25, 29, 32, 36, 40},
        {10, 12, 15, 18, 21, 25, 30, 35, 40, 46, 52, 57, 63}, {14, 18, 22, 27, 33, 39, 46, 54, 63, 72, 81, 89, 97},
        {25, 30, 36, 43, 52, 62, 74, 87, 100, 115, 130, 140, 155}, {40, 48, 58, 70, 84, 100, 120, 140, 160, 185, 210, 230, 250},
        {60, 75, 90, 110, 130, 160, 190, 220, 250, 290, 320, 360, 400}, {100, 120, 150, 180, 210, 250, 300, 350, 400, 460, 520, 570, 630}};
    if (g < 3 || g > 12) return -1;
    int i = 0; while (i < 12 && nom > lim[i]) i++;
    return T[g - 3][i] / 1000.0;
}
// Banda de tolerancia (mm) del texto de tolerancia de una cota; -1 si no se puede saber (tolerancia general o sin definir)
double bandOf(const std::string& tol, const std::string& req) {
    size_t sl = tol.find(" / ");
    if (!tol.empty() && (tol[0] == '+' || tol[0] == '-' || tol[0] == '0') && sl != std::string::npos) return std::fabs(num(tol.substr(0, sl)) - num(tol.substr(sl + 3)));
    size_t pm = tol.find("±");
    if (pm != std::string::npos) return 2 * std::fabs(num(tol.substr(pm + 2)));
    size_t gi = tol.find_first_of("0123456789"); if (gi == std::string::npos) return -1;
    int g = 99; for (size_t i = 0; i < tol.size(); i++) if (std::isalpha((unsigned char)tol[i]) && i + 1 < tol.size() && std::isdigit((unsigned char)tol[i + 1])) { g = std::min(g, std::atoi(tol.c_str() + i + 1)); }
    if (g == 99) return -1;
    std::string n; for (unsigned char c : req) { if (std::isdigit(c) || c == ',' || c == '.') n += (char)c; else if (!n.empty()) break; }
    return n.empty() ? -1 : itBand(num(n), g);
}
std::string clsName(char c, const std::string& lang) { return c == 'C' ? tr("Crítica", lang) : c == 'M' ? tr("Mayor", lang) : c == 'K' ? tr("Clave", lang) : "—"; }
std::string kindEs(const std::string& k) {
    static const char* t[][2] = {{"length", "Longitud"}, {"diameter", "Diámetro"}, {"radius", "Radio"}, {"angle", "Ángulo"}, {"chamfer", "Chaflán"}, {"hole", "Taladro (Ø)"},
        {"pcd", "Círculo de taladros"}, {"position", "Posición de taladro"}, {"slot_depth", "Profundidad de ranura"}, {"flat_across", "Plano (entre caras)"}, {"slot_width", "Ancho de ranura"}, {"gdt", "Tolerancia geométrica"}};
    for (auto& e : t) if (k == e[0]) return e[1];
    return k;
}
// Tolerancia escrita dentro del texto de la cota (p. ej. «Ø35 0/+0,2 pasante», «Ø25 ±0,15 pasante», «Ø30 H7»): solo el símbolo de tolerancia, sin las notas
std::string inlineTol(const std::string& s) {
    std::vector<std::string> tk; std::string c; for (char ch : s + " ") { if (ch == ' ') { if (!c.empty()) tk.push_back(c); c.clear(); } else c += ch; }
    for (size_t i = 1; i < tk.size(); i++) {
        const std::string& t = tk[i]; const size_t sl = t.find('/');
        if (t.compare(0, 2, "±") == 0 && t.size() > 2 && std::isdigit((unsigned char)t[2])) return t;
        if (sl != std::string::npos && sl > 0 && sl + 1 < t.size() && std::isdigit((unsigned char)t[t.find_first_of("0123456789")]) && t.find_first_not_of("0123456789,.+-/") == std::string::npos) return t.substr(0, sl) + " / " + t.substr(sl + 1);
        if (t.size() <= 4 && std::isalpha((unsigned char)t[0]) && std::isdigit((unsigned char)t.back()) && t.find_first_of("0123456789") <= 2 && !std::isdigit((unsigned char)t[0])) return t;
    }
    return "";
}
std::string baseOf(const std::string& s) { size_t k = s.find(kStk); return k == std::string::npos ? s : s.substr(0, k); }
}  // namespace

std::vector<InspRow> addBalloons(Drawing& d, const Meta& m) { g_fl = -1; g_hasIso = false; g_tb.clear();
    for (const Poly& p : d.polys) if (p.gray >= 0) for (auto& q : p.pts) { if (!g_hasIso) { g_iso[0] = g_iso[2] = q.first; g_iso[1] = g_iso[3] = q.second; g_hasIso = true; } g_iso[0] = std::min(g_iso[0], q.first); g_iso[2] = std::max(g_iso[2], q.first); g_iso[1] = std::min(g_iso[1], q.second); g_iso[3] = std::max(g_iso[3], q.second); }
    struct Cand { size_t ti; size_t di; };
    std::vector<Cand> cs; std::vector<char> used(d.texts.size(), 0); std::vector<InspRow> unplaced;
    size_t last = 0;
    for (size_t i = 0; i < d.dims.size(); i++) {
        const DimInfo& di = d.dims[i]; if (di.kind == "globo" || di.text.empty()) continue;
        const std::string want = baseOf(di.text); long f = -1;
        if (di.kind == "gdt") for (size_t t = d.texts.size(); t-- > 0;) if (!used[t] && !d.texts[t].undefined && d.texts[t].s == want) { f = (long)t; break; }
        for (int pass = 0; pass < 5 && f < 0; pass++)
            for (size_t t = (pass < 2 ? last : 0); t < d.texts.size(); t++) {
                if ((used[t] && pass != 4) || d.texts[t].undefined) continue;
                const std::string& s = d.texts[t].s;
                if (pass == 0 || pass == 2 ? s == want : ((want.size() >= 2 || (pass == 4 && s.size() > 2)) && s.find(want) != std::string::npos)) { f = (long)t; break; }
            }
        if (f >= 0) { used[f] = 1; last = (size_t)f; cs.push_back({(size_t)f, i}); }
        else { if (getenv("DIEDRO_DBG")) { fprintf(stderr, "UNMATCHED [%s] kind=%s\n", want.c_str(), di.kind.c_str()); } InspRow r; r.kind = tr(kindEs(di.kind), m.lang); r.req = want; unplaced.push_back(r); }
    }
    // numeración en orden de lectura: filas de 12 mm de arriba abajo, de izquierda a derecha (ISO 6433 4.5, por analogía)
    std::sort(cs.begin(), cs.end(), [&](const Cand& a, const Cand& b) {
        const Text &ta = d.texts[a.ti], &tb = d.texts[b.ti]; const long ra = std::lround(-ta.y / 12), rb = std::lround(-tb.y / 12);
        return ra != rb ? ra < rb : ta.x < tb.x; });
    std::vector<InspRow> rows; double R = 3.2, H = 3.5; const double R0 = 3.2, H0 = 3.5; int n = 0;
    rows.resize(cs.size()); n = (int)cs.size();
    std::vector<size_t> po(cs.size()); for (size_t i = 0; i < po.size(); i++) po[i] = i;
    std::stable_sort(po.begin(), po.end(), [&](size_t a, size_t b) { return (d.dims[cs[a].di].kind == "gdt") < (d.dims[cs[b].di].kind == "gdt"); });   // los marcos GD&T se sitúan al final: tienen más libertad que las cotas de zonas densas
    size_t pdone = 0;
    for (size_t pi : po) {
        progress(86 + (int)(12 * pdone++ / std::max<size_t>(1, po.size())), 4);
        const Cand& c = cs[pi];
        const DimInfo& di = d.dims[c.di]; const Text tx = d.texts[c.ti]; const Box b = tbox(tx);
        InspRow r; r.n = (int)pi + 1; r.kind = tr(kindEs(di.kind), m.lang); r.qty = qtyOf(tx.s);
        Stk k; r.req = baseOf(di.text);
        if (di.kind == "gdt") {   // marco de tolerancia geométrica: requisito = marco completo, tolerancia = valor; clase por banda (decisión propia, como las cotas)
            const std::string kk = di.key.substr(4); const size_t tb = kk.find('\t'); r.req = kk.substr(0, tb); r.tol = kk.substr(tb + 1);
            r.tolUndef = r.tol == "NO DEFINIDO"; if (!r.tolUndef) r.cls = di.value <= 0.0255 ? 'K' : di.value <= 0.1005 ? 'M' : 0;
            auto ci = m.cls.find(r.req.substr(0, r.req.find(' '))); if (ci != m.cls.end()) r.cls = ci->second;
        } else
        if (stkSplit(di.text, 3.5, k)) r.tol = k.u + " / " + k.l;
        else if (!di.key.empty() && m.tols.count(di.key)) r.tol = m.tols.at(di.key);
        else if (!(r.tol = inlineTol(r.req)).empty()) {}
        else if (!m.generalTolerance.empty()) r.tol = tr("General", m.lang) + " " + m.generalTolerance;
        else { r.tol = "NO DEFINIDO"; r.tolUndef = true; }
        if (di.kind != "gdt") { auto ci = m.cls.find(di.key); if (!di.key.empty() && ci != m.cls.end()) r.cls = ci->second;
          else if (!r.tolUndef) { const double bd = bandOf(r.tol, r.req); if (bd >= 0) r.cls = bd <= 0.0255 ? 'K' : bd <= 0.1005 ? 'M' : 0; } }
        if (tx.g >= 0 && tx.g < (int)d.groups.size()) r.view = tr(d.groups[tx.g], m.lang);
        const double mx = (b.x0 + b.x1) / 2, my = (b.y0 + b.y1) / 2, hw = (b.x1 - b.x0) / 2, hh = (b.y1 - b.y0) / 2;
        std::vector<std::array<double, 2>> dir; for (int k = 0; k < 16; k++) { const int j = k < 4 ? k * 4 : k < 8 ? (k - 4) * 4 + 2 : (k - 8) * 2 + 1; dir.push_back({std::cos(j * M_PI / 8), std::sin(j * M_PI / 8)}); }
        R = R0; H = H0;
        double bx = 0, by = 0, bnx = 0, bny = 0; int bestX = 1 << 30; double bestGap = 0, bestScore = 1e18;   // mejor sitio: menos cruces de la guía con líneas, luego el más cercano
        for (int tryN = 0; tryN < 3 && bestX == (1 << 30); tryN++) {   // 2.º intento: globo pequeño (R 2,4) y búsqueda más lejana, para zonas densas
            R = tryN ? 2.4 : R0; H = tryN ? 2.9 : H0; const double lc = tryN == 2 ? 0.2 : 1.0;   // 3.er intento: solo separación mínima de líneas (ordenadas muy juntas)
        for (double gap : {1.5, 4.0, 8.0, 14.0, 22.0, 32.0, 45.0, 60.0, 80.0, 110.0}) {
            for (auto& v : dir) {
                const double ext = std::fabs(v[0]) * hw + std::fabs(v[1]) * hh, cx = mx + v[0] * (ext + R + gap), cy = my + v[1] * (ext + R + gap);
                if (!freeSpot(d, cx, cy, R, c.ti, lc)) continue;
                const double nx = std::max(b.x0, std::min(cx, b.x1)), ny = std::max(b.y0, std::min(cy, b.y1)), dl = std::hypot(cx - nx, cy - ny);
                const int cr = dl > R + 0.8 ? segCross(d, cx + (nx - cx) / dl * R, cy + (ny - cy) / dl * R, nx, ny, c.ti) : 0;
                const double sc = cr * 15 + gap; if (cr < 1000 && sc < bestScore) { bestScore = sc; bestX = cr; bx = cx; by = cy; bnx = nx; bny = ny; bestGap = gap; }
            }
        }
        }
        if (bestScore > 14 && bestX < (1 << 30)) {   // guía larga: rejilla a izquierda/derecha del texto con desplazamientos verticales (columna de globos escalonados, guías cortas casi horizontales)
            for (double gx : {1.5, 4.0, 8.0, 14.0, 22.0}) for (int sd = -1; sd <= 1; sd += 2) for (int j = -12; j <= 12; j++) {
                const double cx = sd < 0 ? b.x0 - R - gx : b.x1 + R + gx, cy = my + j * 2.6;
                if (!freeSpot(d, cx, cy, R, c.ti)) continue;
                const double nx = std::max(b.x0, std::min(cx, b.x1)), ny = std::max(b.y0, std::min(cy, b.y1)), dl = std::hypot(cx - nx, cy - ny);
                const int cr = dl > R + 0.8 ? segCross(d, cx + (nx - cx) / dl * R, cy + (ny - cy) / dl * R, nx, ny, c.ti) : 0;
                const double sc = cr * 15 + dl - R; if (cr < 1000 && sc < bestScore - 3) { bestScore = sc; bestX = cr; bx = cx; by = cy; bnx = nx; bny = ny; }
            }
        }
        (void)bestGap;
        if (bestX < (1 << 30)) {
            { bool under = false; for (const Line& l : d.lines) if (hatchLn(l) && segDist(bx, by, l) < R + 0.3) { under = true; break; }
              if (under) { Poly w; w.white = true; for (int k = 0; k < 24; k++) w.pts.push_back({bx + (R - 0.15) * std::cos(k * M_PI / 12), by + (R - 0.15) * std::sin(k * M_PI / 12)}); d.polys.push_back(w); } }
            d.arcs.push_back({bx, by, R, 0, 360, LineType::Continuous, 0.25});
            const std::string s = std::to_string(r.n);
            d.texts.push_back({bx - textWraw(s, H) / 2, by - H * 0.36, H, s});
            const double dl = std::hypot(bx - bnx, by - bny);
            if (dl > R + 0.8) d.lines.push_back({bx + (bnx - bx) / dl * R, by + (bny - by) / dl * R, bnx, bny, LineType::Continuous, 0.25});
            r.x = bx; r.y = by; r.placed = true;
        }
        if (!r.placed) { r.x = mx; r.y = my; if (getenv("DIEDRO_DBG")) fprintf(stderr, "NOSPOT [%s] at %.1f,%.1f ang=%.0f sheet=%.0fx%.0f\n", tx.s.c_str(), mx, my, tx.angle, d.sheetW, d.sheetH); }
        rows[pi] = r;
    }
    for (auto& u : unplaced) { u.n = ++n; u.tol = !m.generalTolerance.empty() ? tr("General", m.lang) + " " + m.generalTolerance : "NO DEFINIDO"; u.tolUndef = m.generalTolerance.empty(); rows.push_back(u); }
    int np = 0; for (auto& r : rows) if (!r.placed) np++;
    if (np) d.warnings.push_back(std::to_string(np) + " " + tr("cotas sin globo en el plano (sin sitio libre o sin posición): constan en la tabla de inspección", m.lang));
    return rows;
}

std::vector<Drawing> inspectionSheets(const Drawing& d, const std::vector<InspRow>& rows, const Meta& m) {
    (void)d; std::vector<Drawing> out; const size_t per = 23;
    const double X[] = {14, 24, 66, 100, 135, 148, 168, 198, 228, 256}, RH = 6.5;
    const char* head[] = {"N.°", "Característica", "Requisito", "Tolerancia", "Cant.", "Clase", "Vista", "Resultado", "Útil", "N.° NC"};
    for (size_t p = 0; p == 0 || p * per < rows.size(); p++) {
        Drawing s; s.sheetName = "A4"; s.sheetW = 297; s.sheetH = 210; s.kind = "inspect"; s.label = "G8";
        auto ln = [&](double x1, double y1, double x2, double y2, double w) { s.lines.push_back({x1, y1, x2, y2, LineType::Continuous, w}); };
        ln(10, 10, 287, 10, 0.7); ln(287, 10, 287, 200, 0.7); ln(287, 200, 10, 200, 0.7); ln(10, 200, 10, 10, 0.7);
        std::string t = tr("TABLA DE INSPECCIÓN", m.lang) + (m.title.empty() ? "" : " · " + m.title);
        text(s, 14, 189, 6, t); text(s, 14, 182, 3, tr("Un globo por cota; el número del globo es el de la característica. Resultado, útil y NC los rellena quien mide.", m.lang));
        text(s, 14, 177, 2.6, tr("Clase: Crítica = seguridad/función vital (solo si se marca con !C); Clave = tolerancia ≤ 0,025 mm o ajuste IT6 o más fino (!K); Mayor = tolerancia ≤ 0,1 mm (!M).", m.lang));
        const double y0 = 175;
        ln(12, y0 + 2, 285, y0 + 2, 0.5);
        for (int c = 0; c < 10; c++) text(s, X[c], y0 - 3.5, 3, tr(head[c], m.lang));
        ln(12, y0 - 6, 285, y0 - 6, 0.5);
        for (size_t i = 0; i < per && p * per + i < rows.size(); i++) {
            const InspRow& r = rows[p * per + i]; const double y = y0 - 6 - (i + 1) * RH + 2;
            text(s, X[0], y, 3, std::to_string(r.n)); text(s, X[1], y, 3, tr(r.kind, m.lang)); text(s, X[2], y, 3, r.req);
            text(s, X[3], y, 3, r.tol, 0, r.tolUndef); text(s, X[4], y, 3, std::to_string(r.qty)); text(s, X[5], y, 3, clsName(r.cls, m.lang)); text(s, X[6], y, 3, r.view.empty() ? "—" : r.view);
            ln(12, y - 2, 285, y - 2, 0.18);
        }
        for (int c = 0; c < 10; c++) ln(X[c] - 1.5, y0 + 2, X[c] - 1.5, std::max(12.0, y0 - 6 - (double)std::min(per, rows.size() - std::min(rows.size(), p * per)) * RH - 2), 0.18);
        text(s, 250, 13, 3, tr("Hoja", m.lang) + " " + std::to_string(p + 1) + "/" + std::to_string(std::max<size_t>(1, (rows.size() + per - 1) / per)));
        out.push_back(s);
    }
    return out;
}

std::string inspectionCsv(const std::vector<InspRow>& rows) {
    std::string o = "\xEF\xBB\xBF" "n;caracteristica;requisito;tolerancia;cantidad;clase;vista;x_hoja_mm;y_hoja_mm;resultado;util;nc\n";
    auto f = [](double v) { char b[32]; std::snprintf(b, sizeof b, "%.1f", v); return std::string(b); };
    for (auto& r : rows) o += std::to_string(r.n) + ";" + r.kind + ";" + r.req + ";" + r.tol + ";" + std::to_string(r.qty) + ";" + (r.cls ? std::string(1, r.cls) : std::string()) + ";" + r.view + ";" + (r.placed ? f(r.x) + ";" + f(r.y) : ";") + ";;;\n";
    return o;
}

void setUserTol(Meta& m, const std::string& key, std::string v) {
    while (!v.empty() && v.back() == ' ') v.pop_back();
    if (v.size() >= 2 && v[v.size() - 2] == '!' && std::strchr("CMKcmk", v.back())) { m.cls[key] = (char)std::toupper((unsigned char)v.back()); v.resize(v.size() - 2); while (!v.empty() && v.back() == ' ') v.pop_back(); }
    if (!v.empty()) m.tols[key] = v;
}

std::vector<Drawing> withInspection(Drawing d, const Meta& m, const std::string& csvPath) {
    auto rows = addBalloons(d, m); auto pages = inspectionSheets(d, rows, m);
    for (auto& p : pages) { p.kind = "inspect"; p.label = tr("TABLA DE INSPECCIÓN", m.lang); }
    pages.insert(pages.begin(), d);
    if (!csvPath.empty()) std::ofstream(csvPath, std::ios::binary) << inspectionCsv(rows);
    return pages;
}
}  // namespace diedro
