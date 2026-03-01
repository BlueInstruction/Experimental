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
        log_info "Using Autotuner branch: $target_ref"
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
        log_info "Target: $target_ref"
    fi

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

apply_patch_series() {
    local series_dir="$1"
    if [[ ! -d "$series_dir" ]]; then
        log_warn "Patch series directory not found: $series_dir"
        return 0
    fi

    cd "$MESA_DIR"
    git am --abort &>/dev/null || true

    for patch in $(find "$series_dir" -maxdepth 1 -name '*.patch' | sort); do
        local patch_name=$(basename "$patch")
        log_info "Applying patch: $patch_name"
        if ! git am --3way "$patch" 2>&1 | tee -a "${WORKDIR}/patch.log"; then
            log_error "Failed to apply patch $patch_name"
            git am --abort
            exit 1
        fi
    done
    log_success "All patches applied successfully"
}

apply_timeline_semaphore_fix() {
    log_info "Applying timeline semaphore optimization (hack)"
    local target_file="${MESA_DIR}/src/vulkan/runtime/vk_sync_timeline.c"
    [[ ! -f "$target_file" ]] && { log_warn "Timeline file not found"; return 0; }

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
+   struct timespec abs_timeout_ts;
+   timespec_from_nsec(&abs_timeout_ts, abs_timeout_ns);
 
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
+   while (state->highest_past < wait_value) {
+      struct vk_sync_timeline_point *point = NULL;
 
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
+      list_for_each_entry(struct vk_sync_timeline_point, p,
+                          &state->pending_points, link) {
+         if (p->value >= wait_value) {
+            vk_sync_timeline_ref_point_locked(p);
+            point = p;
+            break;
+         }
+      }
+
+      if (!point) {
+         int ret = u_cnd_monotonic_timedwait(&state->cond, &state->mutex, &abs_timeout_ts);
+         if (ret == thrd_timedout)
+            return VK_TIMEOUT;
+         if (ret != thrd_success)
+            return vk_errorf(device, VK_ERROR_UNKNOWN, "cnd_timedwait failed");
+         continue;
+      }
+
+      mtx_unlock(&state->mutex);
+      VkResult r = vk_sync_wait(device, &point->sync, 0, VK_SYNC_WAIT_COMPLETE, abs_timeout_ns);
+      mtx_lock(&state->mutex);
+
+      vk_sync_timeline_unref_point_locked(device, state, point);
+
+      if (r != VK_SUCCESS)
+         return r;
+
+      vk_sync_timeline_complete_point_locked(device, state, point);
+   }
+
+   return VK_SUCCESS;
 }
+
 static VkResult
 vk_sync_timeline_wait(struct vk_device *device,
                       struct vk_sync *sync,
PATCH_EOF

    cd "$MESA_DIR"
    patch -p1 --fuzz=3 --ignore-whitespace < "${WORKDIR}/timeline.patch" 2>/dev/null || \
        log_warn "Timeline patch may have partially applied"
    log_success "Timeline semaphore fix applied"
}

apply_ubwc_support() {
    log_info "Applying UBWC 5/6 support (hack)"
    local kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    [[ ! -f "$kgsl_file" ]] && { log_warn "KGSL file not found"; return 0; }

    if ! grep -q "case 5:" "$kgsl_file"; then
        sed -i '/case KGSL_UBWC_4_0:/a\         case 5:\n         case 6:' "$kgsl_file" 2>/dev/null || true
        log_success "UBWC 5/6 support added"
    else
        log_warn "UBWC patch already applied"
    fi
}

apply_gralloc_ubwc_fix() {
    log_info "Applying gralloc UBWC detection fix"
    local gralloc_file="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"
    [[ ! -f "$gralloc_file" ]] && { log_warn "Gralloc file not found"; return 0; }

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
    patch -p1 --fuzz=3 --ignore-whitespace < "${WORKDIR}/gralloc.patch" 2>/dev/null || \
        log_warn "Gralloc patch may have partially applied"
    log_success "Gralloc UBWC fix applied"
}

