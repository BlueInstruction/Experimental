#!/usr/bin/env bash
#
# build-wine-arm64ec.sh
# Build Wine ARM64EC for Winlator + FEXCore
#
# Usage: ./build-wine-arm64ec.sh <version_name> [options]
#
# Options:
#   --proton-dir=PATH    Path to Proton source (default: ./proton)
#   --output-dir=PATH    Output directory (default: ./out)
#   --build-type=TYPE    Build type: release|debug (default: release)
#   --with-dxvk          Include DXVK
#   --with-vkd3d         Include VKD3D-Proton
#   --jobs=N             Number of parallel jobs (default: auto)
#   --clean              Clean build directories before building
#   --help               Show this help
#

set -Eeuo pipefail

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Logging ===
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" || true; }

# === Error handling ===
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Build failed with exit code: $exit_code"
        log_error "Check logs for details"
    fi
}
trap cleanup EXIT

# === Default configuration ===
VERSION_NAME=""
PROTON_DIR="./proton"
OUT_DIR="./out"
BUILD_TYPE="release"
WITH_DXVK=false
WITH_VKD3D=false
JOBS=$(nproc 2>/dev/null || echo 4)
CLEAN_BUILD=false

# === Parse arguments ===
show_help() {
    cat << EOF
Usage: $0 <version_name> [options]

Build Wine ARM64EC for Winlator + FEXCore

Arguments:
  version_name          Version name for the build (e.g., proton-10.0-4-arm64ec)

Options:
  --proton-dir=PATH     Path to Proton source (default: ./proton)
  --output-dir=PATH     Output directory (default: ./out)
  --build-type=TYPE     Build type: release|debug (default: release)
  --with-dxvk           Include DXVK (DirectX 9/10/11 to Vulkan)
  --with-vkd3d          Include VKD3D-Proton (DirectX 12 to Vulkan)
  --jobs=N              Number of parallel jobs (default: $(nproc))
  --clean               Clean build directories before building
  --help                Show this help

Examples:
  $0 proton-10.0-4-arm64ec
  $0 my-wine-build --with-dxvk --with-vkd3d --build-type=debug
  $0 test-build --proton-dir=/path/to/proton --clean

EOF
    exit 0
}

parse_args() {
    [[ $# -eq 0 ]] && show_help
    
    for arg in "$@"; do
        case "$arg" in
            --proton-dir=*)
                PROTON_DIR="${arg#*=}"
                ;;
            --output-dir=*)
                OUT_DIR="${arg#*=}"
                ;;
            --build-type=*)
                BUILD_TYPE="${arg#*=}"
                ;;
            --with-dxvk)
                WITH_DXVK=true
                ;;
            --with-vkd3d)
                WITH_VKD3D=true
                ;;
            --jobs=*)
                JOBS="${arg#*=}"
                ;;
            --clean)
                CLEAN_BUILD=true
                ;;
            --help|-h)
                show_help
                ;;
            -*)
                log_error "Unknown option: $arg"
                exit 1
                ;;
            *)
                if [[ -z "$VERSION_NAME" ]]; then
                    VERSION_NAME="$arg"
                else
                    log_error "Unexpected argument: $arg"
                    exit 1
                fi
                ;;
        esac
    done
    
    if [[ -z "$VERSION_NAME" ]]; then
        log_error "Version name is required"
        show_help
    fi
}

