#!/usr/bin/env bash
set -e

ANDROID_NDK="${ANDROID_NDK:?Set ANDROID_NDK path}"
ANDROID_API=24
ARCH=aarch64
BUILD_DIR=build-android
OUT_DIR=out

mkdir -p "$BUILD_DIR" "$OUT_DIR"

# Generate cross file
cat > "$BUILD_DIR/android-aarch64.ini" <<EOF
[binaries]
c = '${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/${ARCH}-linux-android${ANDROID_API}-clang'
cpp = '${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/${ARCH}-linux-android${ANDROID_API}-clang++'
ar = '${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar'
strip = '${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip'
pkgconfig = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'arm'
cpu = 'armv8'
endian = 'little'
EOF

# Clone Mesa release
if [ ! -d mesa ]; then
    git clone --branch mesa-25.3.3 --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git mesa
fi

meson setup "$BUILD_DIR/meson" mesa \
    --cross-file "$BUILD_DIR/android-aarch64.ini" \
    -Dvulkan-drivers=freedreno

ninja -C "$BUILD_DIR/meson" src/freedreno/vulkan/libvulkan_freedreno.so

cp "$BUILD_DIR/meson/src/freedreno/vulkan/libvulkan_freedreno.so" "$OUT_DIR/vulkan.ad07xx.so"

cat > "$OUT_DIR/meta.json" <<JSON
{
  "name": "Turnip Vulkan Driver",
  "version": "25.3.3",
  "library": "vulkan.ad07xx.so",
  "adreno_support": ["6xx", "7xx", "750"]
}
JSON

zip -9 -r "$OUT_DIR/turnip_adreno_emulator.zip" "$OUT_DIR/vulkan.ad07xx.so" "$OUT_DIR/meta.json"
