#!/bin/bash -e

set -o pipefail

BUILD_DIR="$(pwd)/build_workspace"
PATCHES_DIR="$(pwd)/patches"
NDK_VERSION="${NDK_VERSION:-android-ndk-r30}"
API_LEVEL="${API_LEVEL:-35}"

MESA_FREEDESKTOP="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_FREEDESKTOP_MIRROR="https://github.com/mesa3d/mesa.git"
MESA_LFDEVS_SOURCE="https://github.com/lfdevs/mesa-for-android-container.git"
MESA_LFDEVS_BRANCH="adreno-main"
MESA_8GEN_SOURCE="https://github.com/whitebelyash/mesa-tu8.git"
MESA_8GEN_BRANCH="8gen"

MESA_SOURCE_TYPE="${MESA_SOURCE_TYPE:-official_release}"
OFFICIAL_VERSION="${OFFICIAL_VERSION:-25.3.4}"
STAGING_BRANCH="${STAGING_BRANCH:-staging/25.3}"
CUSTOM_COMMIT="${CUSTOM_COMMIT:-}"
MESA_REPO_SOURCE="${MESA_REPO_SOURCE:-freedesktop}"
BUILD_VARIANT="${BUILD_VARIANT:-a7xx}"
NAMING_FORMAT="${NAMING_FORMAT:-emulator}"

COMMIT_HASH_SHORT=""
MESA_VERSION=""
MAX_RETRIES=3
RETRY_DELAY=15
BUILD_DATE=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[Build] $1"; }
success() { echo "[OK] $1"; }
warn() { echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; exit 1; }
info() { echo "[INFO] $1"; }

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

setup_ndk() {
    info "Setting up NDK..."

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

    if ! retry_command "curl -sL '$ndk_url' -o ndk.zip" "Downloading NDK"; then
        error "Failed to download NDK"
    fi

    unzip -q ndk.zip && rm -f ndk.zip
    export ANDROID_NDK_HOME="$BUILD_DIR/$NDK_VERSION"
    success "NDK installed: $ANDROID_NDK_HOME"
}

clone_mesa() {
    info "Selecting Mesa source..."

    [ -d "$BUILD_DIR/mesa" ] && rm -rf "$BUILD_DIR/mesa"

    case "$MESA_REPO_SOURCE" in
        "lfdevs")
            clone_lfdevs_source
            ;;
        "8gen")
            clone_8gen_source
            ;;
        "freedesktop"|*)
            clone_freedesktop_source
            ;;
    esac

    setup_mesa_repo
}

clone_lfdevs_source() {
    log "Cloning from lfdevs/mesa-for-android-container (adreno-main branch)..."
    
    if ! retry_command "git clone --depth 500 --branch '$MESA_LFDEVS_BRANCH' '$MESA_LFDEVS_SOURCE' '$BUILD_DIR/mesa'" "Cloning lfdevs source"; then
        error "Failed to clone lfdevs source"
    fi
    
    success "Cloned lfdevs source with Adreno 830/840 support"
}

clone_8gen_source() {
    log "Cloning from 8gen source..."
    
    if ! retry_command "git clone --depth 200 --branch '$MESA_8GEN_BRANCH' '$MESA_8GEN_SOURCE' '$BUILD_DIR/mesa'" "Cloning 8gen source"; then
        error "Failed to clone 8gen source"
    fi
    
    success "Cloned 8gen source"
}

clone_freedesktop_source() {
    case "$MESA_SOURCE_TYPE" in
        "official_release")
            clone_official_release
            ;;
        "staging_branch")
            clone_staging_branch
            ;;
        "custom_commit")
            clone_custom_commit
            ;;
        *)
            warn "Unknown source type: $MESA_SOURCE_TYPE, defaulting to official_release"
            clone_official_release
            ;;
    esac
}

