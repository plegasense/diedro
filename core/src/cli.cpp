// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// diedro_cli entrada.step salida.pdf [titulo] [material] [tolerancia] [n_plano]
#include "projsym.hpp"
#include "dfm.hpp"
#include "i18n.hpp"
#include "progress.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include "analyze.hpp"
#include "prism.hpp"
#include "classify.hpp"
#include "gear.hpp"
#include "special.hpp"
#include "assembly.hpp"
#include "iso.hpp"
#include "inspect.hpp"
using namespace diedro;

int main(int argc, char** argv) {
    if (argc < 3) { std::puts("uso: diedro_cli in.step out.pdf [titulo] [material] [tolerancia] [n_plano]"); return 2; }
    if (std::getenv("DIEDRO_CLASSIFY")) {
        Classification c = classifyStep(argv[1]);
        if (!c.error.empty()) { std::printf("ERROR %s\n", c.error.c_str()); return 1; }
        std::printf("CLASE G%d %s conf=%.2f | %s%s\n", c.group, groupName(c.group), c.conf, c.reason.c_str(), c.alt ? (" | alt=G" + std::to_string(c.alt)).c_str() : "");
        if (std::getenv("DIEDRO_CLASSIFY_FEAT")) { for (auto& f : c.feat) std::printf("FEAT %s=%g\n", f.first.c_str(), f.second); }
        return 0;
    }
    if (std::getenv("DIEDRO_DFM_ONLY")) { for (auto& w : dfmCheck(argv[1], "es")) std::printf("DFM %s\n", w.c_str()); return 0; }   // G12: solo la revisión, sin plano
    auto t0 = std::chrono::steady_clock::now();
    Meta m;
    if (argc > 3) m.title = argv[3];
    if (argc > 4) m.material = argv[4];
    if (argc > 5) m.generalTolerance = argv[5];
    if (argc > 6) m.partNo = argv[6];
    if (const char* l = std::getenv("DIEDRO_LANG")) { m.langUi = l; m.lang = pdfLang(l); }
    m.imperial = std::getenv("DIEDRO_IMPERIAL") != nullptr;
    if (const char* pj = std::getenv("DIEDRO_PROJ")) gThirdAngle = std::string(pj) == "asme" || std::string(pj) == "3";   // G10: asme = tercer diedro
    if (const char* sh = std::getenv("DIEDRO_SHEET")) m.sheet = sh;
    m.explode = std::getenv("DIEDRO_EXPLODE") != nullptr;
    for (int i = 7; i + 1 < argc; i += 2) setUserTol(m, argv[i], argv[i + 1]);
    if (!std::getenv("DIEDRO_NO_DISCARD")) {   // G15: pieza fuera de alcance -> hoja de aviso, sin vistas ni cotas
        Classification c = classifyStep(argv[1]);
        if (c.discard) { Drawing d = layoutDiscard(c, m, argv[1]); std::ofstream(argv[2], std::ios::binary) << toPdf(d); std::printf("DESCARTE %d %s | %s\n", c.discard, d.warnings.empty() ? "" : d.warnings[0].c_str(), c.reason.c_str()); return 0; }
    }
    if (!std::getenv("DIEDRO_FORCE_PRISM") && !std::getenv("DIEDRO_NO_ASM")) {
        Classification c = classifyStep(argv[1]);
        if (c.error.empty() && c.group == 7 && c.conf >= 0.6) {
            std::string out = argv[2], e;
            size_t sl = out.find_last_of('/');
            std::string tmp = sl == std::string::npos ? "." : out.substr(0, sl);
            if (m.title.empty()) { std::string b = argv[1]; b = b.substr(b.find_last_of('/') + 1); m.title = b.substr(0, b.rfind('.')); }
            auto t0 = std::chrono::steady_clock::now();
            auto pages = layoutAssembly(argv[1], m, tmp, e, c.nParts);
            if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "CLI layoutAssembly %.1fs\n", std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
            if (!e.empty()) { std::printf("ERROR %s\n", e.c_str()); return 1; }
            auto t1 = std::chrono::steady_clock::now();
            std::ofstream(argv[2], std::ios::binary) << toPdfMulti(pages);
            if (std::getenv("DIEDRO_DBG")) std::fprintf(stderr, "CLI pdf %.1fs\n", std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count());
            std::printf("OK %s escala=%g hojas=%zu\nCONJUNTO\n", pages[0].sheetName.c_str(), pages[0].scale, pages.size());
            for (auto& x : pages[0].dims) std::printf("GLOBO %g cant=%s\n", x.value, x.text.c_str());
            std::printf("HOJAS %zu\n", pages.size());
            if (std::getenv("DIEDRO_CHECK")) for (size_t i = 0; i < pages.size(); i++) for (auto& o : findOverlaps(pages[i])) std::printf("SOLAPE hoja %zu %s\n", i + 1, o.c_str());
            for (auto& pg : pages) for (auto& w : pg.warnings) std::printf("AVISO %s\n", w.c_str());
            return 0;
        }
    }
    progress(1, 0);
    Profile p;
    Drawing d;
    bool gear = false;
    if (!std::getenv("DIEDRO_NO_GEAR") && !std::getenv("DIEDRO_FORCE_PRISM")) { Classification c = classifyStep(argv[1]); if (c.error.empty() && (c.group == 6 || c.group == 0)) { const bool corona = c.reason.find("corona") != std::string::npos; gear = (!corona && layoutSpring(argv[1], m, d)) || layoutGear(argv[1], m, p, d) || (!gManyFree && (layoutCamshaft(argv[1], m, d) || layoutCam(argv[1], m, d) || layoutCam3D(argv[1], m, d))); } }   // rosca de tornillo (>100 caras B-spline, «corona») no es muelle ni leva: ahorra ≈0,6 s
    if (!gear && !std::getenv("DIEDRO_NO_GEAR") && !std::getenv("DIEDRO_FORCE_PRISM")) { Classification c = classifyStep(argv[1]); if (c.error.empty() && (c.group == 13 || c.group == 14)) gear = layoutPipe(argv[1], m, d, c.group == 14); if (!gear && c.error.empty() && c.group == 14) gear = layoutHarness(argv[1], m, d); }   // tubo curvado: línea media y tabla de curvado
    if (!gear && !std::getenv("DIEDRO_NO_GEAR") && !std::getenv("DIEDRO_FORCE_PRISM")) { Classification c = classifyStep(argv[1]); if (c.error.empty() && c.group >= 1 && c.group <= 3) { gCamStrict = true; gCamMinH = 0.4; gear = layoutCamshaft(argv[1], m, d) || layoutCam(argv[1], m, d); gCamStrict = false; gCamMinH = 0; } }   // lóbulo de leva suelto: lo clasifica G1–G3, pero su contorno de arcos con taladro es de leva
    if (!gear) p = analyzeStep(argv[1]);
    if (std::getenv("DIEDRO_PMI")) for (auto& q : readPmi(argv[1])) std::printf("PMI %s %g +%g %g\n", q.diameter ? "dia" : q.radius ? "rad" : "len", q.value, q.upper, q.lower);
    if (const char* tp = std::getenv("DIEDRO_TESTPMI")) { PmiDim q; q.diameter = true; std::sscanf(tp, "%lf:%lf:%lf", &q.value, &q.upper, &q.lower); p.pmi.push_back(q); }  // solo pruebas
    bool prism = false;
    if (!gear && (std::getenv("DIEDRO_FORCE_PRISM") || chooseEnginePrism(argv[1], p))) {
        std::string e;
        d = layoutPrism(argv[1], m, e);
        if (e.empty()) prism = true;
        else if (!p.error.empty()) { std::printf("ERROR %s\n", e.c_str()); return 1; }
    }
    if (!prism && !gear && !p.error.empty()) { std::printf("ERROR %s\n", p.error.c_str()); return 1; }
    for (auto& h : p.rholes) std::printf("RHOLE z=%g ang=%.1f r=%g depth=%g thru=%d\n", h.z, h.ang * 57.29578, h.r, h.depth, (int)h.through);
    for (auto& k : p.cuts) std::printf("CUT slot=%d ang=%.1f h=%g w=%g z=%g..%g\n", (int)k.slot, k.ang * 57.29578, k.h, k.w, k.z0, k.z1);
    if (std::getenv("DIEDRO_SEGS")) for (auto& g : p.segs) std::printf("SEG kind=%d inner=%d z=%g..%g r=%g..%g\n", (int)g.kind, (int)g.inner, g.z0, g.z1, g.r0, g.r1);
    if (!prism && !gear) d = layout(p, m);
    if (!prism && !gear) {   // torneado inválido (pieza no de revolución, p. ej. pistón): si el motor prismático la entiende, mejor ese
        bool nt = false; for (auto& w : d.warnings) if (w == tr("PIEZA NO TORNEADA: predominan rasgos que no son de revolución; este plano NO es válido para fabricar.", m.lang)) nt = true;
        if (nt) { std::string e2; Drawing d2 = layoutPrism(argv[1], m, e2); bool bad = !e2.empty(); for (auto& w : d2.warnings) if (w == tr("PIEZA NO PRISMÁTICA: predominan rasgos sin acotar; este plano NO es válido para fabricar.", m.lang)) bad = true; if (!bad) { d = d2; prism = true; } }
    }
    progress(70, 3);
    if (!std::getenv("DIEDRO_NO_ISO")) { addIsoStep(d, argv[1]); if (!std::getenv("DIEDRO_NO_BAL")) balanceViews(d); }
    if (const char* eo = std::getenv("DIEDRO_EDIT")) {   // pruebas del editor: órdenes con \t y \n literales
        std::string o = eo;
        for (size_t i; (i = o.find("\\t")) != std::string::npos;) o.replace(i, 2, "\t");
        for (size_t i; (i = o.find("\\n")) != std::string::npos;) o.replace(i, 2, "\n");
        applyEdits(d, 0, o);
        std::printf("%s", editInfo(d, 0).substr(0, 4000).c_str());
    }
    progress(86, 4);
    std::string pdf; std::vector<Drawing> allp{d};
    if (std::getenv("DIEDRO_INSPECT")) {   // G8: globos + tabla de inspección (PDF de varias hojas) y CSV junto al PDF
        auto rows = addBalloons(d, m); auto pages = inspectionSheets(d, rows, m); pages.insert(pages.begin(), d); allp = pages;
        pdf = toPdfMulti(pages); std::ofstream(std::string(argv[2]) + ".csv", std::ios::binary) << inspectionCsv(rows, m.lang);
        for (auto& r : rows) std::printf("CARACT %d %s %s | %s x%d %c %s\n", r.n, r.kind.c_str(), r.req.c_str(), r.tol.c_str(), r.qty, r.cls ? r.cls : '-', r.placed ? "globo" : "SIN-GLOBO");
    } else pdf = toPdf(d);
    if (const char* jp = std::getenv("DIEDRO_JSON")) std::ofstream(jp, std::ios::binary) << toJson(d);
    std::ofstream(argv[2], std::ios::binary) << pdf;
    if (const char* fm = std::getenv("DIEDRO_FMT")) {   // G9: además del PDF, DXF y/o SVG de cada hoja (<salida>.NN.dxf / .svg)
        const std::string fs = fm;
        for (size_t i = 0; i < allp.size(); i++) {
            char nn[16]; std::snprintf(nn, sizeof nn, ".%02zu", i + 1);
            if (fs.find("dxf") != std::string::npos) std::ofstream(std::string(argv[2]) + nn + ".dxf", std::ios::binary) << toDxf(allp[i], fs.find("sombra") != std::string::npos);
            if (fs.find("svg") != std::string::npos) std::ofstream(std::string(argv[2]) + nn + ".svg", std::ios::binary) << toSvg(allp[i]);
        }
        if (fs.find("todo") != std::string::npos) std::ofstream(std::string(argv[2]) + ".todo.dxf", std::ios::binary) << toDxfMulti(allp, fs.find("sombra") != std::string::npos);
    }
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    std::printf("OK %s escala=%g tiempo=%.0fms L=%g segs=%zu\n", d.sheetName.c_str(), d.scale, ms, p.length, p.segs.size());
    if (prism) std::puts("PRISMA");
    { Classification c = classifyStep(argv[1]); if (c.error.empty()) std::printf("GRUPO G%d %s conf=%.2f | %s\n", c.group, groupName(c.group), c.conf, c.reason.c_str()); }
    { Classification c = classifyStep(argv[1]); if (c.error.empty() && c.group == 4 && c.cut.ok) { const CutInfo& k = c.cut; std::printf("CORTE kind=%d w=%.3f h=%.3f lmax=%.3f lmin=%.3f e1=%.2f,%.2f e2=%.2f,%.2f t=%.3f,%.3f\n", k.kind, k.w, k.h, k.lenMax, k.lenMin, 90 - std::fabs(k.tilt[0][0]), 90 - std::fabs(k.tilt[0][1]), 90 - std::fabs(k.tilt[1][0]), 90 - std::fabs(k.tilt[1][1]), k.t1, k.t2); } }
    for (auto& x : d.dims) { std::printf("DIM %s %g %s\n", x.kind.c_str(), x.value, x.text.c_str()); if (x.axis >= 0) std::printf("ORD %d %g\n", x.axis, x.value); }
    if (std::getenv("DIEDRO_CHECK")) { for (auto& o : findOverlaps(d)) std::printf("SOLAPE %s\n", o.c_str()); for (auto& o : parallelGaps(d)) std::printf("PARALELA %s\n", o.c_str()); }
    for (auto& h : d.holeRefs) std::printf("AGUJERO hoja(%.1f,%.1f) p(%.3f,%.3f,%.3f) eje(%.2f,%.2f,%.2f) d=%.2f\n", h.x, h.y, h.p[0], h.p[1], h.p[2], h.a[0], h.a[1], h.a[2], h.dia);
    for (auto& r : d.viewRefs) std::printf("VISTA %d o(%.1f,%.1f) x(%.2f,%.2f) y(%.2f,%.2f) z(%.2f,%.2f) caja(%.1f,%.1f,%.1f,%.1f)\n", r.v, r.o[0], r.o[1], r.e[0][0], r.e[0][1], r.e[1][0], r.e[1][1], r.e[2][0], r.e[2][1], r.box[0], r.box[1], r.box[2], r.box[3]);
    for (auto& w : d.warnings) std::printf("AVISO %s\n", w.c_str());
    if (std::getenv("DIEDRO_DFM")) for (auto& w : dfmCheck(argv[1], m.lang)) std::printf("DFM %s\n", w.c_str());   // G12: solo avisos, el plano no cambia
    return 0;
}
