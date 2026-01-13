#!/bin/bash -e

# ╔═══════════════════════════════════════════════════════════════╗
# ║                  🐉 DRAGON FORGE v3.0 🐉                      ║
# ║              Professional Build System                        ║
# ╚═══════════════════════════════════════════════════════════════╝

# === COLORS ===
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# === CONFIG ===
CHAMBER="$(pwd)/forge_chamber"
SPELLS_DIR="$(pwd)/spells"
CORE_VER="${CORE_VER:-android-ndk-r29}"
LEVEL="${LEVEL:-35}"
LAIR="https://gitlab.freedesktop.org/mesa/mesa.git"
MIRROR_LAIR="https://github.com/mesa3d/mesa.git"

VARIANT="${1:-tiger}"
CUSTOM_COMMIT="${2:-}"
COMMIT_SHORT=""
DRAGON_VER=""
MAX_RETRIES=3
RETRY_DELAY=15

# === LOGGING ===
log() { echo -e "${CYAN}[🐉 Dragon]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${MAGENTA}[ℹ]${NC} $1"; }

# === UTILITIES ===
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

# === PREPARE CHAMBER ===
prepare_chamber() {
    log "Preparing forge chamber..."
    mkdir -p "$CHAMBER"
    cd "$CHAMBER"

    # NDK Setup
    setup_ndk
    
    # Clone Mesa
    clone_mesa
    
    cd "$CHAMBER"
    success "Chamber ready - Mesa $DRAGON_VER ($COMMIT_SHORT)"
}

setup_ndk() {
    if [ -n "${ANDROID_NDK_LATEST_HOME}" ] && [ -d "${ANDROID_NDK_LATEST_HOME}" ]; then
        export ANDROID_NDK_HOME="${ANDROID_NDK_LATEST_HOME}"
        info "Using system NDK: $ANDROID_NDK_HOME"
        return
    fi
    
    if [ -d "$CHAMBER/$CORE_VER" ]; then
        export ANDROID_NDK_HOME="$CHAMBER/$CORE_VER"
        info "Using cached NDK: $ANDROID_NDK_HOME"
        return
    fi
    
    log "Downloading NDK..."
    local ndk_url="https://dl.google.com/android/repository/${CORE_VER}-linux.zip"
    
    if ! retry_command "curl -sL '$ndk_url' -o core.zip" "Downloading NDK"; then
        error "Failed to download NDK"
    fi
    
    unzip -q core.zip && rm -f core.zip
    export ANDROID_NDK_HOME="$CHAMBER/$CORE_VER"
    success "NDK installed: $ANDROID_NDK_HOME"
}

clone_mesa() {
    [ -d mesa ] && rm -rf mesa
    
    log "Cloning Mesa repository..."
    
    # Try primary source
    if retry_command "git clone --depth=500 '$LAIR' mesa 2>/dev/null" "Cloning from GitLab"; then
        setup_mesa_repo
        return
    fi
    
    # Try mirror
    warn "GitLab unavailable, trying GitHub mirror..."
    if retry_command "git clone --depth=500 '$MIRROR_LAIR' mesa 2>/dev/null" "Cloning from GitHub"; then
        setup_mesa_repo
        return
    fi
    
    error "Failed to clone Mesa from all sources"
}

setup_mesa_repo() {
    cd "$CHAMBER/mesa"
    git config user.name "DragonForge"
    git config user.email "forge@dragon.local"
    
    # Custom commit checkout
    if [ -n "$CUSTOM_COMMIT" ]; then
        log "Checking out: $CUSTOM_COMMIT"
        git fetch --depth=100 origin
        git checkout "$CUSTOM_COMMIT" 2>/dev/null || warn "Could not checkout $CUSTOM_COMMIT, using HEAD"
    fi
    
    COMMIT_SHORT=$(git rev-parse --short HEAD)
    DRAGON_VER=$(cat VERSION 2>/dev/null || echo "unknown")
}

# === SPELLS (PATCHES) ===
apply_spell_file() {
    local spell_path="$1"
    local full_path="$SPELLS_DIR/$spell_path.patch"
    
    if [ ! -f "$full_path" ]; then
        warn "Spell not found: $spell_path"
        return 1
    fi
    
    log "Casting spell: $spell_path"
    cd "$CHAMBER/mesa"
    
    if git apply "$full_path" --check 2>/dev/null; then
        git apply "$full_path"
        success "Spell applied: $spell_path"
    else
        warn "Spell may conflict, trying 3-way merge..."
        git apply "$full_path" --3way 2>/dev/null || warn "Spell partially applied: $spell_path"
    fi
}

