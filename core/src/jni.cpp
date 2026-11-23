// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include "projsym.hpp"
#include "dfm.hpp"
#include <jni.h>
#include <fstream>
#include <stdexcept>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <chrono>
#include <sstream>
#include "analyze.hpp"
#include "prism.hpp"
#include "classify.hpp"
#include "assembly.hpp"
#include "iso.hpp"
#include "gear.hpp"
#include "special.hpp"
#include "i18n.hpp"
#include "inspect.hpp"
#include "progress.hpp"
#include <atomic>

using namespace diedro;

static std::vector<Drawing> gPages;   // último plano generado, sin ediciones (para re-renderizar sin repetir el análisis del STEP)
static std::mutex gMu;

// m5: escritura comprobada (disco lleno → error en vez de PDF truncado)
static void wfile(const std::string& p, const std::string& data) {
    std::ofstream f(p, std::ios::binary);
    f << data;
    f.flush();
    if (!f) throw std::runtime_error("no se pudo escribir el archivo (¿disco lleno?)");
}

// S5: NewStringUTF/GetStringUTFChars usan UTF-8 modificado (CESU-8): los caracteres fuera del BMP (emoji) se corrompen. Se convierte a mano por UTF-16.
static std::string str(JNIEnv* e, jstring s) {
    if (!s) return "";
    const jchar* c = e->GetStringChars(s, nullptr);
    jsize n = e->GetStringLength(s);
    std::string r;
    for (jsize i = 0; i < n; i++) {
        unsigned u = c[i];
        if (u >= 0xD800 && u < 0xDC00 && i + 1 < n && c[i + 1] >= 0xDC00 && c[i + 1] < 0xE000) { u = 0x10000 + ((u - 0xD800) << 10) + (c[i + 1] - 0xDC00); i++; }
        if (u < 0x80) r += (char)u;
        else if (u < 0x800) { r += (char)(0xC0 | (u >> 6)); r += (char)(0x80 | (u & 63)); }
        else if (u < 0x10000) { r += (char)(0xE0 | (u >> 12)); r += (char)(0x80 | ((u >> 6) & 63)); r += (char)(0x80 | (u & 63)); }
        else { r += (char)(0xF0 | (u >> 18)); r += (char)(0x80 | ((u >> 12) & 63)); r += (char)(0x80 | ((u >> 6) & 63)); r += (char)(0x80 | (u & 63)); }
    }
    e->ReleaseStringChars(s, c);
    return r;
}
static jstring mkstr(JNIEnv* e, const char* p) {
    std::vector<jchar> w;
    const unsigned char* c = (const unsigned char*)p;
    while (*c) {
        unsigned u = *c, k = 0;
        if (u >= 0xF0) { u &= 7; k = 3; } else if (u >= 0xE0) { u &= 15; k = 2; } else if (u >= 0xC0) { u &= 31; k = 1; } else if (u >= 0x80) { u = 0xFFFD; }
        c++;
        for (; k && (*c & 0xC0) == 0x80; k--, c++) u = (u << 6) | (*c & 63);
        if (u >= 0x10000) { u -= 0x10000; w.push_back((jchar)(0xD800 + (u >> 10))); w.push_back((jchar)(0xDC00 + (u & 1023))); }
        else w.push_back((jchar)u);
    }
    return e->NewString(w.data(), (jsize)w.size());
}

// Devuelve un informe de texto: primera línea "OK ..." o "ERROR ...", luego una línea por cota/aviso.
extern "C" JNIEXPORT jint JNICALL Java_app_diedro_planos_Native_progress(JNIEnv*, jclass) { return gProg.load() * 10 + gStage.load(); }

extern "C" JNIEXPORT void JNICALL Java_app_diedro_planos_Native_setProjection(JNIEnv*, jclass, jboolean third) { gThirdAngle = third; }   // G10: método de proyección (ajuste de la app)
static std::atomic<bool> gDfm{false};
extern "C" JNIEXPORT void JNICALL Java_app_diedro_planos_Native_setDfm(JNIEnv*, jclass, jboolean on) { gDfm = on; }   // G12: revisión para fresado (ajuste de la app)