# === Validation ===
validate_environment() {
    log_step "Validating build environment..."
    
    local missing_tools=()
    
    # Check required tools
    for cmd in gcc make autoconf flex bison tar xz; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_tools+=("$cmd")
        fi
    done
    
    # Check MinGW toolchains
    if ! command -v i686-w64-mingw32-gcc &>/dev/null; then
        missing_tools+=("i686-w64-mingw32-gcc (mingw-w64)")
    fi
    
    if ! command -v aarch64-w64-mingw32-gcc &>/dev/null; then
        missing_tools+=("aarch64-w64-mingw32-gcc (llvm-mingw)")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            log_error "  - $tool"
        done
        log_error ""
        log_error "Install on Ubuntu/Debian:"
        log_error "  sudo apt install build-essential gcc-mingw-w64 flex bison autoconf"
        log_error ""
        log_error "Install LLVM-MinGW for ARM64:"
        log_error "  wget https://github.com/mstorsjo/llvm-mingw/releases/download/20250114/llvm-mingw-20250114-ucrt-ubuntu-20.04-x86_64.tar.xz"
        log_error "  tar -xf llvm-mingw-*.tar.xz"
        log_error "  export PATH=\$PWD/llvm-mingw-*/bin:\$PATH"
        exit 1
    fi
    
    # Check Proton directory
    if [[ ! -d "$PROTON_DIR/wine" ]]; then
        log_error "Proton wine directory not found: $PROTON_DIR/wine"
        log_error "Clone Proton with: git clone --recurse-submodules https://github.com/ValveSoftware/Proton.git"
        exit 1
    fi
    
    # Check for meson/ninja if building DXVK/VKD3D
    if [[ "$WITH_DXVK" == true ]] || [[ "$WITH_VKD3D" == true ]]; then
        for cmd in meson ninja glslangValidator; do
            if ! command -v "$cmd" &>/dev/null; then
                log_warn "Optional tool not found: $cmd (needed for DXVK/VKD3D)"
            fi
        done
    fi
    
    log_info "✓ Build environment validated"
    log_info "  - GCC: $(gcc --version | head -n1)"
    log_info "  - MinGW i686: $(i686-w64-mingw32-gcc --version | head -n1)"
    log_info "  - MinGW ARM64: $(aarch64-w64-mingw32-gcc --version | head -n1)"
    log_info "  - Jobs: $JOBS"
}

# === Build functions ===
build_wine_tools() {
    log_step "Building Wine tools (native)..."
    
    local tools_dir="wine-tools"
    
    if [[ "$CLEAN_BUILD" == true ]]; then
        rm -rf "$tools_dir"
    fi
    
    if [[ -f "$tools_dir/tools/widl/widl" ]]; then
        log_info "Using existing wine-tools"
        return 0
    fi
    
    mkdir -p "$tools_dir"
    cd "$tools_dir"
    
    "../${PROTON_DIR}/wine/configure" \
        --enable-win64 \
        --without-x \
        --without-freetype \
        --without-fontconfig \
        --disable-tests
    
    make -j"$JOBS" tools nls/locale.nls
    
    cd ..
    log_info "✓ Wine tools built successfully"
}

build_wine_arm64ec() {
    log_step "Building Wine ARM64EC..."
    
    local build_dir="wine-arm64ec"
    
    if [[ "$CLEAN_BUILD" == true ]]; then
        rm -rf "$build_dir"
    fi
    
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    local configure_flags=(
        --host=aarch64-w64-mingw32
        --with-wine-tools=../wine-tools
        --without-x
        --without-freetype
        --without-fontconfig
        --disable-tests
        --prefix="$PWD/install"
    )
    
    local cflags=""
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        configure_flags+=(--enable-debug)
        cflags="-g -O0"
    else
        cflags="-O2 -DNDEBUG"
    fi
    
    CFLAGS="$cflags" CXXFLAGS="$cflags" \
        "../${PROTON_DIR}/wine/configure" "${configure_flags[@]}"
    
    make -j"$JOBS"
    make install
    
    cd ..
    log_info "✓ Wine ARM64EC built successfully"
}

build_wine_i386() {
    log_step "Building Wine i386 (WoW64)..."
    
    local build_dir="wine-i386"
    
    if [[ "$CLEAN_BUILD" == true ]]; then
        rm -rf "$build_dir"
    fi
    
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    "../${PROTON_DIR}/wine/configure" \
        --host=i686-w64-mingw32 \
        --with-wine-tools=../wine-tools \
        --without-x \
        --without-freetype \
        --without-fontconfig \
        --disable-tests \
        --prefix="$PWD/install"
    
    make -j"$JOBS"
    make install
    
    cd ..
    log_info "✓ Wine i386 built successfully"
}

