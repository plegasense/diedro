#!/bin/sh
# Compila Open CASCADE Technology 7.9.3 (sin modificar) como biblioteca estática para android-arm64.
# Uso: tools/build_occt_android.sh <carpeta de trabajo>   (requiere git, cmake, ninja y el NDK; variable NDK opcional)
set -e
W="${1:?indica una carpeta de trabajo}"
NDK="${NDK:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
mkdir -p "$W" && cd "$W"
[ -d occt-src ] || git clone --depth 1 --branch V7_9_3 https://github.com/Open-Cascade-SAS/OCCT.git occt-src
mkdir -p build-arm64 install-arm64 && cd build-arm64
# -ffile-prefix-map evita que rutas de la máquina de compilación queden dentro de los binarios.
cmake -G Ninja ../occt-src \
 -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_shared \
 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=../install-arm64 -DBUILD_LIBRARY_TYPE=Static \
 -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$W=occt" -DCMAKE_C_FLAGS="-ffile-prefix-map=$W=occt" \
 -DBUILD_MODULE_Draw=OFF -DBUILD_MODULE_Visualization=OFF -DBUILD_MODULE_ApplicationFramework=ON -DBUILD_MODULE_DataExchange=ON \
 -DBUILD_DOC_Overview=OFF -DBUILD_Inspector=OFF -DBUILD_SAMPLES_MFC=OFF -DUSE_FREETYPE=OFF -DUSE_TK=OFF -DUSE_FREEIMAGE=OFF -DUSE_RAPIDJSON=OFF \
 -DUSE_TBB=OFF -DUSE_VTK=OFF -DUSE_DRACO=OFF -DUSE_OPENVR=OFF -DUSE_FFMPEG=OFF -DUSE_XLIB=OFF -DUSE_GLES2=OFF -DBUILD_WITH_DEBUG=OFF
ninja && ninja install
echo "OCCT instalado en $W/install-arm64  (usa occt.dir=$W/install-arm64 en android/local.properties)"
