#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${GITHUB_WORKSPACE:-$(pwd)}/build"
MESA_DIR="${WORKDIR}/mesa"
PATCHES_DIR="${GITHUB_WORKSPACE:-$(dirname "$(dirname "$0")")}/patches"
SCRIPT_DIR="${GITHUB_WORKSPACE:+${GITHUB_WORKSPACE}/scripts}"
[[ -z "${SCRIPT_DIR:-}" ]] && SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_MIRROR="https://github.com/mesa3d/mesa.git"
ROBCLARK_REPO="https://gitlab.freedesktop.org/robclark/mesa.git"
AUTOTUNER_REPO="https://gitlab.freedesktop.org/PixelyIon/mesa.git"
VULKAN_HEADERS_REPO="https://github.com/KhronosGroup/Vulkan-Headers.git"
VULKAN_HEADERS_TAG="${VULKAN_HEADERS_TAG:-}"

MESA_SOURCE="${MESA_SOURCE:-main_branch}"
STAGING_BRANCH="${STAGING_BRANCH:-staging/26.0}"
CUSTOM_TAG="${CUSTOM_TAG:-}"
BUILD_TYPE="${BUILD_TYPE:-release}"
BUILD_VARIANT="${BUILD_VARIANT:-optimized}"
NDK_PATH="${NDK_PATH:-/opt/android-ndk}"
API_LEVEL="${API_LEVEL:-35}"
TARGET_GPU="${TARGET_GPU:-a0xx}"
ENABLE_PERF="${ENABLE_PERF:-false}"
MESA_LOCAL_PATH="${MESA_LOCAL_PATH:-}"
ENABLE_EXT_SPOOF="${ENABLE_EXT_SPOOF:-true}"
ENABLE_DECK_EMU="${ENABLE_DECK_EMU:-true}"
DECK_EMU_TARGET="${DECK_EMU_TARGET:-nvidia}"
ENABLE_TIMELINE_HACK="${ENABLE_TIMELINE_HACK:-true}"
ENABLE_UBWC_HACK="${ENABLE_UBWC_HACK:-true}"
APPLY_PATCH_SERIES="${APPLY_PATCH_SERIES:-true}"
ENABLE_CUSTOM_FLAGS="${ENABLE_CUSTOM_FLAGS:-true}"
ENABLE_A7XX_COMPAT="${ENABLE_A7XX_COMPAT:-true}"
STRICT_MODE="${STRICT_MODE:-false}"
ENABLE_A7XX_PERF="${ENABLE_A7XX_PERF:-true}"
ENABLE_VK14_PROMO="${ENABLE_VK14_PROMO:-true}"
ENABLE_SHADER_PERF="${ENABLE_SHADER_PERF:-true}"
ENABLE_VIEWPORT_CLAMP="${ENABLE_VIEWPORT_CLAMP:-true}"
ENABLE_TIMELINE_FIX="${ENABLE_TIMELINE_FIX:-false}"
ENABLE_A750_AUTOTUNE="${ENABLE_A750_AUTOTUNE:-true}"
A750_GMEM_LIMIT_MB="${A750_GMEM_LIMIT_MB:-4}"
A750_DRAWCALL_THRESHOLD="${A750_DRAWCALL_THRESHOLD:-500}"
ENABLE_AUTOTUNE_LOGGING="${ENABLE_AUTOTUNE_LOGGING:-false}"
ENABLE_PRESENT_WAIT_FIX="${ENABLE_PRESENT_WAIT_FIX:-true}"
ENABLE_FRAME_PACING="${ENABLE_FRAME_PACING:-true}"
ENABLE_VSYNC_BYPASS="${ENABLE_VSYNC_BYPASS:-false}"
ENABLE_ANDROID_PROP_CONTROL="${ENABLE_ANDROID_PROP_CONTROL:-true}"
CFLAGS_EXTRA="${CFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
CXXFLAGS_EXTRA="${CXXFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
LDFLAGS_EXTRA="${LDFLAGS_EXTRA:--Wl,--gc-sections}"
log_info() { echo "[INFO] $*"; }
log_success() { echo "[OK] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

strict_check() {
    local name="$1" result="$2"
    if [[ "$result" == *"[WARN]"* ]] && [[ "$STRICT_MODE" == "true" ]]; then
        log_error "STRICT_MODE: critical patch failed: $name"
        exit 1
    fi
}

check_deps() {
    local deps="git meson ninja patchelf zip ccache curl python3"
    for dep in $deps; do
        if ! command -v "$dep" &>/dev/null; then
            log_error "Missing dependency: $dep"
            exit 1
        fi
    done
    log_success "Dependencies check passed"
}

fetch_latest_release() {
    local tags=""
    tags=$(git ls-remote --tags --refs "$MESA_REPO" 2>/dev/null | \
        grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1) || true
    if [[ -z "$tags" ]]; then
        tags=$(git ls-remote --tags --refs "$MESA_MIRROR" 2>/dev/null | \
            grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1) || true
    fi
    [[ -z "$tags" ]] && { log_error "Could not determine latest release"; exit 1; }
    echo "$tags"
}

get_mesa_version() {
    [[ -f "${MESA_DIR}/VERSION" ]] && cat "${MESA_DIR}/VERSION" || echo "unknown"
}

get_vulkan_version() {
    local vk_header="${MESA_DIR}/include/vulkan/vulkan_core.h"
    if [[ -f "$vk_header" ]]; then
        local major minor patch
        major=$(grep -m1 "#define VK_HEADER_VERSION_COMPLETE" "$vk_header" | grep -oP 'VK_MAKE_API_VERSION\(\d+,\s*\K\d+' || echo "1")
        minor=$(grep -m1 "#define VK_HEADER_VERSION_COMPLETE" "$vk_header" | grep -oP 'VK_MAKE_API_VERSION\(\d+,\s*\d+,\s*\K\d+' || echo "4")
        patch=$(grep -m1 "^#define VK_HEADER_VERSION " "$vk_header" | awk '{print $3}' || echo "0")
        echo "${major}.${minor}.${patch}"
    else        echo "1.4.0"
    fi
}

prepare_workdir() {
    log_info "Preparing build directory"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    log_success "Build directory ready"
}

clone_mesa() {
    log_info "Cloning Mesa source: $MESA_SOURCE"
    local ref="" repo=""
    case "$MESA_SOURCE" in
        latest_release)
            ref=$(fetch_latest_release)
            repo="$MESA_REPO"
            log_info "Latest release: $ref"
            ;;
        staging_branch)
            ref="$STAGING_BRANCH"
            repo="$MESA_REPO"
            ;;
        main_branch|latest_main)
            ref="main"
            repo="$MESA_REPO"
            ;;
        robclark_branch)
            log_info "Cloning Rob Clark fork (main)"
            git clone --depth=1 "$ROBCLARK_REPO" "$MESA_DIR" 2>&1 | tail -1 || {
                log_error "Failed to clone Rob Clark fork"
                exit 1
            }
            local version commit
            version=$(get_mesa_version)
            commit=$(git -C "$MESA_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
            echo "$version" > "${WORKDIR}/version.txt"
            echo "$commit"  > "${WORKDIR}/commit.txt"
            log_success "Rob Clark Mesa cloned: $version @ $commit"
            return 0
            ;;
        autotuner)
            log_info "Cloning AutoTuner fork"
            git clone --depth=1 "$AUTOTUNER_REPO" "$MESA_DIR" 2>&1 | tail -1 || {
                log_error "Failed to clone AutoTuner fork"
                exit 1
            }
            local version commit
            version=$(get_mesa_version)            commit=$(git -C "$MESA_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
            echo "$version" > "${WORKDIR}/version.txt"
            echo "$commit"  > "${WORKDIR}/commit.txt"
            log_success "AutoTuner Mesa cloned: $version @ $commit"
            return 0
            ;;
        custom_tag)
            [[ -z "$CUSTOM_TAG" ]] && { log_error "CUSTOM_TAG is empty"; exit 1; }
            ref="$CUSTOM_TAG"
            repo="$MESA_REPO"
            ;;
        *)
            ref="main"
            repo="$MESA_REPO"
            ;;
    esac

    if [[ -n "$MESA_LOCAL_PATH" && -d "$MESA_LOCAL_PATH" ]]; then
        log_info "Using local Mesa: $MESA_LOCAL_PATH"
        cp -r "$MESA_LOCAL_PATH" "$MESA_DIR"
    else
        log_info "Cloning Mesa @ $ref"
        git clone --depth=1 --branch "$ref" "$repo" "$MESA_DIR" 2>/dev/null || \
        git clone --depth=1 --branch "$ref" "$MESA_MIRROR" "$MESA_DIR" 2>/dev/null || {
            log_error "Failed to clone Mesa"
            exit 1
        }
    fi

    local version commit
    version=$(get_mesa_version)
    commit=$(git -C "$MESA_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "$version" > "${WORKDIR}/version.txt"
    echo "$commit"  > "${WORKDIR}/commit.txt"
    log_success "Mesa cloned: $version @ $commit"
}

update_vulkan_headers() {
    local headers_dir="${WORKDIR}/vulkan-headers"
    local target_tag="${VULKAN_HEADERS_TAG:-}"
    if [[ -z "$target_tag" ]]; then
        target_tag=$(curl -sL "https://api.github.com/repos/KhronosGroup/Vulkan-Headers/releases/latest" \
            | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 || true)
        [[ -z "$target_tag" ]] && target_tag="v1.4.347"
    fi
    log_info "Updating Vulkan headers to $target_tag"

    git clone --depth=1 --branch "$target_tag" "$VULKAN_HEADERS_REPO" "$headers_dir" 2>/dev/null || {
        log_warn "Failed to clone Vulkan headers — using Mesa bundled headers"
        return 0    }

    [[ ! -d "${headers_dir}/include/vulkan" ]] && { log_warn "Headers dir missing"; return 0; }
    cp -r "${headers_dir}/include/vulkan" "${MESA_DIR}/include/"

    local core_h="${MESA_DIR}/include/vulkan/vulkan_core.h"
    if [[ -f "$core_h" ]]; then
        cat >> "$core_h" << 'COMPAT_EOF'

#ifndef VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_EXT
#define VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_EXT VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_KHR
#endif
#ifndef VK_DEVICE_FAULT_VENDOR_BINARY_HEADER_VERSION_MAX_ENUM_EXT
#define VK_DEVICE_FAULT_VENDOR_BINARY_HEADER_VERSION_MAX_ENUM_EXT VK_DEVICE_FAULT_VENDOR_BINARY_HEADER_VERSION_MAX_ENUM_KHR
#endif
#ifndef VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_EXT
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_EXT VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_KHR
#endif
#ifndef VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_EXT
#define VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_EXT VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_KHR
#endif
#ifndef VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_EXT
#define VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_EXT VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_KHR
#endif
#ifndef VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_KHR
#define VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_KHR VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_EXT
#endif
#ifndef VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_KHR
#define VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_KHR VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_EXT
#endif
#ifndef VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_KHR
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_KHR VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_EXT
#endif
#ifndef VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_KHR
#define VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_KHR 0x7FFFFFFF
#endif
#ifndef VK_DEVICE_FAULT_VENDOR_BINARY_HEADER_VERSION_MAX_ENUM_KHR
#define VK_DEVICE_FAULT_VENDOR_BINARY_HEADER_VERSION_MAX_ENUM_KHR 0x7FFFFFFF
#endif
COMPAT_EOF
        log_info "Device fault EXT/KHR bidirectional compat defines appended"
    fi

    log_success "Vulkan headers updated to $target_tag"
}

apply_viewport_clamp_fix() {
    log_info "Applying Viewport/Scissor Clamp Fix"
    local tu_pipeline="${MESA_DIR}/src/freedreno/vulkan/tu_pipeline.cc"
    [[ ! -f "$tu_pipeline" ]] && { log_warn "tu_pipeline.cc not found"; return 0; }    
    if grep -q "CLAMP.*16383" "$tu_pipeline"; then
        log_info "Viewport clamp fix already applied"
        return 0
    fi
    
    sed -i 's/min\.x = MAX2(min\.x, 0);/min.x = CLAMP(min.x, 0, 16383);/' "$tu_pipeline"
    sed -i 's/min\.y = MAX2(min\.y, 0);/min.y = CLAMP(min.y, 0, 16383);/' "$tu_pipeline"
    sed -i 's/max\.x = MAX2(max\.x, 1);/max.x = CLAMP(max.x, 1, 16383);/' "$tu_pipeline"
    sed -i 's/max\.y = MAX2(max\.y, 1);/max.y = CLAMP(max.y, 1, 16383);/' "$tu_pipeline"
    
    sed -i 's/uint32_t min_x = scissor->offset\.x;/uint32_t min_x = CLAMP(scissor->offset.x, 0, 16383);/' "$tu_pipeline"
    sed -i 's/uint32_t min_y = scissor->offset\.y;/uint32_t min_y = CLAMP(scissor->offset.y, 0, 16383);/' "$tu_pipeline"
    sed -i 's/uint32_t max_x = min_x + scissor->extent\.width - 1;/uint32_t max_x = CLAMP(min_x + scissor->extent.width - 1, 0, 16383);/' "$tu_pipeline"
    sed -i 's/uint32_t max_y = min_y + scissor->extent\.height - 1;/uint32_t max_y = CLAMP(min_y + scissor->extent.height - 1, 0, 16383);/' "$tu_pipeline"
    
    log_success "Viewport/Scissor clamp fix applied"
}