build_dxvk() {
    [[ "$WITH_DXVK" != true ]] && return 0
    
    log_step "Building DXVK..."
    
    local dxvk_dir="${PROTON_DIR}/dxvk"
    
    if [[ ! -d "$dxvk_dir" ]]; then
        log_warn "DXVK directory not found, skipping"
        return 0
    fi
    
    cd "$dxvk_dir"
    
    # Build x86
    if [[ -f "build-win32.txt" ]]; then
        rm -rf build-x86
        meson setup build-x86 \
            --cross-file build-win32.txt \
            --buildtype release \
            --prefix "$PWD/install-x86" \
            -Denable_tests=false
        ninja -C build-x86 install
    fi
    
    # Build x64
    if [[ -f "build-win64.txt" ]]; then
        rm -rf build-x64
        meson setup build-x64 \
            --cross-file build-win64.txt \
            --buildtype release \
            --prefix "$PWD/install-x64" \
            -Denable_tests=false
        ninja -C build-x64 install
    fi
    
    cd - >/dev/null
    log_info "✓ DXVK built successfully"
}

build_vkd3d() {
    [[ "$WITH_VKD3D" != true ]] && return 0
    
    log_step "Building VKD3D-Proton..."
    
    local vkd3d_dir="${PROTON_DIR}/vkd3d-proton"
    
    if [[ ! -d "$vkd3d_dir" ]]; then
        log_warn "VKD3D-Proton directory not found, skipping"
        return 0
    fi
    
    cd "$vkd3d_dir"
    
    # Build x86
    if [[ -f "build-win32.txt" ]]; then
        rm -rf build-x86
        meson setup build-x86 \
            --cross-file build-win32.txt \
            --buildtype release \
            --prefix "$PWD/install-x86" \
            -Denable_tests=false
        ninja -C build-x86 install
    fi
    
    # Build x64
    if [[ -f "build-win64.txt" ]]; then
        rm -rf build-x64
        meson setup build-x64 \
            --cross-file build-win64.txt \
            --buildtype release \
            --prefix "$PWD/install-x64" \
            -Denable_tests=false
        ninja -C build-x64 install
    fi
    
    cd - >/dev/null
    log_info "✓ VKD3D-Proton built successfully"
}

create_prefix_pack() {
    log_step "Creating Wine prefix pack..."
    
    local prefix_dir="prefix_temp"
    rm -rf "$prefix_dir"
    mkdir -p "$prefix_dir"
    
    cd "$prefix_dir"
    
    # Create directory structure
    mkdir -p drive_c/windows/system32
    mkdir -p drive_c/windows/syswow64
    mkdir -p drive_c/users/Public/Temp
    mkdir -p "drive_c/Program Files"
    mkdir -p "drive_c/Program Files (x86)"
    mkdir -p drive_c/ProgramData
    
    # Create system.reg
    cat > system.reg << 'REGEOF'
WINE REGISTRY Version 2
;; All keys relative to \\Machine

[Software\\Microsoft\\Windows\\CurrentVersion]
"ProgramFilesDir"="C:\\Program Files"
"CommonFilesDir"="C:\\Program Files\\Common Files"
"ProgramFilesDir (x86)"="C:\\Program Files (x86)"
"CommonFilesDir (x86)"="C:\\Program Files (x86)\\Common Files"
"ProgramW6432Dir"="C:\\Program Files"
"CommonW6432Dir"="C:\\Program Files\\Common Files"

[Software\\Microsoft\\Windows NT\\CurrentVersion]
"CurrentVersion"="10.0"
"CurrentBuild"="19041"
"CurrentBuildNumber"="19041"
"ProductName"="Windows 10 Pro"
"CSDVersion"=""
"CurrentMajorVersionNumber"=dword:0000000a
"CurrentMinorVersionNumber"=dword:00000000

[System\\CurrentControlSet\\Control\\Session Manager\\Environment]
"PATH"="C:\\windows\\system32;C:\\windows;C:\\windows\\system32\\wbem"
"TEMP"="C:\\users\\Public\\Temp"
"TMP"="C:\\users\\Public\\Temp"
"ComSpec"="C:\\windows\\system32\\cmd.exe"
"OS"="Windows_NT"
"PATHEXT"=".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC"
REGEOF

    # Create user.reg
    cat > user.reg << 'REGEOF'
WINE REGISTRY Version 2
;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

[Environment]
"PATH"="C:\\windows\\system32;C:\\windows"
"TEMP"="C:\\users\\Public\\Temp"
"TMP"="C:\\users\\Public\\Temp"

[Software\\Wine\\DllOverrides]
"*version"="native,builtin"
REGEOF

    # Create userdef.reg
    cat > userdef.reg << 'REGEOF'
WINE REGISTRY Version 2
;; All keys relative to \\User\\.Default
REGEOF

    # Create .update-timestamp
    echo "$(date +%s)" > .update-timestamp
    
    # Compress
    tar -cJf ../prefixPack.txz .
    
    cd ..
    rm -rf "$prefix_dir"
    
    log_info "✓ Prefix pack created"
}

