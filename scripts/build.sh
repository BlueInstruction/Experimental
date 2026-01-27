#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly REPO_URL="https://github.com/HansKristian-Work/vkd3d-proton.git"

VERSION="${1:-}"
ARCH="${2:-x86_64}"
PROFILE="${PROFILE:-ue5}"
OUTPUT_DIR="${3:-$PROJECT_ROOT/output}"
SRC_DIR="$PROJECT_ROOT/src"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

fetch_version() {
    if [[ -z "$VERSION" ]]; then
        log "Fetching latest version..."
        VERSION=$(curl -sL https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/latest \
            | grep -oP '"tag_name":\s*"\K[^"]+') || true
        [[ -z "$VERSION" ]] && error "Failed to fetch latest version"
    fi
    [[ "$VERSION" =~ ^v ]] || VERSION="v$VERSION"
    log "Version: $VERSION"
}

clone_source() {
    [[ -d "$SRC_DIR" ]] && rm -rf "$SRC_DIR"

    log "Cloning vkd3d-proton $VERSION..."
    git clone --branch "$VERSION" --depth 1 "$REPO_URL" "$SRC_DIR"

    cd "$SRC_DIR"
    log "Initializing submodules..."
    git submodule update --init --recursive --depth 1 --jobs 4

    COMMIT=$(git rev-parse --short=8 HEAD)
    log "Commit: $COMMIT"
    export COMMIT
}

apply_patches() {
    log "Applying patches (profile: $PROFILE, arch: $ARCH)..."

    python3 "$PROJECT_ROOT/patches/patcher.py" "$SRC_DIR" \
        --arch "$ARCH" \
        --profile "$PROFILE" \
        --report \
        || error "Patch application failed"

    log "Patches applied successfully"
}

setup_x86_64_flags() {
    export CFLAGS="-O3 -march=x86-64-v3 -mtune=generic -msse4.2 -mavx -mavx2 -mfma"
    export CFLAGS="$CFLAGS -ffast-math -fno-math-errno -fomit-frame-pointer"
    export CFLAGS="$CFLAGS -flto=auto -fno-semantic-interposition -DNDEBUG"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,--gc-sections -flto=auto -s"
}

setup_arm64ec_flags() {
    export CFLAGS="-O3 -DNDEBUG -ffast-math -fno-strict-aliasing"
    export CFLAGS="$CFLAGS -mno-outline-atomics -flto=auto -fno-semantic-interposition"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-static -s -flto=auto"
}

build_x86_64() {
    log "Building x86_64..."
    setup_x86_64_flags

    cd "$SRC_DIR"
    chmod +x ./package-release.sh
    ./package-release.sh "$VERSION" "$OUTPUT_DIR" --no-package
}

create_arm64ec_cross_file() {
    cat > "$PROJECT_ROOT/arm64ec-cross.txt" << 'EOF'
[binaries]
c = 'aarch64-w64-mingw32-clang'
cpp = 'aarch64-w64-mingw32-clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
windres = 'aarch64-w64-mingw32-windres'
widl = 'aarch64-w64-mingw32-widl'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-mno-outline-atomics', '-flto=auto']
cpp_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-mno-outline-atomics', '-flto=auto']
c_link_args = ['-static', '-s', '-flto=auto']
cpp_link_args = ['-static', '-s', '-flto=auto']

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

    cat > "$PROJECT_ROOT/i686-cross.txt" << 'EOF'
[binaries]
c = 'i686-w64-mingw32-gcc'
cpp = 'i686-w64-mingw32-g++'
ar = 'i686-w64-mingw32-ar'
strip = 'i686-w64-mingw32-strip'
windres = 'i686-w64-mingw32-windres'
widl = 'i686-w64-mingw32-widl'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-ffast-math', '-msse', '-msse2', '-flto=auto']
cpp_args = ['-O3', '-DNDEBUG', '-ffast-math', '-msse', '-msse2', '-flto=auto']
c_link_args = ['-static', '-s', '-flto=auto']
cpp_link_args = ['-static', '-s', '-flto=auto']

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
EOF
}

build_arm64ec() {
    log "Building ARM64EC..."
    create_arm64ec_cross_file

    cd "$SRC_DIR"

    log "Configuring ARM64EC build..."
    meson setup build-arm64ec \
        --cross-file "$PROJECT_ROOT/arm64ec-cross.txt" \
        --buildtype release \
        -Denable_tests=false \
        -Denable_extras=false

    log "Compiling ARM64EC..."
    ninja -C build-arm64ec -j"$(nproc)"

    log "Configuring i686 build..."
    meson setup build-i686 \
        --cross-file "$PROJECT_ROOT/i686-cross.txt" \
        --buildtype release \
        -Denable_tests=false \
        -Denable_extras=false

    log "Compiling i686..."
    ninja -C build-i686 -j"$(nproc)"
}

verify_build() {
    log "Verifying build..."
    local errors=0

    if [[ "$ARCH" == "x86_64" ]]; then
        local build_output
        build_output=$(find "$OUTPUT_DIR" -maxdepth 1 -type d -name "vkd3d-proton-*" | head -1)
        [[ -z "$build_output" ]] && error "Build output not found"

        for arch_dir in x64 x86; do
            for dll in d3d12.dll d3d12core.dll; do
                local dll_path="$build_output/$arch_dir/$dll"
                if [[ -f "$dll_path" ]]; then
                    log "OK: $dll_path ($(stat -c%s "$dll_path") bytes)"
                else
                    log "MISSING: $dll_path"
                    ((errors++))
                fi
            done
        done
    else
        for build_dir in arm64ec i686; do
            for dll in d3d12.dll d3d12core.dll; do
                local dll_path
                dll_path=$(find "$SRC_DIR/build-$build_dir" -name "$dll" -type f 2>/dev/null | head -1)
                if [[ -n "$dll_path" ]]; then
                    log "OK: $dll ($build_dir) - $(stat -c%s "$dll_path") bytes"
                else
                    log "MISSING: $dll ($build_dir)"
                    ((errors++))
                fi
            done
        done
    fi

    [[ $errors -gt 0 ]] && error "Build verification failed with $errors error(s)"
    log "Build verification passed"
}

export_env() {
    {
        echo "VERSION=${VERSION#v}"
        echo "COMMIT=$COMMIT"
        echo "ARCH=$ARCH"
        echo "PROFILE=$PROFILE"
    } >> "${GITHUB_ENV:-/dev/null}"
}

main() {
    log "VKD3D-Proton Build Script"
    log "========================="

    fetch_version
    clone_source
    apply_patches

    case "$ARCH" in
        x86_64)  build_x86_64 ;;
        arm64ec) build_arm64ec ;;
        *)       error "Unknown architecture: $ARCH" ;;
    esac

    verify_build
    export_env

    log "Build completed successfully"
}

main "$@"
