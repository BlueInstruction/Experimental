#!/usr/bin/env bash
set -euo pipefail

readonly SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PR="$(dirname "$SD")"
readonly RU="https://github.com/HansKristian-Work/vkd3d-proton.git"

VERSION="${1:-}"
PROFILE="${PROFILE:-p7}"
OD="${2:-$PR/output}"
SRC="$PR/src"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[E] $*" >&2; exit 1; }

fetch_ver() {
    if [[ -z "$VERSION" ]]; then
        log "Fetching..."
        VERSION=$(curl -sL https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+') || true
        [[ -z "$VERSION" ]] && err "Fetch failed"
    fi
    [[ "$VERSION" =~ ^v ]] || VERSION="v$VERSION"
    log "V:$VERSION"
}

clone() {
    [[ -d "$SRC" ]] && rm -rf "$SRC"
    log "Cloning $VERSION..."
    git clone --branch "$VERSION" --depth 1 --recursive --shallow-submodules "$RU" "$SRC"
    cd "$SRC"
    COMMIT=$(git rev-parse --short=8 HEAD)
    log "C:$COMMIT"
    export COMMIT
}

patch() {
    log "Patching P:$PROFILE..."
    python3 "$SD/patcher.py" "$SRC" --profile "$PROFILE" --report || err "Patch failed"
    log "Patched"
}

flags() {
    export CFLAGS="-O3 -march=x86-64-v3 -mtune=generic -msse4.2 -mavx -mavx2 -mfma -ffast-math -fno-math-errno -fomit-frame-pointer -flto=auto -fno-semantic-interposition -DNDEBUG"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,--gc-sections -flto=auto -s"
}

build() {
    log "Building..."
    flags
    cd "$SRC"
    chmod +x ./package-release.sh
    ./package-release.sh "$VERSION" "$OD" --no-package
}

verify() {
    log "Verifying..."
    local e=0
    local bo
    bo=$(find "$OD" -maxdepth 1 -type d -name "vkd3d-proton-*" | head -1)
    [[ -z "$bo" ]] && err "Output not found"
    for ad in x64 x86; do
        for dll in d3d12.dll d3d12core.dll; do
            local dp="$bo/$ad/$dll"
            [[ -f "$dp" ]] && log "OK:$dp ($(stat -c%s "$dp"))" || { log "MISS:$dp"; ((e++)); }
        done
    done
    [[ $e -gt 0 ]] && err "Verify failed:$e"
    log "Verified"
}

export_env() {
    { echo "VERSION=${VERSION#v}"; echo "COMMIT=$COMMIT"; echo "PROFILE=$PROFILE"; } >> "${GITHUB_ENV:-/dev/null}"
}

main() {
    log "V3X Build"
    log "========="
    fetch_ver
    clone
    patch
    build
    verify
    export_env
    log "Done"
}

main "$@"
