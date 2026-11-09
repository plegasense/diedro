// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
// Perfiles construidos a mano (verdad analítica) -> layout -> PDF. Sin OCCT: corre en Mac.
#include <cstdio>
#include <fstream>
#include "../src/profile.hpp"
using namespace diedro;

static Seg L(double z0, double r0, double z1, double r1, bool in = false) { Seg s; s.kind = Seg::Line; s.z0 = z0; s.r0 = r0; s.z1 = z1; s.r1 = r1; s.inner = in; return s; }
static Seg P(double z, double r0, double r1) { Seg s; s.kind = Seg::Plane; s.z0 = s.z1 = z; s.r0 = r0; s.r1 = r1; return s; }

int main(int argc, char** argv) {
    Profile t1;  // T01: D30x20, D20x30, D12x15
    t1.length = 65;
    t1.segs = {P(0, 0, 15), L(0, 15, 20, 15), P(20, 10, 15), L(20, 10, 50, 10), P(50, 6, 10), L(50, 6, 65, 6), P(65, 0, 6)};
    Profile t5;  // T05 casquillo escalonado con avellanado
    t5.length = 40;
    t5.segs = {P(0, 14, 25), L(0, 25, 12, 25), P(12, 18, 25), L(12, 18, 40, 18), P(40, 10, 18), L(6, 10, 40, 10, true), P(6, 10, 14), L(0, 14, 6, 14, true)};
    Meta m; m.title = "Eje escalonado";
    const char* dir = argc > 1 ? argv[1] : ".";
    int i = 0;
    for (Profile* p : {&t1, &t5}) {
        Drawing d = layout(*p, m);
        std::ofstream((std::string(dir) + "/h" + std::to_string(i++) + ".pdf"), std::ios::binary) << toPdf(d);
        for (auto& x : d.dims) std::printf("%s %s\n", x.kind.c_str(), x.text.c_str());
        std::printf("-- %s escala %g\n", d.sheetName.c_str(), d.scale);
    }
}