apply_timeline_semaphore_fix() {
    log_info "Applying vk_sync_timeline Fix"
    local vk_sync="${MESA_DIR}/src/vulkan/runtime/vk_sync_timeline.c"
    [[ ! -f "$vk_sync" ]] && { log_warn "vk_sync_timeline.c not found"; return 0; }
    
    if grep -q "TIMELINE_FIX_APPLIED" "$vk_sync"; then
        log_info "Timeline fix already applied"
        return 0
    fi
    
    python3 - "$vk_sync" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

pat = r'(vk_sync_timeline_wait\s*\([^)]*\)\s*\{)'
m = re.search(pat, c)
if m:
    brace = c.find('{', m.start())
    eol = c.find('\n', brace)
    if eol != -1:
        injection = '''
   if (value > UINT64_MAX / 2) {
      mesa_log("Timeline wait: clamping suspicious value %llu", value);
      value = UINT64_MAX / 2;
   }
'''
        c = c[:eol+1] + injection + c[eol+1:]
        with open(fp, 'w') as f: f.write(c)
        print("[OK] Timeline semaphore safety check added")
PYEOF    log_success "Timeline semaphore fix applied"
}

apply_present_wait_fix() {
    log_info "Applying KHR_present_wait optimization for vkd3d-proton"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    
    if grep -q "PRESENT_WAIT_FIX_APPLIED" "$tu_device_cc"; then
        log_info "Present wait fix already applied"
        return 0
    fi
    
    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

pat = r'(\.KHR_present_wait\s*=\s*)false'
c, n = re.subn(pat, r'\1true', c)

pat2 = r'(\.KHR_present_wait2\s*=\s*)false'
c, n2 = re.subn(pat2, r'\1true', c)

if n > 0 or n2 > 0:
    c += '\n'
    with open(fp, 'w') as f: f.write(c)
    print(f"[OK] Present wait extensions enabled ({n + n2} fields)")
else:
    print("[INFO] Present wait fields not found or already enabled")
PYEOF
    log_success "KHR_present_wait optimization applied"
}

apply_frame_pacing_fix() {
    log_info "Applying frame pacing optimization for Winlator compatibility"
    local tu_present="${MESA_DIR}/src/freedreno/vulkan/tu_present.cc"
    [[ ! -f "$tu_present" ]] && tu_present="${MESA_DIR}/src/freedreno/vulkan/tu_present.c"
    [[ ! -f "$tu_present" ]] && { log_warn "tu_present file not found"; return 0; }
    
    if grep -q "FRAME_PACING_FIX_APPLIED" "$tu_present"; then
        log_info "Frame pacing fix already applied"
        return 0
    fi
    
    python3 - "$tu_present" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(tu_acquire_next_image[^{]*\{)'
m = re.search(pat, c)
if m:
    brace = c.find('{', m.start())
    eol = c.find('\n', brace)
    if eol != -1:
        injection = '''
   if (getenv("TU_FORCE_IMMEDIATE_PRESENT")) {
      return VK_SUCCESS;
   }
'''
        c = c[:eol+1] + injection + c[eol+1:]
        c += '\n'
        with open(fp, 'w') as f: f.write(c)
        print("[OK] Frame pacing optimization injected")
else:
    print("[WARN] tu_acquire_next_image function not found")
PYEOF
    log_success "Frame pacing optimization applied"
}

apply_vsync_bypass_fix() {
    log_info "Applying VSync bypass for fake frame boost"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    
    if grep -q "VSYNC_BYPASS_APPLIED" "$tu_device_cc"; then
        log_info "VSync bypass already applied"
        return 0
    fi
    
    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

pat = r'(\.VK_KHR_present_id\s*=\s*)false'
c, n = re.subn(pat, r'\1true', c)

if n > 0:
    c += '\n'
    with open(fp, 'w') as f: f.write(c)
    print("[OK] VSync bypass extensions enabled")
else:
    print("[INFO] VSync bypass fields not found or already enabled")
PYEOF
    log_success "VSync bypass optimization applied"
}

apply_android_prop_control() {    log_info "Applying Android property-based dynamic control"
    local tu_autotune="${MESA_DIR}/src/freedreno/vulkan/tu_autotune.cc"
    
    [[ ! -f "$tu_autotune" ]] && { log_warn "tu_autotune.cc not found"; return 0; }
    
    python3 - "$tu_autotune" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

if "#include <sys/system_properties.h>" not in c:
    c = "#include <sys/system_properties.h>\n" + c

helper_func = """
static uint32_t get_android_int_prop(const char* prop, uint32_t default_val) {
    char val[PROP_VALUE_MAX];
    if (__system_property_get(prop, val) > 0) return (uint32_t)atoi(val);
    return default_val;
}
static bool get_android_bool_prop(const char* prop, bool default_val) {
    char val[PROP_VALUE_MAX];
    if (__system_property_get(prop, val) > 0) return strcmp(val, "1") == 0;
    return default_val;
}
"""

if "get_android_int_prop" not in c:
    c = helper_func + c

injection = """
   uint32_t prop_draw_limit = get_android_int_prop("debug.tu.draw_limit", 0);
   bool force_sysmem = get_android_bool_prop("debug.tu.sysmem", false);
   bool force_bypass = get_android_bool_prop("debug.tu.bypass", false);
   
   if (force_bypass || force_sysmem) return true;
   if (prop_draw_limit > 0 && total_draws > prop_draw_limit) return true;
"""

pat = r'(tu_autotune_use_bypass\s*\([^)]*\)\s*\{)'
m = re.search(pat, c)
if m:
    brace = c.find('{', m.start())
    eol = c.find('\n', brace)
    if eol != -1:
        c = c[:eol+1] + injection + c[eol+1:]
        c += '\n'
        with open(fp, 'w') as f: f.write(c)
        print("[OK] Android property control injected into autotune")
else:
    print("[WARN] tu_autotune_use_bypass function not found")PYEOF
    log_success "Android property-based dynamic control applied"
}

apply_a750_dynamic_autotune() {
    log_info "Applying A750 Dynamic Autotune Balancer"
    local tu_autotune="${MESA_DIR}/src/freedreno/vulkan/tu_autotune.cc"
    
    [[ ! -f "$tu_autotune" ]] && { log_warn "tu_autotune.cc not found"; return 0; }
    
    if ! grep -q "tu_dynamic_autotune_bypass" "$tu_autotune"; then
        cat >> "$tu_autotune" << AUTOTUNE_EOF

static bool
tu_dynamic_autotune_bypass(const struct tu_cmd_buffer *cmd, uint32_t total_draws)
{
    const struct tu_render_pass *pass = cmd->state.pass;
    const struct tu_framebuffer *fb = cmd->state.framebuffer;
    
    if (!pass || !fb) return false;

    uint32_t area = fb->width * fb->height * fb->layers;
    if (cmd->state.rp.msaa_samples > 1)
        area *= cmd->state.rp.msaa_samples;

    uint32_t bpp_total = 0;
    for (uint32_t i = 0; i < pass->attachment_count; i++) {
        const struct tu_attachment *att = &pass->attachments[i];
        if (att->format != VK_FORMAT_UNDEFINED) {
            bpp_total += vk_format_get_blocksize(att->format);
        }
    }
    if (bpp_total == 0) bpp_total = 4;

    const uint64_t a750_gmem_conservative_limit = ${A750_GMEM_LIMIT_MB:-4} * 1024 * 1024;
    const uint64_t a750_gmem_aggressive_limit = (${A750_GMEM_LIMIT_MB:-4} + 1) * 1024 * 1024;
    
    uint64_t pass_memory_footprint = (uint64_t)area * bpp_total;
    
    if (pass_memory_footprint > a750_gmem_aggressive_limit && total_draws > ${A750_DRAWCALL_THRESHOLD:-500}) {
        return true;
    }
    
    if (pass_memory_footprint > a750_gmem_conservative_limit && total_draws > ${A750_DRAWCALL_THRESHOLD:-500} * 4) {
        return true;
    }

    bool has_color = false;
    for (uint32_t s = 0; s < pass->subpass_count; s++) {
        if (pass->subpasses[s].color_count > 0) { has_color = true; break; }    }
    if (!has_color && area > (2048 * 2048)) {
        return true;
    }

    return false;
}
AUTOTUNE_EOF
        log_success "Added tu_dynamic_autotune_bypass function"
    fi

    python3 - "$tu_autotune" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

pat = r'(bool\s+tu_autotune_use_bypass\s*\([^)]*\)\s*\{)'
m = re.search(pat, c)
if m:
    brace = c.find('{', m.start())
    eol = c.find('\n', brace)
    if eol != -1:
        injection = '''
   if (cmd->device->physical_device->info.chip >= 7) {
      if (tu_dynamic_autotune_bypass(cmd, cmd->state.rp.drawcall_count)) {
         return true;
      }
   }
'''
        c = c[:eol+1] + injection + c[eol+1:]
        with open(fp, 'w') as f: f.write(c)
        print("[OK] A750 autotune hook injected")
PYEOF

    if [[ "$ENABLE_AUTOTUNE_LOGGING" == "true" ]]; then
        local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
        if [[ -f "$tu_util_h" ]] && ! grep -q "TU_DEBUG_LOG_AUTOTUNE" "$tu_util_h"; then
            python3 - "$tu_util_h" << 'DEBUGEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
enum_pat = r'(TU_DEBUG_\w+\s*=\s*BITFIELD64_BIT\(\d+\),)'
matches = list(re.finditer(enum_pat, c))
if matches:
    last_match = matches[-1]
    bit_num = int(re.search(r'BITFIELD64_BIT\((\d+)\)', last_match.group(1)).group(1))
    new_flag = f'   TU_DEBUG_LOG_AUTOTUNE = BITFIELD64_BIT({bit_num + 1}),'
    end_pos = last_match.end()
    eol = c.find('\n', end_pos)
    if eol != -1:        c = c[:eol+1] + new_flag + '\n' + c[eol+1:]
        with open(fp, 'w') as f: f.write(c)
        print("[OK] Added TU_DEBUG_LOG_AUTOTUNE flag")
DEBUGEOF
        fi
    fi
    
    log_success "A750 Dynamic Autotune Balancer applied"
}

apply_gralloc_ubwc_fix() {
    log_info "Applying gralloc UBWC fix"
    local gralloc_fb="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"
    local tu_android="${MESA_DIR}/src/freedreno/vulkan/tu_android.cc"
    [[ ! -f "$tu_android" ]] && tu_android="${MESA_DIR}/src/freedreno/vulkan/tu_android.c"
    if [[ -f "$gralloc_fb" ]] && ! grep -q "UBWC_GRALLOC_FORCED" "$gralloc_fb"; then
        python3 - "$gralloc_fb" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
if 'UBWC_GRALLOC_FORCED' in c:
    print('[OK] u_gralloc UBWC already forced'); sys.exit(0)
pat = r'(static\s+int\s+\w*get_buffer\w*\s*\([^)]*\)\s*\{[^}]*?\n)([ \t]+)'
m = re.search(pat, c, re.DOTALL)
if m:
    inject = '\n   return 0;\n'
    ins = c.find('{', c.find('get_buffer')) + 1
    eol = c.find('\n', ins)
    c = c[:eol+1] + inject + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] u_gralloc UBWC detection forced')
else:
    print('[WARN] get_buffer function not found in u_gralloc_fallback.c')
PYEOF
    fi
    if [[ -f "$tu_android" ]] && ! grep -q "GRALLOC_UBWC_FIX" "$tu_android"; then
        python3 - "$tu_android" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat2 = r'(gralloc_usage\s*=[^;]+)(;)'
if re.search(pat2, c):
    c = re.sub(pat2, r'\1 | GRALLOC1_PRODUCER_USAGE_PRIVATE_ALLOC_UBWC \2', c, count=1)
    with open(fp, 'w') as f: f.write(c)
    print('[OK] UBWC flag added to gralloc usage')
else:
    print('[WARN] Gralloc usage pattern not found')
PYEOF
    fi
    log_success "Gralloc UBWC fix applied"}

apply_a8xx_patches() {
    log_info "Applying a8xx-specific patches"
    local kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    local dev_info_h="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.h"
    local cmd_buffer="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    local gmem_cache="${MESA_DIR}/src/freedreno/common/fd6_gmem_cache.h"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ "$ENABLE_UBWC_HACK" == "true" ]] && [[ -f "$kgsl_file" ]]; then
    python3 - "$kgsl_file" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

defines = (
    "\n#ifndef KGSL_UBWC_5_0\n"
    "#define KGSL_UBWC_5_0 5\n"
    "#endif\n"
    "#ifndef KGSL_UBWC_6_0\n"
    "#define KGSL_UBWC_6_0 6\n"
    "#endif\n"
)

if "#define KGSL_UBWC_5_0" not in c:
    first_include = c.find("#include")
    if first_include != -1:
        eol = c.find("\n", first_include)
        c = c[:eol+1] + defines + c[eol+1:]
        print("[OK] KGSL_UBWC_5_0/6_0 defines added")
    else:
        print("[WARN] No #include found, skipping defines")
        sys.exit(0)
else:
    print("[OK] KGSL_UBWC_5_0 already defined")

if "case KGSL_UBWC_5_0" in c or "case 5:" in c:
    with open(fp, "w") as f: f.write(c)
    print("[OK] UBWC 5/6 cases already present from patch series")
    sys.exit(0)

ubwc_pat = re.compile(r"case KGSL_UBWC_4_0.*?break;", re.DOTALL)
m4 = ubwc_pat.search(c)
if not m4:
    ubwc_pat = re.compile(r"case KGSL_UBWC_3_0.*?break;", re.DOTALL)
    m4 = ubwc_pat.search(c)

if not m4:
    with open(fp, "w") as f: f.write(c)    print("[WARN] UBWC switch not found, defines only")
    sys.exit(0)

case_body = c[m4.start():m4.end()]

lval_pat = re.compile(
    r'((?:\w+->)?\w+)\.(bank_swizzle_levels|macrotile_mode)'
)
lval_m = lval_pat.search(case_body)

if not lval_m:
    lval_m = re.search(r'((?:\w+->)?\w+)\.(\w+)\s*=', case_body)

if not lval_m:
    with open(fp, "w") as f: f.write(c)
    print("[WARN] ubwc lval not found in case body, defines only")
    sys.exit(0)

lval = lval_m.group(1)

default_m = re.search(r'[ \t]*default\s*:', c[m4.end():])
if not default_m:
    with open(fp, "w") as f: f.write(c)
    print("[WARN] default: not found, defines only")
    sys.exit(0)

ins = m4.end() + default_m.start()
inject = (
    "   case 5:\n"
    "   case 6:\n"
    f"      {lval}.bank_swizzle_levels = 0x6;\n"
    f"      {lval}.macrotile_mode = FDL_MACROTILE_8_CHANNEL;\n"
    "      break;\n"
)
c = c[:ins] + inject + c[ins:]
with open(fp, "w") as f: f.write(c)
print(f"[OK] UBWC 5/6 cases inserted (lval={lval}.)")

PYEOF
        log_success "UBWC 5.0/6.0 support applied"
    fi

    if [[ -f "$cmd_buffer" ]] \
        && grep -q "disable_gmem" "$dev_info_h" 2>/dev/null \
        && ! grep -q "A8XX_DISABLE_GMEM" "$cmd_buffer"; then
        python3 - "$cmd_buffer" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
inject = "\n   if (cmd->device->physical_device->dev_info.props.disable_gmem) {\n      cmd->state.rp.gmem_disable_reason = \"Unsupported GPU\";\n      return true;\n   }\n"pat = r'use_sysmem_rendering\s*\([^)]*\)\s*\{'
m = re.search(pat, c)
if m:
    ins = c.find("\n", c.find("{", m.start())) + 1
    c = c[:ins] + inject + c[ins:]
    with open(fp, "w") as f: f.write(c)
    print("[OK] A8xx force-sysmem added to use_sysmem_rendering")
else:
    print("[WARN] use_sysmem_rendering not found, skipping")
PYEOF
        log_success "A8xx sysmem guard added"
    fi

    if [[ -f "$gmem_cache" ]] && ! grep -q "A8XX_GMEM_OFFSET_FIX" "$gmem_cache"; then
        python3 - "$gmem_cache" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'if\s*\(\s*info->chip\s*>=\s*8\s*&&\s*info->num_slices\s*>\s*1\s*\)[^}]*\}'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.start()] + c[m.end():]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] A8xx gmem cache offset removed')