clone_official_release() {
    log "Cloning official release: $OFFICIAL_VERSION"
    
    if ! retry_command "git clone --depth 500 '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning from GitLab"; then
        warn "GitLab unavailable, trying GitHub mirror..."
        retry_command "git clone --depth 500 '$MESA_FREEDESKTOP_MIRROR' '$BUILD_DIR/mesa'" "Cloning from GitHub" || error "Failed to clone Mesa"
    fi
    
    cd "$BUILD_DIR/mesa"
    
    if [ "$OFFICIAL_VERSION" = "custom" ]; then
        warn "Using latest available version"
        return
    fi
    
    if git tag -l | grep -q "^mesa-${OFFICIAL_VERSION}$"; then
        log "Checking out version: mesa-$OFFICIAL_VERSION"
        git checkout "mesa-$OFFICIAL_VERSION"
    elif git tag -l | grep -q "^${OFFICIAL_VERSION}$"; then
        log "Checking out version: $OFFICIAL_VERSION"
        git checkout "$OFFICIAL_VERSION"
    else
        warn "Version $OFFICIAL_VERSION not found, using latest stable"
        LATEST_TAG=$(git tag -l "mesa-*" | grep -E '^mesa-[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
        if [ -n "$LATEST_TAG" ]; then
            log "Using latest stable: $LATEST_TAG"
            git checkout "$LATEST_TAG"
        fi
    fi
}

clone_staging_branch() {
    log "Cloning staging branch: $STAGING_BRANCH"
    
    if ! retry_command "git clone --depth 500 --branch '$STAGING_BRANCH' '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning staging branch"; then
        warn "Failed to clone staging branch, trying main branch"
        retry_command "git clone --depth 500 '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning main branch" || error "Failed to clone Mesa"
    fi
}

clone_custom_commit() {
    log "Cloning for custom commit"
    
    retry_command "git clone --depth 500 '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning for custom commit" || error "Failed to clone Mesa"
    
    cd "$BUILD_DIR/mesa"
    
    if [ -n "$CUSTOM_COMMIT" ]; then
        log "Checking out custom commit: $CUSTOM_COMMIT"
        if ! git checkout "$CUSTOM_COMMIT" 2>/dev/null; then
            warn "Could not checkout $CUSTOM_COMMIT, fetching more history..."
            git fetch --depth=500 origin 2>/dev/null || true
            if ! git checkout "$CUSTOM_COMMIT" 2>/dev/null; then
                warn "Could not checkout $CUSTOM_COMMIT, using HEAD"
            else
                success "Checked out custom commit after fetch"
            fi
        else
            success "Checked out custom commit: $CUSTOM_COMMIT"
        fi
    fi
}

setup_mesa_repo() {
    cd "$BUILD_DIR/mesa"
    
    git config user.name "BuildUser"
    git config user.email "build@system.local"
    
    COMMIT_HASH_SHORT=$(git rev-parse --short HEAD)
    MESA_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
    
    if [ "$MESA_VERSION" = "unknown" ] || [ -z "$MESA_VERSION" ]; then
        MESA_VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^mesa-//' || echo "unknown")
    fi
    
    if [ "$MESA_REPO_SOURCE" = "lfdevs" ]; then
        MESA_VERSION="${MESA_VERSION}-lfdevs"
    elif [ "$MESA_REPO_SOURCE" = "8gen" ]; then
        MESA_VERSION="${MESA_VERSION}-8gen"
    fi
    
    echo "$MESA_VERSION" > "$BUILD_DIR/version.txt"
    echo "$COMMIT_HASH_SHORT" > "$BUILD_DIR/commit.txt"
    success "Mesa ready: $MESA_VERSION ($COMMIT_HASH_SHORT)"
}

prepare_build_dir() {
    info "Preparing build directory..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    setup_ndk
    clone_mesa

    cd "$BUILD_DIR"
    success "Build directory ready - Mesa $MESA_VERSION ($COMMIT_HASH_SHORT)"
}

apply_patch_file() {
    local patch_name="$1"
    local patch_file="$PATCHES_DIR/$patch_name"
    
    if [ ! -f "$patch_file" ]; then
        warn "Patch not found: $patch_file"
        return 1
    fi
    
    log "Applying patch: $patch_name"
    cd "$BUILD_DIR/mesa"
    
    if git apply --check "$patch_file" 2>/dev/null; then
        if git apply "$patch_file"; then
            success "Patch applied successfully: $patch_name"
            return 0
        fi
    fi
    
    warn "Standard patch failed, trying 3-way merge..."
    if git apply --3way "$patch_file" 2>/dev/null; then
        success "Patch applied with 3-way merge: $patch_name"
        return 0
    fi
    
    warn "Patch could not be applied: $patch_name"
    return 1
}

apply_direct_modifications() {
    if [ "$MESA_REPO_SOURCE" = "lfdevs" ]; then
        info "Using lfdevs source, skipping direct modifications (already patched)"
        return
    fi
    
    info "Applying direct modifications..."
    
    cd "$BUILD_DIR/mesa"
    
    log "Applying memory optimization..."
    if [ -f "src/freedreno/vulkan/tu_query.cc" ]; then
        if grep -q "tu_bo_init_new_cached" "src/freedreno/vulkan/tu_query.cc"; then
            sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
            success "Memory optimization applied to tu_query.cc"
        else
            info "tu_query.cc: No cached memory calls found"
        fi
    fi
    
    if [ -f "src/freedreno/vulkan/tu_device.cc" ]; then
        if grep -q "has_cached_coherent_memory = true" "src/freedreno/vulkan/tu_device.cc"; then
            sed -i 's/has_cached_coherent_memory = true/has_cached_coherent_memory = false/g' src/freedreno/vulkan/tu_device.cc
            success "Memory optimization applied to tu_device.cc"
        else
            info "tu_device.cc: cached_coherent_memory setting not found"
        fi
    fi
    
    log "Applying sysmem rendering preference..."
    if [ -f "src/freedreno/vulkan/tu_device.cc" ]; then
        if grep -q "use_bypass = false" "src/freedreno/vulkan/tu_device.cc"; then
            sed -i 's/use_bypass = false/use_bypass = true/g' src/freedreno/vulkan/tu_device.cc
            success "Sysmem rendering enabled"
        else
            info "tu_device.cc: use_bypass setting not found"
        fi
    fi
    
    success "Direct modifications completed"
}

apply_8gen_fixes() {
    if [ "$MESA_REPO_SOURCE" != "8gen" ]; then
        return
    fi
    
    info "Applying 8gen-specific fixes..."
    cd "$BUILD_DIR/mesa"
    
    if [ -f "src/freedreno/vulkan/tu_device.cc" ]; then
        sed -i 's/ && (pdevice->info->chip != 8)//g' src/freedreno/vulkan/tu_device.cc 2>/dev/null || true
        sed -i 's/ && (pdevice->info->chip == 8)//g' src/freedreno/vulkan/tu_device.cc 2>/dev/null || true
    fi
    
    success "8gen fixes applied"
}

create_cross_file() {
    local NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local CROSS_FILE="$BUILD_DIR/cross_build"
    local NATIVE_FILE="$BUILD_DIR/native_build"

    cat > "$CROSS_FILE" << EOF
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
c_args = ['-O3', '-DNDEBUG', '-w']
cpp_args = ['-O3', '-DNDEBUG', '-w']
EOF

    cat > "$NATIVE_FILE" << EOF
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

    local build_options=(
        "--cross-file" "$BUILD_DIR/cross_build"
        "--native-file" "$BUILD_DIR/native_build"
        "-Dbuildtype=release"
        "-Dplatforms=android"
        "-Dplatform-sdk-version=$API_LEVEL"
        "-Dandroid-stub=true"
        "-Dgallium-drivers="
        "-Dgallium-va=disabled"
        "-Dvulkan-drivers=freedreno"
        "-Dvulkan-beta=true"
        "-Dvulkan-layers="
        "-Dfreedreno-kmds=kgsl"
        "-Db_lto=true"
        "-Db_ndebug=true"
        "-Dcpp_rtti=false"
        "-Dgles1=disabled"
        "-Dgles2=disabled"
        "-Degl=disabled"
        "-Dgbm=disabled"
        "-Dglx=disabled"
        "-Dopengl=false"
        "-Dllvm=disabled"
        "-Dlibunwind=disabled"
        "-Dlmsensors=disabled"
        "-Dzstd=disabled"
        "-Dwerror=false"
        "-Dvalgrind=disabled"
        "-Dbuild-tests=false"
        "-Dandroid-libbacktrace=disabled"
    )

    if ! meson setup build-release "${build_options[@]}" 2>&1 | tee "$log_file"; then
        error "Meson setup failed. Check: $log_file"
    fi

    success "Meson setup complete"
}

run_ninja_build() {
    local variant_name="$1"
    local log_file="$BUILD_DIR/ninja_${variant_name}.log"
    local cores=$(nproc 2>/dev/null || echo 4)

    log "Building with Ninja ($cores cores)..."

    if ! ninja -C build-release -j"$cores" 2>&1 | tee "$log_file"; then
        echo ""
        warn "Build failed. Last 100 lines of log:"
        tail -100 "$log_file"
        error "Ninja build failed for $variant_name"
    fi

    success "Build complete"
}

extract_vulkan_version() {
    cd "$BUILD_DIR/mesa"
    
    local vulkan_version="1.3.250"
    
    for file in "src/vulkan/util/vk_common.h" "include/vulkan/vulkan_core.h"; do
        if [ -f "$file" ]; then
            local vk_header=$(grep -o 'VK_HEADER_VERSION [0-9]*' "$file" 2>/dev/null | head -1 | awk '{print $2}')
            if [ -n "$vk_header" ] && [ "$vk_header" -gt 0 ] 2>/dev/null; then
                vulkan_version="1.3.$vk_header"
                break
            fi
        fi
    done
    
    echo "$vulkan_version"
}

generate_filename() {
    local variant_name="$1"
    local mesa_version="$2"
    local naming_format="$3"
    
    local clean_version=$(echo "$mesa_version" | sed 's/[^0-9.]//g' | sed 's/\.$//g')
    
    if [ -z "$clean_version" ] || [ "$clean_version" = "unknown" ]; then
        clean_version=$(date +'%Y%m%d')
    fi
    
    local source_suffix=""
    if [ "$MESA_REPO_SOURCE" = "lfdevs" ]; then
        source_suffix="-lfdevs"
    elif [ "$MESA_REPO_SOURCE" = "8gen" ]; then
        source_suffix="-8gen"
    fi
    
    case "$naming_format" in
        "emulator")
            echo "Turnip-${clean_version}${source_suffix}"
            ;;
        "simple")
            if [ "$variant_name" = "gen8" ]; then
                echo "Turnip-Gen8-${clean_version}${source_suffix}"
            else
                echo "Turnip-A7xx-${clean_version}${source_suffix}"
            fi
            ;;
        "detailed")
            local date_part=$(date +'%Y%m%d')
            echo "Turnip-${variant_name}-Mesa${clean_version}-${date_part}${source_suffix}"
            ;;
        *)
            echo "turnip-${variant_name}-${clean_version}${source_suffix}"
            ;;
    esac
}

