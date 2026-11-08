#pragma once
#include <string>
namespace diedro {
struct NoticeLine { const int* d; unsigned n; int w; };   // contornos: [npts,x,y,...]*, 1/1000 em, y hacia arriba, origen en la línea base
struct NoticeText { const NoticeLine* lines; unsigned nlines; };
// Aviso G15 ya modelado para ja/ko/zh/tw/th/hi (la fuente del PDF no tiene esos alfabetos); nullptr si no hay.
const NoticeText* noticeText(const std::string& lang, const std::string& es);
}