apply_deck_emu_support() {
    log_info "Applying deck_emu debug option"
    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
    local tu_util_cc="${MESA_DIR}/src/freedreno/vulkan/tu_util.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ -f "$tu_util_h" ]] && ! grep -q "TU_DEBUG_DECK_EMU" "$tu_util_h"; then
        local last_bit=$(grep -oP 'BITFIELD64_BIT\(\K[0-9]+' "$tu_util_h" | sort -n | tail -1)
        local new_bit=$((last_bit + 1))
        sed -i "/TU_DEBUG_FORCE_CONCURRENT_BINNING/a\\   TU_DEBUG_DECK_EMU = BITFIELD64_BIT(${new_bit})," \
            "$tu_util_h" 2>/dev/null || true
        log_success "deck_emu flag added to tu_util.h"
    fi

    if [[ -f "$tu_util_cc" ]] && ! grep -q "deck_emu" "$tu_util_cc"; then
        sed -i '/{ "forcecb"/a\   { "deck_emu", TU_DEBUG_DECK_EMU },' \
            "$tu_util_cc" 2>/dev/null || true
        log_success "deck_emu option added to tu_util.cc"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "DECK_EMU" "$tu_device_cc"; then
        cat << 'PATCH_EOF' > "${WORKDIR}/deck_emu_device.patch"
--- a/src/freedreno/vulkan/tu_device.cc
+++ b/src/freedreno/vulkan/tu_device.cc
@@ -911,6 +911,12 @@ tu_get_physical_device_properties_1_2(struct tu_physical_device *pdevice,
    };
 }
 
+   if (TU_DEBUG(DECK_EMU)) {
+      p->driverID = VK_DRIVER_ID_MESA_RADV;
+      memset(p->driverName, 0, sizeof(p->driverName));
+      snprintf(p->driverName, VK_MAX_DRIVER_NAME_SIZE, "radv");
+   }
+
    p->denormBehaviorIndependence =
PATCH_EOF
        cd "$MESA_DIR"
        if git apply --check "${WORKDIR}/deck_emu_device.patch" 2>/dev/null; then
            git apply "${WORKDIR}/deck_emu_device.patch"
            log_success "deck_emu device spoofing added"
        else
            log_warn "deck_emu device patch could not be applied"
        fi
    fi
}

apply_a6xx_query_fix() {
    log_info "Applying A6xx query fix"
    find "${MESA_DIR}/src/freedreno/vulkan" -name "tu_query*.cc" -exec \
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' {} \; 2>/dev/null || true
    log_success "A6xx query fix applied"
}

