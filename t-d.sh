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

# ========== User configurable variables ==========
MESA_SOURCE="${MESA_SOURCE:-main_branch}"          # latest_release, staging_branch, main_branch, custom_tag, latest_main
STAGING_BRANCH="${STAGING_BRANCH:-staging/26.0}"
CUSTOM_TAG="${CUSTOM_TAG:-}"
BUILD_TYPE="${BUILD_TYPE:-release}"
BUILD_VARIANT="${BUILD_VARIANT:-optimized}"        # optimized, autotuner, vanilla, debug, profile
NDK_PATH="${NDK_PATH:-/opt/android-ndk}"
API_LEVEL="${API_LEVEL:-35}"
TARGET_GPU="${TARGET_GPU:-a7xx}"                    # a6xx, a7xx, a8xx
ENABLE_PERF="${ENABLE_PERF:-false}"                 # Enable performance options
MESA_LOCAL_PATH="${MESA_LOCAL_PATH:-}"              # If set, use local Mesa source
ENABLE_EXT_SPOOF="${ENABLE_EXT_SPOOF:-true}"        # Enable Vulkan extension spoofing (improves Winlator compatibility)
ENABLE_DECK_EMU="${ENABLE_DECK_EMU:-true}"          # Enable deck_emu spoofing
DECK_EMU_TARGET="${DECK_EMU_TARGET:-nvidia}"        # Spoof target: nvidia (RTX 4090), amd (Steam Deck/RADV)
ENABLE_TIMELINE_HACK="${ENABLE_TIMELINE_HACK:-true}" # Enable timeline semaphore hack (improves DXVK performance)
ENABLE_UBWC_HACK="${ENABLE_UBWC_HACK:-true}"        # Enable UBWC 5/6 blind enabling (may cause corruption, but improves performance)
APPLY_PATCH_SERIES="${APPLY_PATCH_SERIES:-true}"    # Apply full patch series from patches/series/ if present

# Extra compiler flags – properly handled as list elements
CFLAGS_EXTRA="${CFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
CXXFLAGS_EXTRA="${CXXFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod}"
LDFLAGS_EXTRA="${LDFLAGS_EXTRA:--Wl,--gc-sections}"
# =================================================

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
                clone_args=("--branch" "main")  # Without --depth 1 to allow pulling updates
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

# ================== Patch functions ==================

apply_patch_series() {
    local series_dir="$1"
    if [[ ! -d "$series_dir" ]]; then
        log_warn "Patch series directory not found: $series_dir"
        return 0
    fi

    cd "$MESA_DIR"
    # Abort any previous am session
    git am --abort &>/dev/null || true

    # Apply all .patch files in sorted order
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
    log_info "Applying deck_emu debug option (target: ${DECK_EMU_TARGET})"
    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
    local tu_util_cc="${MESA_DIR}/src/freedreno/vulkan/tu_util.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    # ── Step 1: Add TU_DEBUG_DECK_EMU flag to tu_util.h ──────────────────────
    if [[ -f "$tu_util_h" ]] && ! grep -q "TU_DEBUG_DECK_EMU" "$tu_util_h"; then
        local last_bit=$(grep -oP 'BITFIELD64_BIT\(\K[0-9]+' "$tu_util_h" | sort -n | tail -1)
        local new_bit=$((last_bit + 1))
        sed -i "/TU_DEBUG_FORCE_CONCURRENT_BINNING/a\\   TU_DEBUG_DECK_EMU = BITFIELD64_BIT(${new_bit})," \
            "$tu_util_h" 2>/dev/null || true
        log_success "deck_emu flag added to tu_util.h (bit ${new_bit})"
    fi

    # ── Step 2: Register "deck_emu" debug string in tu_util.cc ───────────────
    if [[ -f "$tu_util_cc" ]] && ! grep -q "deck_emu" "$tu_util_cc"; then
        sed -i '/{ "forcecb"/a\   { "deck_emu", TU_DEBUG_DECK_EMU },' \
            "$tu_util_cc" 2>/dev/null || true
        log_success "deck_emu option added to tu_util.cc"
    fi

    # ── Step 3: Inject spoofing code into tu_device.cc ───────────────────────
    if [[ -f "$tu_device_cc" ]] && ! grep -q "DECK_EMU" "$tu_device_cc"; then

        # Select identity based on DECK_EMU_TARGET
        local driver_id driver_name device_name vendor_id device_id
        case "${DECK_EMU_TARGET}" in
            nvidia)
                # RTX 4090 — Vulkan reports: NVIDIA, proprietary driver
                driver_id="VK_DRIVER_ID_NVIDIA_PROPRIETARY"
                driver_name="NVIDIA"
                device_name="NVIDIA GeForce RTX 4090"
                vendor_id="0x10de"   # NVIDIA PCI vendor ID
                device_id="0x2684"   # RTX 4090 PCI device ID
                log_info "Spoofing as NVIDIA GeForce RTX 4090"
                ;;
            amd|*)
                # Steam Deck GPU — Mesa RADV
                driver_id="VK_DRIVER_ID_MESA_RADV"
                driver_name="radv"
                device_name="AMD RADV VANGOGH"
                vendor_id="0x1002"   # AMD PCI vendor ID
                device_id="0x163f"   # Van Gogh (Steam Deck) PCI device ID
                log_info "Spoofing as AMD Steam Deck (RADV)"
                ;;
        esac

        python3 - "$tu_device_cc" "$driver_id" "$driver_name" "$device_name" \
                                  "$vendor_id" "$device_id" << 'PYEOF'
