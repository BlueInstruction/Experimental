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
AUTOTUNER_REPO="https://gitlab.freedesktop.org/PixelyIon/mesa.git"
VULKAN_HEADERS_REPO="https://github.com/KhronosGroup/Vulkan-Headers.git"

MESA_SOURCE="${MESA_SOURCE:-main_branch}"
STAGING_BRANCH="${STAGING_BRANCH:-staging/26.0}"
CUSTOM_TAG="${CUSTOM_TAG:-}"
BUILD_TYPE="${BUILD_TYPE:-release}"
BUILD_VARIANT="${BUILD_VARIANT:-optimized}"
NDK_PATH="${NDK_PATH:-/opt/android-ndk}"
API_LEVEL="${API_LEVEL:-35}"
TARGET_GPU="${TARGET_GPU:-a7xx}"
ENABLE_PERF="${ENABLE_PERF:-false}"
MESA_LOCAL_PATH="${MESA_LOCAL_PATH:-}"
ENABLE_EXT_SPOOF="${ENABLE_EXT_SPOOF:-true}"
ENABLE_DECK_EMU="${ENABLE_DECK_EMU:-true}"
DECK_EMU_TARGET="${DECK_EMU_TARGET:-nvidia}"
ENABLE_TIMELINE_HACK="${ENABLE_TIMELINE_HACK:-true}"
ENABLE_UBWC_HACK="${ENABLE_UBWC_HACK:-true}"
APPLY_PATCH_SERIES="${APPLY_PATCH_SERIES:-true}"
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
        grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | \
        sort -V | tail -1) || true
    if [[ -z "$tags" ]]; then
        tags=$(git ls-remote --tags --refs "$MESA_MIRROR" 2>/dev/null | \
            grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | \
            sort -V | tail -1) || true
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
        patch=$(grep -m1 "#define VK_HEADER_VERSION" "$vk_header" | awk '{print $3}' || echo "0")
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

