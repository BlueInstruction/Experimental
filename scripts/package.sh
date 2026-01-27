#!/usr/bin/env bash
set -euo pipefail

readonly SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PR="$(dirname "$SD")"

VERSION="${1:-}"
COMMIT="${2:-}"
OD="${PR}/output"
PD="${PR}/package"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[E] $*" >&2; exit 1; }

validate() {
    [[ -z "$VERSION" ]] && err "VERSION required"
    [[ -z "$COMMIT" ]] && err "COMMIT required"
    VC="${VERSION#v}"
    AN="vkd3d-${VC}-${COMMIT}-d3mu"
    log "V:$VC"
    log "C:$COMMIT"
    log "A:$AN"
}

find_output() {
    BO=$(find "$OD" -maxdepth 1 -type d -name "vkd3d-proton-*" | head -1)
    [[ -z "$BO" ]] && err "Output not found"
    log "BO:$BO"
}

create_pkg() {
    log "Creating pkg..."
    rm -rf "$PD"
    mkdir -p "$PD/system32" "$PD/syswow64"
    [[ -d "$BO/x64" ]] && cp -v "$BO/x64/d3d12.dll" "$BO/x64/d3d12core.dll" "$PD/system32/" 2>/dev/null || true
    [[ -d "$BO/x86" ]] && cp -v "$BO/x86/d3d12.dll" "$BO/x86/d3d12core.dll" "$PD/syswow64/" 2>/dev/null || true
    log "Pkg created"
}

create_profile() {
    log "Creating profile..."
    cat > "$PD/profile.json" << EOF
{
  "type": "VKD3D",
  "versionName": "${VC}-${COMMIT}-d3mu",
  "versionCode": $(date +%Y%m%d),
  "description": "V3X ${VC} D3MU",
  "files": [
    {"source": "system32/d3d12.dll", "target": "\${system32}/d3d12.dll"},
    {"source": "system32/d3d12core.dll", "target": "\${system32}/d3d12core.dll"},
    {"source": "syswow64/d3d12.dll", "target": "\${syswow64}/d3d12.dll"},
    {"source": "syswow64/d3d12core.dll", "target": "\${syswow64}/d3d12core.dll"}
  ]
}
EOF
    log "Profile created"
}

verify_pkg() {
    log "Verifying..."
    local e=0
    local rf=("profile.json" "system32/d3d12.dll" "system32/d3d12core.dll" "syswow64/d3d12.dll" "syswow64/d3d12core.dll")
    for f in "${rf[@]}"; do
        if [[ -f "$PD/$f" ]]; then
            log "OK:$f ($(stat -c%s "$PD/$f"))"
        else
            log "MISS:$f"
            ((e++))
        fi
    done
    [[ $e -gt 0 ]] && err "Verify failed:$e"
    log "Verified"
}

archive() {
    log "Archiving..."
    cd "$PD"
    tar --zstd -cf "$PR/${AN}.wcp" .
    log "Pkg:${AN}.wcp"
    log "Size:$(du -h "$PR/${AN}.wcp" | cut -f1)"
}

copy_report() {
    [[ -f "$PR/patch-report.json" ]] && cp "$PR/patch-report.json" "$PD/" && log "Report included"
}

export_env() {
    {
        echo "ARTIFACT_NAME=$AN"
        echo "VERSION_CLEAN=$VC"
    } >> "${GITHUB_ENV:-/dev/null}"
}

main() {
    log "V3X Packager"
    log "============"
    validate
    find_output
    create_pkg
    create_profile
    copy_report
    verify_pkg
    archive
    export_env
    log "Done"
}

main "$@"
