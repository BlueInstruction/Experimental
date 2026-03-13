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
PATCHES_DIR="$(pwd)/patches"
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

apply_all_gpu_device_support() {
    log_info "Applying full GPU device support (a7xx + a8xx)"
    local devices_py="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"
    [[ ! -f "$devices_py" ]] && { log_warn "freedreno_devices.py not found, skipping"; return 0; }
    if grep -q "ALL_GPU_DEVICES_INJECTED" "$devices_py"; then
        log_info "GPU device entries already injected"
        return 0
    fi
    python3 - "$devices_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

a7xx_ids = {
    '725': [('0x43020600', 'FD725'), ('0xffff43020600', 'FD725')],
    '730': [('0x43021000', 'FD730'), ('0xffff43021000', 'FD730')],
    '735': [('0x43021300', 'FD735'), ('0xffff43021300', 'FD735')],
    '740': [('0x43050a01', 'FD740'), ('0xffff43050a01', 'FD740'),
            ('0x43050b00', 'FD740'), ('0xffff43050b00', 'FD740')],
    '750': [('0x43050c00', 'FD750'), ('0xffff43050c00', 'FD750')],
}

a8xx_ids = {
    '810': [('0x44010000', 'FD810')],
    '825': [('0x44030000', 'FD825')],
    '829': [('0x44030A00', 'FD829'), ('0x44030A20', 'FD829'), ('0xffff44030A00', 'FD829')],
    '830': [('0x44050000', 'FD830'), ('0x44050001', 'FD830'), ('0xffff44050000', 'FD830')],
    '840': [('0xffff44050A31', 'FD840'), ('0x44050A00', 'FD840')],
}

inject = '\n# ALL_GPU_DEVICES_INJECTED\n'

for gpu, ids in a7xx_ids.items():
    present = all(chip_id in c for chip_id, _ in ids)
    if present:
        continue
    id_lines = '\n'.join(f"        GPUId(chip_id={chip_id}, name=\"{name}\")," for chip_id, name in ids)
    inject += f'''
add_gpus([
{id_lines}
    ], A6xxGPUInfo(
        CHIP.A7XX,
        [a7xx_base, a7xx_gen1],
        num_ccu = 4,
        tile_align_w = 96,
        tile_align_h = 32,
        num_vsc_pipes = 32,
        cs_shared_mem_size = 32 * 1024,
        wave_granularity = 2,
        fibers_per_sp = 128 * 2 * 16,
        magic_regs = dict(),
        raw_magic_regs = [],
    ))
'''

for gpu, ids in a8xx_ids.items():
    present = all(chip_id in c for chip_id, _ in ids)
    if present:
        continue
    id_lines = '\n'.join(f"        GPUId(chip_id={chip_id}, name=\"{name}\")," for chip_id, name in ids)
    disable_gmem = 'True' if gpu == '810' else 'False'
    inject += f'''
add_gpus([
{id_lines}
    ], A6xxGPUInfo(
        CHIP.A8XX,
        [a7xx_base, a7xx_gen3, a8xx_base],
        num_ccu = 2 if {gpu} == 810 else 4,
        num_slices = 1 if {gpu} == 810 else 2,
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
'''

m = re.search(r'\nadd_gpus\(', c)
if m:
    c = c[:m.start()] + inject + c[m.start():]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] GPU device entries injected (a7xx 725/730/735/740/750 + a8xx 810/825/829/830/840)')
else:
    c += inject
    with open(fp, 'w') as f: f.write(c)
    print('[OK] GPU device entries appended')
PYEOF
    log_success "Full GPU device support applied"
}

apply_a8xx_patches() {
    log_info "Applying a8xx-specific patches"
    local kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    local dev_info_h="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.h"
    local cmd_buffer="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    local gmem_cache="${MESA_DIR}/src/freedreno/common/fd6_gmem_cache.h"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ "$ENABLE_UBWC_HACK" == "true" ]] && [[ -f "$kgsl_file" ]] && ! grep -q "UBWC_56_APPLIED" "$kgsl_file"; then
        python3 - "$kgsl_file" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
inject = (
    '   case KGSL_UBWC_5_0:\n'
    '      ubwc_config->bank_swizzle_levels = 0x4;\n'
    '      ubwc_config->macrotile_mode = FDL_MACROTILE_8_CHANNEL;\n'
    '      break;\n'
    '   case KGSL_UBWC_6_0:\n'
    '      ubwc_config->bank_swizzle_levels = 0x6;\n'
    '      ubwc_config->macrotile_mode = FDL_MACROTILE_8_CHANNEL;\n'
    '      break;\n'
    '   /* UBWC_56_APPLIED */\n'
)
for pat in [
    r'(case KGSL_UBWC_4_0:.*?break;\n)([ \t]*default:)',
    r'(case KGSL_UBWC_3_0:.*?break;\n)([ \t]*default:)',
]:
    m = re.search(pat, c, re.DOTALL)
    if m:
        c = c[:m.start(2)] + inject + c[m.start(2):]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] UBWC 5.0/6.0 cases inserted')
        break