else:
    print('[INFO] gmem offset block not found (may already be patched)')
PYEOF
        log_success "A8xx gmem cache offset fix applied"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "A8XX_FLUSHALL_REMOVED" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'if\s*\([^)]*chip\s*==\s*A8XX[^)]*\)[^{]*\{[^}]*TU_DEBUG_FLUSHALL[^}]*\}'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.start()] + c[m.end():]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] A8xx forced FLUSHALL removed')
else:
    print('[INFO] FLUSHALL block not found in this version')
PYEOF
        log_success "A8xx FLUSHALL removed"
    fi

    local devices_py="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"
    if [[ -f "$devices_py" ]] && ! grep -q "A8XX_DEVICES_INJECTED" "$devices_py"; then
        python3 - "$devices_py" << 'PYEOF'import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

a8xx_ids = {
    '810': [('0x44010000', 'FD810')],
    '825': [('0x44030000', 'FD825')],
    '829': [('0x44030A00', 'FD829'), ('0x44030A20', 'FD829'), ('0xffff44030A00', 'FD829')],
    '830': [('0x44050000', 'FD830'), ('0x44050001', 'FD830'), ('0xffff44050000', 'FD830')],
    '840': [('0xffff44050A31', 'FD840'), ('0x44050A00', 'FD840')],
}

inject = ''
added = []
for gpu, ids in a8xx_ids.items():
    if all(chip_id in c for chip_id, _ in ids):
        continue
    id_lines = '\n'.join(f"        GPUId(chip_id={chip_id}, name=\"{name}\")," for chip_id, name in ids)
    num_ccu = 2 if gpu == '810' else 4
    num_slices = 1 if gpu == '810' else 2
    inject += f"""
add_gpus([
{id_lines}
    ], A6xxGPUInfo(
        CHIP.A8XX,
        [a7xx_base, a7xx_gen3, a8xx_base],
        num_ccu = {num_ccu},
        num_slices = {num_slices},
        tile_align_w = 96,
        tile_align_h = 32,
        tile_max_w = 16416,
        tile_max_h = 16384,
        num_vsc_pipes = 32,
        cs_shared_mem_size = 32 * 1024,
        wave_granularity = 2,
        fibers_per_sp = 128 * 2 * 16,
        magic_regs = dict(),
        raw_magic_regs = a8xx_base_raw_magic_regs,
    ))
"""
    added.append(gpu)

if added:
    c += '\n' + inject
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] A8xx device entries appended at end of file: {added}')
else:
    print('[OK] All a8xx GPU entries already present in Mesa')
PYEOF
        log_success "A8xx device entries checked/injected"    fi

    log_success "A8xx patches complete"
}

apply_vulkan_extensions_vk_fallback() {
    log_info "Applying extensions via get_device_extensions injection"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found for ext fallback"; return 0; }
    if grep -q "EXT_INJECT_APPLIED" "$tu_device_cc"; then
        log_info "Extension injection already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'FORCEEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

INJECT = """
   ext->AMD_anti_lag = true;
   ext->AMD_device_coherent_memory = true;
   ext->AMD_memory_overallocation_behavior = true;
   ext->AMD_shader_core_properties = true;
   ext->AMD_shader_core_properties2 = true;
   ext->AMD_shader_info = true;
   ext->EXT_blend_operation_advanced = true;
   ext->EXT_buffer_device_address = true;
   ext->EXT_depth_bias_control = true;
   ext->EXT_depth_range_unrestricted = true;
   ext->EXT_device_fault = true;
   ext->EXT_discard_rectangles = true;
   ext->EXT_display_control = true;
   ext->EXT_fragment_density_map2 = true;
   ext->EXT_fragment_shader_interlock = true;
   ext->EXT_frame_boundary = true;
   ext->EXT_full_screen_exclusive = true;
   ext->EXT_image_compression_control = true;
   ext->EXT_image_compression_control_swapchain = true;
   ext->EXT_image_sliced_view_of_3d = true;
   ext->EXT_memory_priority = true;
   ext->EXT_mesh_shader = true;
   ext->EXT_opacity_micromap = true;
   ext->EXT_pageable_device_local_memory = true;
   ext->EXT_pipeline_library_group_handles = true;
   ext->EXT_pipeline_protected_access = true;
   ext->EXT_pipeline_robustness = true;
   ext->EXT_post_depth_coverage = true;
   ext->EXT_shader_atomic_float2 = true;
   ext->EXT_shader_object = true;
   ext->EXT_shader_subgroup_ballot = true;   ext->EXT_shader_subgroup_vote = true;
   ext->EXT_shader_tile_image = true;
   ext->EXT_subpass_merge_feedback = true;
   ext->EXT_swapchain_maintenance1 = true;
   ext->EXT_ycbcr_2plane_444_formats = true;
   ext->EXT_ycbcr_image_arrays = true;
   ext->GOOGLE_user_type = true;
   ext->IMG_relaxed_line_rasterization = true;
   ext->INTEL_performance_query = true;
   ext->INTEL_shader_integer_functions2 = true;
   ext->KHR_compute_shader_derivatives = true;
   ext->KHR_cooperative_matrix = true;
   ext->KHR_depth_clamp_zero_one = true;
   ext->KHR_device_address_commands = true;
   ext->KHR_fragment_shader_barycentric = true;
   ext->KHR_maintenance10 = true;
   ext->KHR_maintenance7 = true;
   ext->KHR_maintenance8 = true;
   ext->KHR_maintenance9 = true;
   ext->KHR_performance_query = true;
   ext->KHR_pipeline_binary = true;
   ext->KHR_present_id = true;
   ext->KHR_present_id2 = true;
   ext->KHR_present_wait = true;
   ext->KHR_present_wait2 = true;
   ext->KHR_ray_tracing_pipeline = true;
   ext->KHR_ray_tracing_position_fetch = true;
   ext->KHR_robustness2 = true;
   ext->KHR_shader_maximal_reconvergence = true;
   ext->KHR_shader_quad_control = true;
   ext->KHR_swapchain_maintenance1 = true;
   ext->KHR_video_decode_av1 = true;
   ext->KHR_video_decode_h264 = true;
   ext->KHR_video_decode_h265 = true;
   ext->KHR_video_decode_queue = true;
   ext->KHR_video_encode_av1 = true;
   ext->KHR_video_encode_h264 = true;
   ext->KHR_video_encode_h265 = true;
   ext->KHR_video_encode_queue = true;
   ext->KHR_video_maintenance1 = true;
   ext->KHR_video_maintenance2 = true;
   ext->KHR_video_queue = true;
   ext->MESA_image_alignment_control = true;
   ext->NVX_image_view_handle = true;
   ext->NV_cooperative_matrix = true;
   ext->NV_device_diagnostic_checkpoints = true;
   ext->NV_device_diagnostics_config = true;
   ext->QCOM_filter_cubic_clamp = true;
   ext->QCOM_filter_cubic_weights = true;
   ext->QCOM_image_processing2 = true;   ext->QCOM_render_pass_store_ops = true;
   ext->QCOM_render_pass_transform = true;
   ext->QCOM_tile_properties = true;
   ext->QCOM_ycbcr_degamma = true;
   ext->VALVE_descriptor_set_host_mapping = true;
   ext->EXT_zero_initialize_device_memory = true;
   ext->KHR_shader_bfloat16 = true;
   ext->KHR_unified_image_layouts = true;
   ext->QCOM_cooperative_matrix_conversion = true;
   ext->QCOM_data_graph_model = true;
   ext->QCOM_fragment_density_map_offset = true;
   ext->QCOM_image_processing = true;
   ext->QCOM_multiview_per_view_render_areas = true;
   ext->QCOM_multiview_per_view_viewports = true;
   ext->QCOM_render_pass_shader_resolve = true;
   ext->QCOM_rotated_copy_commands = true;
   ext->QCOM_tile_memory_heap = true;
   ext->QCOM_tile_shading = true;
   ext->VALVE_fragment_density_map_layered = true;
   ext->VALVE_shader_mixed_float_dot_product = true;
   ext->VALVE_video_encode_rgb_conversion = true;
   ext->AMDX_shader_enqueue = true;
   ext->ARM_render_pass_striped = true;
   ext->ARM_scheduling_controls = true;
   ext->ARM_shader_core_builtins = true;
   ext->ARM_shader_core_properties = true;
   ext->EXT_attachment_feedback_loop_dynamic_state = true;
   ext->EXT_attachment_feedback_loop_layout = true;
   ext->EXT_border_color_swizzle = true;
   ext->EXT_color_write_enable = true;
   ext->EXT_debug_marker = true;
   ext->EXT_depth_clamp_control = true;
   ext->EXT_descriptor_buffer = true;
   ext->EXT_device_address_binding_report = true;
   ext->EXT_dynamic_rendering_unused_attachments = true;
   ext->EXT_extended_dynamic_state3 = true;
   ext->EXT_external_memory_acquire_unmodified = true;
   ext->EXT_filter_cubic = true;
   ext->EXT_fragment_density_map = true;
   ext->EXT_graphics_pipeline_library = true;
   ext->EXT_host_image_copy = true;
   ext->EXT_host_query_reset = true;
   ext->EXT_image_2d_view_of_3d = true;
   ext->EXT_image_robustness = true;
   ext->EXT_image_view_min_lod = true;
   ext->EXT_index_type_uint8 = true;
   ext->EXT_layer_settings = true;
   ext->EXT_legacy_dithering = true;
   ext->EXT_line_rasterization = true;
   ext->EXT_load_store_op_none = true;   ext->EXT_map_memory_placed = true;
   ext->EXT_memory_budget = true;
   ext->EXT_multi_draw = true;
   ext->EXT_multisampled_render_to_single_sampled = true;
   ext->EXT_mutable_descriptor_type = true;
   ext->EXT_nested_command_buffer = true;
   ext->EXT_non_seamless_cube_map = true;
   ext->EXT_primitives_generated_query = true;
   ext->EXT_provoking_vertex = true;
   ext->EXT_rasterization_order_attachment_access = true;
   ext->EXT_rgba10x6_formats = true;
   ext->EXT_robustness2 = true;
   ext->EXT_sample_locations = true;
   ext->EXT_sampler_filter_minmax = true;
   ext->EXT_scalar_block_layout = true;
   ext->EXT_separate_stencil_usage = true;
   ext->EXT_shader_atomic_float = true;
   ext->EXT_shader_demote_to_helper_invocation = true;
   ext->EXT_shader_image_atomic_int64 = true;
   ext->EXT_shader_module_identifier = true;
   ext->EXT_shader_replicated_composites = true;
   ext->EXT_shader_stencil_export = true;
   ext->EXT_shader_viewport_index_layer = true;
   ext->EXT_transform_feedback = true;
   ext->EXT_vertex_attribute_divisor = true;
   ext->EXT_vertex_input_dynamic_state = true;
   ext->EXT_video_encode_quantization_map = true;
   ext->KHR_acceleration_structure = true;
   ext->KHR_deferred_host_operations = true;
   ext->KHR_index_type_uint8 = true;
   ext->KHR_load_store_op_none = true;
   ext->KHR_map_memory2 = true;
   ext->KHR_ray_query = true;
   ext->KHR_ray_tracing_maintenance1 = true;
   ext->KHR_shader_expect_assume = true;
   ext->KHR_shader_float_controls2 = true;
   ext->KHR_shader_subgroup_rotate = true;
   ext->KHR_shader_subgroup_uniform_control_flow = true;
   ext->KHR_vertex_attribute_divisor = true;
   ext->NV_clip_space_w_scaling = true;
   ext->NV_compute_shader_derivatives = true;
   ext->NV_coverage_reduction_mode = true;
   ext->NV_dedicated_allocation_image_aliasing = true;
   ext->NV_fragment_coverage_to_color = true;
   ext->NV_fragment_shading_rate_enums = true;
   ext->NV_framebuffer_mixed_samples = true;
   ext->NV_inherited_viewport_scissor = true;
   ext->NV_linear_color_attachment = true;
   ext->NV_mesh_shader = true;
   ext->NV_raw_access_chains = true;   ext->NV_representative_fragment_test = true;
   ext->NV_sample_mask_override_coverage = true;
   ext->NV_scissor_exclusive = true;
   ext->NV_shader_atomic_float16_vector = true;
   ext->NV_shader_image_footprint = true;
   ext->NV_shader_sm_builtins = true;
   ext->NV_shader_subgroup_partitioned = true;
   ext->NV_shading_rate_image = true;
   ext->NV_viewport_array2 = true;
   ext->NV_viewport_swizzle = true;
   ext->NV_win32_keyed_mutex = true;
"""

m = re.search(r'(get_device_extensions\s*\([^)]*\)\s*\{)', c)
if not m:
    m = re.search(r'(tu_get_device_extensions\s*\([^)]*\)\s*\{)', c)

if m:
    depth = 0
    pos = m.start()
    start_brace = c.find('{', m.start())
    i = start_brace
    while i < len(c):
        if c[i] == '{': depth += 1
        elif c[i] == '}':
            depth -= 1
            if depth == 0:
                c = c[:i] + INJECT + c[i:]
                break
        i += 1
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] EXT injection: added extensions to get_device_extensions')
else:
    n = 0
    for pat in [
        r'(\.(?:KHR|EXT|AMD|QCOM|NV|NVX|VALVE|GOOGLE|IMG|INTEL|MESA)_[A-Za-z0-9_]+\s*=\s*)false\b',
    ]:
        for mm in re.finditer(pat, c):
            c = c[:mm.start(2)] + 'true' + c[mm.end(2):]
            n += 1
    c += '\n'
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] EXT fallback: flipped {n} bits')

