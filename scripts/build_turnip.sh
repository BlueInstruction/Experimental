#!/usr/bin/env bash
set -e

# Configuration
MESA_VERSION="mesa-25.3.3"
MESA_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_DIR="build-android"
OUTPUT_DIR="build_output"
ANDROID_API_LEVEL="29"

echo ">>> [1/6] Preparing Build Environment..."
mkdir -p "$OUTPUT_DIR"
rm -rf mesa "$BUILD_DIR"

echo ">>> [2/6] Cloning Mesa ($MESA_VERSION)..."
git clone --depth 1 --branch "$MESA_VERSION" "$MESA_URL" mesa

echo ">>> [3/6] Applying Turnip environment injection..."
cd mesa

# Find the file containing the TU_API_VERSION assignment (robust for Mesa 24.x/25.x)
TARGET_FILE=$(grep -Rwl "instance->api_version = TU_API_VERSION;" src/freedreno/vulkan || true)

if [ -z "$TARGET_FILE" ] || [ ! -f "$TARGET_FILE" ]; then
    echo "CRITICAL ERROR: TU_API_VERSION assignment not found."
    echo "Debug dump:"
    grep -R "TU_API_VERSION" src/freedreno/vulkan || true
    exit 1
fi

echo "Injecting into file: $TARGET_FILE"

# Inject environment overrides directly after the api_version assignment
sed -i '/instance->api_version = TU_API_VERSION;/a \
\
   if (!getenv("FD_DEV_FEATURES")) {\
       setenv("FD_DEV_FEATURES", "enable_tp_ubwc_flag_hint=1", 1);\
   }\
   if (!getenv("MESA_SHADER_CACHE_MAX_SIZE")) {\
       setenv("MESA_SHADER_CACHE_MAX_SIZE", "1024M", 1);\
   }\
   if (!getenv("TU_DEBUG")) {\
       setenv("TU_DEBUG", "force_unaligned_device_local", 1);\
   }' "$TARGET_FILE"

echo "Verification:"
grep -n "setenv(" "$TARGET_FILE"

cd ..

echo ">>> [4/6] Configuring Meson..."

# Cross file must exist at repo root with exact name
if [ ! -f "android-aarch64" ]; then
    echo "ERROR: Cross file 'android-aarch64' not found in repository root."
    exit 1
fi

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
    -Dllvm=disabled

echo ">>> [5/6] Compiling..."
ninja -C "$BUILD_DIR"

echo ">>> [6/6] Packaging Artifacts..."
DRIVER_LIB=$(find "$BUILD_DIR" -name "libvulkan_freedreno.so" | head -n 1)

if [ -z "$DRIVER_LIB" ]; then
    echo "ERROR: libvulkan_freedreno.so not found."
    exit 1
fi

cp "$DRIVER_LIB" ../"$OUTPUT_DIR"/vulkan.ad07xx.so

cd ../"$OUTPUT_DIR"

cat <<EOF > meta.json
{
  "name": "Turnip v25.3.3 - Adreno 750 Optimized",
  "version": "25.3.3",
  "description": "Custom A750 build with Turnip environment overrides.",
  "library": "vulkan.ad07xx.so"
}
EOF

zip -r turnip_adreno750_optimized.zip vulkan.ad07xx.so meta.json

echo ">>> Build Complete."
