#!/bin/bash -e

# ╔═══════════════════════════════════════╗
# ║        🐉 DRAGON FORGE v2.0 🐉        ║
# ╚═══════════════════════════════════════╝

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === CONFIG ===
CHAMBER="$(pwd)/forge_chamber"
SPELLS_DIR="$(pwd)/spells"
CONFIG_FILE="$(pwd)/config/variants.conf"
CORE_VER="${CORE_VER:-android-ndk-r29}"
LEVEL="${LEVEL:-35}"
LAIR="https://gitlab.freedesktop.org/mesa/mesa.git"

VARIANT="${1:-tiger}"
CUSTOM_COMMIT="${2:-}"
COMMIT_SHORT=""
DRAGON_VER=""

# === LOGGING ===
log() { echo -e "${CYAN}[🐉 Dragon]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1" && exit 1; }

# === PREPARE CHAMBER ===
prepare_chamber() {
    log "Preparing forge chamber..."
    mkdir -p "$CHAMBER"
    cd "$CHAMBER"

    # NDK Setup
    if [ -z "${ANDROID_NDK_LATEST_HOME}" ] || [ ! -d "${ANDROID_NDK_LATEST_HOME}" ]; then
        if [ ! -d "$CORE_VER" ]; then
            log "Downloading core tools..."
            curl -sL "https://dl.google.com/android/repository/${CORE_VER}-linux.zip" -o core.zip
            unzip -q core.zip && rm core.zip
        fi
        export ANDROID_NDK_HOME="$CHAMBER/$CORE_VER"
    else
        export ANDROID_NDK_HOME="${ANDROID_NDK_LATEST_HOME}"
    fi

    # Clone Mesa
    [ -d mesa ] && rm -rf mesa
    log "Cloning dragon source..."
    git clone --depth=500 "$LAIR" mesa
    cd mesa
    git config user.name "DragonForge"
    git config user.email "forge@dragon.local"

    # Custom commit
    if [ -n "$CUSTOM_COMMIT" ]; then
        log "Checking out custom commit: $CUSTOM_COMMIT"
        git checkout "$CUSTOM_COMMIT"
    fi

    COMMIT_SHORT=$(git rev-parse --short HEAD)
    DRAGON_VER=$(cat VERSION 2>/dev/null || echo "unknown")
    
    cd "$CHAMBER"
    success "Chamber ready - Mesa $DRAGON_VER ($COMMIT_SHORT)"
}

# === APPLY SPELLS ===
apply_spell_file() {
    local spell_path="$1"
    local full_path="$SPELLS_DIR/$spell_path.patch"
    
    if [ -f "$full_path" ]; then
        log "Casting spell: $spell_path"
        cd "$CHAMBER/mesa"
        git apply "$full_path" --verbose 2>/dev/null && success "Spell applied: $spell_path" || warn "Spell partially applied: $spell_path"
    else
        warn "Spell not found: $full_path"
    fi
}

apply_merge_request() {
    local mr_id="$1"
    log "Merging shadow power: MR !$mr_id"
    cd "$CHAMBER/mesa"
    git fetch origin "refs/merge-requests/$mr_id/head" 2>/dev/null || { warn "Could not fetch MR $mr_id"; return 1; }
    git merge --no-edit FETCH_HEAD 2>/dev/null || { warn "Merge conflict in MR $mr_id"; return 1; }
    success "Shadow merged: MR !$mr_id"
}

# === INLINE SPELLS ===
spell_tiger_velocity() {
    log "Applying Tiger Velocity (inline)..."
    cd "$CHAMBER/mesa"
    local file="src/freedreno/vulkan/tu_cmd_buffer.cc"
    
    if [ -f "$file" ]; then
        if ! grep -q "// Dragon: Force sysmem" "$file"; then
            sed -i '/use_sysmem_rendering.*cmd/,/^{/ { /^{/a\   // Dragon: Force sysmem\n   return true;
            }' "$file" 2>/dev/null || \
            sed -i '/if (TU_DEBUG(SYSMEM))/i\   return true; // Dragon: Tiger Velocity' "$file"
        fi
        success "Tiger Velocity applied"
    fi
}