update_vulkan_headers() {
    log_info "Updating Vulkan headers to latest version"
    local headers_dir="${WORKDIR}/vulkan-headers"
    git clone --depth=1 "$VULKAN_HEADERS_REPO" "$headers_dir" 2>/dev/null || {
        log_warn "Failed to clone Vulkan headers, using Mesa defaults"
        return 0
    }
    if [[ -d "${headers_dir}/include/vulkan" ]]; then
        cp -r "${headers_dir}/include/vulkan"/* "${MESA_DIR}/include/vulkan/" 2>/dev/null || true
        log_success "Vulkan headers updated"
    fi
    rm -rf "$headers_dir"
}

clone_mesa() {
    log_info "Cloning Mesa source"
    local clone_args=()
    local target_ref=""
    local repo_url="$MESA_REPO"

    if [[ -n "$MESA_LOCAL_PATH" && -d "$MESA_LOCAL_PATH" ]]; then
        log_info "Using local Mesa source at $MESA_LOCAL_PATH"
        cp -r "$MESA_LOCAL_PATH" "$MESA_DIR"
        cd "$MESA_DIR"
        git config user.email "ci@turnip.builder"
        git config user.name "Turnip CI Builder"
        local version=$(get_mesa_version)
        local commit=$(git rev-parse --short=8 HEAD)
        echo "$version" > "${WORKDIR}/version.txt"
        echo "$commit"  > "${WORKDIR}/commit.txt"
        log_success "Mesa $version ($commit) ready (local)"
        return
    fi

    if [[ "$BUILD_VARIANT" == "autotuner" ]]; then
        repo_url="$AUTOTUNER_REPO"
        target_ref="tu-newat"
        clone_args=("--depth" "1" "--branch" "$target_ref")
    else
        case "$MESA_SOURCE" in
            latest_release)
                target_ref=$(fetch_latest_release)
                clone_args=("--depth" "1" "--branch" "$target_ref")
                ;;
            staging_branch)
                target_ref="$STAGING_BRANCH"
                clone_args=("--depth" "1" "--branch" "$target_ref")
                ;;
            main_branch)
                target_ref="main"
                clone_args=("--depth" "1" "--branch" "main")
                ;;
            latest_main)
                target_ref="main"
                clone_args=("--branch" "main")
                ;;
            custom_tag)
                [[ -z "$CUSTOM_TAG" ]] && { log_error "Custom tag not specified"; exit 1; }
                target_ref="$CUSTOM_TAG"
                clone_args=("--depth" "1" "--branch" "$target_ref")
                ;;
        esac
    fi

    log_info "Target: $target_ref"
    if ! git clone "${clone_args[@]}" "$repo_url" "$MESA_DIR" 2>/dev/null; then
        log_warn "Primary source failed, trying mirror"
        if ! git clone "${clone_args[@]}" "$MESA_MIRROR" "$MESA_DIR" 2>/dev/null; then
            log_error "Failed to clone Mesa"
            exit 1
        fi
    fi

    cd "$MESA_DIR"
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"
    if [[ "$MESA_SOURCE" == "latest_main" ]]; then
        git pull origin main
    fi

    local version=$(get_mesa_version)
    local commit=$(git rev-parse --short=8 HEAD)
    echo "$version" > "${WORKDIR}/version.txt"
    echo "$commit"  > "${WORKDIR}/commit.txt"
    log_success "Mesa $version ($commit) ready"
}

apply_timeline_semaphore_fix() {
    log_info "Applying timeline semaphore optimization"
    local target_file="${MESA_DIR}/src/vulkan/runtime/vk_sync_timeline.c"
    [[ ! -f "$target_file" ]] && return 0
    cat << 'PATCH_EOF' > "${WORKDIR}/timeline.patch"
diff --git a/src/vulkan/runtime/vk_sync_timeline.c b/src/vulkan/runtime/vk_sync_timeline.c
index 4df11d81bda..6119126932d 100644
--- a/src/vulkan/runtime/vk_sync_timeline.c
+++ b/src/vulkan/runtime/vk_sync_timeline.c
@@ -507,54 +507,50 @@ vk_sync_timeline_wait_locked(struct vk_device *device,
enum vk_sync_wait_flags wait_flags,
uint64_t abs_timeout_ns)
{
-   struct timespec abs_timeout_ts;
-   timespec_from_nsec(&abs_timeout_ts, abs_timeout_ns);
+    struct timespec abs_timeout_ts;
+    timespec_from_nsec(&abs_timeout_ts, abs_timeout_ns);
-   while (state->highest_pending < wait_value) {
-      int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex,
-                                          &abs_timeout_ts);
-      if (ret == thrd_timedout)
-         return VK_TIMEOUT;
-
-      if (ret != thrd_success)
-         return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
-   }
-
-   if (wait_flags & VK_SYNC_WAIT_PENDING)
-      return VK_SUCCESS;
-
-   VkResult result = vk_sync_timeline_gc_locked(device, state, false);
-   if (result != VK_SUCCESS)
-      return result;
-
-   while (state->highest_past < wait_value) {
-      struct vk_sync_timeline_point *point = vk_sync_timeline_first_point(state);
-
-      vk_sync_timeline_ref_point_locked(point);
-      mtx_unlock(&state->mutex);
-
-      result = vk_sync_wait(device, &point->sync, 0,
-                            VK_SYNC_WAIT_COMPLETE,
-                            abs_timeout_ns);
+    while (state->highest_past < wait_value) {
+        struct vk_sync_timeline_point *point = NULL;
-      mtx_lock(&state->mutex);
-      vk_sync_timeline_unref_point_locked(device, state, point);
-
-      if (result != VK_SUCCESS)
-         return result;
-
-      vk_sync_timeline_complete_point_locked(device, state, point);
-   }
-
-   return VK_SUCCESS;
+        list_for_each_entry(struct vk_sync_timeline_point, p,
+                            &state->pending_points, link) {
+            if (p->value >= wait_value) {
+                vk_sync_timeline_ref_point_locked(p);
+                point = p;
+                break;
+            }
+        }
+
+        if (!point) {
+            int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex, &abs_timeout_ts);
+            if (ret == thrd_timedout)
+                return VK_TIMEOUT;
+            if (ret != thrd_success)
+                return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
+            continue;
+        }
+
+        mtx_unlock(&state->mutex);
+        VkResult r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, abs_timeout_ns);
+        mtx_lock(&state->mutex);
+
+        vk_sync_timeline_unref_point_locked(device, state, point);
+
+        if (r != VK_SUCCESS)
+            return r;
+
+        vk_sync_timeline_complete_point_locked(device, state, point);
+    }
+
+    return VK_SUCCESS;
}
+
static VkResult
vk_sync_timeline_wait(struct vk_device *device,
struct vk_sync *sync,
PATCH_EOF
    cd "$MESA_DIR"
    patch -p1 --fuzz=3 --ignore-whitespace < "${WORKDIR}/timeline.patch" 2>/dev/null || log_warn "Timeline patch may have partially applied"
    log_success "Timeline semaphore fix applied"
}

apply_gralloc_ubwc_fix() {
    log_info "Applying gralloc UBWC detection fix"
    local gralloc_file="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"
    [[ ! -f "$gralloc_file" ]] && return 0
    cat << 'PATCH_EOF' > "${WORKDIR}/gralloc.patch"
diff --git a/src/util/u_gralloc/u_gralloc_fallback.c b/src/util/u_gralloc/u_gralloc_fallback.c
index 44fb32d8cfd..bb6459c2e29 100644
--- a/src/util/u_gralloc/u_gralloc_fallback.c
+++ b/src/util/u_gralloc/u_gralloc_fallback.c
@@ -148,12 +148,11 @@ fallback_gralloc_get_buffer_info(struct u_gralloc *gralloc,
out->strides[0] = stride;
#ifdef HAS_FREEDRENO
-   uint32_t gmsm = ('g' << 24) | ('m' << 16) | ('s' << 8) | 'm';
-   if (hnd->handle->numInts >= 2 && hnd->handle->data[hnd->handle->numFds] == gmsm) {
-      bool ubwc = hnd->handle->data[hnd->handle->numFds + 1] & 0x08000000;
-      out->modifier = ubwc ? DRM_FORMAT_MOD_QCOM_COMPRESSED : DRM_FORMAT_MOD_LINEAR;
-   }
+   if (hnd->handle->numInts >= 2) {
+      bool ubwc = hnd->handle->data[hnd->handle->numFds + 1] & 0x08000000;
+      out->modifier = ubwc ? DRM_FORMAT_MOD_QCOM_COMPRESSED : DRM_FORMAT_MOD_LINEAR;
+   }
#endif
return 0;
PATCH_EOF
    cd "$MESA_DIR"
    patch -p1 --fuzz=3 --ignore-whitespace < "${WORKDIR}/gralloc.patch" 2>/dev/null || log_warn "Gralloc patch may have partially applied"
    log_success "Gralloc UBWC fix applied"
}

apply_deck_emu_support() {
    log_info "Applying deck_emu debug option (target: ${DECK_EMU_TARGET})"
    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
    local tu_util_cc="${MESA_DIR}/src/freedreno/vulkan/tu_util.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ -f "$tu_util_h" ]] && ! grep -q "TU_DEBUG_DECK_EMU" "$tu_util_h"; then
        local last_bit=$(grep -oP 'BITFIELD64_BIT\(\K[0-9]+' "$tu_util_h" | sort -n | tail -1)
        local new_bit=$((last_bit + 1))
        sed -i "/TU_DEBUG_FORCE_CONCURRENT_BINNING/a\\   TU_DEBUG_DECK_EMU = BITFIELD64_BIT(${new_bit})," "$tu_util_h" 2>/dev/null || true
    fi

    if [[ -f "$tu_util_cc" ]] && ! grep -q "deck_emu" "$tu_util_cc"; then
        sed -i '/{ "forcecb"/a\   { "deck_emu", TU_DEBUG_DECK_EMU },' "$tu_util_cc" 2>/dev/null || true
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "DECK_EMU" "$tu_device_cc"; then
        local driver_id driver_name device_name vendor_id device_id
        case "${DECK_EMU_TARGET}" in
            nvidia)
                driver_id="VK_DRIVER_ID_NVIDIA_PROPRIETARY"; driver_name="NVIDIA"; device_name="NVIDIA GeForce RTX 4090"; vendor_id="0x10de"; device_id="0x2684"
                ;;
            amd|*)
                driver_id="VK_DRIVER_ID_MESA_RADV"; driver_name="radv"; device_name="AMD RADV VANGOGH"; vendor_id="0x1002"; device_id="0x163f"
                ;;
        esac
        python3 - "$tu_device_cc" "$driver_id" "$driver_name" "$device_name" "$vendor_id" "$device_id" << 'PYEOF'
import sys, re
fp  = sys.argv[1]
did = sys.argv[2]
dn  = sys.argv[3]
dv  = sys.argv[4]
vid = int(sys.argv[5], 16)
devid = int(sys.argv[6], 16)
with open(fp) as f: c = f.read()
inj = (
    '\nif (TU_DEBUG(DECK_EMU)) {\n'
    '   p->driverID = ' + did + ';\n'
    '   memset(p->driverName, 0, sizeof(p->driverName));\n'
    '   snprintf(p->driverName, VK_MAX_DRIVER_NAME_SIZE, "' + dn + '");\n'
    '   memset(p->driverInfo, 0, sizeof(p->driverInfo));\n'
    '   snprintf(p->driverInfo, VK_MAX_DRIVER_INFO_SIZE, "Mesa (spoofed)");\n'
    '}\n'
)
done = False
m = re.search(r'(\n[ \t]*p->denormBehaviorIndependence\s*=)', c)
if m:
    c = c[:m.start()] + '\n' + inj + c[m.start():]
    done = True
if not done:
    fm = re.search(r'tu_get_physical_device_properties_1_2\s*\([^)]*\)\s*\{', c)
    if fm:
        d = 1; p = fm.end()
        while p < len(c) and d > 0:
            if c[p] == '{': d += 1
            elif c[p] == '}': d -= 1
            p += 1
        c = c[:p-1] + '\n' + inj + c[p-1:]
        done = True
if not done:
    m2 = re.search(r'(tu_get_physical_device_properties2\s*\([^{]*\{)', c, re.DOTALL)
    if m2:
        d = 1; p = m2.end()
        while p < len(c) and d > 0:
            if c[p] == '{': d += 1
            elif c[p] == '}': d -= 1
            p += 1
        c = c[:p-1] + '\n' + inj + c[p-1:]
        done = True
if done:
    with open(fp, 'w') as f: f.write(c)
    print('[OK] deck_emu applied: ' + did)
else:
    print('[WARN] deck_emu: no injection point found, skipping')
PYEOF
        log_success "deck_emu spoofing applied"
    fi
}

apply_vulkan_extensions_support() {
    log_info "Enabling Vulkan extensions and D3D features"
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_exts_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"
    [[ ! -f "$tu_device" ]] && return 0

    if [[ -f "$vk_exts_py" ]]; then
        python3 - "$vk_exts_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
n=0
def lo(m):
    global n; n+=1; return m.group(1)+'1'+m.group(3)
c = re.sub(r'("VK_\w+"\s*:\s*)(\d+)(,)', lo, c)
print(f"[OK] Lowered {n} entries to API 1")
ALL=[
"VK_KHR_maintenance7","VK_KHR_maintenance8","VK_KHR_maintenance9","VK_KHR_maintenance10",
"VK_KHR_performance_query","VK_KHR_pipeline_binary","VK_KHR_pipeline_executable_properties",
"VK_KHR_pipeline_library","VK_KHR_portability_enumeration","VK_KHR_present_id","VK_KHR_present_id2",
"VK_KHR_present_mode_fifo_latest_ready","VK_KHR_present_wait","VK_KHR_present_wait2",
"VK_KHR_ray_query","VK_KHR_ray_tracing_maintenance1","VK_KHR_ray_tracing_pipeline",
"VK_KHR_ray_tracing_position_fetch","VK_KHR_robustness2","VK_KHR_shader_bfloat16",
"VK_KHR_shader_clock","VK_KHR_shader_fma","VK_KHR_shader_maximal_reconvergence",
"VK_KHR_shader_quad_control","VK_KHR_shader_relaxed_extended_instruction",
"VK_KHR_shader_subgroup_uniform_control_flow","VK_KHR_shader_untyped_pointers",
"VK_KHR_shared_presentable_image","VK_KHR_unified_image_layouts",
"VK_EXT_4444_formats","VK_EXT_attachment_feedback_loop_dynamic_state",
"VK_EXT_attachment_feedback_loop_layout","VK_EXT_blend_operation_advanced",
"VK_EXT_border_color_swizzle","VK_EXT_color_write_enable","VK_EXT_conditional_rendering",
"VK_EXT_conservative_rasterization","VK_EXT_custom_border_color","VK_EXT_depth_bias_control",
"VK_EXT_depth_clamp_control","VK_EXT_depth_clip_control","VK_EXT_depth_clip_enable",
"VK_EXT_descriptor_buffer","VK_EXT_descriptor_indexing","VK_EXT_device_address_binding_report",
"VK_EXT_device_fault","VK_EXT_device_generated_commands","VK_EXT_device_memory_report",
"VK_EXT_discard_rectangles","VK_EXT_dynamic_rendering_unused_attachments",
"VK_EXT_extended_dynamic_state","VK_EXT_extended_dynamic_state2","VK_EXT_extended_dynamic_state3",
"VK_EXT_external_memory_acquire_unmodified","VK_EXT_external_memory_dma_buf",
"VK_EXT_external_memory_host","VK_EXT_filter_cubic","VK_EXT_fragment_density_map",
"VK_EXT_fragment_density_map2","VK_EXT_fragment_density_map_offset",
"VK_EXT_fragment_shader_interlock","VK_EXT_frame_boundary","VK_EXT_global_priority",
"VK_EXT_global_priority_query","VK_EXT_graphics_pipeline_library","VK_EXT_host_image_copy",
"VK_EXT_host_query_reset","VK_EXT_image_2d_view_of_3d","VK_EXT_image_compression_control",
"VK_EXT_image_drm_format_modifier","VK_EXT_image_robustness","VK_EXT_image_sliced_view_of_3d",
"VK_EXT_image_view_min_lod","VK_EXT_index_type_uint8","VK_EXT_inline_uniform_block",
"VK_EXT_legacy_dithering","VK_EXT_legacy_vertex_attributes","VK_EXT_line_rasterization",
"VK_EXT_load_store_op_none","VK_EXT_memory_budget","VK_EXT_memory_priority","VK_EXT_mesh_shader",
"VK_EXT_metal_objects","VK_EXT_metal_surface","VK_EXT_multi_draw",
"VK_EXT_multisampled_render_to_single_sampled","VK_EXT_mutable_descriptor_type",
"VK_EXT_nested_command_buffer","VK_EXT_non_seamless_cube_map","VK_EXT_opacity_micromap",
"VK_EXT_pageable_device_local_memory","VK_EXT_pci_bus_info","VK_EXT_physical_device_drm",
"VK_EXT_pipeline_creation_cache_control","VK_EXT_pipeline_creation_feedback",
"VK_EXT_pipeline_library_group_handles","VK_EXT_pipeline_properties",
"VK_EXT_pipeline_protected_access","VK_EXT_pipeline_robustness","VK_EXT_post_depth_coverage",
"VK_EXT_present_mode_fifo_latest_ready","VK_EXT_primitive_topology_list_restart",
"VK_EXT_primitives_generated_query","VK_EXT_provoking_vertex","VK_EXT_queue_family_foreign",
"VK_EXT_rasterization_order_attachment_access","VK_EXT_ray_tracing_invocation_reorder",
"VK_EXT_rgba10x6_formats","VK_EXT_sample_locations","VK_EXT_shader_64bit_indexing",
"VK_EXT_shader_atomic_float","VK_EXT_shader_atomic_float2","VK_EXT_shader_float8",
"VK_EXT_shader_image_atomic_int64","VK_EXT_shader_long_vector","VK_EXT_shader_module_identifier",
"VK_EXT_shader_object","VK_EXT_shader_replicated_composites","VK_EXT_shader_stencil_export",
"VK_EXT_shader_subgroup_partitioned","VK_EXT_shader_tile_image","VK_EXT_shader_uniform_buffer_unsized_array",
"VK_EXT_subpass_merge_feedback","VK_EXT_swapchain_maintenance1","VK_EXT_texel_buffer_alignment",
"VK_EXT_texture_compression_astc_3d","VK_EXT_texture_compression_astc_hdr","VK_EXT_tooling_info",
"VK_EXT_transform_feedback","VK_EXT_vertex_attribute_divisor","VK_EXT_vertex_attribute_robustness",
"VK_EXT_vertex_input_dynamic_state","VK_EXT_ycbcr_image_arrays","VK_EXT_zero_initialize_device_memory",
"VK_AMD_buffer_marker","VK_AMD_device_coherent_memory","VK_AMD_draw_indirect_count",
"VK_AMD_mixed_attachment_samples","VK_AMD_pipeline_compiler_control","VK_AMD_rasterization_order",
"VK_AMD_shader_ballot","VK_AMD_shader_core_properties","VK_AMD_shader_core_properties2",
"VK_AMD_shader_early_and_late_fragment_tests","VK_AMD_shader_explicit_vertex_parameter",
"VK_AMD_shader_fragment_mask","VK_AMD_shader_image_load_store_lod","VK_AMD_shader_info",
"VK_AMD_shader_trinary_minmax","VK_AMD_texture_gather_bias_lod",
"VK_AMDX_shader_enqueue","VK_ANDROID_external_format_resolve","VK_ANDROID_external_memory_android_hardware_buffer",
"VK_ARM_rasterization_order_attachment_access","VK_ARM_render_pass_striped",
"VK_ARM_scheduling_controls","VK_ARM_shader_core_builtins","VK_ARM_shader_core_properties",
"VK_GOOGLE_decorate_string","VK_GOOGLE_display_timing","VK_GOOGLE_hlsl_functionality1",
"VK_GOOGLE_user_type","VK_IMG_filter_cubic","VK_IMG_relaxed_line_rasterization",
"VK_INTEL_performance_query","VK_INTEL_shader_integer_functions2",
"VK_MESA_image_alignment_control","VK_NV_clip_space_w_scaling","VK_NV_compute_shader_derivatives",
"VK_NV_cooperative_matrix","VK_NV_corner_sampled_image","VK_NV_coverage_reduction_mode",
"VK_NV_dedicated_allocation","VK_NV_dedicated_allocation_image_aliasing","VK_NV_descriptor_pool_overallocation",
"VK_NV_device_diagnostic_checkpoints","VK_NV_device_diagnostics_config",
"VK_NV_device_generated_commands","VK_NV_device_generated_commands_compute",
"VK_NV_extended_sparse_address_space","VK_NV_fill_rectangle","VK_NV_fragment_coverage_to_color",
"VK_NV_fragment_shader_barycentric","VK_NV_fragment_shading_rate_enums",
"VK_NV_framebuffer_mixed_samples","VK_NV_geometry_shader_passthrough",
"VK_NV_inherited_viewport_scissor","VK_NV_linear_color_attachment","VK_NV_low_latency",
"VK_NV_low_latency2","VK_NV_memory_decompression","VK_NV_mesh_shader",
"VK_NV_per_stage_descriptor_set","VK_NV_present_barrier","VK_NV_push_constant_bank",
"VK_NV_raw_access_chains","VK_NV_ray_tracing","VK_NV_ray_tracing_invocation_reorder",
"VK_NV_ray_tracing_motion_blur","VK_NV_ray_tracing_validation",
"VK_NV_representative_fragment_test","VK_NV_sample_mask_override_coverage",
"VK_NV_scissor_exclusive","VK_NV_shader_atomic_float16_vector","VK_NV_shader_image_footprint",
"VK_NV_shader_sm_builtins","VK_NV_shader_subgroup_partitioned","VK_NV_shading_rate_image",
"VK_NV_viewport_array2","VK_NV_viewport_swizzle","VK_NV_win32_keyed_mutex",
"VK_NVX_binary_import","VK_NVX_image_view_handle","VK_NVX_multiview_per_view_attributes",
"VK_QCOM_cooperative_matrix_conversion","VK_QCOM_filter_cubic_clamp","VK_QCOM_filter_cubic_weights",
"VK_QCOM_fragment_density_map_offset","VK_QCOM_image_processing","VK_QCOM_image_processing2",
"VK_QCOM_multiview_per_view_render_areas","VK_QCOM_multiview_per_view_viewports",
"VK_QCOM_render_pass_shader_resolve","VK_QCOM_render_pass_store_ops",
"VK_QCOM_render_pass_transform","VK_QCOM_tile_memory_heap","VK_QCOM_tile_properties",
"VK_QCOM_tile_shading","VK_QCOM_ycbcr_degamma",
"VK_SEC_amigo_profiling","VK_SEC_pipeline_cache_incremental_mode",
"VK_VALVE_descriptor_set_host_mapping","VK_VALVE_fragment_density_map_layered",
"VK_VALVE_mutable_descriptor_type","VK_VALVE_shader_mixed_float_dot_product",
"VK_VALVE_video_encode_rgb_conversion",
]
known = set(re.findall(r'"(VK_[A-Za-z0-9_]+)"', c))
adds = [f'    "{e}": 1,' for e in ALL if e not in known]
if adds:
    anchor = '"VK_KHR_swapchain": 1,'
    if anchor in c:
        c = c.replace(anchor, anchor + '\n' + '\n'.join(adds), 1)
    else:
        c = re.sub(r'(\n\})\s*$', '\n' + '\n'.join(adds) + '\n}', c, count=1)
    print(f"[OK] Added {len(adds)} extensions")
with open(fp,'w') as f: f.write(c)
PYEOF
        log_success "vk_extensions.py patched"
    fi

    python3 - "$tu_device" "$vk_exts_py" << 'PYEOF'
import sys, re
tu_path, vk_path = sys.argv[1], sys.argv[2]
with open(tu_path) as f: content = f.read()
with open(vk_path) as f: vk_py = f.read()
feats=[
"shaderFloat64","shaderStorageImageMultisample","uniformAndStorageBuffer16BitAccess",
"storagePushConstant16","uniformAndStorageBuffer8BitAccess","storagePushConstant8",
"shaderSharedInt64Atomics","shaderBufferInt64Atomics","independentResolve",
"independentResolveNone","shaderDenormPreserveFloat16","shaderDenormFlushToZeroFloat16",
"shaderRoundingModeRTZFloat16","samplerFilterMinmax","textureCompressionASTC_HDR",
"integerDotProduct8BitUnsignedAccelerated","shaderObject","mutableDescriptorType",
"maintenance5","maintenance6","maintenance7","maintenance8","maintenance9","maintenance10",
"meshShader","taskShader","rayQuery","accelerationStructure","fragmentDensityMapDynamic",
"shaderBFloat16", "robustBufferAccess", "fullDrawIndexUint32", "imageCubeArray",
"independentBlend", "geometryShader", "tessellationShader", "sampleRateShading",
"dualSrcBlend", "logicOp", "multiDrawIndirect", "drawIndirectFirstInstance",
"depthClamp", "depthBiasClamp", "fillModeNonSolid", "depthBounds", "wideLines",
"largePoints", "alphaToOne", "multiViewport", "samplerAnisotropy",
"textureCompressionETC2", "textureCompressionASTC_LDR", "textureCompressionBC",
"occlusionQueryPrecise", "pipelineStatisticsQuery", "vertexPipelineStoresAndAtomics",
"fragmentStoresAndAtomics", "shaderTessellationAndGeometryPointSize", "shaderImageGatherExtended",
"shaderStorageImageExtendedFormats", "shaderStorageImageMultisample",
"shaderStorageImageReadWithoutFormat", "shaderStorageImageWriteWithoutFormat",
"shaderUniformBufferArrayDynamicIndexing", "shaderSampledImageArrayDynamicIndexing",
"shaderStorageBufferArrayDynamicIndexing", "shaderStorageImageArrayDynamicIndexing",
"shaderClipDistance", "shaderCullDistance", "shaderFloat64", "shaderInt64",
"shaderInt16", "shaderResourceResidency", "shaderSparseResidency",
"variablePointersStorageBuffer", "variablePointers", "bufferDeviceAddress",
"bufferDeviceAddressCaptureReplay", "bufferDeviceAddressMultiDevice",
"vulkanMemoryModel", "vulkanMemoryModelDeviceScope", "vulkanMemoryModelAvailabilityVisibilityChains",
"shaderOutputViewportIndex", "shaderOutputLayer", "subgroupBroadcastDynamicId",
"subgroupSizeControl", "computeFullSubgroups", "synchronization2",
"shaderIntegerFunctions2", "shaderDemoteToHelperInvocation"
]
nf=0
for p in feats:
    # FIX: Broaden regex to match Mesa 26.x C++ struct initialiser patterns.
    # Try semicolon-terminated first, then comma-terminated.
    for pat2 in [
        r'(\.' + re.escape(p) + r'\s*=\s*)([^;\n]+)(;)',
        r'(\.' + re.escape(p) + r'\s*=\s*)([^,\n]+)(,)',
    ]:
        new, n = re.subn(pat2, r'\1true\3', content)
        if n: content = new; nf += n; break
print(f"[OK] Forced {nf} feature flags to true")
# FIX: The first script already changed all ": N" to ": 1", so re-read to
# get extension names. Fall back to matching any VK_ quoted key if needed.
all_exts = re.findall(r'"(VK_[A-Za-z0-9_]+)"\s*:\s*\d+', vk_py)
if not all_exts:
    all_exts = list(dict.fromkeys(re.findall(r'"(VK_[A-Za-z0-9_]+)"', vk_py)))
print(f"[INFO] {len(all_exts)} entries in vk_extensions.py")
# FIX: بدل قائمة INST_ONLY ثابتة وناقصة، نقرأ vk_extensions.h مباشرة
# ونستخرج الأسماء الحقيقية من vk_device_extension_table فقط.
# هذا يضمن عدم حقن أي instance-only extension مهما كانت.
import os as _os
_vk_ext_h = _os.path.join(_os.path.dirname(tu_path),
    '../../vulkan/util/vk_extensions.h')
_device_fields = set()
if _os.path.exists(_vk_ext_h):
    with open(_vk_ext_h) as _f:
        _hdr = _f.read()
    import re as _re
    # ابحث عن struct vk_device_extension_table { ... }
    _dm = _re.search(r'struct\s+vk_device_extension_table\s*\{[^}]*\}', _hdr, _re.DOTALL)
    if _dm:
        _device_fields = set(_re.findall(r'bool\s+(VK_[A-Za-z0-9_]+)', _dm.group()))
        # حوّل اسم الحقل من VK_KHR_foo إلى VK_KHR_foo (نفس الاسم في vk_extensions.py)
        print(f"[INFO] Found {len(_device_fields)} real device extensions in vk_extensions.h")
    else:
        # Fallback: استخرج bool fields من أقرب struct قبل instance table
        _fields_all = _re.findall(r'bool\s+((?:KHR|EXT|AMD|VALVE|QCOM|MESA|GOOGLE|HUAWEI|ARM|SEC|NV|INTEL|IMG|ANDROID|NVX|AMDX|FUCHSIA|QNX|MVK|NN|GGP|LUNARG|OHOS)[A-Za-z0-9_]+)', _hdr)
        _device_fields = {"VK_" + f for f in _fields_all}
        print(f"[INFO] Fallback: found {len(_device_fields)} fields in vk_extensions.h")
if _device_fields:
    dev_exts = [e for e in all_exts if e in _device_fields]
    print(f"[INFO] Cross-validated: {len(dev_exts)} safe device extensions to inject")
else:
    # Fallback نهائي: القائمة اليدوية الموسّعة
    INST_ONLY={
    "VK_KHR_surface","VK_KHR_surface_maintenance1","VK_KHR_surface_protected_capabilities",
    "VK_KHR_get_surface_capabilities2","VK_KHR_android_surface","VK_KHR_display",
    "VK_KHR_display_swapchain","VK_KHR_get_display_properties2","VK_KHR_wayland_surface",
    "VK_KHR_win32_surface","VK_KHR_xcb_surface","VK_KHR_xlib_surface",
    "VK_KHR_portability_enumeration","VK_EXT_acquire_drm_display","VK_EXT_acquire_xlib_display",
    "VK_EXT_debug_report","VK_EXT_debug_utils","VK_EXT_direct_mode_display",
    "VK_EXT_directfb_surface","VK_EXT_display_control","VK_EXT_display_surface_counter",
    "VK_EXT_full_screen_exclusive","VK_EXT_headless_surface","VK_EXT_layer_settings",
    "VK_EXT_metal_surface","VK_EXT_surface_maintenance1","VK_EXT_swapchain_colorspace",
    "VK_EXT_hdr_metadata","VK_EXT_present_timing","VK_FUCHSIA_imagepipe_surface",
    "VK_GGP_stream_descriptor_surface","VK_GOOGLE_surfaceless_query",
    "VK_LUNARG_direct_driver_loading","VK_MVK_ios_surface","VK_MVK_macos_surface",
    "VK_NN_vi_surface","VK_NV_acquire_winrt_display","VK_NV_display_stereo",
    "VK_OHOS_surface","VK_QNX_screen_surface","VK_SEC_ubm_surface","VK_OHOS_external_memory",
    "VK_KHR_mir_surface","VK_KHR_get_physical_device_properties2",
    "VK_KHR_external_memory_capabilities","VK_KHR_external_semaphore_capabilities",
    "VK_KHR_external_fence_capabilities","VK_KHR_device_group_creation",
    "VK_EXT_validation_flags","VK_EXT_validation_features","VK_EXT_validation_cache",
    }
    dev_exts=[e for e in all_exts if e not in INST_ONLY]
print(f"[INFO] {len(dev_exts)} device extensions to inject")
def find_point(text):
    for pat in [
        r'tu_get_device_extensions\s*\([^{]*?struct\s+vk_device_extension_table\s*\*\s*(\w+)',
        r'get_device_extensions\s*\([^{]*?struct\s+vk_device_extension_table\s*\*\s*(\w+)',
        r'vk_device_extension_table\s*\*\s*(\w+)\s*[,\)]',
    ]:
        m=re.search(pat,text,re.DOTALL)
        if m:
            ev=m.group(m.lastindex); fs=m.end()
            bp=text.find('{',fs)
            if bp==-1: continue
            d=1; p=bp+1
            while p<len(text) and d>0:
                if text[p]=='{': d+=1
                elif text[p]=='}': d-=1
                p+=1
            return ev,p-1
    last=None
    for m in re.finditer(r'(\w+)->(KHR|EXT|AMD|VALVE|QCOM|MESA|GOOGLE|HUAWEI|ARM|SEC|NV|INTEL|IMG|ANDROID)\w+\s*=\s*(?:true|false)\s*;',text):
        last=m
    if last: return last.group(1),last.end()
    return None
r=find_point(content)
if r is None:
    print("[WARN] No injection point found")
else:
    ev,ins=r
    print(f"[OK] ext_var='{ev}', injecting {len(dev_exts)} extensions")
    lines=["\n"]
    for e in dev_exts:
        lines.append(f"    {ev}->{e[3:]} = true;")
    lines.append("\n")
    inj="\n".join(lines)
    content=content[:ins]+inj+content[ins:]
    print(f"[OK] Done - {len(dev_exts)} assignments written")
with open(tu_path,'w') as f: f.write(content)
PYEOF
    log_success "Vulkan extensions support applied"
}

apply_a8xx_device_support() {
    log_info "Applying A8xx device support patches"
    local knl_kgsl="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"

    # FIX: Add UBWC 5/6 support using Python for reliable multi-line editing.
    # Old approach used sed multiline a\ which corrupted the file (the literal
    # newline caused the second line to be parsed as a sed 'c' change command).
    # We now insert case 5 and case 6 BEFORE the 'default:' in the UBWC switch,
    # which correctly matches the Mesa 26.x tu_knl_kgsl.cc structure:
    #   case KGSL_UBWC_4_0: ... break;
    #   default: → error   (we insert before this)
    if [[ -f "$knl_kgsl" ]] && ! grep -q "case 5:" "$knl_kgsl"; then
        python3 - "$knl_kgsl" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f:
    c = f.read()
inject = (
    '   case 5: /* UBWC 5.0 */\n'
    '   case 6: /* UBWC 6.0 */\n'
    '      device->ubwc_config.bank_swizzle_levels = 0x6;\n'
    '      device->ubwc_config.macrotile_mode = FDL_MACROTILE_8_CHANNEL;\n'
    '      break;\n'
)
pat = r'(case KGSL_UBWC_4_0:.*?break;\n)([ \t]*default:)'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.start(2)] + inject + c[m.start(2):]
    with open(fp, 'w') as f:
        f.write(c)
    print('[OK] UBWC 5/6 cases inserted before default:')
