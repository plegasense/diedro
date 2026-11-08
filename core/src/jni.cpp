#include "projsym.hpp"
#include "dfm.hpp"
#include <jni.h>
#include <fstream>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <mutex>
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

using namespace diedro;

static std::vector<Drawing> gPages;   // último plano generado, sin ediciones (para re-renderizar sin repetir el análisis del STEP)
static std::mutex gMu;

static std::string str(JNIEnv* e, jstring s) {
    if (!s) return "";
    const char* c = e->GetStringUTFChars(s, nullptr);
    std::string r = c;
    e->ReleaseStringUTFChars(s, c);
    return r;
}

// Devuelve un informe de texto: primera línea "OK ..." o "ERROR ...", luego una línea por cota/aviso.
extern "C" JNIEXPORT jint JNICALL Java_app_diedro_planos_Native_progress(JNIEnv*, jclass) { return gProg.load() * 10 + gStage.load(); }

extern "C" JNIEXPORT void JNICALL Java_app_diedro_planos_Native_setProjection(JNIEnv*, jclass, jboolean third) { gThirdAngle = third; }   // G10: método de proyección (ajuste de la app)
static bool gDfm = false;
extern "C" JNIEXPORT void JNICALL Java_app_diedro_planos_Native_setDfm(JNIEnv*, jclass, jboolean on) { gDfm = on; }   // G12: revisión para fresado (ajuste de la app)

