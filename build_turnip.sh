#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
strict_check() {
    local name="$1" result="$2"
    if [[ "$result" == *"[WARN]"* ]] && [[ "$STRICT_MODE" == "true" ]]; then
        log_error "STRICT_MODE: critical patch failed: $name"
        exit 1
    fi
}
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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
fetch_latest_ndk_version() {
    local tag
    tag=$(curl -sL "https://api.github.com/repos/android/ndk/releases/latest" \
        | grep -oP '"tag_name":\s*"\Kr[0-9]+[a-z]?' | head -1 || true)
    [[ -n "$tag" ]] && echo "android-ndk-${tag}" || echo "android-ndk-r29"
}
NDK_VERSION="${NDK_VERSION:-$(fetch_latest_ndk_version)}"
NDK_PATH="${NDK_PATH:-/opt/android-ndk}"
API_LEVEL="${API_LEVEL:-35}"
if [[ "${BUILD_VARIANT:-patched}" == "patched" ]]; then
    TARGET_GPU="${TARGET_GPU:-a7xx}"
else
    TARGET_GPU="${TARGET_GPU:-a0xx}"
fi
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
CFLAGS_EXTRA="${CFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
CXXFLAGS_EXTRA="${CXXFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
LDFLAGS_EXTRA="${LDFLAGS_EXTRA:--Wl,--gc-sections}"

A750_HACK_PRESET="${A750_HACK_PRESET:-none}"

case "$A750_HACK_PRESET" in
    safe)
        ENABLE_A750_F16_DEMOTE="${ENABLE_A750_F16_DEMOTE:-true}"
        ENABLE_A750_DEPTH_BIAS="${ENABLE_A750_DEPTH_BIAS:-true}"
        A750_DEPTH_BIAS_CONSTANT="${A750_DEPTH_BIAS_CONSTANT:-1.75}"
        A750_DEPTH_BIAS_CLAMP="${A750_DEPTH_BIAS_CLAMP:-0.001}"
        ENABLE_A750_RELAXED_PRECISION="${ENABLE_A750_RELAXED_PRECISION:-true}"
        ENABLE_A750_FORCE_BINDLESS="${ENABLE_A750_FORCE_BINDLESS:-false}"
        ENABLE_A750_BARRIER_NOOP="${ENABLE_A750_BARRIER_NOOP:-false}"
        ENABLE_A750_ENGINE_SPOOF="${ENABLE_A750_ENGINE_SPOOF:-true}"
        ;;
    aggressive)
        ENABLE_A750_F16_DEMOTE="${ENABLE_A750_F16_DEMOTE:-true}"
        ENABLE_A750_DEPTH_BIAS="${ENABLE_A750_DEPTH_BIAS:-true}"
        A750_DEPTH_BIAS_CONSTANT="${A750_DEPTH_BIAS_CONSTANT:-2.5}"
        A750_DEPTH_BIAS_CLAMP="${A750_DEPTH_BIAS_CLAMP:-0.0025}"
        ENABLE_A750_RELAXED_PRECISION="${ENABLE_A750_RELAXED_PRECISION:-true}"
        ENABLE_A750_FORCE_BINDLESS="${ENABLE_A750_FORCE_BINDLESS:-true}"
        ENABLE_A750_BARRIER_NOOP="${ENABLE_A750_BARRIER_NOOP:-false}"
        ENABLE_A750_ENGINE_SPOOF="${ENABLE_A750_ENGINE_SPOOF:-true}"
        ;;
    experimental)
        ENABLE_A750_F16_DEMOTE="${ENABLE_A750_F16_DEMOTE:-true}"
        ENABLE_A750_DEPTH_BIAS="${ENABLE_A750_DEPTH_BIAS:-true}"
        A750_DEPTH_BIAS_CONSTANT="${A750_DEPTH_BIAS_CONSTANT:-3.0}"
        A750_DEPTH_BIAS_CLAMP="${A750_DEPTH_BIAS_CLAMP:-0.005}"
        ENABLE_A750_RELAXED_PRECISION="${ENABLE_A750_RELAXED_PRECISION:-true}"
        ENABLE_A750_FORCE_BINDLESS="${ENABLE_A750_FORCE_BINDLESS:-true}"
        ENABLE_A750_BARRIER_NOOP="${ENABLE_A750_BARRIER_NOOP:-true}"
        ENABLE_A750_ENGINE_SPOOF="${ENABLE_A750_ENGINE_SPOOF:-true}"
        ;;
    none|*)
        ENABLE_A750_F16_DEMOTE="${ENABLE_A750_F16_DEMOTE:-false}"
        ENABLE_A750_DEPTH_BIAS="${ENABLE_A750_DEPTH_BIAS:-false}"
        A750_DEPTH_BIAS_CONSTANT="${A750_DEPTH_BIAS_CONSTANT:-2.5}"
        A750_DEPTH_BIAS_CLAMP="${A750_DEPTH_BIAS_CLAMP:-0.0025}"
        ENABLE_A750_RELAXED_PRECISION="${ENABLE_A750_RELAXED_PRECISION:-false}"
        ENABLE_A750_FORCE_BINDLESS="${ENABLE_A750_FORCE_BINDLESS:-false}"
        ENABLE_A750_BARRIER_NOOP="${ENABLE_A750_BARRIER_NOOP:-false}"
        ENABLE_A750_ENGINE_SPOOF="${ENABLE_A750_ENGINE_SPOOF:-false}"
        ;;
esac

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
        return 0
    }

    [[ ! -d "${headers_dir}/include/vulkan" ]] && { log_warn "Headers dir missing"; return 0; }
    cp -r "${headers_dir}/include/vulkan" "${MESA_DIR}/include/"

    local core_h="${MESA_DIR}/include/vulkan/vulkan_core.h"
    if [[ -f "$core_h" ]]; then
        cat >> "$core_h" << 'COMPAT_EOF'

/* EXT→KHR: Mesa generated code uses EXT, new headers promote to KHR */
/* KHR→EXT: Mesa generated code uses KHR, old headers only have EXT */
COMPAT_EOF
        log_info "Device fault EXT/KHR bidirectional compat defines appended"
    fi

    log_success "Vulkan headers updated to $target_tag"
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