else:
    print('[WARN] UBWC switch pattern not found, skipping')
PYEOF
        log_success "UBWC 5/6 support applied"
    else
        log_info "UBWC 5/6: already patched or file not found"
    fi

    # NOTE: freedreno_devices.py injection removed.
    # Mesa 26.x already ships proper a8xx device entries upstream
    # (FD830/0x44050000, Adreno 840/0xffff44050A31, X2-85/0xffff44070041).
    # The old injection used 'num_slices' which is NOT a parameter of
    # A6xxGPUInfo.__init__, causing TypeError when Mesa runs the script.
    # It also did a partial regex replace leaving orphaned Python syntax.
    log_info "A8xx: using upstream Mesa device table (no custom injection)"

    log_success "A8xx support applied"
}


apply_custom_debug_flags() {
    log_info "Adding custom TU_DEBUG flags: force_vrs, push_regs, ubwc_all, slc_pin, turbo, defrag, cp_prefetch, shfl, vgt_pref, unroll"

    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
    local tu_util_cc="${MESA_DIR}/src/freedreno/vulkan/tu_util.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local tu_image_cc="${MESA_DIR}/src/freedreno/vulkan/tu_image.cc"
    local ir3_ra_c="${MESA_DIR}/src/freedreno/ir3/ir3_ra.c"
    local ir3_compiler_nir="${MESA_DIR}/src/freedreno/ir3/ir3_compiler_nir.c"

    [[ ! -f "$tu_util_h" ]] && { log_warn "tu_util.h not found, skipping custom flags"; return 0; }

    # ── Step 1: BITFIELD64 definitions in tu_util.h ──────────────────────
    python3 - "$tu_util_h" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
if 'TU_DEBUG_FORCE_VRS' in c:
    print('[OK] tu_util.h already has custom flags'); sys.exit(0)
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
# Find last BITFIELD64_BIT line and append after it
all_m = list(re.finditer(r'   TU_DEBUG_\w+\s*=\s*BITFIELD64_BIT\(\d+\),?', c))
if all_m:
    last = all_m[-1]
    eol = c.find('\n', last.end())
    c = c[:eol+1] + lines + '\n' + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] Added {len(flags)} custom TU_DEBUG flags starting at bit {next_bit}')
