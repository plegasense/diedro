#pragma once
// Progreso del motor (0-100 y etapa) para la pantalla de carga de la app; con DIEDRO_PROGRESS=1 el CLI lo imprime con tiempos (para ver dónde se va el tiempo).
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
namespace diedro {
inline std::atomic<int> gProg{0}, gStage{0};   // etapa: 0 leer, 1 analizar, 2 vistas y cotas, 3 isométrico, 4 globos, 5 escribir
inline void progress(int pct, int stage) {
    static const auto t0 = std::chrono::steady_clock::now();
    if (pct < gProg.load() && pct != 0) return;   // nunca retrocede
    gProg = pct; gStage = stage;
    if (std::getenv("DIEDRO_PROGRESS")) std::fprintf(stderr, "PROG %5.1fs %3d%% etapa %d\n", std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(), pct, stage);
}
}
