#!/usr/bin/env bash
set -e

# Configuration
MESA_VERSION="mesa-25.3.3"
MESA_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_DIR="build-android"
OUTPUT_DIR="build_output"
ANDROID_API_LEVEL="29" # Android 10+ required for some A7xx features

echo ">>> [1/6] Preparing Build Environment..."
mkdir -p "$OUTPUT_DIR"
rm -rf mesa "$BUILD_DIR"

echo ">>> [2/6] Cloning Mesa ($MESA_VERSION)..."
git clone --depth 1 --branch "$MESA_VERSION" "$MESA_URL" mesa

echo ">>> [3/6] Applying Secret Recipe Patch..."
cp 000001.patch mesa/
cd mesa
git apply 000001.patch
cd ..

echo ">>> [4/6] Configuring Meson (Optimization Level: Aggressive)..."
# Using NDK from environment
cp android-aarch64 mesa/

cd mesa
meson setup "$BUILD_DIR" \
    --cross-file android-aarch64 \
    --buildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version="$ANDROID_API_LEVEL" \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Db_lto=true \
    -Doptimization=3 \
    -Dstrip=true \
    -Dglx=disabled \
    -Dgbm=disabled \
    -Degl=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dshared-glapi=false \
    -Dllvm=disabled

echo ">>> [5/6] Compiling Driver..."
ninja -C "$BUILD_DIR"

echo ">>> [6/6] Packaging Artifacts..."
mkdir -p ../"$OUTPUT_DIR"
cp "$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so" ../"$OUTPUT_DIR"/vulkan.ad07xx.so

cd ../"$OUTPUT_DIR"

# Create meta.json for Winlator/Mobox
cat <<EOF > meta.json
{
  "name": "Turnip v25.3.3 - Adreno 750 Secret Recipe",
  "version": "25.3.3",
  "description": "Optimized for A750. Fixes: AC Mirage Sky, Valhalla Cache, Horizon Glitches. Enforced UBWC & High Cache.",
  "author": "Custom Build",
  "library": "vulkan.ad07xx.so"
}
EOF

zip -r turnip_adreno750_optimized.zip vulkan.ad07xx.so meta.json

echo ">>> Build Complete. Check $OUTPUT_DIR"
