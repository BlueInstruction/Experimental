#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

WORKDIR="${GITHUB_WORKSPACE:-$(pwd)}/build"
MESA_DIR="${WORKDIR}/mesa"
PATCHES_DIR="${GITHUB_WORKSPACE:-$(dirname "$(dirname "$0")")}/patches"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_MIRROR="https://github.com/mesa3d/mesa.git"
ROBCLARK_REPO="https://gitlab.freedesktop.org/robclark/mesa.git"
AUTOTUNER_REPO="https://gitlab.freedesktop.org/PixelyIon/mesa.git"
VULKAN_HEADERS_REPO="https://github.com/KhronosGroup/Vulkan-Headers.git"

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
ENABLE_A7XX_PERF="${ENABLE_A7XX_PERF:-true}"
ENABLE_VK14_PROMO="${ENABLE_VK14_PROMO:-true}"
ENABLE_SHADER_PERF="${ENABLE_SHADER_PERF:-true}"
CFLAGS_EXTRA="${CFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
CXXFLAGS_EXTRA="${CXXFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
LDFLAGS_EXTRA="${LDFLAGS_EXTRA:--Wl,--gc-sections}"

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
    else
        echo "1.4.0"
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
            version=$(get_mesa_version)
            commit=$(git -C "$MESA_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
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
    log_info "Updating Vulkan headers to latest version"
    local headers_dir="${WORKDIR}/vulkan-headers"
    git clone --depth=1 "$VULKAN_HEADERS_REPO" "$headers_dir" 2>/dev/null || {
        log_warn "Failed to clone Vulkan headers, using Mesa defaults"
        return 0
    }
    if [[ -d "${headers_dir}/include/vulkan" ]]; then
        cp -r "${headers_dir}/include/vulkan" "${MESA_DIR}/include/"
        log_success "Vulkan headers updated"
    else
        log_warn "Vulkan headers include dir not found, skipping"
    fi
}

apply_timeline_semaphore_fix() {
    log_info "Applying timeline semaphore fix"
    local tu_sync="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    [[ ! -f "$tu_sync" ]] && tu_sync="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.c"
    [[ ! -f "$tu_sync" ]] && { log_warn "KGSL kernel file not found, skipping"; return 0; }
    if grep -q "TIMELINE_SEMAPHORE_FIX" "$tu_sync"; then
        log_info "Timeline fix already applied"
        return 0
    fi
    python3 - "$tu_sync" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(\.has_timeline_sem\s*=\s*)false'
if re.search(pat, c):
    c = re.sub(pat, r'\1true ', c)
    with open(fp, 'w') as f: f.write(c)
    print('[OK] Timeline semaphore enabled')
else:
    print('[WARN] Timeline semaphore pattern not found, skipping')
PYEOF
    log_success "Timeline semaphore fix applied"
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
    inject = '\n   /* UBWC_GRALLOC_FORCED */\n   return 0;\n'
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
    c = re.sub(pat2, r'\1 | GRALLOC1_PRODUCER_USAGE_PRIVATE_ALLOC_UBWC /* GRALLOC_UBWC_FIX */ \2', c, count=1)
    with open(fp, 'w') as f: f.write(c)
    print('[OK] UBWC flag added to gralloc usage')
else:
    print('[WARN] Gralloc usage pattern not found')
PYEOF
    fi
    log_success "Gralloc UBWC fix applied"
}


apply_a8xx_patches() {
    log_info "Applying a8xx-specific patches"
    local kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    local dev_info_h="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.h"
    local cmd_buffer="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    local gmem_cache="${MESA_DIR}/src/freedreno/common/fd6_gmem_cache.h"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ "$ENABLE_UBWC_HACK" == "true" ]] && [[ -f "$kgsl_file" ]]; then
        python3 - "$kgsl_file" << 'INNEREOF'
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
    with open(fp, "w") as f: f.write(c)
    print("[WARN] UBWC switch not found, defines only")
    sys.exit(0)

# Find the FULL lvalue expression that writes bank_swizzle_levels/macrotile_mode
# Pattern: device->ubwc_config.bank_swizzle_levels — must capture 'device->ubwc_config'
case_body = c[m4.start():m4.end()]

# Capture full expression: optional 'ptr->' prefix + struct name
# e.g. 'device->ubwc_config.bank_swizzle_levels' -> lval='device->ubwc_config'
# e.g. 'ubwc_config.bank_swizzle_levels'         -> lval='ubwc_config'
lval_pat = re.compile(
    r'((?:\w+->)?\w+)\.(bank_swizzle_levels|macrotile_mode)'
)
lval_m = lval_pat.search(case_body)

if not lval_m:
    # Fallback: any ptr->field or var.field assignment in the case body
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
INNEREOF
        log_success "UBWC 5.0/6.0 support applied"
    fi

    if [[ -f "$cmd_buffer" ]] \
        && grep -q "disable_gmem" "$dev_info_h" 2>/dev/null \
        && ! grep -q "A8XX_DISABLE_GMEM" "$cmd_buffer"; then
        python3 - "$cmd_buffer" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
inject = "\n   /* A8XX_DISABLE_GMEM */\n   if (cmd->device->physical_device->dev_info.props.disable_gmem) {\n      cmd->state.rp.gmem_disable_reason = \"Unsupported GPU\";\n      return true;\n   }\n"
pat = r'use_sysmem_rendering\s*\([^)]*\)\s*\{'
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
    c = c[:m.start()] + '/* A8XX_GMEM_OFFSET_FIX */' + c[m.end():]
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
    c = c[:m.start()] + '/* A8XX_FLUSHALL_REMOVED */' + c[m.end():]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] A8xx forced FLUSHALL removed')
