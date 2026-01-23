#!/bin/bash -e

set -o pipefail

# COLORS
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# CONFIG
BUILD_DIR="$(pwd)/build_workspace"
PATCHES_DIR="$(pwd)/patches"
NDK_VERSION="${NDK_VERSION:-android-ndk-r30}"
API_LEVEL="${API_LEVEL:-35}"

# Mesa Sources
MESA_FREEDESKTOP="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_FREEDESKTOP_MIRROR="https://github.com/mesa3d/mesa.git"
MESA_WHITEBELYASH="https://github.com/whitebelyash/mesa-tu8.git"
MESA_WHITEBELYASH_BRANCH="8gen"

# Runtime Config
MESA_REPO_SOURCE="${MESA_REPO_SOURCE:-freedesktop}"
BUILD_VARIANT="${1:-a7xx}"
CUSTOM_COMMIT="${2:-}"
COMMIT_HASH_SHORT=""
MESA_VERSION=""
MAX_RETRIES=3
RETRY_DELAY=15
BUILD_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# LOGGING
log()     { echo -e "${CYAN}[Build]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()    { echo -e "${MAGENTA}[INFO]${NC} $1"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}\n"; }

# UTILITIES
retry_command() {
    local cmd="$1"
    local description="$2"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log "Attempt $attempt/$MAX_RETRIES: $description"
        if eval "$cmd"; then
            return 0
        fi
        warn "Failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        ((attempt++))
    done

    return 1
}

check_dependencies() {
    log "Checking dependencies..."
    local deps=(git curl unzip patchelf zip meson ninja ccache)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
    fi
    success "All dependencies found"
}

# NDK SETUP
setup_ndk() {
    header "NDK Setup"

    if [ -n "${ANDROID_NDK_LATEST_HOME}" ] && [ -d "${ANDROID_NDK_LATEST_HOME}" ]; then
        export ANDROID_NDK_HOME="${ANDROID_NDK_LATEST_HOME}"
        info "Using system NDK: $ANDROID_NDK_HOME"
        return
    fi

    if [ -d "$BUILD_DIR/$NDK_VERSION" ]; then
        export ANDROID_NDK_HOME="$BUILD_DIR/$NDK_VERSION"
        info "Using cached NDK: $ANDROID_NDK_HOME"
        return
    fi

    log "Downloading NDK $NDK_VERSION..."
    local ndk_url="https://dl.google.com/android/repository/${NDK_VERSION}-linux.zip"

    if ! retry_command "curl -sL '$ndk_url' -o core.zip" "Downloading NDK"; then
        error "Failed to download NDK"
    fi

    unzip -q core.zip && rm -f core.zip
    export ANDROID_NDK_HOME="$BUILD_DIR/$NDK_VERSION"
    success "NDK installed: $ANDROID_NDK_HOME"
}

# MESA CLONE
clone_mesa() {
    header "Mesa Source"

    [ -d "$BUILD_DIR/mesa" ] && rm -rf "$BUILD_DIR/mesa"

    if [ "$MESA_REPO_SOURCE" = "whitebelyash" ]; then
        log "Cloning from Whitebelyash (Gen8 branch)..."
        if retry_command "git clone --depth=200 --branch '$MESA_WHITEBELYASH_BRANCH' '$MESA_WHITEBELYASH' '$BUILD_DIR/mesa' 2>/dev/null" "Cloning Whitebelyash"; then
            setup_mesa_repo
            apply_whitebelyash_fixes
            return
        fi
        warn "Whitebelyash unavailable, falling back to freedesktop..."
    fi

    log "Cloning from freedesktop.org..."
    if retry_command "git clone --depth=500 '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa' 2>/dev/null" "Cloning from GitLab"; then
        cd "$BUILD_DIR/mesa"
        
        # main
        git remote set-branches origin main
        git fetch origin main --depth=1 --update-shallow || warn "Shallow fetch failed, continuing anyway"
        git checkout main || warn "Checkout main failed, using whatever branch was cloned"
        git reset --hard origin/main || warn "Reset to origin/main failed"
        git clean -fdx || true
        
        setup_mesa_repo
        return
    fi

    warn "GitLab unavailable, trying GitHub mirror..."
    if retry_command "git clone --depth=500 '$MESA_FREEDESKTOP_MIRROR' '$BUILD_DIR/mesa' 2>/dev/null" "Cloning from GitHub"; then
        setup_mesa_repo
        return
    fi

    error "Failed to clone Mesa from all sources"
}