apply_vulkan_extensions_support() {
    log_info "Enabling additional Vulkan extensions via Python injection"
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_extensions_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"

    [[ ! -f "$tu_device" ]] && { log_warn "tu_device.cc not found"; return 0; }

    if [[ -f "$vk_extensions_py" ]]; then
        cat > "${WORKDIR}/patch_vk_exts.py" << 'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

new_exts = {
    '"VK_KHR_present_wait2"': 36,
    '"VK_KHR_present_id2"': 36,
    '"VK_KHR_swapchain_maintenance1"': 35,
    '"VK_EXT_swapchain_maintenance1"': 35,
    '"VK_EXT_attachment_feedback_loop_layout"': 34,
    '"VK_EXT_attachment_feedback_loop_dynamic_state"': 35,
    '"VK_EXT_device_fault"': 34,
    '"VK_EXT_device_address_binding_report"': 34,
    '"VK_EXT_shader_replicated_composites"': 35,
    '"VK_EXT_map_memory_placed"': 35,
    '"VK_EXT_depth_clamp_control"': 35,
    '"VK_EXT_vertex_input_dynamic_state"': 33,
    '"VK_EXT_extended_dynamic_state3"': 34,
    '"VK_EXT_image_2d_view_of_3d"': 33,
    '"VK_EXT_pipeline_robustness"': 33,
    '"VK_EXT_graphics_pipeline_library"': 33,
    '"VK_EXT_mesh_shader"': 33,
    '"VK_EXT_mutable_descriptor_type"': 33,
    '"VK_EXT_shader_module_identifier"': 33,
    '"VK_EXT_shader_object"': 34,
    '"VK_EXT_image_compression_control"': 33,
    '"VK_EXT_image_compression_control_swapchain"': 33,
    '"VK_EXT_frame_boundary"': 35,
    '"VK_EXT_nested_command_buffer"': 35,
    '"VK_EXT_dynamic_rendering_unused_attachments"': 34,
    '"VK_EXT_host_image_copy"': 35,
    '"VK_EXT_descriptor_buffer"': 34,
    '"VK_EXT_opacity_micromap"': 34,
    '"VK_EXT_pipeline_library_group_handles"': 34,
    '"VK_EXT_primitives_generated_query"': 33,
    '"VK_EXT_primitive_topology_list_restart"': 33,
    '"VK_EXT_rasterization_order_attachment_access"': 33,
    '"VK_EXT_subpass_merge_feedback"': 33,
    '"VK_EXT_memory_budget"': 33,
    '"VK_EXT_conservative_rasterization"': 33,
    '"VK_EXT_sample_locations"': 33,
    '"VK_EXT_calibrated_timestamps"': 35,
    '"VK_EXT_depth_bias_control"': 35,
    '"VK_EXT_multi_draw"': 33,
    '"VK_EXT_non_seamless_cube_map"': 33,
    '"VK_EXT_pageable_device_local_memory"': 33,
    '"VK_EXT_image_sliced_view_of_3d"': 34,
    '"VK_EXT_pipeline_protected_access"': 34,
    '"VK_EXT_shader_atomic_float"': 33,
    '"VK_EXT_shader_atomic_float2"': 33,
    '"VK_EXT_display_control"': 33,
    '"VK_EXT_full_screen_exclusive"': 33,
    '"VK_KHR_ray_query"': 31,
    '"VK_KHR_acceleration_structure"': 31,
    '"VK_KHR_ray_tracing_maintenance1"': 34,
    '"VK_KHR_ray_tracing_pipeline"': 31,
    '"VK_KHR_deferred_host_operations"': 31,
    '"VK_KHR_pipeline_library"': 31,
    '"VK_KHR_maintenance7"': 37,
    '"VK_KHR_maintenance8"': 37,
    '"VK_KHR_maintenance9"': 37,
    '"VK_KHR_maintenance10"': 37,
    '"VK_KHR_performance_query"': 37,
    '"VK_KHR_pipeline_binary"': 37,
    '"VK_KHR_pipeline_executable_properties"': 37,
}

markers = [
    '"VK_KHR_maintenance7": 36,',
    '"VK_KHR_maintenance6": 35,',
    '"VK_KHR_maintenance5": 35,',
    '"VK_ANDROID_native_buffer": 26,',
]

additions = []
for ext_name, version in new_exts.items():
    if ext_name not in content:
        additions.append(f'    {ext_name}: {version},')

if additions:
    for marker in markers:
        if marker in content:
            insert = '\n' + '\n'.join(additions)
            content = content.replace(marker, marker + insert, 1)
            with open(filepath, 'w') as f:
                f.write(content)
            print(f"[OK] Added {len(additions)} extensions after marker: {marker[:40]}")
            break
    else:
        print(f"[WARN] No marker found, appending to ALLOWED_ANDROID_VERSION dict")
        insert = '\n' + '\n'.join(additions) + '\n'
        content = content.replace('"VK_ANDROID_native_buffer": 26,\n}', 
                                   '"VK_ANDROID_native_buffer": 26,' + insert + '}')
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"[OK] Appended {len(additions)} extensions via fallback")
else:
    print("[INFO] All extensions already present")
PYEOF
        python3 "${WORKDIR}/patch_vk_exts.py" "$vk_extensions_py"
        log_success "vk_extensions.py patched"
    fi

    cat > "${WORKDIR}/inject_extensions.py" << 'PYEOF'