import sys, re

filepath     = sys.argv[1]
driver_id    = sys.argv[2]
driver_name  = sys.argv[3]
device_name  = sys.argv[4]
vendor_id    = int(sys.argv[5], 16)
device_id    = int(sys.argv[6], 16)

with open(filepath, 'r') as f:
    content = f.read()

# Build injection code
injection = f"""
   if (TU_DEBUG(DECK_EMU)) {{
      /* GPU identity spoof for driver compatibility */
      p->driverID = {driver_id};
      memset(p->driverName, 0, sizeof(p->driverName));
      snprintf(p->driverName, VK_MAX_DRIVER_NAME_SIZE, "{driver_name}");
      memset(p->driverInfo, 0, sizeof(p->driverInfo));
      snprintf(p->driverInfo, VK_MAX_DRIVER_INFO_SIZE, "Mesa (spoofed)");
   }}
"""

injected = False

# Primary: inject BEFORE p->denormBehaviorIndependence (reliable anchor in Mesa)
m = re.search(r'(\n[ \t]*p->denormBehaviorIndependence\s*=)', content)
if m:
    content = content[:m.start()] + '\n' + injection + content[m.start():]
    print(f"[OK] deck_emu {driver_id} injection applied (denorm anchor)")
    injected = True

# Fallback: find the closing of tu_get_physical_device_properties_1_2 by
# locating the function, then counting braces to find real end
if not injected:
    func_m = re.search(r'tu_get_physical_device_properties_1_2\s*\([^)]*\)\s*\{', content)
    if func_m:
        start = func_m.end()
        depth = 1
        pos = start
        while pos < len(content) and depth > 0:
            if content[pos] == '{':
                depth += 1
            elif content[pos] == '}':
                depth -= 1
            pos += 1
        # pos is now just after the closing } of the function
        # inject the block just before that closing }
        insert_at = pos - 1
        content = content[:insert_at] + '\n' + injection + content[insert_at:]
        print(f"[OK] deck_emu {driver_id} injection applied (brace-counting)")
        injected = True

if not injected:
    print(f"[WARN] deck_emu: could not find injection point in tu_device.cc")
    sys.exit(0)

with open(filepath, 'w') as f:
    f.write(content)
PYEOF

        log_success "deck_emu ${DECK_EMU_TARGET} spoofing applied to tu_device.cc"
    else
        log_warn "deck_emu: already applied or tu_device.cc not found"
    fi
}

apply_a6xx_query_fix() {
    log_info "Applying A6xx query fix"
    find "${MESA_DIR}/src/freedreno/vulkan" -name "tu_query*.cc" -exec \
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' {} \; 2>/dev/null || true
    log_success "A6xx query fix applied"
}