else:
    print('[WARN] UBWC switch pattern not found')
PYEOF
        log_success "UBWC 5.0/6.0 support applied"
    fi

    if [[ -f "$dev_info_h" ]] && ! grep -q "disable_gmem" "$dev_info_h"; then
        python3 - "$dev_info_h" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
field = '   bool disable_gmem;\n'
all_m = list(re.finditer(r'bool\s+has_\w+;', c))
if all_m:
    eol = c.find('\n', all_m[-1].end())
    c = c[:eol+1] + field + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] disable_gmem added to fd_dev_info')
else:
    print('[WARN] Insertion point not found in fd_dev_info.h')
PYEOF
        log_success "disable_gmem property added"
    fi

    if [[ -f "$cmd_buffer" ]] && ! grep -q "A8XX_DISABLE_GMEM" "$cmd_buffer"; then
        python3 - "$cmd_buffer" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
inject = '\n   /* A8XX_DISABLE_GMEM */\n   if (cmd->device->physical_device->dev_info.disable_gmem)\n      return true;\n'
pat = r'(use_sysmem_rendering\s*\([^)]*\)\s*\{)'
m = re.search(pat, c)
if m:
    ins = c.find('\n', c.find('{', m.start())) + 1
    c = c[:ins] + inject + c[ins:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] disable_gmem guard added to use_sysmem_rendering')
else:
    print('[WARN] use_sysmem_rendering not found')
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

    log_success "A8xx patches complete"
}