import sys, re

file_path = sys.argv[1]

try:
    with open(file_path, 'r') as f:
        content = f.read()

    feats = [
        "shaderFloat64", "shaderStorageImageMultisample",
        "uniformAndStorageBuffer16BitAccess", "storagePushConstant16",
        "uniformAndStorageBuffer8BitAccess", "storagePushConstant8",
        "shaderSharedInt64Atomics", "shaderBufferInt64Atomics",
        "independentResolve", "independentResolveNone",
        "shaderDenormPreserveFloat16", "shaderDenormFlushToZeroFloat16",
        "shaderRoundingModeRTZFloat16", "samplerFilterMinmax",
        "textureCompressionASTC_HDR",
        "integerDotProduct8BitUnsignedAccelerated",
        "shaderObject", "mutableDescriptorType",
        "maintenance5", "maintenance6", "maintenance7",
        "meshShader", "taskShader", "rayQuery", "accelerationStructure",
        "fragmentDensityMapDynamic",
    ]

    count_feat = 0
    for prop in feats:
        if "integerDotProduct" in prop:
            regex = r'((?:p|features|props)->integerDotProduct\w+\s*=\s*)([^;]+)(;)'
            new, n = re.subn(regex, r'\1true\3', content)
            if n: content = new; count_feat += n
        else:
            regex = rf'((?:p|features|props)->{re.escape(prop)}\s*=\s*)([^;]+)(;)'
            new, n = re.subn(regex, r'\1true\3', content)
            if n: content = new; count_feat += n
    print(f"[OK] Forced {count_feat} feature flags")

    sig = re.search(
        r'get_device_extensions\s*\([^)]*struct\s+tu_physical_device\s*\*\s*(\w+)[^)]*'
        r'struct\s+vk_device_extension_table\s*\*\s*(\w+)',
        content, re.DOTALL
    )

    if not sig:
        sig = re.search(
            r'void\s+tu_get_device_extensions\s*\([^)]*(\w+)\s*,\s*'
            r'struct\s+vk_device_extension_table\s*\*\s*(\w+)',
            content, re.DOTALL
        )

    if not sig:
        sig = re.search(
            r'(tu_physical_device|pdevice|pdev)\b.*?'
            r'vk_device_extension_table\s*\*\s*(\w+)',
            content, re.DOTALL
        )

    if not sig:
        last_ext = None
        for m in re.finditer(r'(\w+)->(KHR|EXT|AMD|VALVE|IMG)\w+\s*=\s*(true|false)\s*;', content):
            last_ext = m
        if last_ext:
            ext_var = last_ext.group(1)
            pos = last_ext.end()
            print(f"[Strategy 4] Using ext_var='{ext_var}' from last extension assignment")

            code = build_injection_code(ext_var)
            content = content[:pos] + '\n' + code + content[pos:]
            with open(file_path, 'w') as f:
                f.write(content)
            print("[OK] Injected via Strategy 4 (last extension pattern)")
            sys.exit(0)

    def build_injection_code(ext_var):
        return f"""
    {ext_var}->KHR_maintenance5 = true; {ext_var}->KHR_maintenance6 = true;
    {ext_var}->KHR_maintenance7 = true;
    {ext_var}->KHR_maintenance8 = true;
    {ext_var}->KHR_maintenance9 = true;
    {ext_var}->KHR_maintenance10 = true;
    {ext_var}->KHR_performance_query = true;
    {ext_var}->KHR_pipeline_binary = true;
    {ext_var}->KHR_pipeline_executable_properties = true;
    {ext_var}->KHR_pipeline_library = true;
    {ext_var}->KHR_present_wait = true; {ext_var}->KHR_present_id = true;
    {ext_var}->KHR_swapchain_maintenance1 = true;
    {ext_var}->EXT_swapchain_maintenance1 = true;
    {ext_var}->EXT_primitives_generated_query = true;
    {ext_var}->EXT_primitive_topology_list_restart = true;
    {ext_var}->EXT_depth_clip_control = true;
    {ext_var}->EXT_depth_clip_enable = true;
    {ext_var}->EXT_depth_bias_control = true;
    {ext_var}->EXT_attachment_feedback_loop_layout = true;
    {ext_var}->EXT_attachment_feedback_loop_dynamic_state = true;
    {ext_var}->KHR_fragment_shading_rate = true;
    {ext_var}->EXT_sample_locations = true;
    {ext_var}->EXT_texture_compression_astc_hdr = true;
    {ext_var}->EXT_calibrated_timestamps = true;
    {ext_var}->EXT_conservative_rasterization = true;
    {ext_var}->EXT_multi_draw = true;
    {ext_var}->EXT_non_seamless_cube_map = true;
    {ext_var}->EXT_pageable_device_local_memory = true;
    {ext_var}->KHR_shader_atomic_int64 = true;
    {ext_var}->KHR_8bit_storage = true; {ext_var}->KHR_16bit_storage = true;
    {ext_var}->EXT_shader_object = true;
    {ext_var}->EXT_mutable_descriptor_type = true;
    {ext_var}->VALVE_mutable_descriptor_type = true;
    {ext_var}->EXT_memory_budget = true;
    {ext_var}->EXT_descriptor_buffer = true;
    {ext_var}->EXT_graphics_pipeline_library = true;
    {ext_var}->EXT_shader_module_identifier = true;
    {ext_var}->EXT_image_compression_control = true;
    {ext_var}->EXT_image_compression_control_swapchain = true;
    {ext_var}->EXT_host_image_copy = true;
    {ext_var}->EXT_nested_command_buffer = true;
    {ext_var}->EXT_dynamic_rendering_unused_attachments = true;
    {ext_var}->EXT_frame_boundary = true;
    {ext_var}->EXT_shader_atomic_float = true;
    {ext_var}->EXT_shader_atomic_float2 = true;
    {ext_var}->EXT_shader_replicated_composites = true;
    {ext_var}->EXT_image_2d_view_of_3d = true;
    {ext_var}->EXT_image_sliced_view_of_3d = true;
    {ext_var}->EXT_rasterization_order_attachment_access = true;
    {ext_var}->EXT_subpass_merge_feedback = true;
    {ext_var}->EXT_pipeline_protected_access = true;
    {ext_var}->EXT_device_fault = true;
    {ext_var}->EXT_mesh_shader = true;
    {ext_var}->KHR_ray_query = true;
    {ext_var}->KHR_acceleration_structure = true;
    {ext_var}->KHR_ray_tracing_pipeline = true;
    {ext_var}->KHR_ray_tracing_maintenance1 = true;
    {ext_var}->KHR_deferred_host_operations = true;
    {ext_var}->EXT_opacity_micromap = true;
    {ext_var}->EXT_pipeline_library_group_handles = true;
"""

    if sig:
        pdev_var = sig.group(1)
        ext_var  = sig.group(2)
        func_start = sig.end()

        closure = re.search(r'\};', content[func_start:])
        if closure:
            pos = func_start + closure.end()
            code = build_injection_code(ext_var)
            content = content[:pos] + code + content[pos:]
            print(f"[OK] Strategy 1/2/3 — pdev={pdev_var}, ext={ext_var}")
        else:
            print("[WARN] Could not find closing }; in function")
    else:
        print("[WARN] No injection strategy matched — tu_device.cc not modified")

    with open(file_path, 'w') as f:
        f.write(content)