# ═══════════════════════════════════════════════════════════════════════════════
apply_vulkan_extensions_support() {
    log_info "Enabling ALL Vulkan extensions via Python injection"
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_exts_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"
    [[ ! -f "$tu_device" ]] && { log_warn "tu_device.cc not found"; return 0; }

    if [[ -f "$vk_exts_py" ]]; then
        python3 - "$vk_exts_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

# Lower ALL API levels to 1
n = 0
def lo(m):
    global n; n += 1
    return m.group(1)+'1'+m.group(3)
c = re.sub(r'("VK_\w+"\s*:\s*)(\d+)(,)', lo, c)
print(f"[OK] Lowered {n} entries to API 1")

ALL=[
"VK_KHR_acceleration_structure","VK_KHR_android_surface","VK_KHR_calibrated_timestamps",
"VK_KHR_compute_shader_derivatives","VK_KHR_cooperative_matrix","VK_KHR_copy_memory_indirect",
"VK_KHR_deferred_host_operations","VK_KHR_depth_clamp_zero_one","VK_KHR_display",
"VK_KHR_display_swapchain","VK_KHR_external_fence_fd","VK_KHR_external_fence_win32",
"VK_KHR_external_memory_fd","VK_KHR_external_memory_win32","VK_KHR_external_semaphore_fd",
"VK_KHR_external_semaphore_win32","VK_KHR_fragment_shader_barycentric",
"VK_KHR_fragment_shading_rate","VK_KHR_get_display_properties2",
"VK_KHR_get_surface_capabilities2","VK_KHR_incremental_present",
"VK_KHR_internally_synchronized_queues","VK_KHR_maintenance7","VK_KHR_maintenance8",
"VK_KHR_maintenance9","VK_KHR_maintenance10","VK_KHR_performance_query",
"VK_KHR_pipeline_binary","VK_KHR_pipeline_executable_properties","VK_KHR_pipeline_library",
"VK_KHR_portability_enumeration","VK_KHR_present_id","VK_KHR_present_id2",
"VK_KHR_present_mode_fifo_latest_ready","VK_KHR_present_wait","VK_KHR_present_wait2",
"VK_KHR_ray_query","VK_KHR_ray_tracing_maintenance1","VK_KHR_ray_tracing_pipeline",
"VK_KHR_ray_tracing_position_fetch","VK_KHR_robustness2","VK_KHR_shader_bfloat16",
"VK_KHR_shader_clock","VK_KHR_shader_fma","VK_KHR_shader_maximal_reconvergence",
"VK_KHR_shader_quad_control","VK_KHR_shader_relaxed_extended_instruction",
"VK_KHR_shader_subgroup_uniform_control_flow","VK_KHR_shader_untyped_pointers",
"VK_KHR_shared_presentable_image","VK_KHR_surface","VK_KHR_surface_maintenance1",
"VK_KHR_surface_protected_capabilities","VK_KHR_swapchain","VK_KHR_swapchain_maintenance1",
"VK_KHR_swapchain_mutable_format","VK_KHR_unified_image_layouts",
"VK_KHR_video_decode_av1","VK_KHR_video_decode_h264","VK_KHR_video_decode_h265",
"VK_KHR_video_decode_queue","VK_KHR_video_decode_vp9","VK_KHR_video_encode_av1",
"VK_KHR_video_encode_h264","VK_KHR_video_encode_h265","VK_KHR_video_encode_intra_refresh",
"VK_KHR_video_encode_quantization_map","VK_KHR_video_encode_queue",
"VK_KHR_video_maintenance1","VK_KHR_video_maintenance2","VK_KHR_video_queue",
"VK_KHR_wayland_surface","VK_KHR_win32_keyed_mutex","VK_KHR_win32_surface",
"VK_KHR_workgroup_memory_explicit_layout","VK_KHR_xcb_surface","VK_KHR_xlib_surface",
"VK_KHR_16bit_storage","VK_KHR_8bit_storage","VK_KHR_bind_memory2",
"VK_KHR_buffer_device_address","VK_KHR_copy_commands2","VK_KHR_create_renderpass2",
"VK_KHR_dedicated_allocation","VK_KHR_depth_stencil_resolve",
"VK_KHR_descriptor_update_template","VK_KHR_device_group","VK_KHR_device_group_creation",
"VK_KHR_draw_indirect_count","VK_KHR_driver_properties","VK_KHR_dynamic_rendering",
"VK_KHR_dynamic_rendering_local_read","VK_KHR_external_fence",
"VK_KHR_external_fence_capabilities","VK_KHR_external_memory",
"VK_KHR_external_memory_capabilities","VK_KHR_external_semaphore",
"VK_KHR_external_semaphore_capabilities","VK_KHR_format_feature_flags2",
"VK_KHR_get_memory_requirements2","VK_KHR_get_physical_device_properties2",
"VK_KHR_global_priority","VK_KHR_image_format_list","VK_KHR_imageless_framebuffer",
"VK_KHR_index_type_uint8","VK_KHR_line_rasterization","VK_KHR_load_store_op_none",
"VK_KHR_maintenance1","VK_KHR_maintenance2","VK_KHR_maintenance3","VK_KHR_maintenance4",
"VK_KHR_maintenance5","VK_KHR_maintenance6","VK_KHR_map_memory2","VK_KHR_multiview",
"VK_KHR_push_descriptor","VK_KHR_relaxed_block_layout","VK_KHR_sampler_mirror_clamp_to_edge",
"VK_KHR_sampler_ycbcr_conversion","VK_KHR_separate_depth_stencil_layouts",
"VK_KHR_shader_atomic_int64","VK_KHR_shader_draw_parameters","VK_KHR_shader_expect_assume",
"VK_KHR_shader_float16_int8","VK_KHR_shader_float_controls","VK_KHR_shader_float_controls2",
"VK_KHR_shader_integer_dot_product","VK_KHR_shader_non_semantic_info",
"VK_KHR_shader_subgroup_extended_types","VK_KHR_shader_subgroup_rotate",
"VK_KHR_shader_terminate_invocation","VK_KHR_spirv_1_4",
"VK_KHR_storage_buffer_storage_class","VK_KHR_synchronization2",
"VK_KHR_timeline_semaphore","VK_KHR_uniform_buffer_standard_layout",
"VK_KHR_variable_pointers","VK_KHR_vertex_attribute_divisor",
"VK_KHR_vulkan_memory_model","VK_KHR_zero_initialize_workgroup_memory",
"VK_EXT_astc_decode_mode","VK_EXT_attachment_feedback_loop_dynamic_state",
"VK_EXT_attachment_feedback_loop_layout","VK_EXT_blend_operation_advanced",
"VK_EXT_border_color_swizzle","VK_EXT_color_write_enable","VK_EXT_conditional_rendering",
"VK_EXT_conservative_rasterization","VK_EXT_custom_border_color","VK_EXT_custom_resolve",
"VK_EXT_debug_utils","VK_EXT_depth_bias_control","VK_EXT_depth_clamp_control",
"VK_EXT_depth_clip_control","VK_EXT_depth_clip_enable","VK_EXT_depth_range_unrestricted",
"VK_EXT_descriptor_heap","VK_EXT_device_address_binding_report","VK_EXT_device_fault",
"VK_EXT_device_generated_commands","VK_EXT_device_memory_report",
"VK_EXT_direct_mode_display","VK_EXT_directfb_surface","VK_EXT_discard_rectangles",
"VK_EXT_display_control","VK_EXT_display_surface_counter",
"VK_EXT_dynamic_rendering_unused_attachments","VK_EXT_extended_dynamic_state3",
"VK_EXT_external_memory_acquire_unmodified","VK_EXT_external_memory_dma_buf",
"VK_EXT_external_memory_host","VK_EXT_external_memory_metal","VK_EXT_filter_cubic",
"VK_EXT_fragment_density_map","VK_EXT_fragment_density_map2",
"VK_EXT_fragment_density_map_offset","VK_EXT_fragment_shader_interlock",
"VK_EXT_frame_boundary","VK_EXT_full_screen_exclusive","VK_EXT_graphics_pipeline_library",
"VK_EXT_hdr_metadata","VK_EXT_headless_surface","VK_EXT_image_2d_view_of_3d",
"VK_EXT_image_compression_control","VK_EXT_image_compression_control_swapchain",
"VK_EXT_image_drm_format_modifier","VK_EXT_image_sliced_view_of_3d",
"VK_EXT_image_view_min_lod","VK_EXT_layer_settings","VK_EXT_legacy_dithering",
"VK_EXT_legacy_vertex_attributes","VK_EXT_map_memory_placed","VK_EXT_memory_budget",
"VK_EXT_memory_decompression","VK_EXT_memory_priority","VK_EXT_mesh_shader",
"VK_EXT_metal_objects","VK_EXT_metal_surface","VK_EXT_multi_draw",
"VK_EXT_multisampled_render_to_single_sampled","VK_EXT_mutable_descriptor_type",
"VK_EXT_nested_command_buffer","VK_EXT_non_seamless_cube_map","VK_EXT_opacity_micromap",
"VK_EXT_pageable_device_local_memory","VK_EXT_pci_bus_info","VK_EXT_physical_device_drm",
"VK_EXT_pipeline_library_group_handles","VK_EXT_pipeline_properties",
"VK_EXT_post_depth_coverage","VK_EXT_present_timing","VK_EXT_primitive_topology_list_restart",
"VK_EXT_primitives_generated_query","VK_EXT_provoking_vertex","VK_EXT_queue_family_foreign",
"VK_EXT_rasterization_order_attachment_access","VK_EXT_ray_tracing_invocation_reorder",
"VK_EXT_rgba10x6_formats","VK_EXT_sample_locations","VK_EXT_shader_64bit_indexing",
"VK_EXT_shader_atomic_float","VK_EXT_shader_atomic_float2","VK_EXT_shader_float8",
"VK_EXT_shader_image_atomic_int64","VK_EXT_shader_long_vector",
"VK_EXT_shader_module_identifier","VK_EXT_shader_object","VK_EXT_shader_replicated_composites",
"VK_EXT_shader_stencil_export","VK_EXT_shader_subgroup_partitioned",
"VK_EXT_shader_tile_image","VK_EXT_shader_uniform_buffer_unsized_array",
"VK_EXT_subpass_merge_feedback","VK_EXT_swapchain_colorspace",
"VK_EXT_texture_compression_astc_3d","VK_EXT_transform_feedback","VK_EXT_validation_cache",
"VK_EXT_vertex_input_dynamic_state","VK_EXT_ycbcr_image_arrays",
"VK_EXT_zero_initialize_device_memory","VK_EXT_4444_formats",
"VK_EXT_buffer_device_address","VK_EXT_calibrated_timestamps","VK_EXT_debug_marker",
"VK_EXT_debug_report","VK_EXT_depth_clamp_zero_one","VK_EXT_descriptor_buffer",
"VK_EXT_descriptor_indexing","VK_EXT_extended_dynamic_state","VK_EXT_extended_dynamic_state2",
"VK_EXT_global_priority","VK_EXT_global_priority_query","VK_EXT_host_image_copy",
"VK_EXT_host_query_reset","VK_EXT_image_robustness","VK_EXT_index_type_uint8",
"VK_EXT_inline_uniform_block","VK_EXT_line_rasterization","VK_EXT_load_store_op_none",
"VK_EXT_pipeline_creation_cache_control","VK_EXT_pipeline_creation_feedback",
"VK_EXT_pipeline_protected_access","VK_EXT_pipeline_robustness",
"VK_EXT_present_mode_fifo_latest_ready","VK_EXT_private_data","VK_EXT_robustness2",
"VK_EXT_sampler_filter_minmax","VK_EXT_scalar_block_layout","VK_EXT_separate_stencil_usage",
"VK_EXT_shader_demote_to_helper_invocation","VK_EXT_shader_subgroup_ballot",
"VK_EXT_shader_subgroup_vote","VK_EXT_shader_viewport_index_layer",
"VK_EXT_subgroup_size_control","VK_EXT_surface_maintenance1","VK_EXT_swapchain_maintenance1",
"VK_EXT_texel_buffer_alignment","VK_EXT_texture_compression_astc_hdr","VK_EXT_tooling_info",
"VK_EXT_validation_features","VK_EXT_validation_flags","VK_EXT_vertex_attribute_divisor",
"VK_EXT_vertex_attribute_robustness","VK_EXT_ycbcr_2plane_444_formats",
"VK_AMD_anti_lag","VK_AMD_buffer_marker","VK_AMD_device_coherent_memory",
"VK_AMD_display_native_hdr","VK_AMD_draw_indirect_count","VK_AMD_gcn_shader",
"VK_AMD_gpu_shader_half_float","VK_AMD_gpu_shader_int16",
"VK_AMD_memory_overallocation_behavior","VK_AMD_mixed_attachment_samples",
"VK_AMD_negative_viewport_height","VK_AMD_pipeline_compiler_control",
"VK_AMD_rasterization_order","VK_AMD_shader_ballot","VK_AMD_shader_core_properties",
"VK_AMD_shader_core_properties2","VK_AMD_shader_early_and_late_fragment_tests",
"VK_AMD_shader_explicit_vertex_parameter","VK_AMD_shader_fragment_mask",
"VK_AMD_shader_image_load_store_lod","VK_AMD_shader_info","VK_AMD_shader_trinary_minmax",
"VK_AMD_texture_gather_bias_lod",
"VK_ANDROID_external_format_resolve","VK_ANDROID_external_memory_android_hardware_buffer",
"VK_ARM_data_graph","VK_ARM_format_pack","VK_ARM_performance_counters_by_region",
"VK_ARM_pipeline_opacity_micromap","VK_ARM_rasterization_order_attachment_access",
"VK_ARM_render_pass_striped","VK_ARM_scheduling_controls","VK_ARM_shader_core_builtins",
"VK_ARM_shader_core_properties","VK_ARM_tensors",
"VK_FUCHSIA_buffer_collection","VK_FUCHSIA_external_memory","VK_FUCHSIA_external_semaphore",
"VK_FUCHSIA_imagepipe_surface",
"VK_GGP_frame_token","VK_GGP_stream_descriptor_surface",
"VK_GOOGLE_decorate_string","VK_GOOGLE_display_timing","VK_GOOGLE_hlsl_functionality1",
"VK_GOOGLE_surfaceless_query","VK_GOOGLE_user_type",
"VK_HUAWEI_cluster_culling_shader","VK_HUAWEI_hdr_vivid","VK_HUAWEI_invocation_mask",
"VK_HUAWEI_subpass_shading",
"VK_IMG_filter_cubic","VK_IMG_format_pvrtc","VK_IMG_relaxed_line_rasterization",
"VK_INTEL_performance_query","VK_INTEL_shader_integer_functions2",
"VK_LUNARG_direct_driver_loading","VK_MESA_image_alignment_control",
"VK_MSFT_layered_driver","VK_MVK_ios_surface","VK_MVK_macos_surface","VK_NN_vi_surface",
"VK_NV_acquire_winrt_display","VK_NV_clip_space_w_scaling",
"VK_NV_cluster_acceleration_structure","VK_NV_command_buffer_inheritance",
"VK_NV_compute_occupancy_priority","VK_NV_compute_shader_derivatives",
"VK_NV_cooperative_matrix","VK_NV_cooperative_matrix2","VK_NV_cooperative_vector",
"VK_NV_copy_memory_indirect","VK_NV_corner_sampled_image","VK_NV_coverage_reduction_mode",
"VK_NV_dedicated_allocation","VK_NV_dedicated_allocation_image_aliasing",
"VK_NV_descriptor_pool_overallocation","VK_NV_device_diagnostic_checkpoints",
"VK_NV_device_diagnostics_config","VK_NV_device_generated_commands",
"VK_NV_device_generated_commands_compute","VK_NV_displacement_micromap",
"VK_NV_display_stereo","VK_NV_extended_sparse_address_space","VK_NV_external_compute_queue",
"VK_NV_external_memory","VK_NV_external_memory_capabilities","VK_NV_external_memory_rdma",
"VK_NV_external_memory_win32","VK_NV_fill_rectangle","VK_NV_fragment_coverage_to_color",
"VK_NV_fragment_shader_barycentric","VK_NV_fragment_shading_rate_enums",
"VK_NV_framebuffer_mixed_samples","VK_NV_geometry_shader_passthrough","VK_NV_glsl_shader",
"VK_NV_inherited_viewport_scissor","VK_NV_linear_color_attachment","VK_NV_low_latency",
"VK_NV_low_latency2","VK_NV_memory_decompression","VK_NV_mesh_shader","VK_NV_optical_flow",
"VK_NV_partitioned_acceleration_structure","VK_NV_per_stage_descriptor_set",
"VK_NV_present_barrier","VK_NV_push_constant_bank","VK_NV_raw_access_chains",
"VK_NV_ray_tracing","VK_NV_ray_tracing_invocation_reorder",
"VK_NV_ray_tracing_linear_swept_spheres","VK_NV_ray_tracing_motion_blur",
"VK_NV_ray_tracing_validation","VK_NV_representative_fragment_test",
"VK_NV_sample_mask_override_coverage","VK_NV_scissor_exclusive",
"VK_NV_shader_atomic_float16_vector","VK_NV_shader_image_footprint",
"VK_NV_shader_sm_builtins","VK_NV_shader_subgroup_partitioned","VK_NV_shading_rate_image",
"VK_NV_viewport_array2","VK_NV_viewport_swizzle","VK_NV_win32_keyed_mutex",
"VK_NVX_binary_import","VK_NVX_image_view_handle","VK_NVX_multiview_per_view_attributes",
"VK_OHOS_external_memory","VK_OHOS_surface",
"VK_QCOM_cooperative_matrix_conversion","VK_QCOM_data_graph_model",
"VK_QCOM_filter_cubic_clamp","VK_QCOM_filter_cubic_weights",
"VK_QCOM_fragment_density_map_offset","VK_QCOM_image_processing","VK_QCOM_image_processing2",
"VK_QCOM_multiview_per_view_render_areas","VK_QCOM_multiview_per_view_viewports",
"VK_QCOM_render_pass_shader_resolve","VK_QCOM_render_pass_store_ops",
"VK_QCOM_render_pass_transform","VK_QCOM_rotated_copy_commands","VK_QCOM_tile_memory_heap",
"VK_QCOM_tile_properties","VK_QCOM_tile_shading","VK_QCOM_ycbcr_degamma",
"VK_QNX_external_memory_screen_buffer","VK_QNX_screen_surface",
"VK_SEC_amigo_profiling","VK_SEC_pipeline_cache_incremental_mode","VK_SEC_ubm_surface",
"VK_VALVE_descriptor_set_host_mapping","VK_VALVE_fragment_density_map_layered",
"VK_VALVE_mutable_descriptor_type","VK_VALVE_shader_mixed_float_dot_product",
"VK_VALVE_video_encode_rgb_conversion",
"VK_KHR_portability_subset","VK_AMDX_dense_geometry_format","VK_AMDX_shader_enqueue",
"VK_NV_cuda_kernel_launch","VK_NV_present_metering",
]
known = set(re.findall(r'"(VK_[A-Z0-9_]+)"', c))
adds = [f'    "{e}": 1,' for e in ALL if e not in known]
if adds:
    for probe in ['"VK_KHR_swapchain": 1,','"VK_KHR_swapchain": 26,','"VK_ANDROID_native_buffer": 26,','"VK_ANDROID_native_buffer": 1,']:
        if probe in c:
            c = c.replace(probe, probe+'\n'+'\n'.join(adds), 1); break
    else:
        c = re.sub(r'(\n\})\s*$','\n'+'\n'.join(adds)+r'\n}',c,count=1)
    print(f"[OK] Added {len(adds)} extensions")
else:
    print("[INFO] All extensions already present")
with open(fp,'w') as f: f.write(c)
total=len(re.findall(r'"VK_[A-Z0-9_]+"\s*:\s*\d+',c))
print(f"[OK] Total entries: {total}")
PYEOF
        log_success "vk_extensions.py patched"
    fi

    # inject_extensions.py — reads patched vk_extensions.py, injects ALL known
    # device extensions into tu_device.cc using safe field names only
    python3 - "$tu_device" "$vk_exts_py" << 'PYEOF'
import sys, re

tu_path, vk_path = sys.argv[1], sys.argv[2]
with open(tu_path) as f: content = f.read()
with open(vk_path) as f: vk_py = f.read()

# Force feature flags
feats=["shaderFloat64","shaderStorageImageMultisample",
"uniformAndStorageBuffer16BitAccess","storagePushConstant16",
"uniformAndStorageBuffer8BitAccess","storagePushConstant8",
"shaderSharedInt64Atomics","shaderBufferInt64Atomics",
"independentResolve","independentResolveNone",
"shaderDenormPreserveFloat16","shaderDenormFlushToZeroFloat16",
"shaderRoundingModeRTZFloat16","samplerFilterMinmax",
"textureCompressionASTC_HDR","integerDotProduct8BitUnsignedAccelerated",
"shaderObject","mutableDescriptorType",
"maintenance5","maintenance6","maintenance7","maintenance8","maintenance9","maintenance10",
"meshShader","taskShader","rayQuery","accelerationStructure",
"fragmentDensityMapDynamic","shaderBFloat16"]
nf=0
for p in feats:
    new,n=re.subn(rf'((?:p|features|props|pdevice|pdev)->{re.escape(p)}\s*=\s*)([^;]+)(;)',r'\1true\3',content)
    if n: content=new; nf+=n
print(f"[OK] Forced {nf} feature flags")

# Get all ext names from vk_extensions.py (these = valid struct fields)
all_exts = re.findall(r'"(VK_[A-Z0-9_]+)"\s*:\s*\d+', vk_py)
print(f"[INFO] {len(all_exts)} entries in vk_extensions.py")

# Instance-only — no field in vk_device_extension_table
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
"VK_OHOS_surface","VK_QNX_screen_surface","VK_SEC_ubm_surface",
"VK_OHOS_external_memory",
}