extern "C" JNIEXPORT jstring JNICALL Java_app_diedro_planos_Native_generate(JNIEnv* env, jclass, jstring step, jstring pdf, jstring title, jstring partNo, jstring material, jstring tol, jstring tols, jstring lang, jboolean imperial, jstring sheet, jboolean explode, jboolean inspect) {
    std::ostringstream out;
    progress(0, 0); progress(1, 0);
    { std::lock_guard<std::mutex> lk(gMu); gPages.clear(); }   // M8: un descarte/error no deja el plano anterior para re-renderizar o exportar
    try {
        Meta m{str(env, title), str(env, partNo), str(env, material), str(env, tol), {}};
        {  // líneas «clave<TAB>valor»
            std::istringstream in(str(env, tols));
            std::string ln;
            while (std::getline(in, ln)) { auto t = ln.find('\t'); if (t != std::string::npos && t + 1 < ln.size()) setUserTol(m, ln.substr(0, t), ln.substr(t + 1)); }
        }
        m.langUi = str(env, lang); m.lang = pdfLang(m.langUi);
        m.imperial = imperial; gImperialUnits = imperial;
        m.sheet = str(env, sheet);
        m.explode = explode; m.inspect = inspect;
        for (int w = 0; w < 300 && gLiveWorkers.load() > 0; w++) std::this_thread::sleep_for(std::chrono::milliseconds(100));   // S-A: espera a un hilo de conjunto abandonado antes de tocar los globales del motor
        if (gLiveWorkers.load() > 0) { out << "ERROR " << tr("Una hoja anterior sigue en proceso; espera unos segundos y vuelve a intentarlo.", m.lang); return mkstr(env, out.str().c_str()); }
        {
            Classification c = classifyStep(str(env, step));
            if (c.discard) {   // G15: hoja de aviso en lugar de plano
                auto tx = discardText(c, m);   // sin plano simulado: la app muestra el aviso
                out << "DESCARTE " << c.discard << "\n";
                for (auto& w : tx) if (!w.empty()) out << "AVISO " << w << "\n";
                return mkstr(env, out.str().c_str());
            }
            if (c.error.empty() && c.group == 7 && c.conf >= 0.6) {
                std::string o = str(env, pdf), e;
                size_t sl = o.find_last_of('/');
                if (m.title.empty()) { std::string b = str(env, step); b = b.substr(b.find_last_of('/') + 1); m.title = b.substr(0, b.rfind('.')); }
                auto pages = layoutAssembly(str(env, step), m, sl == std::string::npos ? "." : o.substr(0, sl), e, c.nParts);
                if (!e.empty()) { out << "ERROR " << e; return mkstr(env, out.str().c_str()); }
                if (pages.empty()) { out << "ERROR sin hojas"; return mkstr(env, out.str().c_str()); }
                if (m.inspect) pages[0].warnings.push_back(tr("inspección con globos no disponible en conjuntos: generarla por pieza", m.lang));
                { std::lock_guard<std::mutex> lk(gMu); gPages = pages; }
                wfile(o, toPdfMulti(pages));
                progress(100, 5);
                out << "OK " << pages[0].sheetName << " escala " << pages[0].scale << "\n";
                for (size_t i = 0; i < pages.size(); i++) out << "HOJA\t" << i << "\t" << pages[i].kind << "\t" << pages[i].label << "\n";
                for (auto& pg : pages) for (auto& w : pg.warnings) out << "AVISO " << w << "\n";
                for (auto& x : pages[0].dims) if (x.kind == "globo") out << "PIEZA\t" << (int)x.value << "\t" << x.key << "\t" << pages[0].sheetW << "\t" << pages[0].sheetH << "\n";
                return mkstr(env, out.str().c_str());
            }
        }
        Profile p; Drawing d;
        bool gear = false;
        { Classification c = classifyStep(str(env, step)); if (c.error.empty() && (c.group == 6 || c.group == 0)) { const bool corona = c.reason.find("corona") != std::string::npos; gear = (!corona && layoutSpring(str(env, step), m, d)) || layoutGear(str(env, step), m, p, d) || (!gManyFree && (layoutCamshaft(str(env, step), m, d) || layoutCam(str(env, step), m, d) || layoutCam3D(str(env, step), m, d))); } }   // B7: igual que cli.cpp
    if (!gear && !std::getenv("DIEDRO_NO_GEAR") && !std::getenv("DIEDRO_FORCE_PRISM")) { Classification c = classifyStep(str(env, step)); if (c.error.empty() && (c.group == 13 || c.group == 14)) gear = layoutPipe(str(env, step), m, d, c.group == 14); if (!gear && c.error.empty() && c.group == 14) gear = layoutHarness(str(env, step), m, d); }
    if (!gear && !std::getenv("DIEDRO_NO_GEAR") && !std::getenv("DIEDRO_FORCE_PRISM")) { Classification c = classifyStep(str(env, step)); if (c.error.empty() && c.group >= 1 && c.group <= 3) { CamGuard cg(0.4); gear = layoutCamshaft(str(env, step), m, d) || layoutCam(str(env, step), m, d); } }   // lóbulo de leva suelto: lo clasifica G1–G3, pero su contorno de arcos con taladro es de leva
        if (!gear) p = analyzeStep(str(env, step));
        bool prism = false;
        if (!gear && chooseEnginePrism(str(env, step), p)) {
            std::string e;
            d = layoutPrism(str(env, step), m, e);
            if (e.empty()) prism = true;
            else if (!p.error.empty()) { out << "ERROR " << e; return mkstr(env, out.str().c_str()); }
        }
        if (!gear && !prism && !p.error.empty()) { out << "ERROR " << p.error; return mkstr(env, out.str().c_str()); }
        if (!prism && !gear) d = layout(p, m);
    if (!prism && !gear) {   // torneado inválido (pieza no de revolución, p. ej. pistón): si el motor prismático la entiende, mejor ese
        bool nt = false; for (auto& w : d.warnings) if (w == tr("PIEZA NO TORNEADA: predominan rasgos que no son de revolución; este plano NO es válido para fabricar.", m.lang)) nt = true;
        if (nt) { std::string e2; Drawing d2 = layoutPrism(str(env, step), m, e2); bool bad = !e2.empty(); for (auto& w : d2.warnings) if (w == tr("PIEZA NO PRISMÁTICA: predominan rasgos sin acotar; este plano NO es válido para fabricar.", m.lang)) bad = true; if (!bad) { d = d2; prism = true; } }
    }
        progress(70, 3); addIsoStep(d, str(env, step)); balanceViews(d);
        std::vector<Drawing> pg{d};
        progress(86, 4);
        if (m.inspect) { pg = withInspection(d, m, str(env, pdf) + ".csv"); d = pg[0]; }
        { std::lock_guard<std::mutex> lk(gMu); gPages = pg; }
        progress(98, 5);
        wfile(str(env, pdf), (m.inspect ? toPdfMulti(pg) : toPdf(d)));
        progress(100, 5);
        out << "OK " << d.sheetName << " escala " << d.scale << "\n";
        if (m.inspect) for (size_t i = 0; i < pg.size(); i++) out << "HOJA\t" << i << "\t" << pg[i].kind << "\t" << pg[i].label << "\n";
        for (auto& x : d.dims) out << "COTA " << x.key << "\t" << x.text << "\n";
        for (auto& w : d.warnings) out << "AVISO " << w << "\n";
        if (gDfm) for (auto& w : dfmCheck(str(env, step), m.lang)) out << "AVISO " << w << "\n";   // G12: solo avisos, el plano no cambia
        for (auto& h : d.holeRefs) out << "AGUJERO\t" << h.x << "\t" << h.y << "\t" << h.p[0] << "\t" << h.p[1] << "\t" << h.p[2] << "\t" << h.a[0] << "\t" << h.a[1] << "\t" << h.a[2] << "\t" << h.dia << "\t" << d.sheetW << "\t" << d.sheetH << "\n";
        for (auto& r : d.viewRefs) out << "VISTA\t" << r.v << "\t" << r.o[0] << "\t" << r.o[1] << "\t" << r.e[0][0] << "\t" << r.e[0][1] << "\t" << r.e[1][0] << "\t" << r.e[1][1] << "\t" << r.e[2][0] << "\t" << r.e[2][1] << "\t" << r.box[0] << "\t" << r.box[1] << "\t" << r.box[2] << "\t" << r.box[3] << "\t" << d.sheetW << "\t" << d.sheetH << "\n";
    } catch (const std::exception& e) {
        out << "ERROR " << e.what();
    } catch (...) {
        out << "ERROR fallo interno al procesar el STEP";
    }
    return mkstr(env, out.str().c_str());
}