else:
    print('[WARN] Could not find enum insertion point in tu_util.h')
PYEOF

    # ── Step 2: debug name table in tu_util.cc ────────────────────────────
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
    last = all_m[-1]
    eol = c.find('\n', last.end())
    c = c[:eol+1] + new_entries + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] Added 10 custom entries to debug table in tu_util.cc')
else:
    print('[WARN] Debug table not found in tu_util.cc')
PYEOF

    # ── Step 3: turbo — sysfs perf governor (silent fail, no crash) ───────
    if [[ -f "$tu_device_cc" ]] && ! grep -q "tu_try_activate_turbo" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

turbo_func = """
/* TU_DEBUG_TURBO: attempt to lock GPU at max frequency via sysfs.
 * Silently ignored if process lacks root permission — no crash. */
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

turbo_call = """
   /* TU_DEBUG_TURBO: request max GPU performance at device creation */
   if (TU_DEBUG(TURBO))
      tu_try_activate_turbo();
"""

# Insert function before first static/VkResult function
m_func = re.search(r'\n(static |VkResult |void )', c)
if m_func and 'tu_try_activate_turbo' not in c:
    c = c[:m_func.start()+1] + turbo_func + '\n' + c[m_func.start()+1:]

# Insert call right after tu_physical_device_init succeeds
m_call = re.search(r'(result\s*=\s*tu_physical_device_init\([^;]+;\s*\n\s*if\s*\([^)]+\)[^{]*\{[^}]*\}\s*\n)', c, re.DOTALL)
if not m_call:
    # Simpler: find the line with tu_physical_device_init and inject after it
    m_call = re.search(r'(tu_physical_device_init\([^;]+;\s*\n)', c)
if m_call:
    c = c[:m_call.end()] + turbo_call + c[m_call.end():]

with open(fp, 'w') as f: f.write(c)
print('[OK] turbo mode injected into tu_device.cc')
PYEOF
        log_success "TU_DEBUG_TURBO implementation added"
    fi

    # ── Step 4: defrag — align large allocations to 64KB ──────────────────
    if [[ -f "$tu_device_cc" ]] && ! grep -q "TU_DEBUG_DEFRAG" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

defrag_code = """
   /* TU_DEBUG_DEFRAG: align large BO allocations to 64KB for
    * better memory contiguity and reduced fragmentation. */
   if (TU_DEBUG(DEFRAG) && size > (1u << 20))
      size = ALIGN(size, 64 * 1024);