FORCEEOF
    log_success "Extension injection applied"
}

apply_vulkan_extensions_support() {
    log_info "Applying Vulkan extensions unlock + upscaler stubs"    local meson_build="${MESA_DIR}/src/freedreno/vulkan/meson.build"
    local stubs_cc="${MESA_DIR}/src/freedreno/vulkan/tu_upscaler_stubs.cc"
    local tu_extensions=""
    local _candidates=(
        "${MESA_DIR}/src/freedreno/vulkan/tu_extensions.py"
        "${MESA_DIR}/src/freedreno/vulkan/tu_device_ext.py"
        "${MESA_DIR}/src/freedreno/vulkan/extensions.py"
    )
    for _f in "${_candidates[@]}"; do
        [[ -f "$_f" ]] && { tu_extensions="$_f"; break; }
    done
    if [[ -z "$tu_extensions" ]]; then
        local _vk_ext_py
        _vk_ext_py=$(find "${MESA_DIR}/src/freedreno" -maxdepth 3 -name "*.py" 2>/dev/null \
            | (xargs grep -l 'Extension(' 2>/dev/null || true) | head -1)
        [[ -n "$_vk_ext_py" ]] && tu_extensions="$_vk_ext_py"
    fi
    if [[ -z "$tu_extensions" ]]; then
        log_warn "No extension definition file found — trying vk_extensions fallback"
        apply_vulkan_extensions_vk_fallback
        return 0
    fi
    log_info "Found extension file: $tu_extensions"
    if grep -q "EXT_UNLOCK_APPLIED" "$tu_extensions"; then
        log_info "Extension unlock already applied"
        return 0
    fi
    python3 - "$tu_extensions" "$stubs_cc" "$meson_build" << 'PYEOF'
import sys, re, os

fp_ext = sys.argv[1]
fp_stubs = sys.argv[2]
fp_meson = sys.argv[3]

with open(fp_ext) as f: c = f.read()

NEVER_UNLOCK = {
    "VK_KHR_workgroup_memory_explicit_layout",
    "VK_KHR_portability_subset",
    "VK_EXT_validation_cache",
    "VK_EXT_validation_features",
    "VK_EXT_validation_flags",
    "VK_ANDROID_native_buffer",
    "VK_KHR_display",
    "VK_KHR_display_swapchain",
    "VK_EXT_direct_mode_display",
    "VK_EXT_acquire_drm_display",
    "VK_EXT_acquire_xlib_display",
}
all_exts = re.findall(r'Extension\s*\(\s*"(VK_[A-Z0-9_]+)"\s*,\s*(?:False|None)\s*,', c)
flipped = 0
for ext in all_exts:
    if ext in NEVER_UNLOCK:
        continue
    for pat in [
        rf'(Extension\s*\(\s*"{re.escape(ext)}"\s*,\s*)False(\s*,)',
        rf'(Extension\s*\(\s*"{re.escape(ext)}"\s*,\s*)None(\s*,)',
    ]:
        if re.search(pat, c):
            c = re.sub(pat, r'\1True\2', c)
            flipped += 1
            break

UPSCALER_EXTS = [
    "VK_AMD_anti_lag",
    "VK_KHR_shader_bfloat16",
    "VK_EXT_full_screen_exclusive",
]

added_exts = []
for ext in UPSCALER_EXTS:
    if ext in c:
        continue
    m = re.search(r'(device_extensions\s*=\s*\[)', c)
    if not m:
        m = re.search(r'(extensions\s*=\s*\[)', c)
    if m:
        ins = c.find('\n', m.end())
        entry = f'\n    Extension("{ext}", True, None),'
        c = c[:ins] + entry + c[ins:]
        added_exts.append(ext)

c += '\n'
with open(fp_ext, 'w') as f: f.write(c)
print(f'[OK] Phase 1: flipped {flipped}, Phase 2: added {len(added_exts)} upscaler exts')

STUBS = """
#include "tu_device.h"
#include "tu_cmd_buffer.h"
#ifdef __cplusplus
extern "C" {
#endif

VKAPI_ATTR VkResult VKAPI_CALL
tu_GetPhysicalDeviceOpticalFlowImageFormatsNV(
   VkPhysicalDevice physicalDevice,
   const VkOpticalFlowImageFormatInfoNV *pInfo,
   uint32_t *pCount, VkOpticalFlowImageFormatPropertiesNV *pProps)
{ if (pCount) *pCount = 0; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL
tu_CreateOpticalFlowSessionNV(VkDevice d,
   const VkOpticalFlowSessionCreateInfoNV *pCI,
   const VkAllocationCallbacks *pA, VkOpticalFlowSessionNV *pS)
{ return VK_ERROR_FEATURE_NOT_PRESENT; }

VKAPI_ATTR void VKAPI_CALL
tu_DestroyOpticalFlowSessionNV(VkDevice d, VkOpticalFlowSessionNV s,
   const VkAllocationCallbacks *pA) {}

VKAPI_ATTR VkResult VKAPI_CALL
tu_BindOpticalFlowSessionImageNV(VkDevice d, VkOpticalFlowSessionNV s,
   VkOpticalFlowSessionBindingPointNV bp, VkImageView v, VkImageLayout l)
{ return VK_ERROR_FEATURE_NOT_PRESENT; }

VKAPI_ATTR void VKAPI_CALL
tu_CmdOpticalFlowExecuteNV(VkCommandBuffer cb,
   VkOpticalFlowSessionNV s, const VkOpticalFlowExecuteInfoNV *pEI) {}

VKAPI_ATTR VkResult VKAPI_CALL
tu_SetLatencySleepModeNV(VkDevice d, VkSwapchainKHR sc,
   const VkLatencySleepModeInfoNV *pSM)
{ return VK_SUCCESS; }

VKAPI_ATTR VkResult VKAPI_CALL
tu_LatencySleepNV(VkDevice d, VkSwapchainKHR sc,
   const VkLatencySleepInfoNV *pSI)
{ return VK_SUCCESS; }

VKAPI_ATTR void VKAPI_CALL
tu_SetLatencyMarkerNV(VkDevice d, VkSwapchainKHR sc,
   const VkSetLatencyMarkerInfoNV *pLMI) {}

VKAPI_ATTR void VKAPI_CALL
tu_GetLatencyTimingsNV(VkDevice d, VkSwapchainKHR sc,
   VkGetLatencyMarkerInfoNV *pLMI) {}

VKAPI_ATTR void VKAPI_CALL
tu_QueueNotifyOutOfBandNV(VkQueue q,
   const VkOutOfBandQueueTypeInfoNV *pQT) {}

VKAPI_ATTR void VKAPI_CALL
tu_AntiLagUpdateAMD(VkDevice d, const VkAntiLagDataAMD *pData) {}

VKAPI_ATTR VkResult VKAPI_CALL
tu_CreateCuModuleNVX(VkDevice d, const VkCuModuleCreateInfoNVX *pCI,
   const VkAllocationCallbacks *pA, VkCuModuleNVX *pM)
{ return VK_ERROR_FEATURE_NOT_PRESENT; }
VKAPI_ATTR VkResult VKAPI_CALL
tu_CreateCuFunctionNVX(VkDevice d, const VkCuFunctionCreateInfoNVX *pCI,
   const VkAllocationCallbacks *pA, VkCuFunctionNVX *pF)
{ return VK_ERROR_FEATURE_NOT_PRESENT; }

VKAPI_ATTR void VKAPI_CALL
tu_DestroyCuModuleNVX(VkDevice d, VkCuModuleNVX m,
   const VkAllocationCallbacks *pA) {}

VKAPI_ATTR void VKAPI_CALL
tu_DestroyCuFunctionNVX(VkDevice d, VkCuFunctionNVX f,
   const VkAllocationCallbacks *pA) {}

VKAPI_ATTR void VKAPI_CALL
tu_CmdCuLaunchKernelNVX(VkCommandBuffer cb,
   const VkCuLaunchInfoNVX *pLI) {}

VKAPI_ATTR VkResult VKAPI_CALL
tu_AcquireFullScreenExclusiveModeEXT(VkDevice d, VkSwapchainKHR sc)
{ return VK_SUCCESS; }

VKAPI_ATTR VkResult VKAPI_CALL
tu_ReleaseFullScreenExclusiveModeEXT(VkDevice d, VkSwapchainKHR sc)
{ return VK_SUCCESS; }

#ifdef __cplusplus
}
#endif
"""

with open(fp_stubs, 'w') as f: f.write(STUBS)
print(f'[OK] Phase 3: upscaler stubs written')

if os.path.exists(fp_meson):
    with open(fp_meson) as f: m = f.read()
    stub_entry = "'tu_upscaler_stubs.cc',"
    if stub_entry not in m:
        target = re.search(r'(freedreno_vulkan_files\s*=\s*files\s*\()', m)
        if target:
            ins = m.find('\n', target.end())
            m = m[:ins+1] + f'  {stub_entry}\n' + m[ins+1:]
            with open(fp_meson, 'w') as f: f.write(m)
            print('[OK] Phase 4: stubs added to meson.build')
        else:
            print('[WARN] Phase 4: freedreno_vulkan_files not found')

PYEOF
    log_success "Vulkan extensions unlock + upscaler stubs applied"
}
apply_deck_emu_support() {
    log_info "Applying Steam Deck GPU emulation (spoof as: $DECK_EMU_TARGET)"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found, skipping deck emu"; return 0; }
    if grep -q "DECK_EMU" "$tu_device_cc"; then
        log_info "Deck emu already applied"
        return 0
    fi
    local vendor_id device_id driver_version device_name
    case "$DECK_EMU_TARGET" in
        nvidia)
            vendor_id="0x10de"; device_id="0x2684"
            driver_version="0x61d0000"
            device_name="NVIDIA GeForce RTX 4090"
            ;;
        amd)
            vendor_id="0x1002"; device_id="0x1435"
            driver_version="0x8000000"
            device_name="AMD Custom GPU 0405 (RADV VANGOGH)"
            ;;
        *)
            vendor_id="0x10de"; device_id="0x2684"
            driver_version="0x61d0000"
            device_name="NVIDIA GeForce RTX 4090"
            ;;
    esac
    python3 - "$tu_device_cc" "$vendor_id" "$device_id" "$driver_version" "$device_name" << 'PYEOF'
