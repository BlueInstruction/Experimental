#!/usr/bin/env bash
set -e

# Configuration
MESON_CROSS_FILE="android-aarch64"
BUILD_DIR="build"
PACKAGE_DIR="package"
DRIVER_NAME="vulkan.ad07xx.so"
META_FILE="meta.json"
ZIP_NAME="MesaTurnipDriver-v25.3.3.zip"

echo "Starting Mesa Turnip build process..."

# 1. Apply patch if it exists
if [ -f "000001.patch" ]; then
    echo "Applying patch 000001.patch..."
    git apply 000001.patch
    echo "Patch applied successfully."
else
    echo "Warning: 000001.patch not found. Skipping patch application."
fi

# 2. Setup Meson build directory
echo "Configuring build with Meson..."
meson setup $BUILD_DIR \
    --cross-file $MESON_CROSS_FILE \
    --buildtype release \
    -Dplatforms=android \
    -Dgallium-drivers=turnip \
    -Dvulkan-drivers=adreno \
    -Dvulkan-beta=true \
    -Dandroid-stub=true \
    -Dstrip=true \
    -Dbuildtype=release

# 3. Compile the driver
echo "Compiling Mesa with Ninja..."
ninja -C $BUILD_DIR

# 4. Prepare package directory
echo "Preparing package directory..."
mkdir -p $PACKAGE_DIR/lib/arm64-v8a

# 5. Copy the built driver
echo "Copying driver to package directory..."
cp $BUILD_DIR/src/vulkan/drivers/turnip/libvulkan_turnip.so $PACKAGE_DIR/lib/arm64-v8a/$DRIVER_NAME

# 6. Create meta.json
echo "Creating $META_FILE..."
cat > $PACKAGE_DIR/$META_FILE << EOF
{
  "arch": "arm64-v8a",
  "abi": "arm64-v8a",
  "id": "mesa_adreno_driver",
  "version": "25.3.3",
  "name": "Mesa Turnip Driver (Adreno)",
  "author": "Mesa Project",
  "description": "Mesa Turnip Vulkan driver for Adreno GPUs, optimized for Android emulators."
}
EOF

# 7. Create the final ZIP archive
echo "Creating final ZIP archive: $ZIP_NAME..."
cd $PACKAGE_DIR && zip -r "../$ZIP_NAME" .

echo "Build and packaging completed successfully!"
echo "Output file: $ZIP_NAME"