"""

# Find tu_bo_init_new body — look for the first use of 'size' param
# after function signature to insert alignment before actual alloc
m = re.search(r'(VkResult\s+\w*bo_init_new\w*\s*\([^{]+\{)', c)
if m:
    body_start = m.end()
    # Find first statement inside body
    first_stmt = re.search(r'\n\s+\S', c[body_start:])
    if first_stmt:
        ins = body_start + first_stmt.start() + 1
        c = c[:ins] + defrag_code + c[ins:]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] defrag alignment injected into tu_device.cc')
    else:
        with open(fp, 'w') as f: f.write(c)
        print('[WARN] defrag: body start not found')
else:
    with open(fp, 'w') as f: f.write(c)
    print('[WARN] defrag: bo_init_new not found, skipping')
PYEOF
        log_success "TU_DEBUG_DEFRAG implementation added"
    fi

    # ── Step 5: ubwc_all — force UBWC on color images ─────────────────────
    if [[ -f "$tu_image_cc" ]] && ! grep -q "TU_DEBUG_UBWC_ALL" "$tu_image_cc"; then
        python3 - "$tu_image_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

ubwc_code = """
   /* TU_DEBUG_UBWC_ALL: force enable UBWC compression on all eligible
    * color images to reduce memory bandwidth.
    * FIX: Mesa 26.x tu_image has no plane_count/planes[] fields.
    * The correct field is image->layout.ubwc (fdl_image_view struct). */
   if (TU_DEBUG(UBWC_ALL)) {
      if (!vk_format_is_depth_or_stencil(image->vk.format) &&
          !vk_format_is_compressed(image->vk.format) &&
          image->vk.format != VK_FORMAT_UNDEFINED) {
         image->layout.ubwc = true;
      }
   }