apply_merge_request() {
    local mr_id="$1"
    log "Fetching MR !$mr_id..."
    cd "$CHAMBER/mesa"
    
    if ! git fetch origin "refs/merge-requests/$mr_id/head" 2>/dev/null; then
        warn "Could not fetch MR $mr_id"
        return 1
    fi
    
    if git merge --no-edit FETCH_HEAD 2>/dev/null; then
        success "Merged MR !$mr_id"
    else
        warn "Merge conflict in MR $mr_id, skipping"
        git merge --abort 2>/dev/null || true
        return 1
    fi
}

# === INLINE SPELLS ===
spell_tiger_velocity() {
    log "Applying Tiger Velocity..."
    cd "$CHAMBER/mesa"
    
    local file="src/freedreno/vulkan/tu_cmd_buffer.cc"
    [ ! -f "$file" ] && { warn "Target file not found"; return 1; }
    
    # Check if already applied
    if grep -q "// Dragon: Tiger Velocity" "$file" 2>/dev/null; then
        info "Tiger Velocity already applied"
        return 0
    fi
    
    # Apply patch
    if grep -q "use_sysmem_rendering" "$file"; then
        sed -i '/^use_sysmem_rendering/,/^{/{/^{/a\   // Dragon: Tiger Velocity\n   return true;
        }' "$file" 2>/dev/null || \
        sed -i '/if (TU_DEBUG(SYSMEM))/i\   // Dragon: Tiger Velocity\n   return true;' "$file"
        success "Tiger Velocity applied"
    else
        warn "Could not apply Tiger Velocity"
    fi
}

spell_falcon_memory() {
    log "Applying Falcon Memory..."
    cd "$CHAMBER/mesa"
    
    local changes=0
    
    if [ -f src/freedreno/vulkan/tu_query.cc ]; then
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
        ((changes++))
    fi
    
    if [ -f src/freedreno/vulkan/tu_device.cc ]; then
        sed -i 's/has_cached_coherent_memory = true/has_cached_coherent_memory = false/g' src/freedreno/vulkan/tu_device.cc
        ((changes++))
    fi
    
    [ $changes -gt 0 ] && success "Falcon Memory applied ($changes files)" || warn "No changes made"
}

# === FORGE (BUILD) ===
forge_dragon() {
    local variant_name="$1"
    
    echo ""
    log "╔═══════════════════════════════════════╗"
    log "║  Forging: $variant_name"
    log "╚═══════════════════════════════════════╝"
    
    cd "$CHAMBER/mesa"
    
    # Setup cross compilation
    create_cross_file
    
    # Meson setup
    run_meson_setup "$variant_name"
    
    # Build
    run_ninja_build "$variant_name"
    
    # Package
    package_build "$variant_name"
}

create_cross_file() {
    local NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local CROSS_FILE="$CHAMBER/cross_dragon"
    
    cat <<EOF > "$CROSS_FILE"
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${LEVEL}-clang', '-Wno-error', '-Wno-array-bounds', '-Wno-c99-designator', '-Wno-typedef-redefinition']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${LEVEL}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '-Wno-error', '-Wno-array-bounds', '-Wno-c++11-narrowing', '-Wno-vla-cxx-extension', '-Wno-c99-designator', '-Wno-typedef-redefinition']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$NDK_BIN/llvm-strip'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF
    
    info "Cross-compilation file created"
}

run_meson_setup() {
    local variant_name="$1"
    local log_file="$CHAMBER/meson_${variant_name}.log"
    
    log "Running Meson setup..."
    rm -rf build-dragon
    
    if ! meson setup build-dragon \
        --cross-file "$CHAMBER/cross_dragon" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$LEVEL \
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
        -Dzstd=disabled \
        -Dspirv-tools=disabled \
        -Dwerror=false \
        -Dvalgrind=disabled \
        &> "$log_file"; then
        
        echo ""
        error "Meson setup failed. Log:"
        tail -30 "$log_file"
        exit 1
    fi
    
    success "Meson setup complete"
}

run_ninja_build() {
    local variant_name="$1"
    local log_file="$CHAMBER/ninja_${variant_name}.log"
    local cores=$(nproc 2>/dev/null || echo 4)
    
    log "Building with Ninja (${cores} cores)..."
    
    if ! ninja -C build-dragon -j"$cores" &> "$log_file"; then
        echo ""
        warn "Build failed. Last 50 lines:"
        tail -50 "$log_file"
        error "Ninja build failed for $variant_name"
    fi
    
    success "Build complete"
}