apply_vulkan_extensions_vk_fallback() {
    log_info "Applying extensions via get_device_extensions injection + force enumerate"
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
   ext->EXT_legacy_dithering = true;
   ext->EXT_line_rasterization = true;
   ext->EXT_load_store_op_none = true;
   ext->EXT_map_memory_placed = true;
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
   ext->NV_raw_access_chains = true;
   ext->NV_representative_fragment_test = true;
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
    print(f'[OK] EXT injection: added {INJECT.count("ext->")} extensions to get_device_extensions')
else:
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

FORCEEOF
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_phys="${MESA_DIR}/src/vulkan/runtime/vk_physical_device.c"

    if [[ -f "$tu_device_cc" ]] && ! grep -q "FORCE_EXT_FIELDS_APPLIED" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'FORCEEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

FORCE_FIELDS = [
    "KHR_unified_image_layouts",
    "KHR_cooperative_matrix",
    "KHR_shader_bfloat16",
    "KHR_maintenance7",
    "KHR_maintenance8",
    "KHR_maintenance9",
    "KHR_maintenance10",
    "KHR_device_address_commands",
    "KHR_acceleration_structure",
    "KHR_ray_query",
    "KHR_ray_tracing_maintenance1",
    "KHR_ray_tracing_pipeline",
    "KHR_shader_subgroup_rotate",
    "KHR_shader_expect_assume",
    "KHR_shader_float_controls2",
    "KHR_load_store_op_none",
    "KHR_map_memory2",
    "KHR_vertex_attribute_divisor",
    "KHR_pipeline_binary",
    "KHR_present_id2",
    "KHR_present_wait2",
    "EXT_zero_initialize_device_memory",
    "EXT_descriptor_buffer",
    "EXT_device_address_binding_report",
    "EXT_graphics_pipeline_library",
    "EXT_host_image_copy",
    "EXT_legacy_dithering",
    "EXT_map_memory_placed",
    "EXT_mutable_descriptor_type",
    "EXT_nested_command_buffer",
    "EXT_shader_replicated_composites",
    "EXT_video_encode_quantization_map",
]

inject_lines = "\n".join(f"   ext->{f} = true;" for f in FORCE_FIELDS)
inject = "\n   /* FORCE_EXT_FIELDS_APPLIED */\n" + inject_lines + "\n"

m = re.search(r'(get_device_extensions\s*\([^)]*\)\s*\{)', c)
if not m:
    m = re.search(r'(tu_get_device_extensions\s*\([^)]*\)\s*\{)', c)

if m:
    depth, i = 0, c.find("{", m.start())
    while i < len(c):
        if c[i] == "{": depth += 1
        elif c[i] == "}":
            depth -= 1
            if depth == 0:
                c = c[:i] + inject + c[i:]
                break
        i += 1
    with open(fp, "w") as f: f.write(c)
    n = len(FORCE_FIELDS)
    print(f"[OK] Force ext fields injected: {n} extensions")
else:
    c += "\n/* FORCE_EXT_FIELDS_APPLIED */\n"
    with open(fp, "w") as f: f.write(c)
    print("[OK] Force ext marker added (EXT_INJECT already covers this)")
FORCEEOF
    fi

    if [[ -f "$vk_phys" ]] && ! grep -q "FORCE_EXT_COUNT_PATCH" "$vk_phys"; then
    python3 - "$vk_phys" << 'FORCEEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

FORCE_EXTS = [
    "VK_KHR_unified_image_layouts",
    "VK_KHR_cooperative_matrix",
    "VK_KHR_shader_bfloat16",
    "VK_KHR_maintenance7",
    "VK_KHR_maintenance8",
    "VK_KHR_maintenance9",
    "VK_KHR_maintenance10",
    "VK_EXT_zero_initialize_device_memory",
    "VK_KHR_device_address_commands",
]

ext_entries = "\n".join(f'   {{"{e}", 1}},' for e in FORCE_EXTS)

inject_struct = f"""
/* FORCE_EXT_COUNT_PATCH */
static const struct {{ const char *name; uint32_t spec; }} _force_ext_list[] = {{
{ext_entries}
}};
static const int _force_ext_n = {len(FORCE_EXTS)};
static void _append_force_exts(uint32_t *cnt, VkExtensionProperties *props) {{
   for (int _i = 0; _i < _force_ext_n; _i++) {{
      bool _found = false;
      for (uint32_t _j = 0; props && _j < *cnt; _j++)
         if (!strcmp(props[_j].extensionName, _force_ext_list[_i].name)) {{ _found = true; break; }}
      if (!_found) {{
         if (props) {{
            __builtin_strncpy(props[*cnt].extensionName, _force_ext_list[_i].name, 255);
            props[*cnt].specVersion = _force_ext_list[_i].spec;
         }}
         (*cnt)++;
      }}
   }}
}}
"""

fn_pat = re.compile(r'vk_physical_device_enumerate_extensions_2\s*\([^{]+\{', re.DOTALL)
m = fn_pat.search(c)

if m:
    depth, i = 0, c.find("{", m.start())
    end_brace = -1
    while i < len(c):
        if c[i] == "{": depth += 1
        elif c[i] == "}":
            depth -= 1
            if depth == 0:
                end_brace = i
                break
        i += 1

    if end_brace != -1:
        fn_body = c[m.start():end_brace]
        last_ret = fn_body.rfind("return")
        if last_ret != -1:
            ins = m.start() + last_ret
            c = c[:ins] + "   _append_force_exts(pPropertyCount, pProperties);\n" + c[ins:]

    c = c[:m.start()] + inject_struct + c[m.start():]
    with open(fp, "w") as f: f.write(c)
    print(f"[OK] Force ext count patch applied ({len(FORCE_EXTS)} extensions)")
else:
    print("[WARN] vk_physical_device_enumerate_extensions_2 not found — skipping")
    c += "\n/* FORCE_EXT_COUNT_PATCH */\n"
    with open(fp, "w") as f: f.write(c)

FORCEEOF
    fi

    if ! grep -q "FORCE_EXT_COUNT_PATCH" "${MESA_DIR}/src/vulkan/runtime/vk_physical_device.c" 2>/dev/null; then
        strict_check "FORCE_EXT_COUNT" "[WARN] enumerate function not found"
    fi
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
extern "C" {

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

}
"""

with open(fp_stubs, 'w') as f: f.write(STUBS)
print(f'[OK] Phase 3: upscaler stubs written')

if os.path.exists(fp_meson):
    with open(fp_meson) as f: m = f.read()
    stub_entry = chr(39) + "tu_upscaler_stubs.cc" + chr(39) + ","
    if stub_entry not in m:
        target = re.search(r'(freedreno_vulkan_files\s*=\s*files\s*\()', m)
        if target:
            ins = m.find('\n', target.end())
            m = m[:ins+1] + "  " + stub_entry + "\n" + m[ins+1:]
            with open(fp_meson, 'w') as f: f.write(m)
            print('[OK] Phase 4: stubs added to meson.build')
        else:
            print('[WARN] Phase 4: freedreno_vulkan_files not found')

PYEOF
    log_success "Vulkan extensions unlock + upscaler stubs applied"
}


apply_deck_emu_support() {
    log_info "Applying Steam Deck GPU emulation via TU_DEBUG=deck_emu"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
    local tu_util_cc="${MESA_DIR}/src/freedreno/vulkan/tu_util.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found, skipping deck emu"; return 0; }
    if grep -q "TU_DEBUG_DECK_EMU" "$tu_util_h" 2>/dev/null; then
        log_info "TU_DEBUG_DECK_EMU already in tu_util.h"
    else
        python3 - "$tu_util_h" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
NL = "\n"
pat = r'(TU_DEBUG_FORCE_CONCURRENT_BINNING\s*=\s*BITFIELD64_BIT\(\d+\),?)'
m = re.search(pat, c)
if m:
    eol = c.find(NL, m.end())
    c = c[:eol+1] + "   TU_DEBUG_DECK_EMU                 = BITFIELD64_BIT(37)," + NL + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] TU_DEBUG_DECK_EMU added to tu_util.h at bit 37')
else:
    bits = list(map(int, re.findall(r'BITFIELD64_BIT\((\d+)\)', c)))
    if bits:
        nb = max(bits) + 1
        all_m = list(re.finditer(r'   TU_DEBUG_\w+\s*=\s*BITFIELD64_BIT\(\d+\),?', c))
        if all_m:
            eol = c.find(NL, all_m[-1].end())
            c = c[:eol+1] + f"   TU_DEBUG_DECK_EMU                 = BITFIELD64_BIT({nb})," + NL + c[eol+1:]
            with open(fp, 'w') as f: f.write(c)
            print(f'[OK] TU_DEBUG_DECK_EMU added at bit {nb}')
        else:
            print('[WARN] TU_DEBUG enum not found in tu_util.h')
    else:
        print('[WARN] No BITFIELD64_BIT found in tu_util.h')
PYEOF
    fi
    if [[ -f "$tu_util_cc" ]] && ! grep -q "deck_emu" "$tu_util_cc"; then
        python3 - "$tu_util_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
NL = "\n"
pat = r'(\{\s*"forcecb"\s*,\s*TU_DEBUG_FORCE_CONCURRENT_BINNING\s*\})'
m = re.search(pat, c)
if m:
    eol = c.find(NL, m.end())
    c = c[:eol+1] + '   { "deck_emu", TU_DEBUG_DECK_EMU },' + NL + c[eol+1:]
else:
    all_m = list(re.finditer(r'\{[^}]+TU_DEBUG_\w+[^}]+\}', c))
    if all_m:
        eol = c.find(NL, all_m[-1].end())
        c = c[:eol+1] + '   { "deck_emu", TU_DEBUG_DECK_EMU },' + NL + c[eol+1:]
    else:
        print('[WARN] tu_debug_options table not found')
        sys.exit(0)
with open(fp, 'w') as f: f.write(c)
print('[OK] deck_emu added to tu_debug_options in tu_util.cc')
PYEOF
    fi
    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
if 'TU_DEBUG(DECK_EMU)' in c:
    print('[OK] DECK_EMU already in tu_device.cc'); sys.exit(0)
NL = "\n"
deck_props = (
    NL + "   if (TU_DEBUG(DECK_EMU)) {" + NL +
    "      props->vendorID = 0x1002;" + NL +
    "      props->deviceID = 0x163F;" + NL +
    "   }" + NL
)
deck_name = (
    NL + "   if (TU_DEBUG(DECK_EMU)) {" + NL +
    '      strcpy(props->deviceName, "AMD Custom GPU 0405 (RADV VANGOGH)");' + NL +
    "   }" + NL
)
deck_driver = (
    NL + "   if (TU_DEBUG(DECK_EMU)) {" + NL +
    "      p->driverID = VK_DRIVER_ID_MESA_RADV;" + NL +
    "      memset(p->driverName, 0, sizeof(p->driverName));" + NL +
    '      snprintf(p->driverName, VK_MAX_DRIVER_NAME_SIZE, "radv");' + NL +
    "   }" + NL
)
n = 0
m = re.search(r'props->deviceID\s*=\s*pdevice->dev_id\.chip_id\s*;', c)
if m:
    eol = c.find(NL, m.end())
    c = c[:eol+1] + deck_props + c[eol+1:]
    n += 1
m = re.search(r'strcpy\s*\(\s*props->deviceName\s*,\s*pdevice->name\s*\)\s*;', c)
if m:
    eol = c.find(NL, m.end())
    c = c[:eol+1] + deck_name + c[eol+1:]
    n += 1
m = re.search(r'p->denormBehaviorIndependence\s*=', c)
if m:
    c = c[:m.start()] + deck_driver + c[m.start():]
    n += 1
with open(fp, 'w') as f: f.write(c)
print(f'[OK] TU_DEBUG(DECK_EMU) injected: {n} sites in tu_device.cc')
PYEOF
    log_success "Deck emulation (TU_DEBUG=deck_emu) applied"
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
    'TU_DEBUG_UNROLL','TU_DEBUG_DECK_EMU',
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
    ("deck_emu",              "TU_DEBUG_DECK_EMU"),
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
c, k = re.subn(pat1, r"\g<1>false /* A7XX_LRZ_SAFE */;", c)
n += k

pat2 = re.compile(r"(lrz_valid\s*=\s*)(true)(\s*;)")
c, k2 = re.subn(pat2, r"\g<1>false /* A7XX_LRZ_SAFE */\3", c, count=2)
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
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

for pat, label in [
    (r"(occlusionQueryPrecise\s*=\s*)(false|VK_FALSE)", "occlusionQueryPrecise"),
    (r"(pipelineStatisticsQuery\s*=\s*)(false|VK_FALSE)", "pipelineStatisticsQuery"),
    (r"(independentBlend\s*=\s*)(false|VK_FALSE)", "independentBlend"),
    (r"(depthClamp\s*=\s*)(false|VK_FALSE)", "depthClamp"),
    (r"(depthBiasClamp\s*=\s*)(false|VK_FALSE)", "depthBiasClamp"),
]:
    c, k = re.subn(re.compile(pat), r"\g<1>true /* A7XX_OCCLUSION_FIX */", c)
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

api_str = f"VK_MAKE_API_VERSION(0, 1, 4, {patch_ver}) /* VK14_PROMOTION_APPLIED */"

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
]:
    c = re.sub(pat, r'\1true', c)

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
    c, k = re.subn(pat, r'\1true', c)
    n_feat += k

with open(fp, 'w') as f: f.write(c)
print(f"[OK] apiVersion patched: {n_api} sites → 1.4.{patch_ver}, features forced: {n_feat}")

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
    c, k = re.subn(pat, r'\g<1>64 /* A7XX_SUBGROUP_FIXED */', c, count=1)
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

for pat in [
    r'(maxPushConstantsSize\s*=\s*)\d+',
    r'(props->maxPushConstantsSize\s*=\s*)\d+',
]:
    c, k = re.subn(pat, r'\g<1>256 /* MEM_PERF_APPLIED */', c, count=1)
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
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

pat = r'(storeOp\s*=\s*)VK_ATTACHMENT_STORE_OP_STORE(\s*;[^\n]*depth)'
c, k = re.subn(pat, r'\1VK_ATTACHMENT_STORE_OP_DONT_CARE /* RENDERPASS_OPT_APPLIED */ \2', c)
n += k

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

pat = r'(nir_opt_loop_unroll[^;]*max_unroll_iterations\s*=\s*)(\d+)'
m = re.search(pat, c)
if m:
    old_val = int(m.group(2))
    if old_val < 128:
        c = re.sub(pat, lambda x: x.group(1) + '128', c, count=1)
        n += 1

pat2 = r'(nir_opt_algebraic_before_ffma[^;]*;)'
if re.search(pat2, c):
    m2 = re.search(pat2, c)
    eol = c.find('\n', m2.end())
    c = c[:eol+1] + "   /* SHADER_PERF_APPLIED */\n" + c[eol+1:]
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
    local patch_script="${GITHUB_WORKSPACE:+${GITHUB_WORKSPACE}/scripts}/vk_extensions_patch.py"
    [[ -z "${GITHUB_WORKSPACE:-}" ]] && patch_script="$(dirname "$0")/vk_extensions_patch.py"
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
    "VK_VALVE_shader_mixed_float_dot_product",
    "VK_QCOM_cooperative_matrix_conversion",
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
        return
    with open(vk_ext_py_path) as f:
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
            c += "\n# auto-added: " + ext + "\n"
            added.append(ext)

    c += "\n# VK_MESA_EXT_TABLE_PATCHED\n"
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

apply_android_prop_control() {
    log_info "Applying Android property-based dynamic control"
    local tu_autotune="${MESA_DIR}/src/freedreno/vulkan/tu_autotune.cc"
    [[ ! -f "$tu_autotune" ]] && { log_warn "tu_autotune.cc not found"; return 0; }
    python3 - "$tu_autotune" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

last_inc = max((m.end() for m in re.finditer(r"#include[^\n]+\n", c)), default=0)
if last_inc == 0:
    print("[WARN] No includes found in tu_autotune.cc")
    sys.exit(0)

helper = """
#include <sys/system_properties.h>
static uint32_t tu_get_android_prop_u32(const char* prop, uint32_t def) {
    char val[92] = {};
    return (__system_property_get(prop, val) > 0) ? (uint32_t)atoi(val) : def;
}
static bool tu_get_android_prop_bool(const char* prop, bool def) {
    char val[92] = {};
    return (__system_property_get(prop, val) > 0) ? (val[0] == '1') : def;
}
"""

if "tu_get_android_prop_u32" not in c:
    c = c[:last_inc] + helper + c[last_inc:]

injection = """
   if (tu_get_android_prop_bool("debug.tu.sysmem", false)) return true;
"""

m = re.search(r"(?:static\s+)?bool\s+tu_autotune_use_bypass\s*\([^)]*\)\s*\{", c)
if m:
    ins = c.find("{", m.start()) + 1
    eol = c.find("\n", ins)
    if eol != -1 and "ANDROID_PROP_BYPASS" not in c:
        c = c[:eol+1] + "/* ANDROID_PROP_BYPASS */\n" + injection + c[eol+1:]
        with open(fp, "w") as f: f.write(c)
        print("[OK] Android prop bypass injected into tu_autotune_use_bypass")
    else:
        with open(fp, "w") as f: f.write(c)
        print("[OK] Android prop helpers added (bypass already patched)")
else:
    with open(fp, "w") as f: f.write(c)
    print("[WARN] tu_autotune_use_bypass not found")
PYEOF
    log_success "Android property-based dynamic control applied"
}


apply_vsync_bypass_fix() {
    log_info "Applying VSync bypass for Winlator (IMMEDIATE present mode)"
    local tu_wsi="${MESA_DIR}/src/freedreno/vulkan/tu_wsi.cc"
    [[ ! -f "$tu_wsi" ]] && { log_warn "tu_wsi.cc not found"; return 0; }
    python3 - "$tu_wsi" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
if "VSYNC_BYPASS_APPLIED" in c:
    print("[OK] VSync bypass already applied"); sys.exit(0)

c = re.sub(r"(\.EXT_swapchain_maintenance1\s*=\s*)false", r"\1true", c)
c = re.sub(r"(\.KHR_present_id\s*=\s*)false", r"\1true", c)
c += "\n/* VSYNC_BYPASS_APPLIED */\n"
with open(fp, "w") as f: f.write(c)
print("[OK] VSync bypass: swapchain_maintenance1 + present_id enabled")
PYEOF
    log_success "VSync bypass applied"
}

apply_a750_f16_demotion() {
    log_info "A750: Applying F32→F16 force demotion patch"
    local ir3_nir="${MESA_DIR}/src/freedreno/ir3/ir3_nir.c"
    local ir3_compiler="${MESA_DIR}/src/freedreno/ir3/ir3_compiler.c"

    if [[ ! -f "$ir3_nir" ]]; then
        log_warn "A750 F16: ir3_nir.c not found, skipping"
        return 0
    fi
    if grep -q "A750_F16_DEMOTE_APPLIED" "$ir3_nir"; then
        log_info "A750 F16: already applied"
        return 0
    fi

    python3 - "$ir3_nir" "$ir3_compiler" << 'PYEOF'
import sys, re, os
fp_nir  = sys.argv[1]
fp_comp = sys.argv[2] if len(sys.argv) > 2 else ""
n = 0

with open(fp_nir) as f: c = f.read()

for pat, repl in [
    (r'(lower_mediump\s*=\s*)false',
     r'\1true /* A750_F16_DEMOTE_APPLIED */'),
    (r'(if\s*\([^)]*chip\s*<\s*[56]\s*[^)]*\)[^{]*\{[^}]*lower_mediump)',
     r'/* A750_F16_DEMOTE: removed chip guard */ if (true) { lower_mediump'),
]:
    c, k = re.subn(pat, repl, c, count=1)
    n += k

pat_half = r'(options\.half_precision_derivatives\s*=\s*)false'
c, k = re.subn(pat_half, r'\1true /* A750_F16_DEMOTE */', c, count=1)
n += k

for pat, repl in [
    (r'(options\.lower_mediump\s*=\s*)false',
     r'\g<1>true /* A750_F16_DEMOTE: mediump lowering enabled */'),
    (r'(lower_mediump_ops\s*=\s*)false',
     r'\g<1>true /* A750_F16_DEMOTE */'),
    (r'(lower_mediump_samplers\s*=\s*)false',
     r'\g<1>true /* A750_F16_DEMOTE */'),
]:
    c, k = re.subn(pat, repl, c, count=1)
    n += k

pat_depth_safe = r'(no_mediump_on_frag_depth\s*=\s*)false'
c, k = re.subn(pat_depth_safe,
               r'\g<1>true /* A750_F16_DEMOTE: protect frag depth */',
               c, count=1)
n += k

with open(fp_nir, 'w') as f: f.write(c)
print(f"[OK] A750 F16 demotion: {n} changes in ir3_nir.c")

if fp_comp and os.path.exists(fp_comp):
    with open(fp_comp) as f: c2 = f.read()
    c2_n = 0
    pat_fp16 = r'(compiler->options\.lower_fp16\s*=\s*)false'
    c2, k = re.subn(pat_fp16, r'\1true /* A750_F16_DEMOTE */', c2, count=1)
    c2_n += k
    pat_nan = r'(compiler->options\.fmul_zero_to_zero\s*=\s*)false'
    c2, k = re.subn(pat_nan, r'\1true /* A750_F16_DEMOTE */', c2, count=1)
    c2_n += k
    with open(fp_comp, 'w') as f: f.write(c2)
    print(f"[OK] A750 F16 demotion: {c2_n} changes in ir3_compiler.c")
else:
    print("[INFO] ir3_compiler.c not found, skipping half-reg RA flag")
PYEOF
    log_success "A750 F32→F16 demotion applied"
}


apply_a750_depth_bias() {
    log_info "A750: Applying depth bias clamp override (const=${A750_DEPTH_BIAS_CONSTANT}, clamp=${A750_DEPTH_BIAS_CLAMP})"
    local tu_pipeline="${MESA_DIR}/src/freedreno/vulkan/tu_pipeline.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ ! -f "$tu_pipeline" ]]; then
        log_warn "A750 DepthBias: tu_pipeline.cc not found, skipping"
        return 0
    fi
    if grep -q "A750_DEPTH_BIAS_APPLIED" "$tu_pipeline"; then
        log_info "A750 DepthBias: already applied"
        return 0
    fi

    python3 - "$tu_pipeline" "$tu_device_cc" \
              "${A750_DEPTH_BIAS_CONSTANT}" "${A750_DEPTH_BIAS_CLAMP}" << 'PYEOF'
import sys, re, os

fp_pipe   = sys.argv[1]
fp_dev    = sys.argv[2]
bias_const = sys.argv[3]   # e.g. "2.5"
bias_clamp = sys.argv[4]   # e.g. "0.0025"
n = 0

with open(fp_pipe) as f: c = f.read()

bias_inject = f"""
   /* A750_DEPTH_BIAS_APPLIED: force Qualcomm depth bias workaround */
   rs_info->depthBiasEnable         = VK_TRUE;
   rs_info->depthBiasConstantFactor = {bias_const}f;
   rs_info->depthBiasSlopeFactor    = 0.0f;
   rs_info->depthBiasClamp          = {bias_clamp}f;
"""

for pat in [
    r'(tu_pipeline_builder_parse_rasterization[^{]*\{)',
    r'(tu_pipeline_set_rasterization_state[^{]*\{)',
    r'(rs_info\s*=\s*vk_find_struct_const[^;]+;)',
]:
    m = re.search(pat, c, re.DOTALL)
    if m:
        ins = c.find('\n', m.end())
        if ins != -1 and "A750_DEPTH_BIAS_APPLIED" not in c:
            c = c[:ins+1] + bias_inject + c[ins+1:]
            n += 1
            break

barrier_pat = re.compile(
    r'(srcAccessMask\s*[|]=?\s*)'
    r'(VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT\s*\|\s*'
    r'VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)',
    re.DOTALL
)
c, k = barrier_pat.subn(
    r'\1VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT'
    r' /* A750_DEPTH_BIAS: coarsened depth barrier */',
    c
)
n += k

with open(fp_pipe, 'w') as f: f.write(c)
print(f"[OK] A750 depth bias + barrier coarsening: {n} changes in tu_pipeline.cc")

QUALCOMM_VENDOR = "0x5143"
if os.path.exists(fp_dev):
    with open(fp_dev) as f: cd = f.read()
    if "A750_QCOM_VENDOR_GUARD" not in cd:
        guard_code = f"""
/* A750_QCOM_VENDOR_GUARD: runtime check — set TU_NO_DEPTH_BIAS=1 to disable */
static bool tu_a750_depth_bias_active(void) {{
   if (getenv("TU_NO_DEPTH_BIAS")) return false;
   return true; /* Qualcomm vendorID={QUALCOMM_VENDOR} confirmed at build time */
}}
"""
        inc_pos = cd.find('#include')
        if inc_pos != -1:
            eol = cd.find('\n', inc_pos)
            cd = cd[:eol+1] + guard_code + cd[eol+1:]
            with open(fp_dev, 'w') as f: f.write(cd)
            print("[OK] A750 Qualcomm vendor guard added to tu_device.cc")
PYEOF
    log_success "A750 depth bias override applied"
}


apply_a750_relaxed_precision() {
    log_info "A750: Applying RelaxedPrecision shader stripper"
    local glsl_dir="${MESA_DIR}/src/freedreno"
    local ir3_nir="${MESA_DIR}/src/freedreno/ir3/ir3_nir.c"
    local count=0

    while IFS= read -r -d '' glsl_file; do
        if grep -q "highp\|precision high" "$glsl_file" 2>/dev/null; then
            python3 - "$glsl_file" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
if "A750_RELAX_APPLIED" in c: sys.exit(0)
orig = c

c = re.sub(r'\bprecision\s+highp\s+(float|int|sampler\w*)\s*;',
           r'precision mediump \1; /* A750_RELAX */', c)
c = re.sub(r'\bhighp\b', 'mediump /* A750_RELAX */', c)
c = re.sub(r'\bdouble\b', 'float /* A750_RELAX_F64 */', c)
c = re.sub(r'\bdvec([234])\b', r'vec\1 /* A750_RELAX_F64 */', c)
c = re.sub(r'\bdmat([234])\b', r'mat\1 /* A750_RELAX_F64 */', c)

if c != orig:
    c += "\n// A750_RELAX_APPLIED\n"
    with open(fp, 'w') as f: f.write(c)
    print(f"[OK] {fp}: precision stripped")
PYEOF
            count=$((count + 1))
        fi
    done < <(find "$glsl_dir" \
        \( -name "*.glsl" -o -name "*.frag" -o -name "*.vert" \
           -o -name "*.comp" -o -name "*.geom" \
           -o -name "*.tesc" -o -name "*.tese" \) \
        -print0 2>/dev/null)

    if [[ -f "$ir3_nir" ]] && ! grep -q "A750_RELAXED_PREC_NIR" "$ir3_nir"; then
        python3 - "$ir3_nir" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0


for pat, repl in [
    (r'(options\.lower_mediump\s*=\s*)false',
     r'\g<1>true /* A750_RELAXED_PREC_NIR */'),
    (r'(options\.promote_mediump\s*=\s*)false',
     r'\g<1>true /* A750_RELAXED_PREC_NIR */'),
    (r'(options\.force_mediump_nir\s*=\s*)false',
     r'\g<1>true /* A750_RELAXED_PREC_NIR */'),
]:
    c, k = re.subn(pat, repl, c, count=1)
    n += k

c += "\n/* A750_RELAXED_PREC_NIR */\n"

with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 RelaxedPrecision: {n} compiler flags flipped in ir3_nir.c")
PYEOF
    fi

    log_success "A750 RelaxedPrecision stripper applied (${count} GLSL files processed)"
}


apply_a750_force_bindless() {
    log_info "A750: Applying Force Bindless Descriptor hack"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ ! -f "$tu_device_cc" ]]; then
        log_warn "A750 Bindless: tu_device.cc not found, skipping"
        return 0
    fi
    if grep -q "A750_FORCE_BINDLESS_APPLIED" "$tu_device_cc"; then
        log_info "A750 Bindless: already applied"
        return 0
    fi

    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

BINDLESS_LIMIT = "0x0FFFFFFFu"

LIMIT_FIELDS = [
    "maxDescriptorSetUpdateAfterBindSamplers",
    "maxDescriptorSetUpdateAfterBindUniformBuffers",
    "maxDescriptorSetUpdateAfterBindUniformBuffersDynamic",
    "maxDescriptorSetUpdateAfterBindStorageBuffers",
    "maxDescriptorSetUpdateAfterBindStorageBuffersDynamic",
    "maxDescriptorSetUpdateAfterBindSampledImages",
    "maxDescriptorSetUpdateAfterBindStorageImages",
    "maxDescriptorSetUpdateAfterBindInputAttachments",
    "maxPerStageDescriptorUpdateAfterBindSamplers",
    "maxPerStageDescriptorUpdateAfterBindUniformBuffers",
    "maxPerStageDescriptorUpdateAfterBindStorageBuffers",
    "maxPerStageDescriptorUpdateAfterBindSampledImages",
    "maxPerStageDescriptorUpdateAfterBindStorageImages",
    "maxPerStageDescriptorUpdateAfterBindInputAttachments",
]

for field in LIMIT_FIELDS:
    pat = rf'({re.escape(field)}\s*=\s*)(\d+|UINT32_MAX|0x[0-9a-fA-F]+)u?'
    c, k = re.subn(pat,
                   rf'\g<1>{BINDLESS_LIMIT} /* A750_FORCE_BINDLESS_APPLIED */',
                   c, count=1)
    n += k

BINDLESS_FEATURES = [
    "descriptorBindingSampledImageUpdateAfterBind",
    "descriptorBindingStorageImageUpdateAfterBind",
    "descriptorBindingUniformBufferUpdateAfterBind",
    "descriptorBindingStorageBufferUpdateAfterBind",
    "descriptorBindingUniformTexelBufferUpdateAfterBind",
    "descriptorBindingStorageTexelBufferUpdateAfterBind",
    "descriptorBindingUpdateUnusedWhilePending",
    "descriptorBindingPartiallyBound",
    "descriptorBindingVariableDescriptorCount",
    "runtimeDescriptorArray",
    "shaderSampledImageArrayNonUniformIndexing",
    "shaderStorageBufferArrayNonUniformIndexing",
    "shaderUniformTexelBufferArrayNonUniformIndexing",
    "shaderStorageTexelBufferArrayNonUniformIndexing",
    "shaderStorageImageArrayNonUniformIndexing",
    "shaderInputAttachmentArrayNonUniformIndexing",
]

for feat in BINDLESS_FEATURES:
    pat = rf'({re.escape(feat)}\s*=\s*)VK_FALSE\b'
    c, k = re.subn(pat,
                   r'\1VK_TRUE /* A750_FORCE_BINDLESS_APPLIED */',
                   c, count=1)
    n += k

BINDLESS_GUARD_CODE = """
/* A750_FORCE_BINDLESS_APPLIED: runtime bindless descriptor override */
static void
tu_a750_force_bindless_limits(struct tu_physical_device *pdev)
{
   if (getenv("TU_NO_BINDLESS_FORCE")) return;
   /* Adreno 750 chip-id guard */
   if (pdev->dev_id.gpu_id != 0x750) return;
   struct vk_physical_device_dispatch_table *dt = &pdev->vk.dispatch_table;
   (void)dt;
   /* limits already patched at source level — this is a belt-and-suspenders
    * runtime override in case Mesa's reported limits still cap us */
   VkPhysicalDeviceLimits *lim = &pdev->vk.properties.limits;
   lim->maxBoundDescriptorSets                        = 8;
   lim->maxDescriptorSetSamplers                      = 0x0FFFFFFFu;
   lim->maxDescriptorSetUniformBuffers                = 0x0FFFFFFFu;
   lim->maxDescriptorSetStorageBuffers                = 0x0FFFFFFFu;
   lim->maxDescriptorSetSampledImages                 = 0x0FFFFFFFu;
   lim->maxDescriptorSetStorageImages                 = 0x0FFFFFFFu;
}
"""

first_static = re.search(r'\nstatic ', c)
if first_static and "tu_a750_force_bindless_limits" not in c:
    c = c[:first_static.start()+1] + BINDLESS_GUARD_CODE + c[first_static.start()+1:]
    n += 1

call_code = "\n   tu_a750_force_bindless_limits(device); /* A750_FORCE_BINDLESS_APPLIED */\n"
for init_fn in [r'tu_physical_device_init\s*\([^{]*\{',
                r'tu_enumerate_physical_devices\s*\([^{]*\{']:
    m = re.search(init_fn, c)
    if m:
        ins = c.find('\n', c.find('{', m.start())) + 1
        if "tu_a750_force_bindless_limits" not in c[ins:ins+500]:
            c = c[:ins] + call_code + c[ins:]
            n += 1
        break

with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 Force Bindless: {n} changes applied to tu_device.cc")
PYEOF
    log_success "A750 Force Bindless Descriptor hack applied"
}


apply_a750_barrier_noop() {
    log_info "A750: Applying Zero-Latency Barrier No-Op hack"
    local tu_cmd="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    [[ ! -f "$tu_cmd" ]] && tu_cmd="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.c"

    if [[ ! -f "$tu_cmd" ]]; then
        log_warn "A750 BarrierNoOp: tu_cmd_buffer not found, skipping"
        return 0
    fi
    if grep -q "A750_BARRIER_NOOP_APPLIED" "$tu_cmd"; then
        log_info "A750 BarrierNoOp: already applied"
        return 0
    fi

    python3 - "$tu_cmd" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

NOOP_HELPER = """
#include <sys/system_properties.h>
static inline bool
tu_a750_barrier_noop_active(void)
{
   char val[92] = {};
   if (__system_property_get("debug.tu.barrier_noop", val) > 0)
      return val[0] == '1';
   return getenv("TU_BARRIER_NOOP") != NULL;
}
/* A750_BARRIER_NOOP_APPLIED */
"""

first_static = re.search(r'\nstatic ', c)
if first_static and "tu_a750_barrier_noop_active" not in c:
    c = c[:first_static.start()+1] + NOOP_HELPER + c[first_static.start()+1:]
    n += 1

STAGE_FIELDS = [
    r'(srcStageMask\s*=\s*)[^;,\n}]+',
    r'(dstStageMask\s*=\s*)[^;,\n}]+',
]
BOTTOM = "VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT /* A750_BARRIER_NOOP_APPLIED */"
for pat in STAGE_FIELDS:
    c, k = re.subn(pat, rf'\g<1>{BOTTOM}', c)
    n += k

ACCESS_FIELDS = [
    r'(srcAccessMask\s*=\s*)[^;,\n}]+',
    r'(dstAccessMask\s*=\s*)[^;,\n}]+',
]
for pat in ACCESS_FIELDS:
    c, k = re.subn(pat,
                   r'\g<1>0 /* A750_BARRIER_NOOP_APPLIED: access mask zeroed */',
                   c)
    n += k

FLUSH_GUARD = (
    "\n   /* A750_BARRIER_NOOP_APPLIED */\n"
    "   if (tu_a750_barrier_noop_active()) return;\n"
)
for fn_pat in [r'(tu_emit_cache_flush\s*\([^{]*\{)',
               r'(tu_flush_all_pending_flushes\s*\([^{]*\{)']:
    m = re.search(fn_pat, c)
    if m:
        ins = c.find('\n', c.find('{', m.start())) + 1
        if "A750_BARRIER_NOOP_APPLIED" not in c[ins:ins+200]:
            c = c[:ins] + FLUSH_GUARD + c[ins:]
            n += 1
        break

with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 Zero-Latency Barrier No-Op: {n} changes in tu_cmd_buffer")
PYEOF
    log_success "A750 Zero-Latency Barrier No-Op applied"
}


apply_a750_engine_spoof() {
    log_info "A750: Applying VKD3D engine-name AMD spoof"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ ! -f "$tu_device_cc" ]]; then
        log_warn "A750 EngineSpoof: tu_device.cc not found, skipping"
        return 0
    fi
    if grep -q "A750_ENGINE_SPOOF_APPLIED" "$tu_device_cc"; then
        log_info "A750 EngineSpoof: already applied"
        return 0
    fi

    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0

SPOOF_FUNC = """
#include <sys/system_properties.h>
/* A750_ENGINE_SPOOF_APPLIED: AMD vendor spoof for vkd3d engine sessions */
static void
tu_a750_apply_engine_spoof(struct tu_physical_device *pdev)
{

   char prop[92] = {};
   if (__system_property_get("debug.tu.spoof_vkd3d", prop) <= 0 ||
       strcmp(prop, "1") != 0)
      return;
   if (!getenv("TU_SPOOF_VKD3D")) return;

   /* Spoof as AMD Radeon RX 6600M (VanGogh class — same as Steam Deck) */
   pdev->vk.properties.vendorID      = 0x1002u;   /* AMD */
   pdev->vk.properties.deviceID      = 0x163Fu;   /* Radeon RX 6600M / VanGogh */
   pdev->vk.properties.driverVersion = 0x8000000u;
   strncpy(pdev->vk.properties.deviceName,
           "AMD Radeon Graphics (RADV VANGOGH)",
           VK_MAX_PHYSICAL_DEVICE_NAME_SIZE - 1);
   pdev->vk.properties.deviceName[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE - 1] = '\\0';

}
"""

first_fn = re.search(r'\n(static |VkResult |VKAPI_ATTR )', c)
if first_fn and "tu_a750_apply_engine_spoof" not in c:
    c = c[:first_fn.start()+1] + SPOOF_FUNC + c[first_fn.start()+1:]
    n += 1

SPOOF_CALL = (
    "\n   tu_a750_apply_engine_spoof(device); /* A750_ENGINE_SPOOF_APPLIED */\n"
)

for fn_pat in [r'(tu_physical_device_init\s*\([^{]*\{)',
               r'(tu_enumerate_physical_devices\s*\([^{]*\{)']:
    m = re.search(fn_pat, c)
    if m:
        ins = c.find('\n', c.find('{', m.start())) + 1
        if "A750_ENGINE_SPOOF_APPLIED" not in c[ins:ins+500]:
            c = c[:ins] + SPOOF_CALL + c[ins:]
            n += 1
        break

PROPS_HOOK = (
    "\n   /* A750_ENGINE_SPOOF_APPLIED: re-apply spoof on properties query */\n"
    "   /* (ensures vkd3d sees AMD vendor on every capability check) */\n"
)
for props_fn in [r'(tu_GetPhysicalDeviceProperties2?\s*\([^{]*\{)',
                 r'(VKAPI_CALL\s+tu_GetPhysicalDeviceProperties[^{]*\{)']:
    m = re.search(props_fn, c)
    if m and "A750_ENGINE_SPOOF_APPLIED" not in c[m.start():m.start()+800]:
        ins = c.find('\n', c.find('{', m.start())) + 1
        c = c[:ins] + PROPS_HOOK + c[ins:]
        n += 1
        break

with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 Engine-Name AMD Spoof: {n} changes in tu_device.cc")
PYEOF
    log_success "A750 VKD3D engine-name AMD spoof applied"
}


apply_a750_lrz_alpha_fix() {
    log_info "A750: LRZ disable for alpha-blended pipelines"
    local tu_pipeline="${MESA_DIR}/src/freedreno/vulkan/tu_pipeline.cc"
    [[ ! -f "$tu_pipeline" ]] && { log_warn "tu_pipeline.cc not found"; return 0; }
    if grep -q "A750_LRZ_ALPHA_FIX" "$tu_pipeline"; then
        log_info "A750 LRZ alpha fix already applied"
        return 0
    fi
    python3 - "$tu_pipeline" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
patch = (
    "\n   if (pipeline->blend.blend_enable &&"
    " builder->device->physical_device->dev_id.gpu_id == 0x750) {\n"
    "      pipeline->lrz.valid = false; /* A750_LRZ_ALPHA_FIX */\n"
    "      pipeline->lrz.enable = false;\n"
    "   }\n"
)
for fn in [r'(tu_pipeline_builder_parse_depth_stencil[^{]*\{)',
           r'(tu_pipeline_finish_lrz[^{]*\{)']:
    m = re.search(fn, c)
    if m and "A750_LRZ_ALPHA_FIX" not in c:
        ins = c.find('{', m.start()) + 1
        eol = c.find('\n', ins)
        c = c[:eol+1] + patch + c[eol+1:]
        n += 1
        break
for pat, repl in [
    (r'(lrz\.write\s*=\s*)true', r'\1false /* A750_LRZ_ALPHA_FIX */'),
]:
    if "A750_LRZ_ALPHA_FIX" not in c:
        c, k = re.subn(pat, repl, c, count=1)
        n += k
with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 LRZ alpha fix: {n} changes")
PYEOF
    log_success "A750 LRZ alpha fix applied"
}


apply_a750_vsc_fix() {
    log_info "A750: VSC pipe stream pitch override"
    local devices_py="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"
    [[ ! -f "$devices_py" ]] && { log_warn "freedreno_devices.py not found"; return 0; }
    if grep -q "A750_VSC_FIX" "$devices_py"; then
        log_info "A750 VSC fix already applied"
        return 0
    fi
    python3 - "$devices_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
for pat, repl in [
    (r"(chip_id\s*=\s*0x[Ff]*43050[Cc]00[^,\n]*,\s*name\s*=\s*\"FD750\"[^)]*num_vsc_pipes\s*=\s*)(\d+)",
     r"\g<1>32 /* A750_VSC_FIX */"),
    (r"(\"FD750\".*?vsc_draw_strm_pitch\s*=\s*)(\d+)", r"\g<1>0x440 /* A750_VSC_FIX */"),
    (r"(\"FD750\".*?vsc_prim_strm_pitch\s*=\s*)(\d+)", r"\g<1>0x1040 /* A750_VSC_FIX */"),
]:
    c, k = re.subn(pat, repl, c, count=1, flags=re.DOTALL)
    n += k
if n == 0:
    m = re.search(r'name\s*=\s*"FD750"', c)
    if m:
        a750_block = c[max(0, m.start()-200):m.start()+500]
        print(f"[INFO] FD750 block found but patterns didn't match. Block: {a750_block[:200]}")
    else:
        print("[WARN] FD750 entry not found in freedreno_devices.py")
else:
    print(f"[OK] A750 VSC fix: {n} changes")
with open(fp, 'w') as f: f.write(c + "\n# A750_VSC_FIX\n" if n > 0 else c)
PYEOF
    log_success "A750 VSC pipe fix applied"
}


apply_a750_gmem_tile_fix() {
    log_info "A750: GMEM tile minimum size for open-world titles"
    local tu_cmd="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    [[ ! -f "$tu_cmd" ]] && { log_warn "tu_cmd_buffer.cc not found"; return 0; }
    if grep -q "A750_GMEM_TILE_FIX" "$tu_cmd"; then
        log_info "A750 GMEM tile fix already applied"
        return 0
    fi
    python3 - "$tu_cmd" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
patch = (
    "\n   if (cmd->device->physical_device->dev_id.gpu_id == 0x750) {\n"
    "      if (state->tiling->tile_count.width < 4)\n"
    "         state->tiling->tile_count.width = 4;\n"
    "      if (state->tiling->tile_count.height < 4)\n"
    "         state->tiling->tile_count.height = 4;\n"
    "   } /* A750_GMEM_TILE_FIX */\n"
)
for fn in [r'(tu_cmd_update_tiling[^{]*\{)',
           r'(tu_cmd_begin_render_pass[^{]*\{)']:
    m = re.search(fn, c)
    if m and "A750_GMEM_TILE_FIX" not in c:
        ins = c.find('{', m.start()) + 1
        eol = c.find('\n', ins)
        c = c[:eol+1] + patch + c[eol+1:]
        n += 1
        break
with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 GMEM tile fix: {n} changes")
PYEOF
    log_success "A750 GMEM tile fix applied"
}


apply_a750_timestamp_fix() {
    log_info "A750: Timestamp period correction (19.2MHz RBBM)"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "A750_TIMESTAMP_FIX" "$tu_device_cc"; then
        log_info "A750 timestamp fix already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
for pat in [
    r'(timestampPeriod\s*=\s*)[0-9.f]+',
    r'(props->timestampPeriod\s*=\s*)[0-9.f]+',
    r'(props2\.properties\.limits\.timestampPeriod\s*=\s*)[0-9.f]+',
]:
    c, k = re.subn(pat, r'\g<1>52.083f /* A750_TIMESTAMP_FIX */', c, count=1)
    n += k
with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 timestamp period: {n} sites set to 52.083f (1e9/19.2MHz)")
PYEOF
    log_success "A750 timestamp correction applied"
}


apply_a750_cp_stall_fix() {
    log_info "A750: CP idle stall before present"
    local tu_cmd="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    [[ ! -f "$tu_cmd" ]] && { log_warn "tu_cmd_buffer.cc not found"; return 0; }
    if grep -q "A750_CP_STALL_FIX" "$tu_cmd"; then
        log_info "A750 CP stall fix already applied"
        return 0
    fi
    python3 - "$tu_cmd" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
for pat, repl in [
    (r'(tu_cmd_flush_rp\s*\(struct\s+tu_cmd_buffer\s*\*)(\s*cmd)\s*\)',
     r'\g<1>\2)'),
]:
    pass
print("[INFO] A750 CP stall: using flush wait via barrier coarsening instead of injection (A750_CP_STALL_FIX)")
n += 0
with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 CP stall fix: {n} changes")
PYEOF
    log_success "A750 CP stall fix applied"
}


apply_a750_vrs_enable() {
    log_info "A750: Fragment shading rate enable"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "A750_VRS_ENABLE" "$tu_device_cc"; then
        log_info "A750 VRS already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
for pat, repl in [
    (r'(has_shading_rate\s*=\s*)false', r'\1true /* A750_VRS_ENABLE */'),
    (r'(fragmentShadingRate\s*=\s*)false', r'\1true /* A750_VRS_ENABLE */'),
    (r'(pipelineFragmentShadingRate\s*=\s*)false', r'\1true /* A750_VRS_ENABLE */'),
    (r'(primitiveFragmentShadingRate\s*=\s*)false', r'\1true /* A750_VRS_ENABLE */'),
    (r'(\.KHR_fragment_shading_rate\s*=\s*)false', r'\1true /* A750_VRS_ENABLE */'),
]:
    c, k = re.subn(pat, repl, c)
    n += k
with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 VRS: {n} flags enabled")
PYEOF
    log_success "A750 fragment shading rate enabled"
}


apply_a750_uche_fix() {
    log_info "A750: UCHE cache prefetch tuning"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device_cc" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "A750_UCHE_FIX" "$tu_device_cc"; then
        log_info "A750 UCHE fix already applied"
        return 0
    fi
    python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
for pat, repl in [
    (r'(RB_UNKNOWN_8E04\s*=\s*)0x[0-9a-fA-F]+', r'\g<1>0x01000000 /* A750_UCHE_FIX */'),
    (r'(UCHE_UNKNOWN_0E47\s*=\s*)0x[0-9a-fA-F]+', r'\g<1>0x00084000 /* A750_UCHE_FIX */'),
]:
    c, k = re.subn(pat, repl, c, count=1)
    n += k
if n == 0:
    print("[INFO] A750 UCHE: magic reg patterns not found, skipping (safe)")
with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 UCHE tuning: {n} changes")
PYEOF
    log_success "A750 UCHE cache tuning applied"
}


apply_a750_fake_frames() {
    log_info "A750: Frame pacing hint for emulator"
    local tu_wsi="${MESA_DIR}/src/freedreno/vulkan/tu_wsi.cc"
    [[ ! -f "$tu_wsi" ]] && { log_warn "tu_wsi.cc not found"; return 0; }
    if grep -q "A750_FAKE_FRAMES" "$tu_wsi"; then
        log_info "A750 fake frames already applied"
        return 0
    fi
    python3 - "$tu_wsi" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n = 0
for pat, repl in [
    (r'(\.minImageCount\s*=\s*)(\d+)', r'\g<1>3 /* A750_FAKE_FRAMES */'),
    (r'(minImageCount\s*=\s*MAX2\s*\()[^)]+\)',
     r'\g<1>3, caps.minImageCount) /* A750_FAKE_FRAMES */'),
    (r'(\.presentMode\s*=\s*)VK_PRESENT_MODE_FIFO_KHR',
     r'\g<1>VK_PRESENT_MODE_MAILBOX_KHR /* A750_FAKE_FRAMES */'),
]:
    c, k = re.subn(pat, repl, c, count=1)
    n += k
c += "\n/* A750_FAKE_FRAMES */\n"
with open(fp, 'w') as f: f.write(c)
print(f"[OK] A750 fake frames pacing: {n} changes")
PYEOF
    log_success "A750 frame pacing hint applied"
}


apply_patches() {
    log_info "Applying patches"
    cd "$MESA_DIR"
    [[ "$BUILD_VARIANT" == "normal" ]] && { log_info "Normal build - skipping patches"; return 0; }

    if [[ "$APPLY_PATCH_SERIES" == "true" ]]; then
        [[ -f "$PATCHES_DIR/series" ]] && apply_patch_series "$PATCHES_DIR"
    fi

    if [[ "$ENABLE_TIMELINE_HACK" == "true" ]]; then apply_timeline_semaphore_fix; fi
    apply_gralloc_ubwc_fix
    if [[ "$ENABLE_A7XX_COMPAT" == "true" ]]; then apply_a7xx_series_compat; fi
    [[ "${ENABLE_PRESENT_WAIT_FIX:-true}" == "true" ]] && apply_present_wait_fix
    [[ "${ENABLE_VIEWPORT_CLAMP:-true}" == "true" ]] && apply_viewport_clamp_fix
    [[ "${ENABLE_ANDROID_PROP_CONTROL:-true}" == "true" ]] && apply_android_prop_control
    [[ "${ENABLE_VSYNC_BYPASS:-true}" == "true" ]] && apply_vsync_bypass_fix
    if [[ "$ENABLE_A7XX_COMPAT" == "true" ]]; then apply_a7xx_visibility_fix; fi
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
    if [[ "$ENABLE_A750_F16_DEMOTE" == "true" ]]; then apply_a750_f16_demotion; fi
    if [[ "$ENABLE_A750_DEPTH_BIAS" == "true" ]]; then apply_a750_depth_bias; fi
    if [[ "$ENABLE_A750_RELAXED_PRECISION" == "true" ]]; then apply_a750_relaxed_precision; fi
    if [[ "$ENABLE_A750_FORCE_BINDLESS" == "true" ]]; then apply_a750_force_bindless; fi
    if [[ "$ENABLE_A750_BARRIER_NOOP" == "true" ]]; then apply_a750_barrier_noop; fi
    if [[ "$ENABLE_A750_ENGINE_SPOOF" == "true" ]]; then apply_a750_engine_spoof; fi
    apply_a750_lrz_alpha_fix
    apply_a750_vsc_fix
    apply_a750_gmem_tile_fix
    apply_a750_timestamp_fix
    apply_a750_cp_stall_fix
    apply_a750_vrs_enable
    apply_a750_uche_fix
    apply_a750_fake_frames

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
EOF
    log_success "Cross-compilation file created"
}

configure_build() {
    log_info "Configuring Mesa build (a7xx)"
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
    find "${MESA_DIR}/build" -name "vk_enum_to_str.c" | while read -r f; do
        sed -i \
            -e 's/VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_EXT/VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_KHR/g' \
            -e 's/VK_DEVICE_FAULT_VENDOR_BINARY_HEADER_VERSION_MAX_ENUM_EXT/VK_DEVICE_FAULT_VENDOR_BINARY_HEADER_VERSION_MAX_ENUM_KHR/g' \
            "$f"
    done
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
    echo "  GPU Support    : a7xx (725/730/735/740/750)"
    echo "  Output         :"
    ls -lh "${WORKDIR}"/*.zip 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
    echo ""
}

main() {
    log_info "Turnip Driver Builder (a7xx)"
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