create_wcp_package() {
    log_step "Creating WCP package..."
    
    local build_date
    build_date=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    local version_code
    version_code=$(date +%Y%m%d)
    
    mkdir -p "$OUT_DIR"
    rm -rf wcp_package
    mkdir -p wcp_package/{bin,lib/wine}
    
    # Copy Wine ARM64EC
    if [[ -d "wine-arm64ec/install/bin" ]]; then
        cp -r wine-arm64ec/install/bin/* wcp_package/bin/
    else
        log_error "Wine ARM64EC bin directory not found"
        exit 1
    fi
    
    if [[ -d "wine-arm64ec/install/lib" ]]; then
        cp -r wine-arm64ec/install/lib/* wcp_package/lib/
    fi
    
    # Copy Wine i386 for WoW64
    if [[ -d "wine-i386/install/lib/wine/i386-windows" ]]; then
        mkdir -p wcp_package/lib/wine/i386-windows
        cp -r wine-i386/install/lib/wine/i386-windows/* wcp_package/lib/wine/i386-windows/
        log_info "  - Added i386 DLLs for WoW64"
    fi
    
    # Copy share directory
    if [[ -d "wine-arm64ec/install/share" ]]; then
        cp -r wine-arm64ec/install/share wcp_package/
    fi
    
    # Copy DXVK
    if [[ "$WITH_DXVK" == true ]]; then
        local dxvk_dir="${PROTON_DIR}/dxvk"
        if [[ -d "$dxvk_dir/install-x86/bin" ]]; then
            cp "$dxvk_dir/install-x86/bin/"*.dll wcp_package/lib/wine/i386-windows/ 2>/dev/null || true
            log_info "  - Added DXVK x86 DLLs"
        fi
        if [[ -d "$dxvk_dir/install-x64/bin" ]]; then
            mkdir -p wcp_package/lib/wine/x86_64-windows
            cp "$dxvk_dir/install-x64/bin/"*.dll wcp_package/lib/wine/x86_64-windows/ 2>/dev/null || true
            log_info "  - Added DXVK x64 DLLs"
        fi
    fi
    
    # Copy VKD3D-Proton
    if [[ "$WITH_VKD3D" == true ]]; then
        local vkd3d_dir="${PROTON_DIR}/vkd3d-proton"
        if [[ -d "$vkd3d_dir/install-x86/bin" ]]; then
            cp "$vkd3d_dir/install-x86/bin/"*.dll wcp_package/lib/wine/i386-windows/ 2>/dev/null || true
            log_info "  - Added VKD3D x86 DLLs"
        fi
        if [[ -d "$vkd3d_dir/install-x64/bin" ]]; then
            mkdir -p wcp_package/lib/wine/x86_64-windows
            cp "$vkd3d_dir/install-x64/bin/"*.dll wcp_package/lib/wine/x86_64-windows/ 2>/dev/null || true
            log_info "  - Added VKD3D x64 DLLs"
        fi
    fi
    
    # Copy prefix pack
    if [[ -f "prefixPack.txz" ]]; then
        cp prefixPack.txz wcp_package/
    else
        log_warn "prefixPack.txz not found, creating..."
        create_prefix_pack
        cp prefixPack.txz wcp_package/
    fi
    
    # Create profile.json
    cat > wcp_package/profile.json << EOF
{
  "type": "Wine",
  "versionName": "${VERSION_NAME}",
  "versionCode": ${version_code},
  "description": "Wine ARM64EC for Winlator + FEXCore. Build: ${build_date}",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
EOF

    # Create README
    cat > wcp_package/README.txt << EOF
Wine ARM64EC for Winlator + FEXCore
====================================
Version: ${VERSION_NAME}
Build Date: ${build_date}
Build Type: ${BUILD_TYPE}

Components:
- Wine ARM64EC (native ARM64 execution)
- Wine i386 DLLs (32-bit WoW64 support)
- Wine prefix template
EOF

    [[ "$WITH_DXVK" == true ]] && echo "- DXVK (DirectX 9/10/11 → Vulkan)" >> wcp_package/README.txt
    [[ "$WITH_VKD3D" == true ]] && echo "- VKD3D-Proton (DirectX 12 → Vulkan)" >> wcp_package/README.txt

    cat >> wcp_package/README.txt << EOF

Installation:
1. Copy .wcp file to your device
2. Open Winlator → Contents → Install from file
3. Select this Wine version in container settings
4. Set emulator to FEXCore

For best compatibility with FEXCore on ARM64 devices.
EOF

    # Create archive
    cd wcp_package
    tar -cJf "../${OUT_DIR}/${VERSION_NAME}.wcp" .
    cd ..
    
    # Generate checksums
    cd "$OUT_DIR"
    sha256sum "${VERSION_NAME}.wcp" > "${VERSION_NAME}.wcp.sha256"
    md5sum "${VERSION_NAME}.wcp" > "${VERSION_NAME}.wcp.md5"
    cd ..
    
    # Cleanup
    rm -rf wcp_package
    
    log_info "✓ WCP package created"
}

print_summary() {
    local wcp_file="${OUT_DIR}/${VERSION_NAME}.wcp"
    
    if [[ ! -f "$wcp_file" ]]; then
        log_error "Build failed - WCP file not found"
        exit 1
    fi
    
    local file_size
    file_size=$(du -h "$wcp_file" | cut -f1)
    local sha256
    sha256=$(cat "${wcp_file}.sha256" | cut -d' ' -f1)
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           BUILD SUCCESSFUL!                ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo "  Version:     ${VERSION_NAME}"
    echo "  Build Type:  ${BUILD_TYPE}"
    echo "  Output:      ${wcp_file}"
    echo "  Size:        ${file_size}"
    echo "  SHA256:      ${sha256:0:16}..."
    echo ""
    echo "  Components:"
    echo "    ✓ Wine ARM64EC"
    echo "    ✓ Wine i386 (WoW64)"
    echo "    ✓ Prefix Pack"
    [[ "$WITH_DXVK" == true ]] && echo "    ✓ DXVK"
    [[ "$WITH_VKD3D" == true ]] && echo "    ✓ VKD3D-Proton"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
}

# === Main ===
main() {
    parse_args "$@"
    
    echo ""
    echo -e "${BLUE}Wine ARM64EC Builder for Winlator + FEXCore${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    
    log_info "Configuration:"
    log_info "  Version:     ${VERSION_NAME}"
    log_info "  Proton Dir:  ${PROTON_DIR}"
    log_info "  Output Dir:  ${OUT_DIR}"
    log_info "  Build Type:  ${BUILD_TYPE}"
    log_info "  DXVK:        ${WITH_DXVK}"
    log_info "  VKD3D:       ${WITH_VKD3D}"
    log_info "  Jobs:        ${JOBS}"
    log_info "  Clean:       ${CLEAN_BUILD}"
    echo ""
    
    validate_environment
    
    build_wine_tools
    build_wine_arm64ec
    build_wine_i386
    build_dxvk
    build_vkd3d
    create_prefix_pack
    create_wcp_package
    
    print_summary
}

main "$@"