apply_vulkan_extensions_support() {
    log_info "Unlocking all Turnip-implemented Vulkan extensions"
    local tu_extensions="${MESA_DIR}/src/freedreno/vulkan/tu_extensions.py"
    [[ ! -f "$tu_extensions" ]] && { log_warn "tu_extensions.py not found, skipping"; return 0; }
    if grep -q "EXT_UNLOCK_APPLIED" "$tu_extensions"; then
        log_info "Extension unlock already applied"
        return 0
    fi
    python3 - "$tu_extensions" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

SAFE_UNLOCK = [
    "VK_KHR_synchronization2",
    "VK_KHR_dynamic_rendering",
    "VK_KHR_dynamic_rendering_local_read",
    "VK_KHR_shader_non_semantic_info",
    "VK_KHR_shader_expect_assume",
    "VK_KHR_shader_maximal_reconvergence",
    "VK_KHR_shader_subgroup_rotate",
    "VK_KHR_shader_subgroup_uniform_control_flow",
    "VK_KHR_shader_quad_control",
    "VK_KHR_shader_float_controls2",
    "VK_KHR_shader_atomic_int64",
    "VK_KHR_shader_float16_int8",
    "VK_KHR_shader_clock",
    "VK_KHR_compute_shader_derivatives",
    "VK_KHR_cooperative_matrix",
    "VK_KHR_global_priority",
    "VK_KHR_performance_query",
    "VK_KHR_pipeline_executable_properties",
    "VK_KHR_pipeline_library",
    "VK_KHR_ray_query",
    "VK_KHR_ray_tracing_maintenance1",
    "VK_KHR_ray_tracing_pipeline",
    "VK_KHR_ray_tracing_position_fetch",
    "VK_KHR_acceleration_structure",
    "VK_KHR_deferred_host_operations",
    "VK_KHR_fragment_shader_barycentric",
    "VK_KHR_fragment_shading_rate",
    "VK_KHR_present_id",
    "VK_KHR_present_wait",
    "VK_KHR_shared_presentable_image",
    "VK_KHR_video_queue",
    "VK_KHR_video_decode_queue",
    "VK_KHR_video_decode_h264",
    "VK_KHR_video_decode_h265",
    "VK_EXT_descriptor_buffer",
    "VK_EXT_descriptor_indexing",
    "VK_EXT_mesh_shader",
    "VK_EXT_shader_object",
    "VK_EXT_shader_tile_image",
    "VK_EXT_shader_stencil_export",
    "VK_EXT_shader_atomic_float",
    "VK_EXT_shader_atomic_float2",
    "VK_EXT_shader_demote_to_helper_invocation",
    "VK_EXT_shader_module_identifier",
    "VK_EXT_shader_replicated_composites",
    "VK_EXT_shader_subgroup_ballot",
    "VK_EXT_shader_subgroup_vote",
    "VK_EXT_shader_viewport_index_layer",
    "VK_EXT_subgroup_size_control",
    "VK_EXT_image_compression_control",
    "VK_EXT_image_compression_control_swapchain",
    "VK_EXT_image_robustness",
    "VK_EXT_image_sliced_view_of_3d",
    "VK_EXT_image_view_min_lod",
    "VK_EXT_image_2d_view_of_3d",
    "VK_EXT_filter_cubic",
    "VK_EXT_fragment_density_map",
    "VK_EXT_fragment_density_map2",
    "VK_EXT_fragment_shader_interlock",
    "VK_EXT_frame_boundary",
    "VK_EXT_memory_budget",
    "VK_EXT_memory_priority",
    "VK_EXT_multi_draw",
    "VK_EXT_multisampled_render_to_single_sampled",
    "VK_EXT_mutable_descriptor_type",
    "VK_EXT_non_seamless_cube_map",
    "VK_EXT_opacity_micromap",
    "VK_EXT_pageable_device_local_memory",
    "VK_EXT_pipeline_creation_cache_control",
    "VK_EXT_pipeline_creation_feedback",
    "VK_EXT_pipeline_library_group_handles",
    "VK_EXT_pipeline_protected_access",
    "VK_EXT_pipeline_robustness",
    "VK_EXT_post_depth_coverage",
    "VK_EXT_primitives_generated_query",
    "VK_EXT_primitive_topology_list_restart",
    "VK_EXT_provoking_vertex",
    "VK_EXT_rasterization_order_attachment_access",
    "VK_EXT_robustness2",
    "VK_EXT_sample_locations",
    "VK_EXT_sampler_filter_minmax",
    "VK_EXT_scalar_block_layout",
    "VK_EXT_separate_stencil_usage",
    "VK_EXT_subpass_merge_feedback",
    "VK_EXT_swapchain_maintenance1",
    "VK_EXT_texel_buffer_alignment",
    "VK_EXT_texture_compression_astc_hdr",
    "VK_EXT_tooling_info",
    "VK_EXT_transform_feedback",
    "VK_EXT_vertex_attribute_divisor",
    "VK_EXT_vertex_input_dynamic_state",
    "VK_EXT_ycbcr_2plane_444_formats",
    "VK_EXT_ycbcr_image_arrays",
    "VK_EXT_attachment_feedback_loop_layout",
    "VK_EXT_attachment_feedback_loop_dynamic_state",
    "VK_EXT_border_color_swizzle",
    "VK_EXT_color_write_enable",
    "VK_EXT_conditional_rendering",
    "VK_EXT_conservative_rasterization",
    "VK_EXT_custom_border_color",
    "VK_EXT_depth_bias_control",
    "VK_EXT_depth_clamp_control",
    "VK_EXT_depth_clamp_zero_one",
    "VK_EXT_depth_clip_control",
    "VK_EXT_depth_clip_enable",
    "VK_EXT_depth_range_unrestricted",
    "VK_EXT_device_address_binding_report",
    "VK_EXT_device_fault",
    "VK_EXT_device_memory_report",
    "VK_EXT_discard_rectangles",
    "VK_EXT_display_control",
    "VK_EXT_dynamic_rendering_unused_attachments",
    "VK_EXT_extended_dynamic_state",
    "VK_EXT_extended_dynamic_state2",
    "VK_EXT_extended_dynamic_state3",
    "VK_EXT_external_memory_dma_buf",
    "VK_EXT_global_priority",
    "VK_EXT_global_priority_query",
    "VK_EXT_graphics_pipeline_library",
    "VK_EXT_host_image_copy",
    "VK_EXT_host_query_reset",
    "VK_EXT_index_type_uint8",
    "VK_EXT_inline_uniform_block",
    "VK_EXT_legacy_dithering",
    "VK_EXT_legacy_vertex_attributes",
    "VK_EXT_line_rasterization",
    "VK_EXT_load_store_op_none",
    "VK_EXT_map_memory_placed",
    "VK_EXT_mesh_shader",
    "VK_EXT_nested_command_buffer",
    "VK_AMD_buffer_marker",
    "VK_AMD_device_coherent_memory",
    "VK_AMD_memory_overallocation_behavior",
    "VK_AMD_shader_core_properties",
    "VK_AMD_shader_core_properties2",
    "VK_AMD_shader_info",
    "VK_QCOM_filter_cubic_clamp",
    "VK_QCOM_filter_cubic_weights",
    "VK_QCOM_image_processing",
    "VK_QCOM_image_processing2",
    "VK_QCOM_multiview_per_view_render_areas",
    "VK_QCOM_multiview_per_view_viewports",
    "VK_QCOM_render_pass_shader_resolve",
    "VK_QCOM_render_pass_store_ops",
    "VK_QCOM_render_pass_transform",
    "VK_QCOM_tile_properties",
    "VK_QCOM_ycbcr_degamma",
    "VK_VALVE_descriptor_set_host_mapping",
    "VK_VALVE_mutable_descriptor_type",
    "VK_NV_compute_shader_derivatives",
    "VK_NV_cooperative_matrix",
    "VK_NV_device_diagnostic_checkpoints",
    "VK_NV_device_diagnostics_config",
    "VK_NVX_image_view_handle",
    "VK_GOOGLE_decorate_string",
    "VK_GOOGLE_display_timing",
    "VK_GOOGLE_hlsl_functionality1",
    "VK_GOOGLE_user_type",
    "VK_IMG_filter_cubic",
    "VK_IMG_relaxed_line_rasterization",
    "VK_INTEL_performance_query",
    "VK_INTEL_shader_integer_functions2",
    "VK_MESA_image_alignment_control",
]

changed = 0
for ext in SAFE_UNLOCK:
    pat_false = rf'(Extension\s*\(\s*"{re.escape(ext)}"\s*,\s*)False(\s*,)'
    pat_none  = rf'(Extension\s*\(\s*"{re.escape(ext)}"\s*,\s*)None(\s*,)'
    if re.search(pat_false, c):
        c = re.sub(pat_false, r'\1True\2', c)
        changed += 1
    elif re.search(pat_none, c):
        c = re.sub(pat_none, r'\1True\2', c)
        changed += 1

c += '\n# EXT_UNLOCK_APPLIED\n'
with open(fp, 'w') as f: f.write(c)
print(f'[OK] Enabled {changed} additional Vulkan extensions')
PYEOF
    log_success "Vulkan extensions unlock applied"
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
if 'force_vrs' in c:
    print('[OK] tu_util.cc already patched'); sys.exit(0)
new_entries = (
    '   { "force_vrs",   TU_DEBUG_FORCE_VRS   },\n'
    '   { "push_regs",   TU_DEBUG_PUSH_REGS   },\n'
    '   { "ubwc_all",    TU_DEBUG_UBWC_ALL    },\n'
    '   { "slc_pin",     TU_DEBUG_SLC_PIN     },\n'
    '   { "turbo",       TU_DEBUG_TURBO       },\n'
    '   { "defrag",      TU_DEBUG_DEFRAG      },\n'
    '   { "cp_prefetch", TU_DEBUG_CP_PREFETCH },\n'
    '   { "shfl",        TU_DEBUG_SHFL        },\n'
    '   { "vgt_pref",    TU_DEBUG_VGT_PREF    },\n'
    '   { "unroll",      TU_DEBUG_UNROLL      },\n'
)
all_m = list(re.finditer(r'\{\s*"[a-z_]+"\s*,\s*TU_DEBUG_\w+\s*\}', c))
if all_m:
    eol = c.find('\n', all_m[-1].end())
    c = c[:eol+1] + new_entries + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] Added 10 entries to debug table')