else:
    print('[INFO] FLUSHALL block not found in this version')
PYEOF
        log_success "A8xx FLUSHALL removed"
    fi

    local devices_py="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"
    if [[ -f "$devices_py" ]] && ! grep -q "A8XX_DEVICES_INJECTED" "$devices_py"; then
        python3 - "$devices_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

a8xx_ids = {
    '810': [('0x44010000', 'FD810')],
    '825': [('0x44030000', 'FD825')],
    '829': [('0x44030A00', 'FD829'), ('0x44030A20', 'FD829'), ('0xffff44030A00', 'FD829')],
    '830': [('0x44050000', 'FD830'), ('0x44050001', 'FD830'), ('0xffff44050000', 'FD830')],
    '840': [('0xffff44050A31', 'FD840'), ('0x44050A00', 'FD840')],
}

inject = '# A8XX_DEVICES_INJECTED\n'
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
        log_success "A8xx device entries checked/injected"
    fi

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
    python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

INJECT = """
   /* EXT_INJECT_APPLIED */
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
   ext->EXT_shader_subgroup_ballot = true;
   ext->EXT_shader_subgroup_vote = true;
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
   ext->QCOM_image_processing2 = true;
   ext->QCOM_render_pass_store_ops = true;
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
"""

# Find get_device_extensions function and inject before its closing brace
m = re.search(r'(get_device_extensions\s*\([^)]*\)\s*\{)', c)
if not m:
    m = re.search(r'(tu_get_device_extensions\s*\([^)]*\)\s*\{)', c)

if m:
    # Find the matching closing brace
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
    print(f'[OK] EXT injection: added {INJECT.count("ext->")} extensions to get_device_extensions')
else:
    # Fallback: flip false->true pattern
    n = 0
    for pat in [
        r'(\.(?:KHR|EXT|AMD|QCOM|NV|NVX|VALVE|GOOGLE|IMG|INTEL|MESA)_[A-Za-z0-9_]+\s*=\s*)false\b',
    ]:
        for mm in re.finditer(pat, c):
            c = c[:mm.start(2)] + 'true' + c[mm.end(2):]
            n += 1
    c += '\n/* EXT_INJECT_APPLIED */\n'
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] EXT fallback: flipped {n} bits')
INNEREOF
    log_success "Extension injection applied"
}

apply_vulkan_extensions_support() {
    log_info "Applying Vulkan extensions unlock + upscaler stubs"
    local meson_build="${MESA_DIR}/src/freedreno/vulkan/meson.build"
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

c += '\n# EXT_UNLOCK_APPLIED\n'
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
spoof_code = f"""
   if (getenv("TU_DECK_EMU")) {{
      props->vendorID      = {vendor_id};
      props->deviceID      = {device_id};
      props->driverVersion = {driver_version};
      snprintf(props->deviceName, VK_MAX_PHYSICAL_DEVICE_NAME_SIZE, "{device_name}");
   }}
"""
m = re.search(r'(tu_GetPhysicalDeviceProperties2?\s*\([^{]*\{)', c)
if not m:
    m = re.search(r'(vkGetPhysicalDeviceProperties2?\s*\([^{]*\{)', c)
if m:
    c = c[:m.end()] + spoof_code + c[m.end():]
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] Deck emu ({device_name}) applied')
else:
    print('[WARN] Properties function not found for deck emu')
PYEOF
    log_success "Deck emulation applied ($DECK_EMU_TARGET)"
}