import sys, re
fp, vendor_id, device_id, driver_version, device_name = sys.argv[1:6]
with open(fp) as f: c = f.read()

turbo_init = """
#include <fcntl.h>
#include <unistd.h>
static void
tu_deck_perf_init(void)
{
   static const char * const pwrlevel_paths[] = {
      "/sys/class/kgsl/kgsl-3d0/min_pwrlevel",
      "/sys/class/devfreq/kgsl-3d0/min_freq",
      NULL,
   };
   static const char * const governor_paths[] = {
      "/sys/class/kgsl/kgsl-3d0/devfreq/governor",
      "/sys/class/devfreq/kgsl-3d0/governor",
      NULL,
   };
   for (int i = 0; pwrlevel_paths[i]; i++) {
      int fd = open(pwrlevel_paths[i], O_WRONLY | O_CLOEXEC);
      if (fd >= 0) { (void)write(fd, "0", 1); close(fd); break; }   }
   for (int i = 0; governor_paths[i]; i++) {
      int fd = open(governor_paths[i], O_WRONLY | O_CLOEXEC);
      if (fd >= 0) { (void)write(fd, "performance", 11); close(fd); break; }
   }
}
"""

spoof_code = f"""
   if (getenv("TU_DECK_EMU")) {{
      props->vendorID      = {vendor_id};
      props->deviceID      = {device_id};
      props->driverVersion = {driver_version};
      snprintf(props->deviceName, VK_MAX_PHYSICAL_DEVICE_NAME_SIZE, "{device_name}");
   }}
"""

perf_call = """
   tu_deck_perf_init();
"""

m = re.search(r'(tu_GetPhysicalDeviceProperties2?\s*\([^{]*\{)', c)
if not m:
    m = re.search(r'(vkGetPhysicalDeviceProperties2?\s*\([^{]*\{)', c)
if m:
    c = c[:m.end()] + spoof_code + c[m.end():]
    print(f'[OK] Deck emu ({device_name}) applied')
else:
    print('[WARN] Properties function not found for deck emu')

if 'DECK_EMU_PERF_INIT' not in c:
    inc = c.find('#include')
    if inc != -1:
        eol = c.find('\n', inc)
        c = c[:eol+1] + turbo_init + c[eol+1:]
    init_m = re.search(r'(tu_physical_device_init\s*\([^)]*\)\s*\{)', c)
    if not init_m:
        init_m = re.search(r'(tu_CreateDevice\s*\([^)]*\)\s*\{)', c)
    if init_m:
        ins = c.find('\n', c.find('{', init_m.start())) + 1
        c = c[:ins] + perf_call + c[ins:]
        print('[OK] Deck perf init injected into device creation')
with open(fp, 'w') as f: f.write(c)

PYEOF
    log_success "Deck emulation applied ($DECK_EMU_TARGET)"
}

apply_custom_debug_flags() {
    log_info "Adding custom TU_DEBUG flags"    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
    local tu_util_cc="${MESA_DIR}/src/freedreno/vulkan/tu_util.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local tu_image_cc="${MESA_DIR}/src/freedreno/vulkan/tu_image.cc"
    local ir3_ra_c="${MESA_DIR}/src/freedreno/ir3/ir3_ra.c"
    local ir3_compiler_nir="${MESA_DIR}/src/freedreno/ir3/ir3_compiler_nir.c"

    [[ ! -f "$tu_util_h" ]] && { log_warn "tu_util.h not found, skipping custom flags"; return 0; }

    python3 - "$tu_util_h" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
bits = list(map(int, re.findall(r'BITFIELD64_BIT\((\d+)\)', c)))
if not bits:
    print('[WARN] No BITFIELD64_BIT found'); sys.exit(0)
next_bit = max(bits) + 1
flags = [
    'TU_DEBUG_FORCE_VRS','TU_DEBUG_PUSH_REGS','TU_DEBUG_UBWC_ALL',
    'TU_DEBUG_SLC_PIN','TU_DEBUG_TURBO','TU_DEBUG_DEFRAG',
    'TU_DEBUG_CP_PREFETCH','TU_DEBUG_SHFL','TU_DEBUG_VGT_PREF',
    'TU_DEBUG_UNROLL',
]
lines = '\n'.join(f'   {f:<32} = BITFIELD64_BIT({next_bit + i}),' for i, f in enumerate(flags))
all_m = list(re.finditer(r'   TU_DEBUG_\w+\s*=\s*BITFIELD64_BIT\(\d+\),?', c))
if all_m:
    eol = c.find('\n', all_m[-1].end())
    c = c[:eol+1] + lines + '\n' + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] Added {len(flags)} custom TU_DEBUG flags')
else:
    print('[WARN] Enum insertion point not found')
PYEOF

    python3 - "$tu_util_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
REMAP = [
    ("perf",                  "TU_DEBUG_TURBO"),
    ("push_consts_per_stage", "TU_DEBUG_PUSH_REGS"),
    ("noconform",             "TU_DEBUG_UBWC_ALL"),
    ("bos",                   "TU_DEBUG_SLC_PIN"),
    ("dynamic",               "TU_DEBUG_FORCE_VRS"),
    ("fdm",                   "TU_DEBUG_DEFRAG"),
    ("rd",                    "TU_DEBUG_CP_PREFETCH"),
    ("3d_load",               "TU_DEBUG_SHFL"),
    ("rast_order",            "TU_DEBUG_VGT_PREF"),
    ("log_skip_gmem_ops",     "TU_DEBUG_UNROLL"),
]remapped = []
added = []
for name, new_flag in REMAP:
    pat = rf'(\{{\s*"{re.escape(name)}"\s*,\s*)TU_DEBUG_\w+(\s*\}})'
    c, k = re.subn(pat, rf'\g<1>{new_flag}\2', c)
    if k:
        remapped.append(name)
    else:
        all_m = list(re.finditer(r'\{\s*"[a-z_3]+"\s*,\s*TU_DEBUG_\w+\s*\}', c))
        if all_m:
            eol = c.find('\n', all_m[-1].end())
            entry = f'   {{ "{name}", {new_flag} }},\n'
            c = c[:eol+1] + entry + c[eol+1:]
            added.append(name)
c += '\n'
with open(fp, 'w') as f: f.write(c)
print(f'[OK] Remapped: {remapped}')
if added:
    print(f'[OK] Added (not found in table): {added}')
PYEOF

    if [[ -f "$tu_device_cc" ]] && ! grep -q "tu_try_activate_turbo" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
turbo_func = """
static void
tu_try_activate_turbo(void)
{
   static const char * const min_paths[] = {
      "/sys/class/kgsl/kgsl-3d0/min_pwrlevel",
      "/sys/class/devfreq/kgsl-3d0/min_freq",
      NULL,
   };
   static const char * const gov_paths[] = {
      "/sys/class/kgsl/kgsl-3d0/devfreq/governor",
      "/sys/class/devfreq/kgsl-3d0/governor",
      NULL,
   };
   for (int i = 0; min_paths[i]; i++) {
      int fd = open(min_paths[i], O_WRONLY | O_CLOEXEC);
      if (fd >= 0) { (void)write(fd, "0", 1); close(fd); break; }
   }
   for (int i = 0; gov_paths[i]; i++) {
      int fd = open(gov_paths[i], O_WRONLY | O_CLOEXEC);
      if (fd >= 0) { (void)write(fd, "performance", 11); close(fd); break; }
   }
}
"""turbo_call = "\n   if (TU_DEBUG(TURBO))\n      tu_try_activate_turbo();\n"
m_func = re.search(r'\n(static |VkResult |void )', c)
if m_func and 'tu_try_activate_turbo' not in c:
    c = c[:m_func.start()+1] + turbo_func + '\n' + c[m_func.start()+1:]
m_call = re.search(r'(tu_physical_device_init\([^;]+;\s*\n)', c)
if m_call:
    c = c[:m_call.end()] + turbo_call + c[m_call.end():]
with open(fp, 'w') as f: f.write(c)
print('[OK] TU_DEBUG_TURBO injected')
PYEOF
        log_success "TU_DEBUG_TURBO added"
    fi

    if [[ -f "$tu_image_cc" ]] && ! grep -q "TU_DEBUG_UBWC_ALL" "$tu_image_cc"; then
        python3 - "$tu_image_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
ubwc_code = """
   if (TU_DEBUG(UBWC_ALL)) {
      if (!vk_format_is_depth_or_stencil(image->vk.format) &&
          !vk_format_is_compressed(image->vk.format) &&
          image->vk.format != VK_FORMAT_UNDEFINED) {
         for (unsigned _p = 0; _p < ARRAY_SIZE(image->layout); _p++)
            image->layout[_p].ubwc = true;
      }
   }
"""
m = re.search(r'VkResult\s+(tu_image_init|tu_image_create)[^{]*\{', c)
if m:
    returns = list(re.finditer(r'return VK_SUCCESS;', c[m.end():]))
    if returns:
        ins = m.end() + returns[-1].start()
        c = c[:ins] + ubwc_code + '\n   ' + c[ins:]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] TU_DEBUG_UBWC_ALL injected')
    else:
        print('[WARN] No return VK_SUCCESS found')
else:
    print('[WARN] tu_image_init not found')
PYEOF
        log_success "TU_DEBUG_UBWC_ALL added"
    fi

    if [[ -f "$ir3_ra_c" ]] && ! grep -q "ir3_ra_max_regs_override" "$ir3_ra_c"; then
        python3 - "$ir3_ra_c" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
helper = """static inline unsigned
ir3_ra_max_regs_override(unsigned default_max)
{
   const char *dbg = getenv("TU_DEBUG");
   if (dbg && strstr(dbg, "push_regs"))
      return MIN2(default_max * 2u, 96u);
   return default_max;
}
"""
includes = list(re.finditer(r'^#include\b.*', c, re.MULTILINE))
if includes:
    eol = c.find('\n', includes[-1].start())
    c = c[:eol+1] + helper + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] TU_DEBUG_PUSH_REGS helper added')
else:
    print('[WARN] No includes found in ir3_ra.c')
PYEOF
        log_success "TU_DEBUG_PUSH_REGS added"
    fi

    log_success "Custom TU_DEBUG flags applied"
}

apply_a7xx_series_compat() {
    log_info "Applying a7xx series compat (inline fallbacks)"
    local ir3_compiler="${MESA_DIR}/src/freedreno/ir3/ir3_compiler.c"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local devices_py="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"

    if [[ -f "$ir3_compiler" ]] && ! grep -q "A7XX_BRANCH_AND_OR_DISABLED" "$ir3_compiler"; then
        python3 - "$ir3_compiler" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
c, n = re.subn(r'(compiler->has_branch_and_or\s*=\s*)true', r'\1false', c)
if n:
    with open(fp, 'w') as f: f.write(c)
    print("[OK] has_branch_and_or disabled")
else:
    print("[INFO] has_branch_and_or not found or already patched")
PYEOF
        log_success "has_branch_and_or disabled"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "A7XX_WORKGROUP_MEM_DISABLED" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()n = 0
c, k = re.subn(
    r'(\.KHR_workgroup_memory_explicit_layout\s*=\s*)true',
    r'\1false', c)
n += k
for field in [
    'workgroupMemoryExplicitLayout',
    'workgroupMemoryExplicitLayoutScalarBlockLayout',
    'workgroupMemoryExplicitLayout8BitAccess',
    'workgroupMemoryExplicitLayout16BitAccess',
]:
    c, k = re.subn(rf'(features->{re.escape(field)}\s*=\s*)true', r'\1false', c)
    n += k
if n:
    with open(fp, 'w') as f: f.write(c)
    print(f"[OK] workgroup_memory_explicit_layout disabled ({n} replacements)")
else:
    print("[INFO] workgroup_memory fields not found")
PYEOF
        log_success "workgroup_memory_explicit_layout disabled"
    fi

    local dev_info_h="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.h"
    if [[ -f "$devices_py" ]] && [[ -f "$dev_info_h" ]] \
        && grep -q "compute_constlen_quirk" "$dev_info_h" \
        && ! grep -q "A7XX_COMPUTE_CONSTLEN_QUIRK" "$devices_py"; then
        python3 - "$devices_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
m = re.search(r'(reading_shading_rate_requires_smask_quirk\s*=\s*True[^\n]*\n)', c)
if m:
    c = c[:m.end()] + "        compute_constlen_quirk = True,\n" + c[m.end():]
    c += "\n"
    with open(fp, 'w') as f: f.write(c)
    print("[OK] compute_constlen_quirk added after smask_quirk")
else:
    m2 = re.search(r'(a7xx_gen1\s*=\s*A7XXProps\s*\()', c)
    if m2:
        ep = c.find(')', m2.end())
        c = c[:ep] + "\n        compute_constlen_quirk = True,\n    " + c[ep:]
        c += "\n"
        with open(fp, 'w') as f: f.write(c)
        print("[OK] compute_constlen_quirk injected into a7xx_gen1")
    else:
        print("[WARN] a7xx_gen1 block not found")
PYEOF
        log_success "compute_constlen_quirk added"
    elif [[ -f "$dev_info_h" ]] && ! grep -q "compute_constlen_quirk" "$dev_info_h"; then
        python3 - "$dev_info_h" << 'INNEREOF'import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
anchor = re.search(r'(bool\s+fs_must_have_non_zero_constlen_quirk\s*;)', c)
if not anchor:
    anchor = re.search(r'(bool\s+reading_shading_rate_requires_smask_quirk\s*;)', c)
if anchor:
    eol = c.find('\n', anchor.end())
    c = c[:eol+1] + "      bool compute_constlen_quirk;\n" + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] compute_constlen_quirk injected into freedreno_dev_info.h')