setup_mesa_repo() {
    cd "$BUILD_DIR/mesa"
    git config user.name "BuildUser"
    git config user.email "build@system.local"

    if [ -n "$CUSTOM_COMMIT" ]; then
        log "Checking out: $CUSTOM_COMMIT"
        git fetch --depth=100 origin 2>/dev/null || true
        git checkout "$CUSTOM_COMMIT" 2>/dev/null || warn "Could not checkout $CUSTOM_COMMIT, using HEAD"
    fi

    COMMIT_HASH_SHORT=$(git rev-parse --short HEAD)
    MESA_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")

    echo "$MESA_VERSION" > "$BUILD_DIR/version.txt"
    success "Mesa ready: $MESA_VERSION ($COMMIT_HASH_SHORT)"
}

apply_whitebelyash_fixes() {
    log "Applying Whitebelyash compatibility fixes..."
    cd "$BUILD_DIR/mesa"

    # Fix device registration syntax
    if [ -f "src/freedreno/common/freedreno_devices.py" ]; then
        perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
        sed -i '/REG_A8XX_GRAS_UNKNOWN_/d' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
    fi

    # chip check removal
    find src/freedreno/vulkan -name "*.cc" -print0 2>/dev/null | \
        xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g' 2>/dev/null || true
    find src/freedreno/vulkan -name "*.cc" -print0 2>/dev/null | \
        xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g' 2>/dev/null || true

    success "Whitebelyash fixes applied"
}

# PREPARE BUILD DIR
prepare_build_dir() {
    header "Preparing Build Directory"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    setup_ndk
    clone_mesa

    cd "$BUILD_DIR"
    success "Build directory ready - Mesa $MESA_VERSION ($COMMIT_HASH_SHORT)"
}

# PATCH SYSTEM
apply_patch_file() {
    local patch_path="$1"
    local full_path="$PATCHES_DIR/$patch_path.patch"

    if [ ! -f "$full_path" ]; then
        warn "Patch not found: $patch_path"
        return 1
    fi

    log "Applying patch: $patch_path"
    cd "$BUILD_DIR/mesa"

    if git apply "$full_path" --check 2>/dev/null; then
        git apply "$full_path"
        success "Patch applied: $patch_path"
        return 0
    fi

    warn "Patch may conflict, trying 3-way merge..."
    if git apply "$full_path" --3way 2>/dev/null; then
        success "Patch applied with 3-way merge: $patch_path"
        return 0
    fi

    warn "Patch failed: $patch_path"
    return 1
}

# INLINE PATCHES

# Sysmem Rendering Preference
apply_sysmem_rendering() {
    log "Applying sysmem rendering preference..."
    cd "$BUILD_DIR/mesa"

    local file="src/freedreno/vulkan/tu_device.cc"
    
    if [ ! -f "$file" ]; then
        warn "Target file not found: $file"
        return 1
    fi

    if grep -q "Build: Sysmem Rendering" "$file" 2>/dev/null; then
        info "Sysmem rendering already applied"
        return 0
    fi

    sed -i '1i\/* Build: Sysmem Rendering Preference */' "$file"

    if grep -q "use_bypass" "$file"; then
        sed -i 's/use_bypass = false/use_bypass = true/g' "$file" 2>/dev/null || true
    fi

    success "Sysmem rendering applied"
    return 0
}

# Memory Optimization
apply_memory_optimization() {
    log "Applying memory optimization..."
    cd "$BUILD_DIR/mesa"

    local changes=0

    if [ -f "src/freedreno/vulkan/tu_query.cc" ]; then
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
        ((changes++))
    fi

    if [ -f "src/freedreno/vulkan/tu_device.cc" ]; then
        sed -i 's/has_cached_coherent_memory = true/has_cached_coherent_memory = false/g' src/freedreno/vulkan/tu_device.cc
        ((changes++))
    fi

    [ $changes -gt 0 ] && success "Memory optimization applied ($changes files)" || warn "No changes made"
}

# BUILD SYSTEM
create_cross_file() {
    local NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local CROSS_FILE="$BUILD_DIR/cross_build"
    local NATIVE_FILE="$BUILD_DIR/native_build"

    cat <<EOF > "$CROSS_FILE"
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$NDK_BIN/llvm-strip'
pkg-config = '/bin/false'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-w', '-Wno-error']
cpp_args = ['-O3', '-DNDEBUG', '-w', '-Wno-error']
EOF

    cat <<EOF > "$NATIVE_FILE"
[binaries]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
pkg-config = '/usr/bin/pkg-config'
EOF

    info "Cross-compilation files created"
}

run_meson_setup() {
    local variant_name="$1"
    local log_file="$BUILD_DIR/meson_${variant_name}.log"

    log "Running Meson setup for $variant_name..."
    rm -rf build-release

    if ! meson setup build-release \
        --cross-file "$BUILD_DIR/cross_build" \
        --native-file "$BUILD_DIR/native_build" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$API_LEVEL \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dvulkan-layers=device-select,overlay \
        -Dfreedreno-kmds=kgsl \
        -Db_lto=true \
        -Db_ndebug=true \
        -Dcpp_rtti=false \
        -Degl=disabled \
        -Dgbm=disabled \
        -Dglx=disabled \
        -Dopengl=false \
        -Dllvm=disabled \
        -Dlibunwind=disabled \
        -Dzstd=disabled \
        -Dwerror=false \
        -Dvalgrind=disabled \
        -Dbuild-tests=false \
        &> "$log_file"; then

        error "Meson setup failed. Check: $log_file"
    fi

    success "Meson setup complete"
}