extern "C" JNIEXPORT jstring JNICALL Java_app_diedro_planos_Native_generate(JNIEnv* env, jclass, jstring step, jstring pdf, jstring title, jstring partNo, jstring material, jstring tol, jstring tols, jstring lang, jboolean imperial, jstring sheet, jboolean explode, jboolean inspect) {
    std::ostringstream out;
    progress(0, 0); progress(1, 0);
    try {
        Meta m{str(env, title), str(env, partNo), str(env, material), str(env, tol), {}};
        {  // líneas «clave<TAB>valor»
            std::istringstream in(str(env, tols));
            std::string ln;
            while (std::getline(in, ln)) { auto t = ln.find('\t'); if (t != std::string::npos && t + 1 < ln.size()) setUserTol(m, ln.substr(0, t), ln.substr(t + 1)); }
        }
        m.langUi = str(env, lang); m.lang = pdfLang(m.langUi);
        m.imperial = imperial;
        m.sheet = str(env, sheet);
        m.explode = explode; m.inspect = inspect;
        {
            Classification c = classifyStep(str(env, step));
            if (c.discard) {   // G15: hoja de aviso en lugar de plano
                auto tx = discardText(c, m);   // sin plano simulado: la app muestra el aviso
                out << "DESCARTE " << c.discard << "\n";
                for (auto& w : tx) if (!w.empty()) out << "AVISO " << w << "\n";
                return env->NewStringUTF(out.str().c_str());
            }
            if (c.error.empty() && c.group == 7 && c.conf >= 0.6) {
                std::string o = str(env, pdf), e;
                size_t sl = o.find_last_of('/');
                if (m.title.empty()) { std::string b = str(env, step); b = b.substr(b.find_last_of('/') + 1); m.title = b.substr(0, b.rfind('.')); }
                auto pages = layoutAssembly(str(env, step), m, sl == std::string::npos ? "." : o.substr(0, sl), e, c.nParts);
                if (!e.empty()) { out << "ERROR " << e; return env->NewStringUTF(out.str().c_str()); }
                if (m.inspect) pages[0].warnings.push_back(tr("inspección con globos no disponible en conjuntos: generarla por pieza", m.lang));
                { std::lock_guard<std::mutex> lk(gMu); gPages = pages; }
                std::ofstream(o, std::ios::binary) << toPdfMulti(pages);
                out << "OK " << pages[0].sheetName << " escala " << pages[0].scale << "\n";
                for (size_t i = 0; i < pages.size(); i++) out << "HOJA\t" << i << "\t" << pages[i].kind << "\t" << pages[i].label << "\n";
                for (auto& pg : pages) for (auto& w : pg.warnings) out << "AVISO " << w << "\n";
                for (auto& x : pages[0].dims) if (x.kind == "globo") out << "PIEZA\t" << (int)x.value << "\t" << x.key << "\t" << pages[0].sheetW << "\t" << pages[0].sheetH << "\n";
                return env->NewStringUTF(out.str().c_str());
            }
        }
        Profile p; Drawing d;
        bool gear = false;
        { Classification c = classifyStep(str(env, step)); if (c.error.empty() && (c.group == 6 || c.group == 0)) gear = layoutSpring(str(env, step), m, d) || layoutGear(str(env, step), m, p, d) || layoutCamshaft(str(env, step), m, d) || layoutCam(str(env, step), m, d) || layoutCam3D(str(env, step), m, d); }
    if (!gear && !std::getenv("DIEDRO_NO_GEAR") && !std::getenv("DIEDRO_FORCE_PRISM")) { Classification c = classifyStep(str(env, step)); if (c.error.empty() && (c.group == 13 || c.group == 14)) gear = layoutPipe(str(env, step), m, d, c.group == 14); if (!gear && c.error.empty() && c.group == 14) gear = layoutHarness(str(env, step), m, d); }
    if (!gear && !std::getenv("DIEDRO_NO_GEAR") && !std::getenv("DIEDRO_FORCE_PRISM")) { Classification c = classifyStep(str(env, step)); if (c.error.empty() && c.group >= 1 && c.group <= 3) { gCamStrict = true; gCamMinH = 0.4; gear = layoutCamshaft(str(env, step), m, d) || layoutCam(str(env, step), m, d); gCamStrict = false; gCamMinH = 0; } }   // lóbulo de leva suelto: lo clasifica G1–G3, pero su contorno de arcos con taladro es de leva
        if (!gear) p = analyzeStep(str(env, step));
        bool prism = false;
        if (!gear && chooseEnginePrism(str(env, step), p)) {
            std::string e;
            d = layoutPrism(str(env, step), m, e);
            if (e.empty()) prism = true;
            else if (!p.error.empty()) { out << "ERROR " << e; return env->NewStringUTF(out.str().c_str()); }
        }
        if (!gear && !prism && !p.error.empty()) { out << "ERROR " << p.error; return env->NewStringUTF(out.str().c_str()); }
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
        std::ofstream(str(env, pdf), std::ios::binary) << (m.inspect ? toPdfMulti(pg) : toPdf(d));
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
    return env->NewStringUTF(out.str().c_str());
}

// Re-renderiza el último plano con las ediciones del usuario y devuelve la información para el editor (ver edit.cpp).
extern "C" JNIEXPORT jstring JNICALL Java_app_diedro_planos_Native_render(JNIEnv* env, jclass, jstring pdf, jstring ops) {
    std::ostringstream out;
    try {
        std::vector<Drawing> pages;
        { std::lock_guard<std::mutex> lk(gMu); pages = gPages; }
        if (pages.empty()) return env->NewStringUTF("ERROR sin plano");
        const std::string o = str(env, ops);
        for (size_t i = 0; i < pages.size(); i++) { applyEdits(pages[i], (int)i, o); out << editInfo(pages[i], (int)i); }
        std::ofstream(str(env, pdf), std::ios::binary) << toPdfMulti(pages);
    } catch (...) {
        return env->NewStringUTF("ERROR fallo interno al editar");
    }
    return env->NewStringUTF(out.str().c_str());
}

// Exporta hojas del último plano (con las ediciones) a PDF. sel = índices separados por coma; split = un PDF por hoja
// (dir/NN_etiqueta.pdf) o uno solo (dir/name). Devuelve las rutas escritas, una por línea, o «ERROR ...».
extern "C" JNIEXPORT jstring JNICALL Java_app_diedro_planos_Native_exportPages(JNIEnv* env, jclass, jstring dir, jstring name, jstring ops, jstring sel, jboolean split) {
    std::ostringstream out;
    try {
        std::vector<Drawing> pages;
        { std::lock_guard<std::mutex> lk(gMu); pages = gPages; }
        if (pages.empty()) return env->NewStringUTF("ERROR sin plano");
        const std::string o = str(env, ops), d = str(env, dir);
        std::vector<size_t> ix;
        { std::istringstream in(str(env, sel)); std::string t; while (std::getline(in, t, ',')) { size_t k = (size_t)std::atoi(t.c_str()); if (k < pages.size()) ix.push_back(k); } }
        if (ix.empty()) return env->NewStringUTF("ERROR sin hojas elegidas");
        for (size_t i = 0; i < pages.size(); i++) applyEdits(pages[i], (int)i, o);
        auto safe = [](const std::string& s) {
            std::string r;
            for (unsigned char c : s) { char o = (std::isalnum(c) || c == '-') ? (char)c : '_'; if (o != '_' || (!r.empty() && r.back() != '_')) r += o; }
            while (!r.empty() && r.back() == '_') r.pop_back();
            return r.empty() ? std::string("hoja") : r;
        };
        const std::string nm0 = str(env, name);
        const bool isDxf = nm0.size() > 4 && nm0.compare(nm0.size() - 4, 4, ".dxf") == 0, isSvg = nm0.size() > 4 && nm0.compare(nm0.size() - 4, 4, ".svg") == 0;
        if (isDxf && split) {   // todas las hojas elegidas en un solo DXF, una junto a otra
            std::vector<Drawing> v; for (size_t k : ix) v.push_back(pages[k]);
            const std::string f = d + "/" + nm0;
            std::ofstream(f, std::ios::binary) << toDxfMulti(v);
            out << f << "\n";
        } else if (isDxf || isSvg) {   // G9: una hoja = un archivo (DXF R12 o SVG); varias hojas: nombre_NN.ext
            for (size_t k : ix) {
                std::string f = d + "/" + nm0;
                if (ix.size() > 1) { char nn[8]; std::snprintf(nn, sizeof nn, "_%02zu", k + 1); f = d + "/" + nm0.substr(0, nm0.size() - 4) + nn + nm0.substr(nm0.size() - 4); }
                std::ofstream(f, std::ios::binary) << (isDxf ? toDxf(pages[k]) : toSvg(pages[k]));
                out << f << "\n";
            }
        } else if (!split) {
            std::vector<Drawing> v; for (size_t k : ix) v.push_back(pages[k]);
            const std::string f = d + "/" + str(env, name);
            std::ofstream(f, std::ios::binary) << toPdfMulti(v);
            out << f << "\n";
        } else for (size_t k : ix) {
            char nn[8]; std::snprintf(nn, sizeof nn, "%02zu_", k + 1);
            const std::string f = d + "/" + nn + safe(pages[k].label.empty() ? "hoja" : pages[k].label) + ".pdf";
            std::ofstream(f, std::ios::binary) << toPdf(pages[k]);
            out << f << "\n";
        }
    } catch (...) {
        return env->NewStringUTF("ERROR fallo interno al exportar");
    }
    return env->NewStringUTF(out.str().c_str());
}