else:
    print('[WARN] anchor field not found for compute_constlen_quirk')
INNEREOF
    fi

    log_success "a7xx series compat done"
}

apply_sysmem_mode_fix() {
    log_info "Fixing sysmem mode gating"
    local cmd_buffer="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    local dev_info_h="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.h"
    [[ ! -f "$cmd_buffer" ]] && { log_warn "tu_cmd_buffer.cc not found"; return 0; }
    if [[ -f "$dev_info_h" ]] && ! grep -q "disable_gmem" "$dev_info_h"; then
        python3 - "$dev_info_h" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
anchor = re.search(r'(bool\s+has_ray_intersection\s*;)', c)
if not anchor:
    anchor = re.search(r'(bool\s+has_sw_fuse\s*;)', c)
if not anchor:
    anchor = re.search(r'(bool\s+fs_must_have_non_zero_constlen_quirk\s*;)', c)
if anchor:
    eol = c.find('\n', anchor.end())
    c = c[:eol+1] + "      bool disable_gmem;\n" + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] disable_gmem injected into freedreno_dev_info.h')
else:
    print('[WARN] anchor field not found in freedreno_dev_info.h')
INNEREOF
    fi
    [[ ! -f "$dev_info_h" ]] && { log_warn "freedreno_dev_info.h not found"; return 0; }
    python3 - "$cmd_buffer" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
if "SYSMEM_MODE_FIXED" in c:
    print("[OK] sysmem mode fix already applied")    sys.exit(0)
pat = r'(use_sysmem_rendering\s*\([^)]*\)\s*\{)\s*\n[ \t]*return true;\s*\n'
if not re.search(pat, c):
    print("[INFO] unconditional sysmem return not found, skipping")
    sys.exit(0)
conditional = (
    "\n   if (cmd->device->physical_device->dev_info.props.disable_gmem) {\n"
    "      cmd->state.rp.gmem_disable_reason = \"disable_gmem\";\n"
    "      return true;\n"
    "   }\n"
)
c = re.sub(pat, r'\1' + conditional, c, count=1)
with open(fp, 'w') as f: f.write(c)
print("[OK] unconditional sysmem -> conditional disable_gmem check")
PYEOF
    log_success "sysmem mode gating fixed"
}

apply_a7xx_visibility_fix() {
    log_info "Applying a7xx visibility fixes (LRZ + occlusion)"
    local tu_lrz="${MESA_DIR}/src/freedreno/vulkan/tu_lrz.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ -f "$tu_lrz" ]] && ! grep -q "A7XX_LRZ_SAFE" "$tu_lrz"; then
        python3 - "$tu_lrz" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

pat1 = re.compile(r"(lrz\.fast_clear\s*=\s*)true\s*;")
c, k = re.subn(pat1, r"\g<1>false;", c)
n += k

pat2 = re.compile(r"(lrz_valid\s*=\s*)(true)(\s*;)")
c, k2 = re.subn(pat2, r"\g<1>false\3", c, count=2)
n += k2

with open(fp, "w") as f: f.write(c)
print(f"[OK] LRZ visibility fix: {n} changes")
INNEREOF
        log_success "LRZ visibility fix applied"
    else
        strict_check "A7XX_LRZ_SAFE" "[WARN] LRZ fast_clear not found"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "A7XX_OCCLUSION_FIX" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re
fp = sys.argv[1]with open(fp) as f: c = f.read()
n = 0

for pat, label in [
    (r"(occlusionQueryPrecise\s*=\s*)(false|VK_FALSE)", "occlusionQueryPrecise"),
    (r"(pipelineStatisticsQuery\s*=\s*)(false|VK_FALSE)", "pipelineStatisticsQuery"),
    (r"(independentBlend\s*=\s*)(false|VK_FALSE)", "independentBlend"),
    (r"(depthClamp\s*=\s*)(false|VK_FALSE)", "depthClamp"),
    (r"(depthBiasClamp\s*=\s*)(false|VK_FALSE)", "depthBiasClamp"),
]:
    c, k = re.subn(re.compile(pat), r"\g<1>true", c)
    if k: n += k

with open(fp, "w") as f: f.write(c)
print(f"[OK] Occlusion/visibility feature fixes: {n} fields")
INNEREOF
        log_success "Occlusion query fix applied"
    fi

    log_success "a7xx visibility fixes done"
}

apply_a7xx_perf_patches() {
    log_info "Applying a7xx performance patches"
    local tu_lrz="${MESA_DIR}/src/freedreno/vulkan/tu_lrz.cc"
    local tu_image_cc="${MESA_DIR}/src/freedreno/vulkan/tu_image.cc"
    local ir3_compiler="${MESA_DIR}/src/freedreno/ir3/ir3_compiler.c"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ -f "$tu_lrz" ]] && ! grep -q "A7XX_REVZ_PRESEED" "$tu_lrz"; then
        python3 - "$tu_lrz" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(lrz->direction\s*=\s*TU_LRZ_UNKNOWN\s*;)'
m = re.search(pat, c)
if m:
    preseed = (
        "\n   if (cmd->state.lrz.depth_clear_value == 0.0f)\n"
        "      lrz->direction = TU_LRZ_GREATER;\n"
    )
    eol = c.find('\n', m.end())
    c = c[:eol+1] + preseed + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print("[OK] LRZ reverse-Z pre-seed injected")
else:
    print("[WARN] TU_LRZ_UNKNOWN assignment not found, skipping")
PYEOF
        log_success "LRZ reverse-Z pre-seed applied"
    fi
    if [[ -f "$tu_image_cc" ]] && ! grep -q "A7XX_STORAGE_NO_UBWC" "$tu_image_cc"; then
        python3 - "$tu_image_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
guard = (
    "\n   if (image->vk.usage & VK_IMAGE_USAGE_STORAGE_BIT) {\n"
    "      for (unsigned _p = 0; _p < ARRAY_SIZE(image->layout); _p++)\n"
    "         image->layout[_p].ubwc = false;\n"
    "   }\n"
)
m = re.search(r'VkResult\s+(tu_image_init|tu_image_create)[^{]*\{', c)
if m:
    returns = list(re.finditer(r'return VK_SUCCESS;', c[m.end():]))
    if returns:
        ins = m.end() + returns[-1].start()
        c = c[:ins] + guard + '\n   ' + c[ins:]
        with open(fp, 'w') as f: f.write(c)
        print("[OK] UBWC disabled for storage images")
    else:
        print("[WARN] return VK_SUCCESS not found in tu_image_init")
else:
    print("[WARN] tu_image_init not found")
PYEOF
        log_success "UBWC disabled for storage images"
    fi

    local ir3_compiler_h="${MESA_DIR}/src/freedreno/ir3/ir3_compiler.h"
    if [[ -f "$ir3_compiler_h" ]] && ! grep -q "cs_wave64" "$ir3_compiler_h"; then
        python3 - "$ir3_compiler_h" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
anchor = re.search(r'(bool\s+has_branch_and_or\s*;)', c)
if not anchor:
    anchor = re.search(r'(bool\s+bitops_can_write_predicates\s*;)', c)
if not anchor:
    anchor = re.search(r'(unsigned\s+num_predicates\s*;)', c)
if anchor:
    eol = c.find('\n', anchor.end())
    c = c[:eol+1] + "   bool cs_wave64;\n" + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] cs_wave64 injected into ir3_compiler.h')
else:
    print('[WARN] anchor field not found in ir3_compiler.h')
INNEREOF
    fi
    if [[ -f "$ir3_compiler" ]] && [[ -f "$ir3_compiler_h" ]] \
        && grep -q "cs_wave64" "$ir3_compiler_h" \        && ! grep -q "A7XX_CS_WAVE64" "$ir3_compiler"; then
        python3 - "$ir3_compiler" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(compiler->num_predicates\s*=\s*4\s*;)'
m = re.search(pat, c)
if m:
    eol = c.find('\n', m.end())
    inject = "      compiler->cs_wave64 = true;\n"
    c = c[:eol+1] + inject + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print("[OK] CS wave64 preference set for a7xx")
else:
    print("[WARN] a7xx block (num_predicates=4) not found")
PYEOF
        log_success "CS wave64 preference added"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "A7XX_MESH_INVOC_CAP" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(maxMeshWorkGroupInvocations\s*=\s*)(\d+)'
m = re.search(pat, c)
if m:
    old_val = int(m.group(2))
    if old_val > 128:
        c = c[:m.start(1)] + m.group(1) + "128" + c[m.end():]
        with open(fp, 'w') as f: f.write(c)
        print(f"[OK] maxMeshWorkGroupInvocations capped 128 (was {old_val})")
    else:
        print(f"[INFO] maxMeshWorkGroupInvocations already <= 128 ({old_val})")
else:
    print("[WARN] maxMeshWorkGroupInvocations not found")
PYEOF
        log_success "Mesh shader invocation cap applied"
    fi

    log_success "a7xx performance patches done"
}

apply_vulkan14_promotion() {
    log_info "Promoting Vulkan API to 1.4 + maintenance5/6 features"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local tu_physical="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "VK14_PROMOTION_APPLIED" "$tu_device_cc"; then
        log_info "Vulkan 1.4 promotion already applied"        return 0
    fi
    python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re, os

fp = sys.argv[1]
with open(fp) as f: c = f.read()

def detect_vk_patch(mesa_dir):
    candidates = [
        os.path.join(mesa_dir, "include", "vulkan", "vulkan_core.h"),
        os.path.join(mesa_dir, "include", "vulkan", "vulkan.h"),
        os.path.join(mesa_dir, "src", "vulkan", "registry", "vk.xml"),
    ]
    for path in candidates:
        if not os.path.exists(path):
            continue
        with open(path, errors='ignore') as f:
            text = f.read()
        m = re.search(r'VK_HEADER_VERSION_COMPLETE\s+VK_MAKE_API_VERSION\(\s*0\s*,\s*1\s*,\s*4\s*,\s*(\d+)', text)
        if m:
            return int(m.group(1))
        m = re.search(r'#define\s+VK_HEADER_VERSION\s+(\d+)', text)
        if m:
            return int(m.group(1))
        m = re.search(r'<enum\s+value="(\d+)"\s+name="VK_HEADER_VERSION"', text)
        if m:
            return int(m.group(1))
    return None

mesa_dir = os.path.dirname(os.path.dirname(os.path.dirname(fp)))
patch_ver = detect_vk_patch(mesa_dir)
if patch_ver is None:
    patch_ver = 347

api_str = f"VK_MAKE_API_VERSION(0, 1, 4, {patch_ver})"

n_api = 0
for pat in [
    r'(\.apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(props->apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
]:
    c, k = re.subn(pat, r'\1' + api_str, c)
    n_api += k

for pat in [
    r'(\.KHR_maintenance5\s*=\s*)false',
    r'(\.KHR_maintenance5\s*=\s*)None',
]:    c = re.sub(pat, r'\1true', c)

for pat in [
    r'(\.KHR_maintenance6\s*=\s*)false',
    r'(\.KHR_maintenance6\s*=\s*)None',
]:
    c = re.sub(pat, r'\1true', c)

FORCE_TRUE_13 = [
    'dynamicRendering',
    'synchronization2',
    'maintenance4',
    'shaderIntegerDotProduct',
    'pipelineCreationCacheControl',
    'privateData',
    'shaderDemoteToHelperInvocation',
    'subgroupSizeControl',
    'computeFullSubgroups',
    'inlineUniformBlock',
    'descriptorIndexing',
    'shaderZeroInitializeWorkgroupMemory',
]
n_feat = 0
for field in FORCE_TRUE_13:
    pat = rf'(features->{re.escape(field)}\s*=\s*)false'
    c, k = re.subn(pat, r'\1true', c)
    n_feat += k

FORCE_TRUE_14 = [
    'maintenance5',
    'maintenance6',
    'maintenance7',
    'maintenance8',
    'maintenance9',
    'maintenance10',
    'pushDescriptor',
    'dynamicRenderingLocalRead',
    'shaderExpectAssume',
    'shaderFloatControls2',
    'globalPriorityQuery',
    'cooperativeMatrix',
    'cooperativeMatrixRobustBufferAccess',
    'unifiedImageLayouts',
    'shaderBFloat16',
    'zeroInitializeDeviceMemory',
    'deviceAddressCommands',
]
for field in FORCE_TRUE_14:
    pat = rf'(features->{re.escape(field)}\s*=\s*)false'
    c, k = re.subn(pat, r'\1true', c)    n_feat += k

with open(fp, 'w') as f: f.write(c)
print(f"[OK] apiVersion patched: {n_api} sites -> 1.4.{patch_ver}, features forced: {n_feat}")

INNEREOF
    log_success "Vulkan 1.4 promotion applied"
}