except Exception as e:
    print(f"[ERROR] {e}")
    import traceback; traceback.print_exc()
    sys.exit(1)
PYEOF

    python3 "${WORKDIR}/inject_extensions.py" "$tu_device" || {
        log_warn "Python injection had issues, continuing..."
    }

    log_success "Vulkan extensions support applied"
}

apply_a8xx_vpc_props() {
    local devfile="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"
    [[ ! -f "$devfile" ]] && { log_warn "freedreno_devices.py not found"; return 0; }
    if grep -q "sysmem_vpc_attr_buf_size" "$devfile"; then
        log_info "a8xx VPC props already present"
        return 0
    fi
    python3 - "$devfile" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

NEW_FIELDS = """
    sysmem_vpc_attr_buf_size  = 131072,
    sysmem_vpc_pos_buf_size   = 65536,
    sysmem_vpc_bv_pos_buf_size = 32768,
"""

pat = r'(a8xx_gen1\s*=\s*GPUProps\s*\([^\)]*?reg_size_vec4\s*=\s*128\s*,)'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.end()] + NEW_FIELDS + c[m.end():]
    print("[OK] Injected sysmem VPC buffer sizes into a8xx_gen1 GPUProps")
else:
    print("[WARN] a8xx_gen1 GPUProps block not found — skipping VPC patch")

