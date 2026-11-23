#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build real de OCCT 7.9.3 (sin modificar) para Android arm64, estático. Uso: OCCT_SRC=... SDK=... tools/build_occt_android.sh
set -e
SDK=${SDK:-$HOME/Library/Android/sdk}; NDK=${NDK:-$SDK/ndk/28.2.13676358}
OCCT_SRC=${OCCT_SRC:-$HOME/occt-build/src}; B=${B:-$HOME/occt-build/b}; PREFIX=${PREFIX:-$HOME/occt-build/install}
export PATH=$SDK/cmake/3.22.1/bin:$PATH
cmake -G Ninja -S "$OCCT_SRC" -B "$B" -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_shared -DCMAKE_BUILD_TYPE=Release -DBUILD_LIBRARY_TYPE=Static -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_MODULE_Draw=OFF -DBUILD_MODULE_Visualization=OFF -DBUILD_MODULE_DETools=OFF -DUSE_FREETYPE=OFF -DUSE_TK=OFF -DUSE_VTK=OFF -DUSE_RAPIDJSON=OFF -DUSE_TBB=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF -DBUILD_DOC_Overview=OFF -DINSTALL_TEST_CASES=OFF -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$OCCT_SRC=occt"
cmake --build "$B" -j10
cmake --install "$B"