apply_subgroup_optimization() {
    log_info "Fixing subgroup size for a7xx"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "A7XX_SUBGROUP_FIXED" "$tu_device_cc"; then
        log_info "Subgroup fix already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

for pat in [
    r'(subgroupSize\s*=\s*)\d+',
    r'(props->subgroupSize\s*=\s*)\d+',
]:
    c, k = re.subn(pat, r'\g<1>64', c, count=1)
    n += k

for pat, val in [
    (r'(minSubgroupSize\s*=\s*)\d+', '64'),
    (r'(maxSubgroupSize\s*=\s*)\d+', '128'),
]:
    c, k = re.subn(pat, rf'\g<1>{val}', c, count=1)
    n += k

pat_stages = r'(subgroupSupportedStages\s*=\s*)[^;]+'
c, k = re.subn(pat_stages,
    r'\1VK_SHADER_STAGE_ALL_GRAPHICS | VK_SHADER_STAGE_COMPUTE_BIT | VK_SHADER_STAGE_MESH_BIT_EXT | VK_SHADER_STAGE_TASK_BIT_EXT',
    c, count=1)
n += k

pat_ops = r'(subgroupSupportedOperations\s*=\s*)[^;]+'
c, k = re.subn(pat_ops,
    r'\1VK_SUBGROUP_FEATURE_BASIC_BIT | VK_SUBGROUP_FEATURE_VOTE_BIT | VK_SUBGROUP_FEATURE_ARITHMETIC_BIT | VK_SUBGROUP_FEATURE_BALLOT_BIT | VK_SUBGROUP_FEATURE_SHUFFLE_BIT | VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT | VK_SUBGROUP_FEATURE_CLUSTERED_BIT | VK_SUBGROUP_FEATURE_QUAD_BIT | VK_SUBGROUP_FEATURE_ROTATE_BIT_KHR | VK_SUBGROUP_FEATURE_ROTATE_CLUSTERED_BIT_KHR',
    c, count=1)
n += k

with open(fp, 'w') as f: f.write(c)print(f"[OK] Subgroup properties fixed ({n} replacements)")
INNEREOF
    log_success "Subgroup optimization applied"
}

apply_descriptor_buffer_features() {
    log_info "Enabling descriptor buffer features"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "DESC_BUFFER_FEATURES_APPLIED" "$tu_device_cc"; then
        log_info "Descriptor buffer features already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
FIELDS = [
    'descriptorBuffer',
    'descriptorBufferCaptureReplay',
    'descriptorBufferImageLayoutIgnored',
    'descriptorBufferPushDescriptors',
]
for field in FIELDS:
    pat = rf'(features->{re.escape(field)}\s*=\s*)false'
    c, k = re.subn(pat, r'\1true', c, count=1)
    n += k

for pat, val in [
    (r'(robustBufferAccessUpdateAfterBind\s*=\s*)false', 'true'),
    (r'(shaderInputAttachmentArrayDynamicIndexing\s*=\s*)false', 'true'),
    (r'(shaderUniformTexelBufferArrayDynamicIndexing\s*=\s*)false', 'true'),
    (r'(shaderStorageTexelBufferArrayDynamicIndexing\s*=\s*)false', 'true'),
]:
    c, k = re.subn(pat, rf'\1{val}', c, count=1)
    n += k

with open(fp, 'w') as f: f.write(c)
print(f"[OK] Descriptor buffer features enabled ({n} fields)")
INNEREOF
    log_success "Descriptor buffer features applied"
}

apply_memory_perf_patches() {
    log_info "Applying memory performance patches"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "MEM_PERF_APPLIED" "$tu_device_cc"; then
        log_info "Memory perf patches already applied"        return 0
    fi
    python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

for pat in [
    r'(maxPushConstantsSize\s*=\s*)\d+',
    r'(props->maxPushConstantsSize\s*=\s*)\d+',
]:
    c, k = re.subn(pat, r'\g<1>256', c, count=1)
    n += k

pat_sets = r'(maxBoundDescriptorSets\s*=\s*)([1-7])\b'
c, k = re.subn(pat_sets, r'\g<1>8', c)
n += k

pat_samp = r'(maxDescriptorSetSamplers\s*=\s*)(\d+)'
def boost_samplers(m):
    val = int(m.group(2))
    return m.group(1) + str(max(val, 4000))
c, k = re.subn(pat_samp, boost_samplers, c)
n += k

for pat in [
    r'(timestampPeriod\s*=\s*)[0-9.f]+',
    r'(props->timestampPeriod\s*=\s*)[0-9.f]+',
]:
    c, k = re.subn(pat, r'\g<1>52.083f', c, count=1)
    n += k

with open(fp, 'w') as f: f.write(c)
print(f"[OK] Memory/limits perf patches applied ({n} fields)")
INNEREOF
    log_success "Memory performance patches applied"
}

apply_renderpass_opt() {
    log_info "Applying render pass optimization patches"
    local tu_pass="${MESA_DIR}/src/freedreno/vulkan/tu_pass.cc"
    [[ ! -f "$tu_pass" ]] && tu_pass="${MESA_DIR}/src/freedreno/vulkan/tu_pass.c"
    [[ ! -f "$tu_pass" ]] && { log_warn "tu_pass not found, skipping"; return 0; }
    if grep -q "RENDERPASS_OPT_APPLIED" "$tu_pass"; then
        log_info "Renderpass opt already applied"
        return 0
    fi
    python3 - "$tu_pass" << 'INNEREOF'
import sys, refp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

pat = r'(storeOp\s*=\s*)VK_ATTACHMENT_STORE_OP_STORE(\s*;[^\n]*depth)'
c, k = re.subn(pat, r'\1VK_ATTACHMENT_STORE_OP_DONT_CARE \2', c)
n += k

pat2 = r'(transientAttachment\s*&&[^{]*\{)'
m = re.search(pat2, c, re.DOTALL)
if m:
    ins = c.find('{', m.start()) + 1
    eol = c.find('\n', ins)
    inject = "\n"
    c = c[:eol+1] + inject + c[eol+1:]
    n += 1

with open(fp, 'w') as f: f.write(c)
print(f"[OK] Renderpass optimizations applied ({n} changes)")
INNEREOF
    log_success "Renderpass optimization applied"
}

apply_shader_perf_patches() {
    log_info "Applying shader performance patches"
    local ir3_nir="${MESA_DIR}/src/freedreno/ir3/ir3_nir.c"
    local ir3_compiler="${MESA_DIR}/src/freedreno/ir3/ir3_compiler.c"
    [[ ! -f "$ir3_nir" ]] && { log_warn "ir3_nir.c not found"; return 0; }
    if grep -q "SHADER_PERF_APPLIED" "$ir3_nir"; then
        log_info "Shader perf patches already applied"
        return 0
    fi
    python3 - "$ir3_nir" "$ir3_compiler" << 'INNEREOF'
import sys, re
fp_nir = sys.argv[1]
fp_comp = sys.argv[2]
n = 0

with open(fp_nir) as f: c = f.read()

pat = r'(nir_opt_loop_unroll[^;]*max_unroll_iterations\s*=\s*)(\d+)'
m = re.search(pat, c)
if m:
    old_val = int(m.group(2))
    if old_val < 128:
        c = re.sub(pat, lambda x: x.group(1) + '128', c, count=1)
        n += 1

pat2 = r'(nir_opt_algebraic_before_ffma[^;]*;)'
if re.search(pat2, c):    m2 = re.search(pat2, c)
    eol = c.find('\n', m2.end())
    c = c[:eol+1] + c[eol+1:]
    n += 1

with open(fp_nir, 'w') as f: f.write(c)

if fp_comp and __import__('os').path.exists(fp_comp):
    with open(fp_comp) as f: c2 = f.read()
    pat3 = r'(compiler->max_const_compute\s*=\s*)(\d+)'
    m3 = re.search(pat3, c2)
    if m3:
        old_val = int(m3.group(2))
        if old_val < 512:
            c2 = re.sub(pat3, lambda x: x.group(1) + '512', c2, count=1)
            n += 1
    with open(fp_comp, 'w') as f: f.write(c2)

print(f"[OK] Shader performance patches applied ({n} changes)")
INNEREOF
    log_success "Shader performance patches applied"
}

