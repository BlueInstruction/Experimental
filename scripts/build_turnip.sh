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

echo ">>> [3/6] Generating and Applying Patch..."
# We create the patch with the standard a/ and b/ prefixes for git compatibility
cat << 'EOF' > mesa_patch.diff
--- a/src/freedreno/vulkan/tu_device.c
+++ b/src/freedreno/vulkan/tu_device.c
@@ -234,6 +234,22 @@
    instance->physical_device_count = -1;
 
    instance->api_version = TU_API_VERSION;
+
+   // === SECRET RECIPE OPTIMIZATIONS ===
+   const char *dev_features = getenv("FD_DEV_FEATURES");
+   if (!dev_features) {
+       setenv("FD_DEV_FEATURES", "enable_tp_ubwc_flag_hint=1", 1);
+   }
+
+   const char *cache_size = getenv("MESA_SHADER_CACHE_MAX_SIZE");
+   if (!cache_size) {
+       setenv("MESA_SHADER_CACHE_MAX_SIZE", "1024M", 1);
+   }
+
+   const char *desc_idx = getenv("TU_DEBUG");
+   if (!desc_idx) {
+       setenv("TU_DEBUG", "force_unaligned_device_local", 1);
+   }
 
    if (pCreateInfo->pApplicationInfo) {
       const VkApplicationInfo *app = pCreateInfo->pApplicationInfo;
EOF

# Move into the mesa directory to apply
cd mesa
if [ -f "src/freedreno/vulkan/tu_device.c" ]; then
    echo "Found tu_device.c, applying patch..."
    git apply -p1 --whitespace=fix ../mesa_patch.diff
else
    echo "CRITICAL ERROR: Could not find src/freedreno/vulkan/tu_device.c"
    find . -name "tu_device.c"
    exit 1
fi
cd ..

echo ">>> [4/6] Configuring Meson..."
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

echo ">>> [6/6] Packaging..."
cp "$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so" ../"$OUTPUT_DIR"/vulkan.ad07xx.so

cd ../"$OUTPUT_DIR"
cat <<EOF > meta.json
{
  "name": "Turnip v25.3.3 - Adreno 750 Secret Recipe",
  "version": "25.3.3",
  "description": "Optimized A750. UBWC Hint + 1GB Shader Cache + Aarch64 LTO.",
  "library": "vulkan.ad07xx.so"
}
EOF

zip -r turnip_adreno750_optimized.zip vulkan.ad07xx.so meta.json
echo ">>> Build Complete."
