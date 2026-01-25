#!/usr/bin/env bash
#
# Turnip Driver Builder
# Mesa Turnip Driver for Android
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"
MESA_DIR="${BUILD_DIR}/mesa"

MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_MIRROR="https://github.com/mesa3d/mesa.git"

MESA_SOURCE="${MESA_SOURCE:-latest_release}"
STAGING_BRANCH="${STAGING_BRANCH:-staging/25.3}"
CUSTOM_TAG="${CUSTOM_TAG:-}"
BUILD_TYPE="${BUILD_TYPE:-release}"
NDK_PATH="${NDK_PATH:-/opt/android-ndk}"
API_LEVEL="${API_LEVEL:-35}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[info]${NC} $*"; }
log_success() { echo -e "${GREEN}[ok]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[warn]${NC} $*"; }
log_error()   { echo -e "${RED}[error]${NC} $*" >&2; }
log_fatal()   { log_error "$*"; exit 1; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "build failed with exit code: $exit_code"
        [[ -f "${BUILD_DIR}/meson.log" ]] && tail -50 "${BUILD_DIR}/meson.log"
    fi
}
trap cleanup EXIT

check_command() {
    command -v "$1" &>/dev/null || log_fatal "required command not found: $1"
}

fetch_latest_release() {
    local tags=""
    
    tags=$(git ls-remote --tags --refs "$MESA_REPO" 2>/dev/null | \
           grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | \
           sort -V | tail -1) || true
    
    if [[ -z "$tags" ]]; then
        tags=$(git ls-remote --tags --refs "$MESA_MIRROR" 2>/dev/null | \
               grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | \
               sort -V | tail -1) || true
    fi
    
    [[ -z "$tags" ]] && log_fatal "could not determine latest release"
    echo "$tags"
}

get_mesa_version() {
    [[ -f "${MESA_DIR}/VERSION" ]] && cat "${MESA_DIR}/VERSION" || echo "unknown"
}

prepare_directories() {
    log_info "preparing build directories..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    log_success "build directory ready"
}

clone_mesa() {
    log_info "cloning mesa source..."
    
    local clone_args=("--depth" "1")
    local target_ref=""
    
    case "$MESA_SOURCE" in
        latest_release)
            log_info "fetching latest mesa release..."
            target_ref=$(fetch_latest_release)
            clone_args+=("--branch" "$target_ref")
            log_info "target: $target_ref"
            ;;
        staging_branch)
            target_ref="$STAGING_BRANCH"
            clone_args+=("--branch" "$target_ref")
            log_info "target: $target_ref"
            ;;
        main_branch)
            target_ref="main"
            clone_args+=("--branch" "main")
            log_info "target: main branch"
            ;;
        custom_tag)
            [[ -z "$CUSTOM_TAG" ]] && log_fatal "custom tag not specified"
            target_ref="$CUSTOM_TAG"
            clone_args+=("--branch" "$target_ref")
            log_info "target: $target_ref"
            ;;
        *)
            log_fatal "unknown mesa source: $MESA_SOURCE"
            ;;
    esac
    
    local clone_success=false
    
    log_info "trying gitlab..."
    if git clone "${clone_args[@]}" "$MESA_REPO" "$MESA_DIR" 2>/dev/null; then
        clone_success=true
    else
        log_warn "gitlab failed, trying github mirror..."
        if git clone "${clone_args[@]}" "$MESA_MIRROR" "$MESA_DIR" 2>/dev/null; then
            clone_success=true
        fi
    fi
    
    [[ "$clone_success" == false ]] && log_fatal "failed to clone mesa from all sources"
    
    cd "$MESA_DIR"
    
    local version commit
    version=$(get_mesa_version)
    commit=$(git rev-parse --short=8 HEAD)
    
    echo "$version" > "${BUILD_DIR}/version.txt"
    echo "$commit" > "${BUILD_DIR}/commit.txt"
    
    log_success "mesa $version ($commit) ready"
}

