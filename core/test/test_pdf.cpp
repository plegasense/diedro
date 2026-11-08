#include <cstdio>
#include <cstdlib>
#include <fstream>
#include "../src/drawing.hpp"
using namespace diedro;

static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FALLO %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

static Drawing sample() {
    Drawing d;
    d.lines.push_back({20, 100, 120, 100});
    d.lines.push_back({20, 90, 120, 90, LineType::Hidden});
    d.lines.push_back({10, 95, 130, 95, LineType::Center, 0.18});
    d.arcs.push_back({150, 100, 20, 0, 270});
    d.texts.push_back({20, 150, 3.5, "Eje (D30) \\ prueba"});
    d.texts.push_back({20, 140, 3.5, "MATERIAL: NO DEFINIDO", 0, true});
    return d;
}

int main(int argc, char** argv) {
    Drawing d = sample();
    std::string a = toPdf(d), b = toPdf(sample());
    CHECK(a == b);                                   // determinista
    CHECK(a.rfind("%PDF-1.4", 0) == 0);
    CHECK(a.find("%%EOF") != std::string::npos);
    CHECK(a.find("/MediaBox [0 0 841.890 595.276]") != std::string::npos);
    CHECK(a.find("(Eje \\(D30\\) \\\\ prueba)") != std::string::npos);  // escape
    // startxref apunta a "xref"
    size_t p = a.rfind("startxref\n") + 10;
    size_t off = std::strtoull(a.c_str() + p, nullptr, 10);
    CHECK(a.compare(off, 4, "xref") == 0);
    // cada entrada xref apunta a "N 0 obj"
    size_t x = off + a.substr(off).find("0000000000 65535 f \n") + 20;
    for (int i = 1; i <= 5; i++, x += 20) {
        size_t o = std::strtoull(a.c_str() + x, nullptr, 10);
        std::string t = std::to_string(i) + " 0 obj";
        CHECK(a.compare(o, t.size(), t) == 0);
    }
    // /Length coincide con el flujo
    size_t l = a.find("/Length ") + 8, len = std::strtoull(a.c_str() + l, nullptr, 10);
    size_t s = a.find("stream\n") + 7, e = a.find("endstream");
    CHECK(e - s == len);
    std::string j = toJson(d);
    CHECK(j == toJson(sample()));
    CHECK(j.find("\"format\":1") != std::string::npos && j.find("\"undefined\":true") != std::string::npos);
    if (argc > 1) { std::ofstream(argv[1], std::ios::binary) << a; }
    std::printf(fails ? "%d FALLOS\n" : "OK todos\n", fails);
    return fails ? 1 : 0;
}