package_build() {
    local variant_name="$1"
    local SO_FILE="build-dragon/src/freedreno/vulkan/libvulkan_freedreno.so"
    
    if [ ! -f "$SO_FILE" ]; then
        error "Build output not found: $SO_FILE"
    fi
    
    log "Packaging $variant_name..."
    cd "$CHAMBER"
    
    # Copy and patch
    cp "mesa/$SO_FILE" libvulkan_freedreno.so
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so vulkan.dragon.so
    
    # Create metadata
    local FILENAME="Dragon-${variant_name}-${DRAGON_VER}-${COMMIT_SHORT}"
    local DATE=$(date '+%Y-%m-%d %H:%M')
    
    cat <<EOF > meta.json
{
    "schemaVersion": 1,
    "name": "Dragon ${variant_name}",
    "description": "Mesa ${DRAGON_VER} - ${variant_name} variant - Built: ${DATE}",
    "author": "DragonForge",
    "packageVersion": "1",
    "vendor": "Mesa",
    "driverVersion": "${DRAGON_VER}",
    "minApi": 27,
    "libraryName": "vulkan.dragon.so"
}
EOF
    
    # Create ZIP
    zip -9 "${FILENAME}.zip" vulkan.dragon.so meta.json
    
    # Cleanup
    rm -f vulkan.dragon.so meta.json
    
    local size=$(du -h "${FILENAME}.zip" | cut -f1)
    success "Created: ${FILENAME}.zip ($size)"
}

# === VARIANT BUILDERS ===
reset_mesa() {
    log "Resetting Mesa source..."
    cd "$CHAMBER/mesa"
    git checkout . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
}

build_tiger() {
    log "🐯 === TIGER BUILD ==="
    reset_mesa
    spell_tiger_velocity
    forge_dragon "Tiger"
}

build_tiger_phoenix() {
    log "🐯🔥 === TIGER-PHOENIX BUILD ==="
    reset_mesa
    spell_tiger_velocity
    apply_spell_file "phoenix/wings_boost"
    forge_dragon "Tiger-Phoenix"
}

build_falcon() {
    log "🦅 === FALCON BUILD ==="
    reset_mesa
    spell_falcon_memory
    spell_tiger_velocity
    forge_dragon "Falcon"
}

build_shadow() {
    log "👤 === SHADOW BUILD ==="
    reset_mesa
    apply_merge_request "37802"
    forge_dragon "Shadow"
}

build_hawk() {
    log "🦅 === HAWK BUILD (Full Power) ==="
    reset_mesa
    spell_tiger_velocity
    spell_falcon_memory
    apply_spell_file "phoenix/wings_boost"
    apply_spell_file "common/memory_fix"
    forge_dragon "Hawk"
}

build_all() {
    log "🔥 === BUILDING ALL VARIANTS ==="
    local variants=("tiger" "tiger_phoenix" "falcon" "shadow" "hawk")
    local success_count=0
    local failed=()
    
    for v in "${variants[@]}"; do
        echo ""
        if "build_${v}" 2>/dev/null || "build_$(echo $v | tr '_' '-')" 2>/dev/null; then
            ((success_count++))
        else
            failed+=("$v")
        fi
    done
    
    echo ""
    info "Build Summary: $success_count/${#variants[@]} successful"
    [ ${#failed[@]} -gt 0 ] && warn "Failed: ${failed[*]}"
}

# === MAIN ===
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                  🐉 DRAGON FORGE v3.0 🐉                      ║"
    echo "║              Professional Build System                        ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    info "Variant: $VARIANT"
    info "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Pre-flight checks
    check_dependencies
    
    # Prepare environment
    prepare_chamber
    
    # Build selected variant
    case "$VARIANT" in
        tiger)          build_tiger ;;
        tiger-phoenix)  build_tiger_phoenix ;;
        falcon)         build_falcon ;;
        shadow)         build_shadow ;;
        hawk)           build_hawk ;;
        all)            build_all ;;
        *)
            warn "Unknown variant: $VARIANT"
            info "Available: tiger, tiger-phoenix, falcon, shadow, hawk, all"
            warn "Defaulting to tiger..."
            build_tiger
            ;;
    esac
    
    # Final summary
    echo ""
    success "╔═══════════════════════════════════════╗"
    success "║     🐉 Dragon Forge Complete! 🐉      ║"
    success "╚═══════════════════════════════════════╝"
    echo ""
    
    # List outputs
    if ls "$CHAMBER"/*.zip 1>/dev/null 2>&1; then
        info "Output files:"
        ls -lh "$CHAMBER"/*.zip
    else
        warn "No output files found"
        exit 1
    fi
}

# Run main
main "$@"