apply_custom_debug_flags() {
    log_info "Adding custom TU_DEBUG flags"
    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
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
if 'TU_DEBUG_FORCE_VRS' in c:
    print('[OK] custom flags already in tu_util.h'); sys.exit(0)
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
if 'TU_DEBUG_REMAP_APPLIED' in c:
    print('[OK] tu_util.cc already remapped'); sys.exit(0)
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
]
remapped = []
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
c += '\n/* TU_DEBUG_REMAP_APPLIED */\n'
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
"""
turbo_call = "\n   if (TU_DEBUG(TURBO))\n      tu_try_activate_turbo();\n"
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
helper = """
static inline unsigned
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
c, n = re.subn(r'(compiler->has_branch_and_or\s*=\s*)true', r'\1false /* A7XX_BRANCH_AND_OR_DISABLED */', c)
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
with open(fp) as f: c = f.read()
n = 0
c, k = re.subn(
    r'(\.KHR_workgroup_memory_explicit_layout\s*=\s*)true',
    r'\1false /* A7XX_WORKGROUP_MEM_DISABLED */', c)
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
    c += "\n# A7XX_COMPUTE_CONSTLEN_QUIRK\n"
    with open(fp, 'w') as f: f.write(c)
    print("[OK] compute_constlen_quirk added after smask_quirk")
else:
    m2 = re.search(r'(a7xx_gen1\s*=\s*A7XXProps\s*\()', c)
    if m2:
        ep = c.find(')', m2.end())
        c = c[:ep] + "\n        compute_constlen_quirk = True,\n    " + c[ep:]
        c += "\n# A7XX_COMPUTE_CONSTLEN_QUIRK\n"
        with open(fp, 'w') as f: f.write(c)
        print("[OK] compute_constlen_quirk injected into a7xx_gen1")
    else:
        print("[WARN] a7xx_gen1 block not found")
PYEOF
        log_success "compute_constlen_quirk added"
    elif [[ -f "$dev_info_h" ]] && ! grep -q "compute_constlen_quirk" "$dev_info_h"; then
        python3 - "$dev_info_h" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
anchor = re.search(r'(bool\s+fs_must_have_non_zero_constlen_quirk\s*;)', c)
if not anchor:
    anchor = re.search(r'(bool\s+reading_shading_rate_requires_smask_quirk\s*;)', c)
if anchor:
    eol = c.find('\n', anchor.end())
    c = c[:eol+1] + "      bool compute_constlen_quirk; /* injected */\n" + c[eol+1:]
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
    c = c[:eol+1] + "      bool disable_gmem; /* injected */\n" + c[eol+1:]
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
    print("[OK] sysmem mode fix already applied")
    sys.exit(0)
pat = r'(use_sysmem_rendering\s*\([^)]*\)\s*\{)\s*\n[ \t]*return true;\s*\n'
if not re.search(pat, c):
    print("[INFO] unconditional sysmem return not found, skipping")
    sys.exit(0)
conditional = (
    "\n   /* SYSMEM_MODE_FIXED */\n"
    "   if (cmd->device->physical_device->dev_info.props.disable_gmem) {\n"
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
        "\n   /* A7XX_REVZ_PRESEED */\n"
        "   if (cmd->state.lrz.depth_clear_value == 0.0f)\n"
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
    "\n   /* A7XX_STORAGE_NO_UBWC */\n"
    "   if (image->vk.usage & VK_IMAGE_USAGE_STORAGE_BIT) {\n"
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
    c = c[:eol+1] + "   bool cs_wave64; /* injected */\n" + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] cs_wave64 injected into ir3_compiler.h')
else:
    print('[WARN] anchor field not found in ir3_compiler.h')
INNEREOF
    fi
    if [[ -f "$ir3_compiler" ]] && [[ -f "$ir3_compiler_h" ]] \
        && grep -q "cs_wave64" "$ir3_compiler_h" \
        && ! grep -q "A7XX_CS_WAVE64" "$ir3_compiler"; then
        python3 - "$ir3_compiler" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(compiler->num_predicates\s*=\s*4\s*;)'
m = re.search(pat, c)
if m:
    eol = c.find('\n', m.end())
    inject = "      compiler->cs_wave64 = true; /* A7XX_CS_WAVE64 */\n"
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
        c = c[:m.start(1)] + m.group(1) + "128 /* A7XX_MESH_INVOC_CAP */" + c[m.end():]
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
        log_info "Vulkan 1.4 promotion already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