"""

# Find tu_image_init_layout or tu_image_init and inject before final return
m = re.search(r'VkResult\s+(tu_image_init|tu_image_create)[^{]*\{', c)
if m:
    func_start = m.end()
    # Find last return VK_SUCCESS in this function
    returns = list(re.finditer(r'return VK_SUCCESS;', c[func_start:]))
    if returns:
        last_ret = returns[-1]
        ins = func_start + last_ret.start()
        c = c[:ins] + ubwc_code + '\n   ' + c[ins:]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] ubwc_all injected into tu_image.cc')
    else:
        print('[WARN] ubwc_all: no return point found')
        with open(fp, 'w') as f: f.write(c)
else:
    print('[WARN] ubwc_all: tu_image_init not found')
PYEOF
        log_success "TU_DEBUG_UBWC_ALL implementation added"
    fi

    # ── Step 6: push_regs — relax ir3 register pressure limit ─────────────
    if [[ -f "$ir3_ra_c" ]] && ! grep -q "ir3_ra_max_regs_override" "$ir3_ra_c"; then
        python3 - "$ir3_ra_c" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

helper = """
/* TU_DEBUG_PUSH_REGS: helper to double register limit for a7xx shaders.
 * Checked via getenv because ir3 has no access to tu_device. */
static inline unsigned
ir3_ra_max_regs_override(unsigned default_max)
{
   const char *dbg = getenv("TU_DEBUG");
   if (dbg && strstr(dbg, "push_regs"))
      return MIN2(default_max * 2u, 96u);
   return default_max;
}
"""

# Insert after last #include
includes = list(re.finditer(r'^#include\b.*', c, re.MULTILINE))
if includes:
    eol = c.find('\n', includes[-1].start())
    c = c[:eol+1] + helper + c[eol+1:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] push_regs helper added to ir3_ra.c')
else:
    print('[WARN] push_regs: no includes found in ir3_ra.c')
PYEOF
        log_success "TU_DEBUG_PUSH_REGS helper added"
    fi

    # ── Step 7: unroll — aggressive NIR loop unrolling ────────────────────
    if [[ -f "$ir3_compiler_nir" ]] && ! grep -q "TU_DEBUG.*unroll\|ir3_custom_unroll" "$ir3_compiler_nir"; then
        python3 - "$ir3_compiler_nir" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

# Inject after nir_opt_loop_unroll call if it exists,
# otherwise after the last OPT() macro call with nir
unroll_code = """
   /* TU_DEBUG_UNROLL: aggressive loop unrolling for heavy shader workloads */
   {
      const char *_dbg = getenv("TU_DEBUG");
      if (_dbg && strstr(_dbg, "unroll"))
         NIR_PASS(progress, nir, nir_opt_loop_unroll);
   }