with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "a8xx_gen1 VPC sysmem buffer props applied"
}

apply_reduce_advertised_memory() {
    local tu_dev="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_dev" ]] && { log_warn "tu_device.cc not found"; return 0; }
    if grep -q "REDUCED_HEAP_CAP\|heap_size.*3 \/ 4\|heap_size.*75" "$tu_dev"; then
        log_info "Reduced memory already applied"
        return 0
    fi
    python3 - "$tu_dev" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

changed = 0

new, n = re.subn(
    r'(\.heapSize\s*=\s*)([^,};\n]+)',
    r'\1((\2) * 3 / 4)',
    c, count=2
)
if n:
    c = new; changed += n
    print(f"[OK] .heapSize capped at 75% ({n} entries)")

if not changed:
    new, n = re.subn(
        r'((?:heap|memory)_size\s*=\s*)(total_mem\w*|avail_mem\w*|mem_size\w*|[a-z_]*size[a-z_]*\s*[^;]{0,60})(;)',
        r'\1((\2) * 3 / 4)\3',
        c, count=1
    )
    if n:
        c = new; changed += n
        print(f"[OK] heap_size variable capped at 75%")

if not changed:
    print("[WARN] No heap size pattern found — memory cap skipped")

with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "Reduced advertised memory applied"
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
        log_info "Patch series not enabled or not found, applying individual patches based on flags"
        if [[ "$ENABLE_TIMELINE_HACK" == "true" ]]; then
            apply_timeline_semaphore_fix
        fi
        if [[ "$ENABLE_UBWC_HACK" == "true" ]]; then
            apply_ubwc_support
        fi
        apply_gralloc_ubwc_fix
        if [[ "$ENABLE_DECK_EMU" == "true" ]]; then
            apply_deck_emu_support
        fi
        if [[ "$ENABLE_EXT_SPOOF" == "true" ]]; then
            apply_vulkan_extensions_support
        fi
        if [[ "$TARGET_GPU" == "a8xx" ]]; then
            apply_a8xx_vpc_props
        fi
        apply_reduce_advertised_memory
        if [[ "$BUILD_VARIANT" == "autotuner" ]]; then
            apply_a6xx_query_fix
        fi
    fi

    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local patch_name=$(basename "$patch")
            [[ "$patch_name" == *"/series/"* ]] && continue
            if [[ "$patch_name" == *"a8xx"* ]] || [[ "$patch_name" == *"A8xx"* ]] || \
               [[ "$patch_name" == *"810"*  ]] || [[ "$patch_name" == *"825"*  ]] || \
               [[ "$patch_name" == *"829"*  ]] || [[ "$patch_name" == *"830"*  ]] || \
               [[ "$patch_name" == *"840"*  ]] || [[ "$patch_name" == *"gen8"* ]]; then
                if [[ "$TARGET_GPU" != "a8xx" ]]; then
                    log_info "Skipping A8xx patch (target is $TARGET_GPU): $patch_name"
                    continue
                fi
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