create_cross_file() {
    log_info "creating cross-compilation file..."
    
    local ndk_toolchain="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64"
    local ndk_bin="${ndk_toolchain}/bin"
    
    [[ ! -d "$ndk_bin" ]] && log_fatal "ndk toolchain not found: $ndk_bin"
    
    local compiler_api="$API_LEVEL"
    if [[ ! -f "${ndk_bin}/aarch64-linux-android${compiler_api}-clang" ]]; then
        compiler_api="34"
        log_warn "api $API_LEVEL compiler not found, using $compiler_api"
    fi
    
    cat > "${BUILD_DIR}/cross-aarch64.txt" << EOF
[binaries]
ar = '${ndk_bin}/llvm-ar'
c = ['ccache', '${ndk_bin}/aarch64-linux-android${compiler_api}-clang']
cpp = ['ccache', '${ndk_bin}/aarch64-linux-android${compiler_api}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '${ndk_bin}/llvm-strip'
pkg-config = '/bin/false'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-Wno-error']
cpp_args = ['-O3', '-DNDEBUG', '-Wno-error']
EOF

    log_success "cross-compilation file created"
}

configure_build() {
    log_info "configuring mesa build..."
    
    cd "$MESA_DIR"
    
    meson setup "${MESA_DIR}/build" \
        --cross-file "${BUILD_DIR}/cross-aarch64.txt" \
        -Dbuildtype="$BUILD_TYPE" \
        -Dplatforms=android \
        -Dplatform-sdk-version="$API_LEVEL" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
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
        -Dlmsensors=disabled \
        -Dzstd=disabled \
        -Dvalgrind=disabled \
        -Dbuild-tests=false \
        -Dwerror=false \
        2>&1 | tee "${BUILD_DIR}/meson.log"
    
    log_success "build configured"
}

compile_driver() {
    log_info "compiling turnip driver..."
    
    local cores
    cores=$(nproc 2>/dev/null || echo 4)
    
    ninja -C "${MESA_DIR}/build" -j"$cores" 2>&1 | tee "${BUILD_DIR}/ninja.log"
    
    local driver_path="${MESA_DIR}/build/src/freedreno/vulkan/libvulkan_freedreno.so"
    [[ ! -f "$driver_path" ]] && log_fatal "build failed: driver not found"
    
    log_success "compilation complete"
}

package_driver() {
    log_info "packaging driver..."
    
    local version commit
    version=$(cat "${BUILD_DIR}/version.txt")
    commit=$(cat "${BUILD_DIR}/commit.txt")
    
    local driver_src="${MESA_DIR}/build/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_dir="${BUILD_DIR}/package"
    local driver_name="vulkan.ad07XX.so"
    
    mkdir -p "$package_dir"
    cp "$driver_src" "${package_dir}/${driver_name}"
    
    patchelf --set-soname "$driver_name" "${package_dir}/${driver_name}"
    "${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
        "${package_dir}/${driver_name}" 2>/dev/null || true
    
    local driver_size
    driver_size=$(du -h "${package_dir}/${driver_name}" | cut -f1)
    
    cat > "${package_dir}/meta.json" << EOF
{
    "schemaVersion": 1,
    "name": "Turnip ${version}",
    "description": "Mesa ${version} (${commit}) - Turnip Vulkan driver for Adreno GPUs",
    "author": "Mesa3D",
    "packageVersion": "1",
    "vendor": "Mesa3D",
    "driverVersion": "${version}",
    "minApi": 27,
    "libraryName": "${driver_name}"
}
EOF

    local filename="turnip-${version}-${commit}"
    echo "$filename" > "${BUILD_DIR}/filename.txt"
    
    cd "$package_dir"
    zip -9 "${BUILD_DIR}/${filename}.zip" "$driver_name" meta.json
    
    log_success "package created: ${filename}.zip ($driver_size)"
}

print_summary() {
    local version commit
    version=$(cat "${BUILD_DIR}/version.txt")
    commit=$(cat "${BUILD_DIR}/commit.txt")
    
    echo ""
    log_info "build summary:"
    echo "  mesa version : $version"
    echo "  commit       : $commit"
    echo "  source       : $MESA_SOURCE"
    echo "  build type   : $BUILD_TYPE"
    echo "  android api  : $API_LEVEL"
    echo ""
    echo "  output:"
    ls -lh "${BUILD_DIR}"/*.zip 2>/dev/null | awk '{print "    " $0}'
    echo ""
}

main() {
    log_info "turnip driver builder"
    log_info "mesa_source=$MESA_SOURCE, build_type=$BUILD_TYPE, api=$API_LEVEL"
    
    for cmd in git meson ninja patchelf zip ccache; do
        check_command "$cmd"
    done
    
    prepare_directories
    clone_mesa
    create_cross_file
    configure_build
    compile_driver
    package_driver
    print_summary
    
    log_success "build completed successfully!"
}

main "$@"