run_ninja_build() {
    local variant_name="$1"
    local log_file="$BUILD_DIR/ninja_${variant_name}.log"
    local cores=$(nproc 2>/dev/null || echo 4)

    log "Building with Ninja ($cores cores)..."

    if ! ninja -C build-release -j"$cores" src/freedreno/vulkan/libvulkan_freedreno.so &> "$log_file"; then
        echo ""
        warn "Build failed. Last 50 lines:"
        tail -50 "$log_file"
        error "Ninja build failed for $variant_name"
    fi

    success "Build complete"
}

package_build() {
    local variant_name="$1"
    local SO_FILE="build-release/src/freedreno/vulkan/libvulkan_freedreno.so"

    if [ ! -f "$SO_FILE" ]; then
        error "Build output not found: $SO_FILE"
    fi

    log "Packaging $variant_name..."
    cd "$BUILD_DIR"

    cp "mesa/$SO_FILE" libvulkan_freedreno.so
    patchelf --set-soname "vulkan.ad07xx.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so vulkan.ad07xx.so

    # source
    local FILENAME
    if [ "$MESA_REPO_SOURCE" = "whitebelyash" ]; then
        FILENAME="Turnip-driver-${variant_name}-${MESA_VERSION}-${COMMIT_HASH_SHORT}"
    else
        FILENAME="Turnip-driver-${MESA_VERSION}-${COMMIT_HASH_SHORT}"
    fi

    cat <<EOF > meta.json
{
    "schemaVersion": 1,
    "name": "Turnip-driver-${variant_name}",
    "description": "Mesa ${MESA_VERSION} - ${variant_name} variant - Built: ${BUILD_DATE}",
    "author": "Freedreno/whitebelyash",
    "packageVersion": "1",
    "vendor": "Meaa",
    "driverVersion": "${MESA_VERSION}",
    "minApi": 27,
    "libraryName": "vulkan.ad07xx.so"
}
EOF

    zip -9 "${FILENAME}.zip" vulkan.ad07xx.so meta.json
    rm -f vulkan.ad07xx.so meta.json

    local size=$(du -h "${FILENAME}.zip" | cut -f1)
    success "Created: ${FILENAME}.zip ($size)"
}

perform_build() {
    local variant_name="$1"

    header "Building: $variant_name"

    cd "$BUILD_DIR/mesa"
    create_cross_file
    run_meson_setup "$variant_name"
    run_ninja_build "$variant_name"
    package_build "$variant_name"
}

# VARIANT BUILDERS
reset_mesa() {
    log "Resetting Mesa source..."
    cd "$BUILD_DIR/mesa"
    git checkout . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
}

build_a7xx() {
    header "A7XX BUILD (Freedesktop)"
    reset_mesa
    apply_memory_optimization
    apply_sysmem_rendering
  # apply_patch_file ""
     
    perform_build "a7xx"
}

build_gen8() {
    header "GEN8 BUILD (Whitebelyash)"
    reset_mesa
    apply_sysmem_rendering
    perform_build "Gen8"
}

# MAIN
main() {
    echo ""
    echo ""
    info "Variant: $BUILD_VARIANT"
    info "Mesa Source: $MESA_REPO_SOURCE"
    info "Date: $BUILD_DATE"
    echo ""

    check_dependencies
    prepare_build_dir

    case "$BUILD_VARIANT" in
        a7xx)
            if [ "$MESA_REPO_SOURCE" != "freedesktop" ]; then
                warn "a7xx is recommended for freedesktop source"
            fi
            build_a7xx
            ;;
        gen8)
            if [ "$MESA_REPO_SOURCE" != "whitebelyash" ]; then
                warn "gen8 is recommended for whitebelyash source"
            fi
            build_gen8
            ;;
        *)
            warn "Unknown variant: $BUILD_VARIANT"
            info "Available: a7xx (freedesktop), gen8 (whitebelyash)"
            if [ "$MESA_REPO_SOURCE" = "whitebelyash" ]; then
                warn "Defaulting to gen8..."
                build_gen8
            else
                warn "Defaulting to a7xx..."
                build_a7xx
            fi
            ;;
    esac

    echo ""
    success "Build Complete"
    echo ""

    if ls "$BUILD_DIR"/*.zip 1>/dev/null 2>&1; then
        info "Output files:"
        ls -lh "$BUILD_DIR"/*.zip
    else
        warn "No output files found"
        exit 1
    fi
}

main "$@"