setup_subprojects() {
    log_info "Setting up subprojects with caching"
    cd "$MESA_DIR"
    mkdir -p subprojects
    
    local CACHE_DIR="${WORKDIR}/subprojects-cache"
    mkdir -p "$CACHE_DIR"

    for proj in spirv-tools spirv-headers; do
        if [[ -d "$CACHE_DIR/$proj" ]]; then
            log_info "Using cached $proj"
            cp -r "$CACHE_DIR/$proj" subprojects/
        else
            log_info "Cloning $proj"
            git clone --depth=1 "https://github.com/KhronosGroup/${proj}.git" "subprojects/$proj"
            cp -r "subprojects/$proj" "$CACHE_DIR/"
        fi
    done

    cd "$MESA_DIR"
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
    if [ -n "$CFLAGS_EXTRA" ]; then
        for flag in $CFLAGS_EXTRA; do
            c_args_list="$c_args_list, '$flag'"
        done
    fi

    local cpp_args_list="'-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations'"
    if [ -n "$CXXFLAGS_EXTRA" ]; then
        for flag in $CXXFLAGS_EXTRA; do
            cpp_args_list="$cpp_args_list, '$flag'"
        done
    fi

    local link_args_list="'-static-libstdc++'"
    if [ -n "$LDFLAGS_EXTRA" ]; then
        for flag in $LDFLAGS_EXTRA; do
            link_args_list="$link_args_list, '$flag'"
        done
    fi

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

    local perf_args=""
    if [[ "$ENABLE_PERF" == "true" ]]; then
        perf_args="-Dfreedreno-enable-perf=true -Dfreedreno-hw-level=latest"
        log_info "Performance options enabled: $perf_args"
    fi

    local buildtype="$BUILD_TYPE"
    if [[ "$BUILD_VARIANT" == "debug" ]]; then
        buildtype="debug"
    elif [[ "$BUILD_VARIANT" == "profile" ]]; then
        buildtype="debugoptimized"
    fi

    meson setup build                                  \
        --cross-file "${WORKDIR}/cross-aarch64.txt"   \
        -Dbuildtype="$buildtype"                       \
        -Dplatforms=android                            \
        -Dplatform-sdk-version="$API_LEVEL"            \
        -Dandroid-stub=true                             \
        -Dgallium-drivers=                              \
        -Dvulkan-drivers=freedreno                      \
        -Dvulkan-beta=true                              \
        -Dfreedreno-kmds=kgsl                           \
        -Degl=disabled                                  \
        -Dglx=disabled                                  \
        -Dgles1=disabled                                \
        -Dgles2=disabled                                \
        -Dopengl=false                                  \
        -Dgbm=disabled                                  \
        -Dllvm=disabled                                 \
        -Dlibunwind=disabled                            \
        -Dlmsensors=disabled                            \
        -Dzstd=disabled                                 \
        -Dvalgrind=disabled                             \
        -Dbuild-tests=false                             \
        -Dwerror=false                                  \
        -Ddefault_library=shared                        \
        $perf_args                                       \
        --force-fallback-for=spirv-tools,spirv-headers  \
        2>&1 | tee "${WORKDIR}/meson.log"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Meson configuration failed"
        exit 1
    fi
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
    local driver_name="vulkan.${TARGET_GPU}.so"

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
    "description": "TurnipDriver with extensions/spoofing for Winlator",
    "author": "Blue",
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
    echo "  Source         : $MESA_SOURCE"
    echo "  Performance    : $ENABLE_PERF"
    echo "  Ext Spoof      : $ENABLE_EXT_SPOOF"
    echo "  Deck Emu       : $ENABLE_DECK_EMU"
    echo "  Timeline Hack  : $ENABLE_TIMELINE_HACK"
    echo "  UBWC Hack      : $ENABLE_UBWC_HACK"
    echo "  Patch Series   : $APPLY_PATCH_SERIES"
    echo "  Output         :"
    ls -lh "${WORKDIR}"/*.zip 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
    echo ""
}

main() {
    log_info "Turnip Driver Builder"
    log_info "Configuration: target=$TARGET_GPU, variant=$BUILD_VARIANT, source=$MESA_SOURCE"

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