# Force VK_API_VERSION_1_4 in apiVersion
n_api = 0
for pat in [
    r'(\.apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
    r'(props->apiVersion\s*=\s*)VK_MAKE_API_VERSION\([^)]+\)',
]:
    c, k = re.subn(pat, r'\1VK_MAKE_API_VERSION(0, 1, 4, 344) /* VK14_PROMOTION_APPLIED */', c)
    n_api += k

# Enable KHR_maintenance5
for pat in [
    r'(\.KHR_maintenance5\s*=\s*)false',
    r'(\.KHR_maintenance5\s*=\s*)None',
]:
    c = re.sub(pat, r'\1true', c)

# Enable KHR_maintenance6
for pat in [
    r'(\.KHR_maintenance6\s*=\s*)false',
    r'(\.KHR_maintenance6\s*=\s*)None',
]:
    c = re.sub(pat, r'\1true', c)

# Force Vulkan13Features that a750 supports but may not advertise
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

# Force Vulkan14Features (maintenance5/6 core)
FORCE_TRUE_14 = [
    'maintenance5',
    'maintenance6',
    'pushDescriptor',
    'dynamicRenderingLocalRead',
    'shaderExpectAssume',
    'shaderFloatControls2',
    'globalPriorityQuery',
]
for field in FORCE_TRUE_14:
    pat = rf'(features->{re.escape(field)}\s*=\s*)false'
    c, k = re.subn(pat, r'\1true', c)
    n_feat += k

with open(fp, 'w') as f: f.write(c)
print(f"[OK] apiVersion patched: {n_api} sites, features forced: {n_feat}")
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

# subgroupSize: a750 has 64-lane waves in most stages
for pat in [
    r'(subgroupSize\s*=\s*)\d+',
    r'(props->subgroupSize\s*=\s*)\d+',
]:
    c, k = re.subn(pat, r'\g<1>64 /* A7XX_SUBGROUP_FIXED */', c, count=1)
    n += k

# minSubgroupSize / maxSubgroupSize
for pat, val in [
    (r'(minSubgroupSize\s*=\s*)\d+', '64'),
    (r'(maxSubgroupSize\s*=\s*)\d+', '128'),
]:
    c, k = re.subn(pat, rf'\g<1>{val}', c, count=1)
    n += k

# supportedStages: all stages
pat_stages = r'(subgroupSupportedStages\s*=\s*)[^;]+'
c, k = re.subn(pat_stages,
    r'\1VK_SHADER_STAGE_ALL_GRAPHICS | VK_SHADER_STAGE_COMPUTE_BIT | VK_SHADER_STAGE_MESH_BIT_EXT | VK_SHADER_STAGE_TASK_BIT_EXT',
    c, count=1)
n += k

# supportedOperations: enable all
pat_ops = r'(subgroupSupportedOperations\s*=\s*)[^;]+'
c, k = re.subn(pat_ops,
    r'\1VK_SUBGROUP_FEATURE_BASIC_BIT | VK_SUBGROUP_FEATURE_VOTE_BIT | VK_SUBGROUP_FEATURE_ARITHMETIC_BIT | VK_SUBGROUP_FEATURE_BALLOT_BIT | VK_SUBGROUP_FEATURE_SHUFFLE_BIT | VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT | VK_SUBGROUP_FEATURE_CLUSTERED_BIT | VK_SUBGROUP_FEATURE_QUAD_BIT | VK_SUBGROUP_FEATURE_ROTATE_BIT_KHR | VK_SUBGROUP_FEATURE_ROTATE_CLUSTERED_BIT_KHR',
    c, count=1)
n += k

with open(fp, 'w') as f: f.write(c)
print(f"[OK] Subgroup properties fixed ({n} replacements)")
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
    c, k = re.subn(pat, r'\1true /* DESC_BUFFER_FEATURES_APPLIED */', c, count=1)
    n += k

# descriptor buffer size limits - ensure reasonable values
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
        log_info "Memory perf patches already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'INNEREOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

# maxPushConstantsSize: vkd3d-proton needs 256 for D3D12 root constants
for pat in [
    r'(maxPushConstantsSize\s*=\s*)\d+',
    r'(props->maxPushConstantsSize\s*=\s*)\d+',
]:
    c, k = re.subn(pat, r'\g<1>256 /* MEM_PERF_APPLIED */', c, count=1)
    n += k

# maxBoundDescriptorSets: D3D12 needs at least 8
pat_sets = r'(maxBoundDescriptorSets\s*=\s*)([1-7])\b'
c, k = re.subn(pat_sets, r'\g<1>8', c)
n += k