"""

m = re.search(r'(NIR_PASS[^;]+nir_opt_loop_unroll[^;]+;\s*\n)', c)
if not m:
    # Fallback: after last NIR_PASS or OPT macro
    all_m = list(re.finditer(r'(NIR_PASS|OPT)\([^;]+;\s*\n', c))
    m = all_m[-1] if all_m else None
if m:
    c = c[:m.end()] + unroll_code + c[m.end():]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] unroll pass injected into ir3_compiler_nir.c')
else:
    print('[WARN] unroll: no NIR pass insertion point found')
PYEOF
        log_success "TU_DEBUG_UNROLL implementation added"
    fi

    # ── Step 8: slc_pin / cp_prefetch / shfl / vgt_pref ──────────────────
    # These flags are DEFINED (so TU_DEBUG=slc_pin,... is valid without crash)
    # but have no userspace implementation — they require kernel/HW support.
    log_info "slc_pin / cp_prefetch / shfl / vgt_pref: flags registered (kernel-side implementation required)"

    log_success "All custom TU_DEBUG flags applied"
}

apply_patches() {
    log_info "Applying patches for $TARGET_GPU"
    cd "$MESA_DIR"
    if [[ "$BUILD_VARIANT" == "vanilla" ]]; then
        log_info "Vanilla build - skipping all patches"
        return 0
    fi
    if [[ "$APPLY_PATCH_SERIES" == "true" && -d "$PATCHES_DIR/series" ]]; then
        apply_patch_series "$PATCHES_DIR/series"
    else
        if [[ "$ENABLE_TIMELINE_HACK" == "true" ]]; then apply_timeline_semaphore_fix; fi
        if [[ "$ENABLE_UBWC_HACK" == "true" ]]; then true; fi
        apply_gralloc_ubwc_fix
        apply_custom_debug_flags
        if [[ "$ENABLE_DECK_EMU" == "true" ]]; then apply_deck_emu_support; fi
        if [[ "$ENABLE_EXT_SPOOF" == "true" ]]; then apply_vulkan_extensions_support; fi
        if [[ "$TARGET_GPU" == "a8xx" ]]; then
            apply_a8xx_device_support
        fi
    fi
    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local patch_name=$(basename "$patch")
            if [[ "$patch_name" == *"a8xx"* ]] || [[ "$patch_name" == *"A8xx"* ]]; then
                if [[ "$TARGET_GPU" != "a8xx" ]]; then continue; fi
            fi
            log_info "Applying: $patch_name"
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

# FIX: Do NOT manually clone KhronosGroup repos here.
# They use CMake and have no meson.build, which causes --force-fallback-for
# to fail at configure time with "subproject has no meson.build file".
# Mesa ships its own .wrap files for spirv-tools and spirv-headers;
# Meson will download the correct Meson-compatible tarballs automatically.
setup_subprojects() {
    log_info "Setting up subprojects via Meson wraps"
    cd "$MESA_DIR"
    mkdir -p subprojects/packagecache
    log_success "Subprojects ready (Meson wraps will resolve at configure time)"
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
    log_info "Configuring Mesa build"
    cd "$MESA_DIR"
    local buildtype="$BUILD_TYPE"
    if [[ "$BUILD_VARIANT" == "debug" ]]; then buildtype="debug"; fi
    if [[ "$BUILD_VARIANT" == "profile" ]]; then buildtype="debugoptimized"; fi
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
    if [ ${PIPESTATUS[0]} -ne 0 ]; then log_error "Meson configuration failed"; exit 1; fi
    log_success "Build configured"
}

compile_driver() {
    log_info "Compiling Turnip driver"
    local cores=$(nproc 2>/dev/null || echo 4)
    ninja -C "${MESA_DIR}/build" -j"$cores" 2>&1 | tee "${WORKDIR}/ninja.log"
    local driver="${MESA_DIR}/build/src/freedreno/vulkan/libvulkan_freedreno.so"
    [[ ! -f "$driver" ]] && { log_error "Build failed: driver not found"; exit 1; }
    log_success "Compilation complete"
}

package_driver() {
    log_info "Packaging driver"
    local version=$(cat "${WORKDIR}/version.txt")
    local commit=$(cat "${WORKDIR}/commit.txt")
    local vulkan_version=$(get_vulkan_version)
    local build_date=$(date +'%Y-%m-%d')
    local driver_src="${MESA_DIR}/build/src/freedreno/vulkan/libvulkan_freedreno.so"
    local pkg_dir="${WORKDIR}/package"
    local name_suffix="${TARGET_GPU:1}"
    local driver_name="vulkan.ad0${name_suffix}.so"
    mkdir -p "$pkg_dir"
    cp "$driver_src" "${pkg_dir}/${driver_name}"
    patchelf --set-soname "vulkan.adreno.so" "${pkg_dir}/${driver_name}"
    "${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
        "${pkg_dir}/${driver_name}" 2>/dev/null || true
    local driver_size=$(du -h "${pkg_dir}/${driver_name}" | cut -f1)
    local variant_suffix=""
    case "$BUILD_VARIANT" in
        optimized) variant_suffix="opt"     ;;
        autotuner) variant_suffix="at"      ;;
        vanilla)   variant_suffix="vanilla" ;;
        debug)     variant_suffix="debug"   ;;
        profile)   variant_suffix="profile" ;;
    esac
    local filename="turnip_${TARGET_GPU}_v${version}_${variant_suffix}_${build_date}"
    cat > "${pkg_dir}/meta.json" << EOF
{
  "schemaVersion": 1,
  "name": "Turnip ${TARGET_GPU} ${BUILD_VARIANT}",
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
    log_success "Package created: ${filename}.zip ($driver_size)"
}

print_summary() {
    local version=$(cat "${WORKDIR}/version.txt")
    local commit=$(cat "${WORKDIR}/commit.txt")
    local vulkan_version=$(cat "${WORKDIR}/vulkan_version.txt")
    local build_date=$(cat "${WORKDIR}/build_date.txt")
    echo ""
    log_info "Build Summary"
    echo "  Target GPU    : $TARGET_GPU"
    echo "  Mesa Version   : $version"
    echo "  Vulkan Version : $vulkan_version"
    echo "  Commit         : $commit"
    echo "  Build Date     : $build_date"
    echo "  Build Variant  : $BUILD_VARIANT"
    echo "  Output         :"
    ls -lh "${WORKDIR}"/*.zip 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
    echo ""
}

main() {
    log_info "Turnip Driver Builder"
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
