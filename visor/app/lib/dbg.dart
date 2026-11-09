// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
/// Trazas de depuración: solo se ejecutan en debug (los assert desaparecen en release).
void dbg(Object? o) {
  assert(() {
    // ignore: avoid_print
    print(o);
    return true;
  }());
}