else:
    print('[WARN] Debug table not found in tu_util.cc')
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
    apply_all_gpu_device_support
    apply_a8xx_patches
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
        "${pkg_dir}/${driver_name}" 2>/dev/null || true
    local driver_size
    driver_size=$(du -h "${pkg_dir}/${driver_name}" | cut -f1)
    local variant_suffix
    case "$BUILD_VARIANT" in
        optimized) variant_suffix="opt"     ;;
        autotuner) variant_suffix="at"      ;;
        vanilla)   variant_suffix="vanilla" ;;
        debug)     variant_suffix="debug"   ;;
        profile)   variant_suffix="profile" ;;
        *)         variant_suffix="opt"     ;;
    esac
    local filename="turnip_a0xx_v${version}_${variant_suffix}_${build_date}"
    cat > "${pkg_dir}/meta.json" << EOF
{
  "schemaVersion": 1,
  "name": "Turnip Unified",
  "description": "Compiled From Mesa Freedreno",
  "author": "BlueInstruction",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "${vulkan_version}",
  "minApi": 28,
  "libraryName": "${driver_name}"
}
EOF
    echo "$filename"        > "${WORKDIR}/filename.txt"
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
    setup_subprojects
    create_cross_file
    configure_build
    compile_driver
    package_driver
    print_summary
    log_success "Build completed successfully"
}

main "$@"
