// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
#include <cstdio>
#include <sstream>
#include "drawing.hpp"

namespace diedro {
namespace {
std::string n(double v) { char b[48]; std::snprintf(b, sizeof b, "%.4f", v); return b; }
std::string esc(const std::string& s) {
    std::string o;
    for (char c : s) { if (c == '"' || c == '\\') o += '\\'; o += c; }
    return o;
}
const char* lt(LineType t) { return t == LineType::Hidden ? "hidden" : t == LineType::Center ? "center" : "continuous"; }
}  // namespace

std::string toJson(const Drawing& d) {
    std::ostringstream o;
    o << "{\"format\":1,\"sheet\":[" << n(d.sheetW) << "," << n(d.sheetH) << "],\"lines\":[";
    for (size_t i = 0; i < d.lines.size(); i++) {
        const auto& l = d.lines[i];
        o << (i ? "," : "") << "{\"p\":[" << n(l.x1) << "," << n(l.y1) << "," << n(l.x2) << "," << n(l.y2) << "],\"type\":\"" << lt(l.type) << "\",\"w\":" << n(l.width) << "}";
    }
    o << "],\"arcs\":[";
    for (size_t i = 0; i < d.arcs.size(); i++) {
        const auto& a = d.arcs[i];
        o << (i ? "," : "") << "{\"c\":[" << n(a.cx) << "," << n(a.cy) << "],\"r\":" << n(a.r) << ",\"a\":[" << n(a.a0) << "," << n(a.a1) << "],\"type\":\"" << lt(a.type) << "\",\"w\":" << n(a.width) << "}";
    }
    o << "],\"texts\":[";
    for (size_t i = 0; i < d.texts.size(); i++) {
        const auto& t = d.texts[i];
        o << (i ? "," : "") << "{\"p\":[" << n(t.x) << "," << n(t.y) << "],\"h\":" << n(t.height) << ",\"angle\":" << n(t.angle) << ",\"undefined\":" << (t.undefined ? "true" : "false") << ",\"s\":\"" << esc(t.s) << "\"}";
    }
    o << "],\"polys\":[";
    for (size_t i = 0, k = 0; i < d.polys.size(); i++) {
        if (d.polys[i].hatch > 0) continue;
        o << (k++ ? "," : "") << "{\"white\":" << (d.polys[i].white ? "true" : "false") << ",\"pts\":[";
        for (size_t j = 0; j < d.polys[i].pts.size(); j++) o << (j ? "," : "") << "[" << n(d.polys[i].pts[j].first) << "," << n(d.polys[i].pts[j].second) << "]";
        o << "]}";
    }
    o << "],\"dims\":[";
    for (size_t i = 0; i < d.dims.size(); i++)
        o << (i ? "," : "") << "{\"kind\":\"" << esc(d.dims[i].kind) << "\",\"value\":" << n(d.dims[i].value) << ",\"text\":\"" << esc(d.dims[i].text) << "\"}";
    o << "],\"warnings\":[";
    for (size_t i = 0; i < d.warnings.size(); i++) o << (i ? "," : "") << "\"" << esc(d.warnings[i]) << "\"";
    o << "],\"scale\":" << n(d.scale) << ",\"sheetName\":\"" << esc(d.sheetName) << "\"}";
    return o.str();
}
}  // namespace diedro
