#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_WORK="$ROOT_DIR/vendor_build"
OUT_DIR="$ROOT_DIR/build/helpers"
SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="${ARCH:-x86_64}"
MIN_MACOS="${MIN_MACOS:-13.0}"

mkdir -p "$BUILD_WORK" "$OUT_DIR"

echo "==> Building native Intel macOS helpers ($ARCH, macOS $MIN_MACOS+)"

# 1. Build ms-sys 2.8.0 (Windows NT6/10/11 MBR + FAT32/ExFAT BOOTMGR VBR)
if [ ! -x "$OUT_DIR/ms-sys" ]; then
    echo "==> Building ms-sys 2.8.0..."
    cd "$BUILD_WORK"
    if [ ! -f ms-sys-2.8.0.tar.gz ]; then
        curl -fSL -o ms-sys-2.8.0.tar.gz "https://sourceforge.net/projects/ms-sys/files/ms-sys%20stable/2.8.0/ms-sys-2.8.0.tar.gz/download"
    fi
    rm -rf ms-sys-2.8.0
    tar -xzf ms-sys-2.8.0.tar.gz
    cd ms-sys-2.8.0
    clang -O2 -arch "$ARCH" -mmacosx-version-min="$MIN_MACOS" \
        -Iinc -Iinclude-fallback -DNO_NLS \
        -DPACKAGE=\"ms-sys\" -DLOCALEDIR=\"/usr/share/locale\" \
        src/*.c -o "$OUT_DIR/ms-sys"
    strip "$OUT_DIR/ms-sys"
    echo "    Built: $OUT_DIR/ms-sys"
else
    echo "    Using existing $OUT_DIR/ms-sys"
fi

# 2. Build static wimlib-imagex 1.14.5 (splits >4GB Windows install.wim into .swm for FAT32)
if [ ! -x "$OUT_DIR/wimlib-imagex" ]; then
    echo "==> Building static wimlib-imagex 1.14.5..."
    cd "$BUILD_WORK"
    if [ ! -f wimlib-1.14.5.tar.gz ]; then
        curl -fSL -o wimlib-1.14.5.tar.gz "https://wimlib.net/downloads/wimlib-1.14.5.tar.gz"
    fi
    rm -rf wimlib-1.14.5
    tar -xzf wimlib-1.14.5.tar.gz
    cd wimlib-1.14.5
    PKG_CONFIG=/usr/bin/true ./configure \
        --disable-shared \
        --enable-static \
        --without-ntfs-3g \
        --without-fuse \
        CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=$MIN_MACOS" \
        LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS" \
        LIBXML2_CFLAGS="-I${SDK_PATH}/usr/include/libxml2" \
        LIBXML2_LIBS="-lxml2"
    make -j"$(sysctl -n hw.ncpu)" wimlib-imagex
    cp wimlib-imagex "$OUT_DIR/wimlib-imagex"
    strip "$OUT_DIR/wimlib-imagex"
    echo "    Built: $OUT_DIR/wimlib-imagex"
else
    echo "    Using existing $OUT_DIR/wimlib-imagex"
fi

echo "==> Helper binaries ready:"
ls -lh "$OUT_DIR"