spell_falcon_memory() {
    log "Applying Falcon Memory fix (inline)..."
    cd "$CHAMBER/mesa"
    
    [ -f src/freedreno/vulkan/tu_query.cc ] && \
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
    
    [ -f src/freedreno/vulkan/tu_device.cc ] && \
        sed -i 's/has_cached_coherent_memory = true/has_cached_coherent_memory = false/g' src/freedreno/vulkan/tu_device.cc
    
    success "Falcon Memory applied"
}

# === FORGE (BUILD) ===
forge_dragon() {
    local variant_name="$1"
    
    log "═══════════════════════════════════════"
    log "  Forging Dragon: $variant_name"
    log "═══════════════════════════════════════"
    
    cd "$CHAMBER/mesa"
    
    local NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local CROSS_FILE="$CHAMBER/cross_dragon"
    
    cat <<EOF > "$CROSS_FILE"
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${LEVEL}-clang']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${LEVEL}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
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

    rm -rf build-dragon
    
    log "Running meson setup..."
    meson setup build-dragon \
        --cross-file "$CROSS_FILE" \
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
        &> "$CHAMBER/meson_${variant_name}.log" || { cat "$CHAMBER/meson_${variant_name}.log"; error "Meson failed"; }

    log "Building with ninja..."
    ninja -C build-dragon &> "$CHAMBER/ninja_${variant_name}.log" || { tail -50 "$CHAMBER/ninja_${variant_name}.log"; error "Ninja failed"; }

    local SO_FILE="build-dragon/src/freedreno/vulkan/libvulkan_freedreno.so"
    [ ! -f "$SO_FILE" ] && error "Build output not found!"

    # Package
    cd "$CHAMBER"
    cp "mesa/$SO_FILE" .
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so "vulkan.dragon.so"

    local FILENAME="Dragon-${variant_name}-${DRAGON_VER}-${COMMIT_SHORT}"
    
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Dragon ${variant_name}",
  "description": "Mesa ${DRAGON_VER} - ${variant_name} variant",
  "author": "DragonForge",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "${DRAGON_VER}",
  "minApi": 27,
  "libraryName": "vulkan.dragon.so"
}
EOF

    zip -9 "${FILENAME}.zip" vulkan.dragon.so meta.json
    success "Created: ${FILENAME}.zip ($(du -h ${FILENAME}.zip | cut -f1))"
    
    rm -f vulkan.dragon.so meta.json
}

# === VARIANT BUILDERS ===
reset_mesa() {
    cd "$CHAMBER/mesa"
    git checkout . && git clean -fd
}

build_tiger() {
    log "Building TIGER variant..."
    reset_mesa
    spell_tiger_velocity
    forge_dragon "Tiger"
}

build_tiger_phoenix() {
    log "Building TIGER-PHOENIX variant..."
    reset_mesa
    spell_tiger_velocity
    apply_spell_file "phoenix/wings_boost"
    forge_dragon "Tiger-Phoenix"
}

build_falcon() {
    log "Building FALCON variant..."
    reset_mesa
    spell_falcon_memory
    spell_tiger_velocity
    forge_dragon "Falcon"
}

build_shadow() {
    log "Building SHADOW variant..."
    reset_mesa
    apply_merge_request "37802"
    forge_dragon "Shadow"
}

build_hawk() {
    log "Building HAWK variant (full power)..."
    reset_mesa
    spell_tiger_velocity
    spell_falcon_memory
    apply_spell_file "phoenix/wings_boost"
    apply_spell_file "common/memory_fix"
    forge_dragon "Hawk"
}

build_all() {
    build_tiger
    build_tiger_phoenix
    build_falcon
    build_shadow
    build_hawk
}

# === MAIN ===
echo ""
echo "╔═══════════════════════════════════════╗"
echo "║        🐉 DRAGON FORGE v2.0 🐉        ║"
echo "╚═══════════════════════════════════════╝"
echo ""

prepare_chamber

case "$VARIANT" in
    tiger)          build_tiger ;;
    tiger-phoenix)  build_tiger_phoenix ;;
    falcon)         build_falcon ;;
    shadow)         build_shadow ;;
    hawk)           build_hawk ;;
    all)            build_all ;;
    *)
        warn "Unknown variant: $VARIANT, defaulting to tiger"
        build_tiger
        ;;
esac

echo ""
success "═══════════════════════════════════════"
success "  Dragon Forge Complete! 🐉"
success "═══════════════════════════════════════"
echo ""
ls -lh "$CHAMBER"/*.zip 2>/dev/null || warn "No builds found"