package_build() {
    local variant_name="$1"
    local SO_FILE="build-release/src/freedreno/vulkan/libvulkan_freedreno.so"

    if [ ! -f "$SO_FILE" ]; then
        error "Build output not found: $SO_FILE"
    fi

    log "Packaging driver..."
    cd "$BUILD_DIR"

    local TEMP_DIR="driver_temp"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    cp "mesa/$SO_FILE" "$TEMP_DIR/libvulkan_freedreno.so"
    
    patchelf --set-soname "libvulkan_freedreno.so" "$TEMP_DIR/libvulkan_freedreno.so" 2>/dev/null || true
    
    "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "$TEMP_DIR/libvulkan_freedreno.so" 2>/dev/null || true
    
    local VULKAN_VERSION=$(extract_vulkan_version)
    local DRIVER_NAME=$(generate_filename "$variant_name" "$MESA_VERSION" "$NAMING_FORMAT")
    
    local source_description="Mesa Official"
    if [ "$MESA_REPO_SOURCE" = "lfdevs" ]; then
        source_description="lfdevs/mesa-for-android-container (Adreno 830/840 support)"
    elif [ "$MESA_REPO_SOURCE" = "8gen" ]; then
        source_description="8gen source"
    fi
    
    cat > "$TEMP_DIR/meta.json" << EOF
{
    "schemaVersion": 1,
    "name": "Mesa Turnip Driver",
    "description": "Mesa ${MESA_VERSION} - Built: ${BUILD_DATE}",
    "author": "Mesa3D",
    "packageVersion": "1",
    "vendor": "Mesa3D",
    "driverVersion": "Vulkan ${VULKAN_VERSION}",
    "minApi": ${API_LEVEL},
    "libraryName": "libvulkan_freedreno.so"
}
EOF

    cat > "$TEMP_DIR/build_info.txt" << EOF
Build Information
Mesa Version: ${MESA_VERSION}
Vulkan Version: ${VULKAN_VERSION}
Commit: ${COMMIT_HASH_SHORT}
Source: ${source_description}
Variant: ${variant_name}
Android API: ${API_LEVEL}
NDK Version: ${NDK_VERSION}
Build Date: ${BUILD_DATE}

Supported GPUs:
- Adreno 730/740/750
- Adreno 830/840 (lfdevs source recommended)
EOF

    cd "$TEMP_DIR"
    zip -9 "../${DRIVER_NAME}.zip" ./*
    cd ..
    
    rm -rf "$TEMP_DIR"
    
    local size=$(du -h "${DRIVER_NAME}.zip" | cut -f1)
    success "Created driver package: ${DRIVER_NAME}.zip ($size)"
}

perform_build() {
    local variant_name="$1"

    log "Building: $variant_name"

    cd "$BUILD_DIR/mesa"
    create_cross_file
    run_meson_setup "$variant_name"
    run_ninja_build "$variant_name"
    package_build "$variant_name"
}

reset_mesa() {
    log "Resetting Mesa source..."
    cd "$BUILD_DIR/mesa"
    git checkout . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
}

build_a7xx() {
    info "Starting A7XX Build"
    reset_mesa
    
    apply_direct_modifications
    
    if [ "$MESA_REPO_SOURCE" != "lfdevs" ]; then
        [ -f "$PATCHES_DIR/memory_optimization.patch" ] && apply_patch_file "memory_optimization.patch"
        [ -f "$PATCHES_DIR/sysmem_rendering.patch" ] && apply_patch_file "sysmem_rendering.patch"
    fi
    
    perform_build "a7xx"
}

build_gen8() {
    info "Starting Gen8 Build"
    reset_mesa
    
    apply_8gen_fixes
    apply_direct_modifications
    
    perform_build "gen8"
}

print_source_info() {
    echo ""
    echo "Source Information:"
    case "$MESA_REPO_SOURCE" in
        "lfdevs")
            echo "  Repository: lfdevs/mesa-for-android-container"
            echo "  Branch: $MESA_LFDEVS_BRANCH"
            echo "  Features: Adreno 830/840 support, KGSL backend patches"
            ;;
        "8gen")
            echo "  Repository: whitebelyash/mesa-tu8"
            echo "  Branch: $MESA_8GEN_BRANCH"
            echo "  Features: 8gen specific optimizations"
            ;;
        "freedesktop")
            echo "  Repository: Mesa Official (freedesktop.org)"
            echo "  Source Type: $MESA_SOURCE_TYPE"
            if [ "$MESA_SOURCE_TYPE" = "official_release" ]; then
                echo "  Version: $OFFICIAL_VERSION"
            elif [ "$MESA_SOURCE_TYPE" = "staging_branch" ]; then
                echo "  Branch: $STAGING_BRANCH"
            fi
            ;;
    esac
    echo ""
}

main() {
    echo ""
    echo "Turnip Driver Build System"
    echo ""
    info "Build Variant: $BUILD_VARIANT"
    info "Mesa Source: $MESA_REPO_SOURCE"
    info "Source Type: $MESA_SOURCE_TYPE"
    info "Naming Format: $NAMING_FORMAT"
    
    print_source_info

    check_dependencies
    prepare_build_dir

    case "$BUILD_VARIANT" in
        a7xx)
            build_a7xx
            ;;
        gen8)
            build_gen8
            ;;
        *)
            warn "Unknown variant: $BUILD_VARIANT"
            info "Available variants: a7xx, gen8"
            if [ "$MESA_REPO_SOURCE" = "8gen" ]; then
                warn "Defaulting to gen8 for 8gen source..."
                build_gen8
            else
                warn "Defaulting to a7xx..."
                build_a7xx
            fi
            ;;
    esac

    echo ""
    success "Build Completed Successfully!"
    echo ""
    
    if ls "$BUILD_DIR"/*.zip 1>/dev/null 2>&1; then
        info "Output files:"
        ls -lh "$BUILD_DIR"/*.zip | while read -r line; do
            echo "  $line"
        done
    else
        warn "No output files found"
        exit 1
    fi
}

main "$@"