// Re-renderiza el último plano con las ediciones del usuario y devuelve la información para el editor (ver edit.cpp).
extern "C" JNIEXPORT jstring JNICALL Java_app_diedro_planos_Native_render(JNIEnv* env, jclass, jstring pdf, jstring ops) {
    std::ostringstream out;
    try {
        std::vector<Drawing> pages;
        { std::lock_guard<std::mutex> lk(gMu); pages = gPages; }
        if (pages.empty()) return mkstr(env, "ERROR sin plano");
        const std::string o = str(env, ops);
        for (size_t i = 0; i < pages.size(); i++) { applyEdits(pages[i], (int)i, o); out << editInfo(pages[i], (int)i); }
        wfile(str(env, pdf), toPdfMulti(pages));
    } catch (const std::exception& e) {
        return mkstr(env, (std::string("ERROR ") + e.what()).c_str());
    } catch (...) {
        return mkstr(env, "ERROR fallo interno al editar");
    }
    return mkstr(env, out.str().c_str());
}

// Exporta hojas del último plano (con las ediciones) a PDF. sel = índices separados por coma; split = un PDF por hoja
// (dir/NN_etiqueta.pdf) o uno solo (dir/name). Devuelve las rutas escritas, una por línea, o «ERROR ...».
extern "C" JNIEXPORT jstring JNICALL Java_app_diedro_planos_Native_exportPages(JNIEnv* env, jclass, jstring dir, jstring name, jstring ops, jstring sel, jboolean split) {
    std::ostringstream out;
    try {
        std::vector<Drawing> pages;
        { std::lock_guard<std::mutex> lk(gMu); pages = gPages; }
        if (pages.empty()) return mkstr(env, "ERROR sin plano");
        const std::string o = str(env, ops), d = str(env, dir);
        std::vector<size_t> ix;
        { std::istringstream in(str(env, sel)); std::string t; while (std::getline(in, t, ',')) { size_t k = (size_t)std::atoi(t.c_str()); if (k < pages.size()) ix.push_back(k); } }
        if (ix.empty()) return mkstr(env, "ERROR sin hojas elegidas");
        for (size_t i = 0; i < pages.size(); i++) applyEdits(pages[i], (int)i, o);
        auto safe = [](const std::string& s) {
            std::string r;
            for (unsigned char c : s) { char o = (std::isalnum(c) || c == '-') ? (char)c : '_'; if (o != '_' || (!r.empty() && r.back() != '_')) r += o; }
            while (!r.empty() && r.back() == '_') r.pop_back();
            return r.empty() ? std::string("hoja") : r;
        };
        std::string nm0 = str(env, name);
        { size_t sl = nm0.find_last_of("/\\"); if (sl != std::string::npos) nm0 = nm0.substr(sl + 1); if (nm0 == ".." || nm0 == ".") nm0.clear(); }   // M8: solo nombre de archivo, sin rutas
        if (nm0.empty()) return mkstr(env, "ERROR nombre de archivo no válido");
        std::string lw = nm0; for (auto& ch : lw) ch = (char)std::tolower((unsigned char)ch);   // B6: extensión sin distinguir mayúsculas
        const bool isDxf = lw.size() > 4 && lw.compare(lw.size() - 4, 4, ".dxf") == 0, isSvg = lw.size() > 4 && lw.compare(lw.size() - 4, 4, ".svg") == 0;
        if (isDxf && !split) {   // sin dividir: todas las hojas elegidas en un solo DXF, una junto a otra; con split cada hoja va en su archivo
            std::vector<Drawing> v; for (size_t k : ix) v.push_back(pages[k]);
            const std::string f = d + "/" + nm0;
            wfile(f, toDxfMulti(v));
            out << f << "\n";
        } else if (isDxf || isSvg) {   // G9: una hoja = un archivo (DXF R2000 o SVG); varias hojas: nombre_NN.ext
            for (size_t k : ix) {
                std::string f = d + "/" + nm0;
                if (ix.size() > 1) { char nn[8]; std::snprintf(nn, sizeof nn, "_%02zu", k + 1); f = d + "/" + nm0.substr(0, nm0.size() - 4) + nn + nm0.substr(nm0.size() - 4); }
                wfile(f, (isDxf ? toDxf(pages[k]) : toSvg(pages[k])));
                out << f << "\n";
            }
        } else if (!split) {
            std::vector<Drawing> v; for (size_t k : ix) v.push_back(pages[k]);
            const std::string f = d + "/" + nm0;
            wfile(f, toPdfMulti(v));
            out << f << "\n";
        } else for (size_t k : ix) {
            char nn[8]; std::snprintf(nn, sizeof nn, "%02zu_", k + 1);
            const std::string f = d + "/" + nn + safe(pages[k].label.empty() ? "hoja" : pages[k].label) + ".pdf";
            wfile(f, toPdf(pages[k]));
            out << f << "\n";
        }
    } catch (const std::exception& e) {
        return mkstr(env, (std::string("ERROR ") + e.what()).c_str());
    } catch (...) {
        return mkstr(env, "ERROR fallo interno al exportar");
    }
    return mkstr(env, out.str().c_str());
}
