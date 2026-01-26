#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="${1:-}"
ARCH="${2:-x86_64}"
OUTPUT_DIR="${3:-$PROJECT_ROOT/output}"

REPO_URL="https://github.com/HansKristian-Work/vkd3d-proton.git"
SRC_DIR="$PROJECT_ROOT/src"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

fetch_version() {
    if [[ -z "$VERSION" ]]; then
        VERSION=$(curl -sL https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
        [[ -z "$VERSION" ]] && error "failed to fetch latest version"
    fi
    [[ "$VERSION" =~ ^v ]] || VERSION="v$VERSION"
    log "version: $VERSION"
}

clone_source() {
    if [[ -d "$SRC_DIR" ]]; then
        rm -rf "$SRC_DIR"
    fi

    log "cloning vkd3d-proton $VERSION"
    git clone --branch "$VERSION" --depth 1 "$REPO_URL" "$SRC_DIR"
    cd "$SRC_DIR"
    git submodule update --init --recursive --depth 1 --jobs 4

    COMMIT=$(git rev-parse --short=8 HEAD)
    log "commit: $COMMIT"
}

apply_patches() {
    log "applying performance patches"
    if ! python3 "$PROJECT_ROOT/patches/performance.py" "$SRC_DIR" --arch "$ARCH" --report; then
        error "patches failed"
    fi
}

build_x86_64() {
    log "building x86_64"

    export CFLAGS="-O3 -march=x86-64 -mtune=generic -msse4.2 -mavx -mavx2 -mfma -ffast-math -fno-math-errno -fomit-frame-pointer -flto=auto -DNDEBUG"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,--gc-sections -flto=auto -s"

    cd "$SRC_DIR"
    chmod +x ./package-release.sh
    ./package-release.sh "$VERSION" "$OUTPUT_DIR" --no-package
}

build_arm64ec() {
    log "building arm64ec"

    cat > "$PROJECT_ROOT/arm64ec-cross.txt" << 'EOF'
[binaries]
c = 'aarch64-w64-mingw32-gcc'
cpp = 'aarch64-w64-mingw32-g++'
ar = 'aarch64-w64-mingw32-ar'
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
strip = 'llvm-strip'
windres = 'i686-w64-mingw32-windres'
widl = 'i686-w64-mingw32-widl'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-msse', '-msse2', '-flto=auto']
cpp_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-msse', '-msse2', '-flto=auto']
c_link_args = ['-static', '-s', '-flto=auto']
cpp_link_args = ['-static', '-s', '-flto=auto']

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
EOF

    cd "$SRC_DIR"

    meson setup build-arm64ec \
        --cross-file "$PROJECT_ROOT/arm64ec-cross.txt" \
        --buildtype release \
        -Denable_tests=false \
        -Denable_extras=false

    ninja -C build-arm64ec -j"$(nproc)"

    meson setup build-i686 \
        --cross-file "$PROJECT_ROOT/i686-cross.txt" \
        --buildtype release \
        -Denable_tests=false \
        -Denable_extras=false

    ninja -C build-i686 -j"$(nproc)"
}

verify_build() {
    log "verifying build"

    if [[ "$ARCH" == "x86_64" ]]; then
        BUILD_OUTPUT=$(find "$OUTPUT_DIR" -maxdepth 1 -type d -name "vkd3d-proton-*" | head -1)
        [[ -z "$BUILD_OUTPUT" ]] && error "build output not found"

        for arch in x64 x86; do
            for dll in d3d12.dll d3d12core.dll; do
                dll_path="$BUILD_OUTPUT/$arch/$dll"
                [[ ! -f "$dll_path" ]] && error "missing: $dll_path"
                log "$dll_path: $(stat -c%s "$dll_path") bytes"
            done
        done
    else
        for arch in arm64ec i686; do
            for dll in d3d12.dll d3d12core.dll; do
                dll_path=$(find "$SRC_DIR/build-$arch" -name "$dll" -type f | head -1)
                [[ -z "$dll_path" ]] && error "missing: $dll ($arch)"
                log "$dll ($arch): $(stat -c%s "$dll_path") bytes"
            done
        done
    fi
}

main() {
    fetch_version
    clone_source
    apply_patches

    if [[ "$ARCH" == "x86_64" ]]; then
        build_x86_64
    else
        build_arm64ec
    fi

    verify_build

    log "build complete"
    echo "VERSION=${VERSION#v}" >> "${GITHUB_ENV:-/dev/null}"
    echo "COMMIT=$COMMIT" >> "${GITHUB_ENV:-/dev/null}"
}

main "$@"