dev_exts=[e for e in all_exts if e not in INST_ONLY]
print(f"[INFO] {len(dev_exts)} device extensions to inject")

# Find injection point
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
    # fallback: last extension assignment
    last=None
    for m in re.finditer(r'(\w+)->(KHR|EXT|AMD|VALVE|QCOM|MESA|GOOGLE|HUAWEI|ARM|SEC|NV|INTEL|IMG|ANDROID)\w+\s*=\s*(?:true|false)\s*;',text):
        last=m
    if last: return last.group(1),last.end()
    return None

r=find_point(content)
if r is None:
    print("[WARN] No injection point found")
    with open(tu_path,'w') as f: f.write(content)
    sys.exit(0)

ev,ins=r
print(f"[OK] ext_var='{ev}', injecting {len(dev_exts)} extensions")

lines=["\n    // === ALL VULKAN EXTENSIONS INJECTED ==="]
for e in dev_exts:
    lines.append(f"    {ev}->{e[3:]} = true;")  # strip VK_ prefix
lines.append("    // === END ===\n")
inj="\n".join(lines)
content=content[:ins]+inj+content[ins:]
with open(tu_path,'w') as f: f.write(content)
print(f"[OK] Done — {len(dev_exts)} assignments written")
PYEOF

    log_success "Vulkan extensions support applied"
}


apply_patches() {
    log_info "Applying patches for $TARGET_GPU"
    cd "$MESA_DIR"

    if [[ "$BUILD_VARIANT" == "vanilla" ]]; then
        log_info "Vanilla build - skipping all patches"
        return 0
    fi

    # Apply full patch series if enabled and present
    if [[ "$APPLY_PATCH_SERIES" == "true" && -d "$PATCHES_DIR/series" ]]; then
        apply_patch_series "$PATCHES_DIR/series"
    else
        log_info "Patch series not enabled or not found, applying individual patches based on flags"
        # Individual patch functions (kept for backward compatibility)
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
        if [[ "$BUILD_VARIANT" == "autotuner" ]]; then
            apply_a6xx_query_fix
        fi
    fi

    # Apply external patches from root patches directory (old method)
    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local patch_name=$(basename "$patch")
            # Skip if it's in series subdir (already applied)
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

    # Build c_args list properly
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
        # perf handled below
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
    log_info "Turnip Driver Builder (Winlator Optimized)"
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