# maxDescriptorSetSamplers: increase for complex games
pat_samp = r'(maxDescriptorSetSamplers\s*=\s*)(\d+)'
def boost_samplers(m):
    val = int(m.group(2))
    return m.group(1) + str(max(val, 4000))
c, k = re.subn(pat_samp, boost_samplers, c)
n += k

# timestampPeriod: fix for accurate frame timing on a750
# a750 GPU timer runs at ~19.2MHz RBBM
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
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

# Force DONT_CARE for depth/stencil store when not read back
# Pattern: depth attachment store op assigned to STORE
pat = r'(storeOp\s*=\s*)VK_ATTACHMENT_STORE_OP_STORE(\s*;[^\n]*depth)'
c, k = re.subn(pat, r'\1VK_ATTACHMENT_STORE_OP_DONT_CARE /* RENDERPASS_OPT_APPLIED */ \2', c)
n += k

# Allow lazy allocation flag on transient attachments
pat2 = r'(transientAttachment\s*&&[^{]*\{)'
m = re.search(pat2, c, re.DOTALL)
if m:
    ins = c.find('{', m.start()) + 1
    eol = c.find('\n', ins)
    inject = "\n      /* RENDERPASS_OPT_APPLIED: prefer lazily allocated */\n"
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

# Increase NIR loop unroll threshold for a7xx
# Default is usually 32 or 64 iterations
pat = r'(nir_opt_loop_unroll[^;]*max_unroll_iterations\s*=\s*)(\d+)'
m = re.search(pat, c)
if m:
    old_val = int(m.group(2))
    if old_val < 128:
        c = re.sub(pat, lambda x: x.group(1) + '128', c, count=1)
        n += 1

# Enable aggressive instruction combining for ir3
pat2 = r'(nir_opt_algebraic_before_ffma[^;]*;)'
if re.search(pat2, c):
    m2 = re.search(pat2, c)
    eol = c.find('\n', m2.end())
    c = c[:eol+1] + "   /* SHADER_PERF_APPLIED */\n" + c[eol+1:]
    n += 1

with open(fp_nir, 'w') as f: f.write(c)

if fp_comp and __import__('os').path.exists(fp_comp):
    with open(fp_comp) as f: c2 = f.read()
    # Increase max_const for compute shaders on a7xx
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
    local patch_script="${GITHUB_WORKSPACE:-$(dirname "$(dirname "$0")")}/vk_extensions_patch.py"
    [[ ! -f "$vk_ext_py" ]] && { log_warn "vk_extensions.py not found"; return 0; }
    if [[ -f "$patch_script" ]]; then
        python3 "$patch_script" "$vk_ext_py"
    else
        log_warn "vk_extensions_patch.py not found at $patch_script, skipping"
    fi
    log_success "vk_extensions.py patched"
}
apply_patches() {
    log_info "Applying patches"
    cd "$MESA_DIR"
    [[ "$BUILD_VARIANT" == "vanilla" ]] && { log_info "Vanilla - skipping patches"; return 0; }

    if [[ "$APPLY_PATCH_SERIES" == "true" ]]; then
        [[ -f "$PATCHES_DIR/series" ]] && apply_patch_series "$PATCHES_DIR"
        [[ -d "$PATCHES_DIR/a8xx" && -f "$PATCHES_DIR/a8xx/series" ]] && apply_patch_series "$PATCHES_DIR/a8xx"
    fi

    if [[ "$ENABLE_TIMELINE_HACK" == "true" ]]; then apply_timeline_semaphore_fix; fi
    apply_gralloc_ubwc_fix
    apply_a8xx_patches
    apply_sysmem_mode_fix
    if [[ "$ENABLE_A7XX_COMPAT" == "true" ]]; then apply_a7xx_series_compat; fi
    if [[ "$ENABLE_A7XX_PERF" == "true" ]]; then apply_a7xx_perf_patches; fi
    if [[ "$ENABLE_VK14_PROMO" == "true" ]]; then apply_vulkan14_promotion; fi
    if [[ "$ENABLE_VK14_PROMO" == "true" ]]; then apply_subgroup_optimization; fi
    if [[ "$ENABLE_VK14_PROMO" == "true" ]]; then apply_descriptor_buffer_features; fi
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
                log_success "Applied: $patch_name"
            else
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
    local cver="$API_LEVEL"
    [[ ! -f "${ndk_bin}/aarch64-linux-android${cver}-clang" ]] && cver="35"
    [[ ! -f "${ndk_bin}/aarch64-linux-android${cver}-clang" ]] && cver="34"
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
EOF
    log_success "Cross-compilation file created"
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
    log_success "Compilation complete"
}

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