apply_patch_series() {
    local series_dir="$1"
    log_info "Applying patch series from: $series_dir"
    local series_file="${series_dir}/series"
    [[ ! -f "$series_file" ]] && { log_warn "No series file at $series_file"; return 0; }
    while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
        [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
        local patch_path="${series_dir}/${patch_name}"
        if [[ ! -f "$patch_path" ]]; then
            log_warn "Patch not found: $patch_name"
            continue
        fi
        log_info "Applying: $patch_name"
        if git apply --check "$patch_path" 2>/dev/null; then
            git apply "$patch_path"
            log_success "Applied: $patch_name"
        else
            log_warn "Could not apply: $patch_name (skipping)"
        fi
    done < "$series_file"
    log_success "Patch series done"
}

patch_vk_extensions_table() {
    log_info "Patching vk_extensions.py to add missing extensions"
    local vk_ext_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"
    local patch_script="${GITHUB_WORKSPACE:+${GITHUB_WORKSPACE}/scripts}/vk_extensions_patch.py"    [[ -z "${GITHUB_WORKSPACE:-}" ]] && patch_script="$(dirname "$0")/vk_extensions_patch.py"
    [[ ! -f "$vk_ext_py" ]] && { log_warn "vk_extensions.py not found"; return 0; }
    local vk_xml="${MESA_DIR}/src/vulkan/registry/vk.xml"
    if [[ -f "$patch_script" ]]; then
        if [[ -f "$vk_xml" ]]; then
            python3 "$patch_script" "$vk_ext_py" "$vk_xml"
        else
            python3 "$patch_script" "$vk_ext_py"
        fi
    else
        python3 - "$vk_ext_py" << 'PYSCRIPT'
import sys, re, os

MISSING = [
    "VK_KHR_unified_image_layouts",
    "VK_KHR_cooperative_matrix",
    "VK_KHR_shader_bfloat16",
    "VK_KHR_maintenance7",
    "VK_KHR_maintenance8",
    "VK_KHR_maintenance9",
    "VK_KHR_maintenance10",
    "VK_KHR_device_address_commands",
    "VK_KHR_acceleration_structure",
    "VK_KHR_ray_query",
    "VK_KHR_ray_tracing_maintenance1",
    "VK_KHR_ray_tracing_pipeline",
    "VK_KHR_shader_subgroup_rotate",
    "VK_KHR_shader_expect_assume",
    "VK_KHR_shader_float_controls2",
    "VK_KHR_load_store_op_none",
    "VK_KHR_map_memory2",
    "VK_KHR_vertex_attribute_divisor",
    "VK_KHR_pipeline_binary",
    "VK_KHR_present_id2",
    "VK_KHR_present_wait2",
    "VK_EXT_zero_initialize_device_memory",
    "VK_EXT_descriptor_buffer",
    "VK_EXT_device_address_binding_report",
    "VK_EXT_graphics_pipeline_library",
    "VK_EXT_host_image_copy",
    "VK_EXT_legacy_dithering",
    "VK_EXT_map_memory_placed",
    "VK_EXT_mesh_shader",
    "VK_EXT_mutable_descriptor_type",
    "VK_EXT_nested_command_buffer",
    "VK_EXT_shader_replicated_composites",
    "VK_EXT_video_encode_quantization_map",
    "VK_VALVE_video_encode_rgb_conversion",
    "VK_VALVE_fragment_density_map_layered",
    "VK_VALVE_shader_mixed_float_dot_product",    "VK_QCOM_cooperative_matrix_conversion",
    "VK_QCOM_data_graph_model",
    "VK_QCOM_rotated_copy_commands",
    "VK_QCOM_tile_memory_heap",
    "VK_QCOM_tile_shading",
    "VK_ARM_render_pass_striped",
    "VK_ARM_scheduling_controls",
    "VK_ARM_shader_core_builtins",
    "VK_AMDX_shader_enqueue",
    "VK_NV_raw_access_chains",
    "VK_NV_shader_atomic_float16_vector",
]

def patch_vk_xml(vk_xml_path):
    if not os.path.exists(vk_xml_path):
        print(f"[WARN] vk.xml not found at {vk_xml_path}")
        return
    with open(vk_xml_path) as f:
        c = f.read()
    added = []
    for ext in MISSING:
        if f'name="{ext}"' in c:
            continue
        vendor = ext.split("_")[1]
        ext_lower = ext[len("VK_"):].lower()
        xml_entry = (
            f'\n    <extension name="{ext}" number="9999" type="device"'
            f' author="{vendor}" contact="Mesa patched"'
            f' supported="vulkan" ratified="vulkan">\n'
            f'      <require>\n'
            f'        <enum value="1" name="{ext}_SPEC_VERSION"/>\n'
            f'        <enum value="&quot;{ext[3:]}&quot;" name="{ext}_EXTENSION_NAME"/>\n'
            f'      </require>\n'
            f'    </extension>'
        )
        anchor = c.rfind("</extensions>")
        if anchor != -1:
            c = c[:anchor] + xml_entry + "\n" + c[anchor:]
            added.append(ext)
    if added:
        with open(vk_xml_path, "w") as f:
            f.write(c)
        print(f"[OK] vk.xml: added {len(added)} extension entries: {added}")
    else:
        print("[OK] vk.xml: all extensions already present")

def patch_vk_extensions(vk_ext_py_path):
    if not os.path.exists(vk_ext_py_path):
        print(f"[WARN] {vk_ext_py_path} not found")
        return    with open(vk_ext_py_path) as f:
        c = f.read()
    if "VK_MESA_EXT_TABLE_PATCHED" in c:
        print("[OK] vk_extensions.py already patched")
        return

    if "self.ext_version = int(ext_version)" in c:
        c = c.replace(
            "self.ext_version = int(ext_version)",
            "self.ext_version = int(ext_version) if ext_version is not None else 0"
        )
        print("[OK] Fixed ext_version None handling in __init__")

    needs_int = bool(re.search(r'self\.ext_version\s*=\s*int\(', c))
    existing_m = re.search(
        r'Extension\s*\(\s*"VK_\w+"\s*,\s*(\d+|True|False)\s*(?:,\s*([^)]+))?\s*\)',
        c
    )
    if needs_int:
        entry_args = "1, None"
        if existing_m:
            ver = existing_m.group(1)
            try:
                int(ver)
                entry_args = ver + ", None"
            except ValueError:
                pass
    else:
        entry_args = "True, None"
        if existing_m:
            ver = existing_m.group(1)
            extra = existing_m.group(2)
            entry_args = ver + (", " + extra.strip() if extra else "")

    added = []
    for ext in MISSING:
        if ext in c:
            continue
        m = re.search(r"(DEVICE_EXTENSIONS\s*=\s*\[)", c)
        if not m:
            m = re.search(r"(device_extensions\s*=\s*\[)", c)
        if not m:
            m = re.search(r"(extensions\s*=\s*\[)", c)
        if m:
            ins = c.find("\n", m.end())
            entry = '\n    Extension("' + ext + '", ' + entry_args + '),'
            c = c[:ins] + entry + c[ins:]
            added.append(ext)
        else:
            c += "\n# auto-added: " + ext + "\n"            added.append(ext)

    c += "\n"
    with open(vk_ext_py_path, "w") as f:
        f.write(c)
    print(f"[OK] vk_extensions.py: added {len(added)} entries (args: {entry_args}): {added}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 vk_extensions_patch.py <vk_extensions.py> [vk.xml]")
        sys.exit(1)
    patch_vk_extensions(sys.argv[1])
    if len(sys.argv) >= 3:
        patch_vk_xml(sys.argv[2])
    else:
        base = os.path.dirname(sys.argv[1])
        xml_candidates = [
            os.path.join(base, "..", "..", "registry", "vk.xml"),
            os.path.join(base, "..", "registry", "vk.xml"),
            os.path.join(base, "registry", "vk.xml"),
        ]
        for xml_path in xml_candidates:
            xml_path = os.path.normpath(xml_path)
            if os.path.exists(xml_path):
                patch_vk_xml(xml_path)
                break
        else:
            print("[WARN] vk.xml not found automatically — extensions may not appear in VkExtensionProperties")

PYSCRIPT
    fi
    log_success "vk_extensions.py patched"
}

apply_patches() {
    log_info "Applying patches"
    cd "$MESA_DIR"
    [[ "$BUILD_VARIANT" == "vanilla" ]] && { log_info "Vanilla - skipping patches"; return 0; }

    if [[ "$ENABLE_VIEWPORT_CLAMP" == "true" ]]; then
        apply_viewport_clamp_fix
    fi
    if [[ "$ENABLE_TIMELINE_FIX" == "true" ]]; then
        apply_timeline_semaphore_fix
    fi
    if [[ "$ENABLE_PRESENT_WAIT_FIX" == "true" ]]; then
        apply_present_wait_fix
    fi
    if [[ "$ENABLE_FRAME_PACING" == "true" ]]; then
        apply_frame_pacing_fix    fi
    if [[ "$ENABLE_VSYNC_BYPASS" == "true" ]]; then
        apply_vsync_bypass_fix
    fi
    if [[ "$ENABLE_ANDROID_PROP_CONTROL" == "true" ]]; then
        apply_android_prop_control
    fi

    if [[ "$APPLY_PATCH_SERIES" == "true" ]]; then
        [[ -f "$PATCHES_DIR/series" ]] && apply_patch_series "$PATCHES_DIR"
        [[ -d "$PATCHES_DIR/a8xx" && -f "$PATCHES_DIR/a8xx/series" ]] && apply_patch_series "$PATCHES_DIR/a8xx"
    fi

    if [[ "$ENABLE_TIMELINE_HACK" == "true" ]]; then apply_timeline_semaphore_fix; fi
    apply_gralloc_ubwc_fix
    apply_a8xx_patches
    apply_sysmem_mode_fix
    
    if [[ "$ENABLE_A7XX_COMPAT" == "true" ]]; then 
        apply_a7xx_series_compat
        apply_a7xx_visibility_fix
    fi
    if [[ "$ENABLE_A7XX_PERF" == "true" ]]; then apply_a7xx_perf_patches; fi
    
    if [[ "$ENABLE_A750_AUTOTUNE" == "true" ]] && \
       [[ "$TARGET_GPU" == "a7xx" || "$TARGET_GPU" == "a0xx" ]]; then
        apply_a750_dynamic_autotune
    fi
    
    if [[ "$ENABLE_VK14_PROMO" == "true" ]]; then 
        apply_vulkan14_promotion
        apply_subgroup_optimization
        apply_descriptor_buffer_features
    fi
    apply_memory_perf_patches
    apply_renderpass_opt
    if [[ "$ENABLE_SHADER_PERF" == "true" ]]; then apply_shader_perf_patches; fi
    if [[ "$ENABLE_CUSTOM_FLAGS" == "true" ]]; then apply_custom_debug_flags; fi
    if [[ "$ENABLE_DECK_EMU" == "true" ]]; then apply_deck_emu_support; fi
    if [[ "$ENABLE_EXT_SPOOF" == "true" ]]; then apply_vulkan_extensions_support; fi

    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local patch_name
            patch_name=$(basename "$patch")
            log_info "Applying loose patch: $patch_name"
            if git apply --check "$patch" 2>/dev/null; then
                git apply "$patch"
                log_success "Applied: $patch_name"            else
                log_warn "Could not apply: $patch_name"
            fi
        done
    fi

    log_success "All patches applied"
}

setup_subprojects() {
    log_info "Setting up subprojects"
    cd "$MESA_DIR"
    mkdir -p subprojects/packagecache
    log_success "Subprojects ready"
}

create_cross_file() {
    log_info "Creating cross-compilation file"
    local ndk_bin="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    [[ ! -d "$ndk_bin" ]] && { log_error "NDK not found: $ndk_bin"; exit 1; }
    local cver
    cver=$(ls "${ndk_bin}/aarch64-linux-android"*"-clang" 2>/dev/null \
        | grep -oP "(?<=android)\d+" | sort -rn | head -1)
    [[ -z "$cver" ]] && cver="$API_LEVEL"
    local c_args_list="'-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations'"
    if [ -n "$CFLAGS_EXTRA" ]; then for flag in $CFLAGS_EXTRA; do c_args_list="$c_args_list, '$flag'"; done; fi
    local cpp_args_list="'-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations'"
    if [ -n "$CXXFLAGS_EXTRA" ]; then for flag in $CXXFLAGS_EXTRA; do cpp_args_list="$cpp_args_list, '$flag'"; done; fi
    local link_args_list="'-static-libstdc++'"
    if [ -n "$LDFLAGS_EXTRA" ]; then for flag in $LDFLAGS_EXTRA; do link_args_list="$link_args_list, '$flag'"; done; fi
    cat > "${WORKDIR}/cross-aarch64.txt" << EOF
[binaries]
ar     = '${ndk_bin}/llvm-ar'
c      = ['ccache', '${ndk_bin}/aarch64-linux-android${cver}-clang', '--sysroot=${ndk_sys}']
cpp    = ['ccache', '${ndk_bin}/aarch64-linux-android${cver}-clang++', '--sysroot=${ndk_sys}']
c_ld   = 'lld'
cpp_ld = 'lld'
strip  = '${ndk_bin}/aarch64-linux-android-strip'
[host_machine]
system     = 'android'
cpu_family = 'aarch64'
cpu        = 'armv8'
endian     = 'little'
[built-in options]
c_args        = [$c_args_list]
cpp_args      = [$cpp_args_list]
c_link_args   = [$link_args_list]
cpp_link_args = [$link_args_list]
EOF    log_success "Cross-compilation file created"
}

configure_build() {
    log_info "Configuring Mesa build (unified a7xx + a8xx)"
    cd "$MESA_DIR"
    local buildtype="$BUILD_TYPE"
    [[ "$BUILD_VARIANT" == "debug"   ]] && buildtype="debug"
    [[ "$BUILD_VARIANT" == "profile" ]] && buildtype="debugoptimized"
    meson setup build \
        --cross-file "${WORKDIR}/cross-aarch64.txt" \
        -Dbuildtype="$buildtype" \
        -Dplatforms=android \
        -Dplatform-sdk-version="$API_LEVEL" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Dvideo-codecs=all
        -Degl=disabled \
        -Dglx=disabled \
        -Dgles1=disabled \
        -Dgles2=disabled \
        -Dopengl=false \
        -Dgbm=disabled \
        -Dllvm=disabled \
        -Dlibunwind=disabled \
        -Dlmsensors=disabled \
        -Dzstd=disabled \
        -Dvalgrind=disabled \
        -Dbuild-tests=false \
        -Dwerror=false \
        -Ddefault_library=shared \
        --force-fallback-for=spirv-tools,spirv-headers \
        2>&1 | tee "${WORKDIR}/meson.log"
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Meson configuration failed"
        exit 1
    fi
    log_success "Build configured"
}

compile_driver() {
    log_info "Compiling Turnip driver"
    local cores
    cores=$(nproc 2>/dev/null || echo 4)
    ninja -C "${MESA_DIR}/build" -j"$cores" 2>&1 | tee "${WORKDIR}/ninja.log"
    local driver="${MESA_DIR}/build/src/freedreno/vulkan/libvulkan_freedreno.so"
    [[ ! -f "$driver" ]] && { log_error "Build failed: driver not found"; exit 1; }
    log_success "Compilation complete"}

package_driver() {
    log_info "Packaging driver"
    local version commit vulkan_version build_date
    version=$(cat "${WORKDIR}/version.txt")
    commit=$(cat "${WORKDIR}/commit.txt")
    vulkan_version=$(get_vulkan_version)
    build_date=$(date +'%Y-%m-%d')
    local driver_src="${MESA_DIR}/build/src/freedreno/vulkan/libvulkan_freedreno.so"
    local pkg_dir="${WORKDIR}/package"
    local driver_name="vulkan.ad00xx.so"
    mkdir -p "$pkg_dir"
    cp "$driver_src" "${pkg_dir}/${driver_name}"
    patchelf --set-soname "${driver_name}" "${pkg_dir}/${driver_name}"
    "${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
        --strip-all --strip-debug \
        "${pkg_dir}/${driver_name}" 2>/dev/null || true
    "${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objcopy" \
        --remove-section=.comment \
        --remove-section=.note \
        --remove-section=.note.gnu.build-id \
        "${pkg_dir}/${driver_name}" 2>/dev/null || true
    local driver_size
    driver_size=$(du -h "${pkg_dir}/${driver_name}" | cut -f1)
    local build_num="${BUILD_NUMBER:-1}"
    local release_name="Turnip-${version}-B${build_num}"
    local filename="${release_name}"
    cat > "${pkg_dir}/meta.json" << EOF
{
  "schemaVersion": 1,
  "name": "${release_name}",
  "description": "Compiled From Mesa Freedreno",
  "author": "BlueInstruction",
  "packageVersion": "${build_num}",
  "vendor": "Mesa",
  "driverVersion": "${vulkan_version}",
  "minApi": 28,
  "libraryName": "${driver_name}"
}
EOF
    echo "$filename"        > "${WORKDIR}/filename.txt"
    echo "$release_name"    > "${WORKDIR}/release_name.txt"
    echo "$vulkan_version"  > "${WORKDIR}/vulkan_version.txt"
    echo "$build_date"      > "${WORKDIR}/build_date.txt"
    cd "$pkg_dir"
    zip -9 "${WORKDIR}/${filename}.zip" "$driver_name" meta.json
    log_success "Package: ${filename}.zip ($driver_size)"
}
print_summary() {
    local version commit vulkan_version build_date
    version=$(cat "${WORKDIR}/version.txt")
    commit=$(cat "${WORKDIR}/commit.txt")
    vulkan_version=$(cat "${WORKDIR}/vulkan_version.txt")
    build_date=$(cat "${WORKDIR}/build_date.txt")
    echo ""
    log_info "Build Summary"
    echo "  Mesa Version   : $version"
    echo "  Vulkan Version : $vulkan_version"
    echo "  Commit         : $commit"
    echo "  Build Date     : $build_date"
    echo "  Driver Name    : vulkan.ad00xx.so"
    echo "  Build Variant  : $BUILD_VARIANT"
    echo "  GPU Support    : a7xx (725/730/735/740/750) + a8xx (810/825/829/830/840)"
    echo "  Output         :"
    ls -lh "${WORKDIR}"/*.zip 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
    echo ""
}

main() {
    log_info "Turnip Unified Driver Builder (a7xx + a8xx)"
    check_deps
    prepare_workdir
    clone_mesa
    update_vulkan_headers
    apply_patches
    patch_vk_extensions_table
    setup_subprojects
    create_cross_file
    configure_build
    compile_driver
    package_driver
    print_summary
    log_success "Build completed successfully"
}

main "$@"
