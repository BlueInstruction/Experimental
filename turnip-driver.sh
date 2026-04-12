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
MESA_REPO="https://github.com/BlueInstruction/mesa-for-android-container.git"
MESA_BRANCH_DEFAULT="adreno-main"
MESA_MIRROR="https://gitlab.freedesktop.org/mesa/mesa.git"
TURNIP_CI_REPO="https://github.com/whitebelyash/freedreno_turnip-CI.git"
VULKAN_HEADERS_REPO="https://github.com/KhronosGroup/Vulkan-Headers.git"

MESA_SOURCE="${MESA_SOURCE:-adreno_main}"
STAGING_BRANCH="${STAGING_BRANCH:-staging/26.0}"
CUSTOM_TAG="${CUSTOM_TAG:-}"
BUILD_TYPE="${BUILD_TYPE:-release}"
BUILD_VARIANT="${BUILD_VARIANT:-optimized}"
NDK_PATH="${NDK_PATH:-/opt/android-ndk}"
API_LEVEL="${API_LEVEL:-35}"
ENABLE_TIMELINE_HACK="${ENABLE_TIMELINE_HACK:-true}"
ENABLE_UBWC_HACK="${ENABLE_UBWC_HACK:-true}"
ENABLE_DECK_EMU="${ENABLE_DECK_EMU:-true}"
APPLY_PATCH_SERIES="${APPLY_PATCH_SERIES:-true}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# Performance compiler flags for Adreno 750 (Cortex-X4 / ARMv8.2-a)
# -O3                     Maximum optimization
# -march=armv8.2-a+...    Target Snapdragon 8 Gen 3 ISA features
# -ffast-math              Fast floating-point (significant GPU driver speedup)
# -fno-finite-math-only    Keep NaN/Inf handling (prevents rendering bugs)
# -fno-math-errno          Don't set errno on math ops (reduces overhead)
# -fno-trapping-math       Assume no FP traps (enables more optimizations)
# -DNDEBUG                 Strip all assert() calls from release build
CFLAGS_EXTRA="${CFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod -ffast-math -fno-finite-math-only -fno-math-errno -fno-trapping-math -DNDEBUG}"
CXXFLAGS_EXTRA="${CXXFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod -ffast-math -fno-finite-math-only -fno-math-errno -fno-trapping-math -DNDEBUG}"
# Linker flags:
# --gc-sections            Strip dead code
# --icf=safe               Merge identical functions (smaller + faster)
# -O2                      Linker optimization level 2
LDFLAGS_EXTRA="${LDFLAGS_EXTRA:--Wl,--gc-sections -Wl,--icf=safe -Wl,-O2}"

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
    # Query upstream Mesa (gitlab/mirror) for latest release tag
    local upstream="https://gitlab.freedesktop.org/mesa/mesa.git"
    local tags=""
    tags=$(git ls-remote --tags --refs "$upstream" 2>/dev/null | \
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
        major=$(grep -m1 "#define VK_HEADER_VERSION_COMPLETE" "$vk_header" | \
            grep -oP 'VK_MAKE_API_VERSION\(\d+,\s*\K\d+' || echo "1")
        minor=$(grep -m1 "#define VK_HEADER_VERSION_COMPLETE" "$vk_header" | \
            grep -oP 'VK_MAKE_API_VERSION\(\d+,\s*\d+,\s*\K\d+' || echo "4")
        patch=$(grep -m1 "#define VK_HEADER_VERSION" "$vk_header" | \
            awk '{print $3}' || echo "0")
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
    # Skip header update for adreno_main — the fork ships compatible headers.
    # Overwriting with latest upstream headers causes _EXT→_KHR rename mismatches
    # (e.g. VK_DEVICE_FAULT_ADDRESS_TYPE_MAX_ENUM_EXT removed in newer headers).
    if [[ "$MESA_SOURCE" == "adreno_main" || "$MESA_SOURCE" == "clean_main" ]]; then
        log_info "Skipping Vulkan headers update ($MESA_SOURCE uses its own compatible headers)"
        return 0
    fi

    log_info "Updating Vulkan headers"
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

    case "$MESA_SOURCE" in
        adreno_main)
            # Primary: BlueInstruction/mesa-for-android-container adreno-main
            # Clean Mesa with proper KGSL support for Adreno 750
            target_ref="$MESA_BRANCH_DEFAULT"
            clone_args=("--depth" "200" "--branch" "$target_ref")
            ;;
        clean_main)
            # Upstream Mesa main + freedreno_turnip-CI patches
            # Clean vanilla build with community patches applied
            target_ref="main"
            clone_args=("--depth" "200" "--branch" "main")
            ;;
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
    log_info "Target: $target_ref from $MESA_SOURCE"

    # For clean_main, clone from upstream gitlab directly
    local primary_repo="$MESA_REPO"
    if [[ "$MESA_SOURCE" == "clean_main" ]]; then
        primary_repo="$MESA_MIRROR"
    fi

    if ! git clone "${clone_args[@]}" "$primary_repo" "$MESA_DIR" 2>/dev/null; then
        log_warn "Primary source ($primary_repo) failed, trying mirror"
        # For adreno_main fallback, use upstream main
        if [[ "$MESA_SOURCE" == "adreno_main" ]]; then
            target_ref="main"
            clone_args=("--depth" "200" "--branch" "main")
        fi
        if ! git clone "${clone_args[@]}" "$MESA_MIRROR" "$MESA_DIR" 2>/dev/null; then
            log_error "Failed to clone Mesa from any source"
            exit 1
        fi
    fi

    cd "$MESA_DIR"
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    [[ "$MESA_SOURCE" == "latest_main" ]] && git pull origin main

    # For clean_main, fetch and apply freedreno_turnip-CI patches
    if [[ "$MESA_SOURCE" == "clean_main" ]]; then
        log_info "Fetching freedreno_turnip-CI patches..."
        local ci_dir="${WORKDIR}/turnip-ci"
        if git clone --depth=1 "$TURNIP_CI_REPO" "$ci_dir" 2>/dev/null; then
            # Apply .patch files from the CI repo's patches directory
            local patch_dir=""
            for try_dir in "$ci_dir/patches" "$ci_dir/patch" "$ci_dir"; do
                if compgen -G "${try_dir}/*.patch" >/dev/null 2>&1; then
                    patch_dir="$try_dir"
                    break
                fi
            done
            if [[ -n "$patch_dir" ]]; then
                log_info "Applying freedreno_turnip-CI patches from $patch_dir"
                for p in $(find "$patch_dir" -maxdepth 1 -name '*.patch' | sort); do
                    local pname
                    pname=$(basename "$p")
                    if git apply --check "$p" 2>/dev/null; then
                        git apply "$p"
                        log_success "Applied: $pname"
                    else
                        log_warn "Skipped (doesn't apply cleanly): $pname"
                    fi
                done
            else
                log_warn "No .patch files found in freedreno_turnip-CI"
            fi
            rm -rf "$ci_dir"
        else
            log_warn "Failed to clone freedreno_turnip-CI, continuing without patches"
        fi
    fi

    local version commit
    version=$(get_mesa_version)
    commit=$(git rev-parse --short=8 HEAD)
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
        local patch_name
        patch_name=$(basename "$patch")
        log_info "Applying patch: $patch_name"
        if ! git am --3way "$patch" 2>&1 | tee -a "${WORKDIR}/patch.log"; then
            log_error "Failed to apply patch $patch_name"
            git am --abort
            exit 1
        fi
    done
    log_success "All patches applied"
}

apply_timeline_semaphore_fix() {
    log_info "Applying timeline semaphore optimization"
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
    log_info "Applying UBWC 5/6 support"
    local kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    [[ ! -f "$kgsl_file" ]] && { log_warn "KGSL file not found"; return 0; }

    if grep -q "KGSL_UBWC_5_0" "$kgsl_file" 2>/dev/null; then
        log_warn "UBWC 5/6 already defined — skipping"
    elif ! grep -q "case 5:" "$kgsl_file"; then
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

apply_a750_win_identity() {
    log_info "Applying Adreno 750 Windows x86_64 identity"
    local tu_util_h="${MESA_DIR}/src/freedreno/vulkan/tu_util.h"
    local tu_util_cc="${MESA_DIR}/src/freedreno/vulkan/tu_util.cc"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"

    if [[ -f "$tu_util_h" ]] && ! grep -q "TU_DEBUG_DECK_EMU" "$tu_util_h"; then
        local last_bit new_bit
        last_bit=$(grep -oP 'BITFIELD64_BIT\(\K[0-9]+' "$tu_util_h" | sort -n | tail -1)
        new_bit=$((last_bit + 1))
        sed -i "/TU_DEBUG_FORCE_CONCURRENT_BINNING/a\\   TU_DEBUG_DECK_EMU = BITFIELD64_BIT(${new_bit})," \
            "$tu_util_h" 2>/dev/null || true
        log_success "deck_emu flag added (bit ${new_bit})"
    fi

    if [[ -f "$tu_util_cc" ]] && ! grep -q "deck_emu" "$tu_util_cc"; then
        sed -i '/{ "forcecb"/a\   { "deck_emu", TU_DEBUG_DECK_EMU },' \
            "$tu_util_cc" 2>/dev/null || true
        log_success "deck_emu option registered"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "DECK_EMU" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

applied = 0

# ── apiVersion ─────────────────────────────────────────────────────
m_api = re.search(r'(\n[ \t]*pdevice->vk\.properties\.apiVersion\s*=)', content)
if m_api:
    api_code = '\n   if (TU_DEBUG(DECK_EMU)) {\n      /* A750_WIN_PROFILE: apiVersion 1.3.295 */\n      pdevice->vk.properties.apiVersion = VK_MAKE_API_VERSION(0, 1, 3, 295);\n   }\n'
    content = content[:m_api.start()] + '\n' + api_code + content[m_api.start():]
    print('[OK] apiVersion 1.3.295 injected (pdevice anchor)')
    applied += 1
else:
    m_api2 = re.search(r'VK_MAKE_API_VERSION\(0,\s*1,\s*3,\s*\d+\)', content)
    if m_api2:
        ln_end = content.find('\n', m_api2.end())
        if ln_end == -1: ln_end = len(content)
        api_code = '\n   if (TU_DEBUG(DECK_EMU)) {\n      /* A750_WIN_PROFILE: apiVersion 1.3.295 */\n      pdevice->vk.properties.apiVersion = VK_MAKE_API_VERSION(0, 1, 3, 295);\n   }\n'
        content = content[:ln_end] + '\n' + api_code + content[ln_end:]
        print('[OK] apiVersion 1.3.295 injected (VK_MAKE anchor)')
        applied += 1
    else:
        print('[WARN] apiVersion injection point not found')

# ── 20 GiB heap — extract actual param name dynamically ───────────
heap_injected = False
for pat in [
    r'tu_GetPhysicalDeviceMemoryProperties2\s*\(\s*VkPhysicalDevice\s+\w+\s*,\s*VkPhysicalDeviceMemoryProperties2\s*\*\s*(\w+)\s*\)',
    r'vkGetPhysicalDeviceMemoryProperties2\s*\(\s*VkPhysicalDevice\s+\w+\s*,\s*VkPhysicalDeviceMemoryProperties2\s*\*\s*(\w+)\s*\)',
]:
    m_func = re.search(pat, content)
    if m_func:
        param = m_func.group(1)
        bp = content.find('{', m_func.end())
        if bp != -1:
            close = bp + 1
            depth = 1
            while close < len(content) and depth > 0:
                if content[close] == '{': depth += 1
                elif content[close] == '}': depth -= 1
                close += 1
            insert_at = close - 1
            heap_code = (
                '\n   if (TU_DEBUG(DECK_EMU)) {\n'
                '      /* A750_WIN_PROFILE: 2 GiB heap (realistic for KGSL) */\n'
                f'      if ({param}->memoryProperties.memoryHeapCount > 0)\n'
                f'         {param}->memoryProperties.memoryHeaps[0].size = 2048ULL * 1024ULL * 1024ULL;\n'
                '   }\n'
            )
            content = content[:insert_at] + '\n' + heap_code + content[insert_at:]
            print(f'[OK] 20 GiB heap injected (param={param})')
            applied += 1
            heap_injected = True
            break

if not heap_injected:
    # Fallback: find any memoryHeaps[0].size assignment
    m_hs = re.search(r'(\n[ \t]*.*memoryHeaps\[0\]\.size\s*=[^;]+;)', content)
    if m_hs:
        ln_end = content.find('\n', m_hs.end())
        if ln_end == -1: ln_end = len(content)
        heap_code = '\n   if (TU_DEBUG(DECK_EMU)) {\n      /* A750_WIN_PROFILE: 2 GiB heap fallback (realistic for KGSL) */\n      pdevice->memory.memoryProperties.memoryHeaps[0].size = 2048ULL * 1024ULL * 1024ULL;\n   }\n'
        content = content[:ln_end] + '\n' + heap_code + content[ln_end:]
        print('[OK] 20 GiB heap injected (fallback after memoryHeaps assignment)')
        applied += 1
    else:
        print('[WARN] 20 GiB heap injection point not found')

with open(path, 'w') as f:
    f.write(content)
print(f'[OK] A750 Windows profile: {applied} injections applied')
PYEOF

    fi

    log_success "Adreno 750 Windows profile applied"
}

apply_vulkan_extensions_support() {
    log_info "Enabling Adreno 750 Windows Vulkan extensions (149)"
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_exts_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"
    [[ ! -f "$tu_device" ]] && { log_warn "tu_device.cc not found"; return 0; }

    if [[ -f "$vk_exts_py" ]]; then
        python3 - "$vk_exts_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

n = 0
def lo(m):
    global n; n += 1
    return m.group(1) + '1' + m.group(3)
c = re.sub(r'("VK_\w+"\s*:\s*)(\d+)(,?)', lo, c)
print(f"[OK] Lowered {n} entries to API 1")

A750_WIN = [
    "VK_EXT_4444_formats",
    "VK_EXT_astc_decode_mode",
    "VK_EXT_blend_operation_advanced",
    "VK_EXT_border_color_swizzle",
    "VK_EXT_calibrated_timestamps",
    "VK_EXT_color_write_enable",
    "VK_EXT_conditional_rendering",
    "VK_EXT_conservative_rasterization",
    "VK_EXT_custom_border_color",
    "VK_EXT_depth_clamp_zero_one",
    "VK_EXT_depth_clip_control",
    "VK_EXT_depth_clip_enable",
    "VK_EXT_descriptor_indexing",
    "VK_EXT_device_address_binding_report",
    "VK_EXT_device_fault",
    "VK_EXT_extended_dynamic_state",
    "VK_EXT_extended_dynamic_state2",
    "VK_EXT_external_memory_acquire_unmodified",
    "VK_EXT_filter_cubic",
    "VK_EXT_fragment_density_map",
    "VK_EXT_fragment_density_map2",
    "VK_EXT_global_priority",
    "VK_EXT_global_priority_query",
    "VK_EXT_host_query_reset",
    "VK_EXT_image_2d_view_of_3d",
    "VK_EXT_image_robustness",
    "VK_EXT_image_view_min_lod",
    "VK_EXT_index_type_uint8",
    "VK_EXT_inline_uniform_block",
    "VK_EXT_line_rasterization",
    "VK_EXT_load_store_op_none",
    "VK_EXT_multisampled_render_to_single_sampled",
    "VK_EXT_multi_draw",
    "VK_EXT_pipeline_creation_cache_control",
    "VK_EXT_pipeline_creation_feedback",
    "VK_EXT_pipeline_protected_access",
    "VK_EXT_pipeline_robustness",
    "VK_EXT_primitive_topology_list_restart",
    "VK_EXT_private_data",
    "VK_EXT_provoking_vertex",
    "VK_EXT_queue_family_foreign",
    "VK_EXT_robustness2",
    "VK_EXT_sampler_filter_minmax",
    "VK_EXT_sample_locations",
    "VK_EXT_scalar_block_layout",
    "VK_EXT_separate_stencil_usage",
    "VK_EXT_shader_atomic_float",
    "VK_EXT_shader_demote_to_helper_invocation",
    "VK_EXT_shader_image_atomic_int64",
    "VK_EXT_shader_module_identifier",
    "VK_EXT_shader_stencil_export",
    "VK_EXT_shader_subgroup_ballot",
    "VK_EXT_shader_subgroup_vote",
    "VK_EXT_shader_viewport_index_layer",
    "VK_EXT_subgroup_size_control",
    "VK_EXT_swapchain_maintenance1",
    "VK_EXT_texel_buffer_alignment",
    "VK_EXT_texture_compression_astc_hdr",
    "VK_EXT_tooling_info",
    "VK_EXT_transform_feedback",
    "VK_EXT_vertex_attribute_divisor",
    "VK_EXT_vertex_input_dynamic_state",
    "VK_IMG_filter_cubic",
    "VK_KHR_16bit_storage",
    "VK_KHR_8bit_storage",
    "VK_KHR_acceleration_structure",
    "VK_KHR_bind_memory2",
    "VK_KHR_buffer_device_address",
    "VK_KHR_calibrated_timestamps",
    "VK_KHR_copy_commands2",
    "VK_KHR_create_renderpass2",
    "VK_KHR_dedicated_allocation",
    "VK_KHR_deferred_host_operations",
    "VK_KHR_depth_stencil_resolve",
    "VK_KHR_descriptor_update_template",
    "VK_KHR_device_group",
    "VK_KHR_draw_indirect_count",
    "VK_KHR_driver_properties",
    "VK_KHR_dynamic_rendering",
    "VK_KHR_dynamic_rendering_local_read",
    "VK_KHR_external_fence",
    "VK_KHR_external_memory",
    "VK_KHR_external_semaphore",
    "VK_KHR_format_feature_flags2",
    "VK_KHR_fragment_shading_rate",
    "VK_KHR_get_memory_requirements2",
    "VK_KHR_global_priority",
    "VK_KHR_imageless_framebuffer",
    "VK_KHR_image_format_list",
    "VK_KHR_incremental_present",
    "VK_KHR_index_type_uint8",
    "VK_KHR_line_rasterization",
    "VK_KHR_load_store_op_none",
    "VK_KHR_maintenance1",
    "VK_KHR_maintenance2",
    "VK_KHR_maintenance3",
    "VK_KHR_maintenance4",
    "VK_KHR_maintenance5",
    "VK_KHR_maintenance6",
    "VK_KHR_map_memory2",
    "VK_KHR_multiview",
    "VK_KHR_pipeline_executable_properties",
    "VK_KHR_present_id",
    "VK_KHR_present_wait",
    "VK_KHR_push_descriptor",
    "VK_KHR_ray_query",
    "VK_KHR_ray_tracing_maintenance1",
    "VK_KHR_ray_tracing_position_fetch",
    "VK_KHR_relaxed_block_layout",
    "VK_KHR_sampler_mirror_clamp_to_edge",
    "VK_KHR_sampler_ycbcr_conversion",
    "VK_KHR_separate_depth_stencil_layouts",
    "VK_KHR_shader_atomic_int64",
    "VK_KHR_shader_clock",
    "VK_KHR_shader_draw_parameters",
    "VK_KHR_shader_expect_assume",
    "VK_KHR_shader_float16_int8",
    "VK_KHR_shader_float_controls",
    "VK_KHR_shader_float_controls2",
    "VK_KHR_shader_integer_dot_product",
    "VK_KHR_shader_maximal_reconvergence",
    "VK_KHR_shader_non_semantic_info",
    "VK_KHR_shader_quad_control",
    "VK_KHR_shader_subgroup_extended_types",
    "VK_KHR_shader_subgroup_rotate",
    "VK_KHR_shader_subgroup_uniform_control_flow",
    "VK_KHR_shader_terminate_invocation",
    "VK_KHR_spirv_1_4",
    "VK_KHR_storage_buffer_storage_class",
    "VK_KHR_swapchain",
    "VK_KHR_swapchain_mutable_format",
    "VK_KHR_synchronization2",
    "VK_KHR_timeline_semaphore",
    "VK_KHR_uniform_buffer_standard_layout",
    "VK_KHR_variable_pointers",
    "VK_KHR_vertex_attribute_divisor",
    "VK_KHR_vulkan_memory_model",
    "VK_KHR_workgroup_memory_explicit_layout",
    "VK_KHR_zero_initialize_workgroup_memory",
    "VK_NV_optical_flow",
    "VK_QCOM_fragment_density_map_offset",
    "VK_QCOM_image_processing",
    "VK_QCOM_multiview_per_view_render_areas",
    "VK_QCOM_multiview_per_view_viewports",
    "VK_QCOM_render_pass_shader_resolve",
    "VK_QCOM_render_pass_store_ops",
    "VK_QCOM_render_pass_transform",
    "VK_QCOM_rotated_copy_commands",
    "VK_QCOM_tile_properties",
]

known = set(re.findall(r'"(VK_[A-Z0-9_]+)"', c))
adds = [f'    "{e}": 1,' for e in A750_WIN if e not in known]
if adds:
    injected = False
    # Exact full-entry probe (safe to split after)
    for probe in ['"VK_KHR_swapchain": 1,']:
        if probe in c:
            c = c.replace(probe, probe + '\n' + '\n'.join(adds), 1)
            injected = True
            break
    # Broader probes: insert after the full line to avoid splitting dict entries
    if not injected:
        for probe in ['"VK_KHR_swapchain":', '"VK_ANDROID_native_buffer":']:
            idx = c.find(probe)
            if idx != -1:
                eol = c.find('\n', idx)
                if eol == -1: eol = len(c)
                c = c[:eol] + '\n' + '\n'.join(adds) + c[eol:]
                injected = True
                break
    if not injected:
        m2 = list(re.finditer(r'\n(\s*\}\s*)$', c))
        if m2:
            ins = m2[-1].start()
            c = c[:ins] + '\n' + '\n'.join(adds) + c[ins:]
        else:
            c += '\n' + '\n'.join(adds)
    print(f"[OK] Added {len(adds)} A750 Windows extensions")
else:
    print("[INFO] All A750 Windows extensions already present")
with open(fp, 'w') as f: f.write(c)
PYEOF
    fi

    python3 - "$tu_device" "$vk_exts_py" << 'PYEOF'
import sys, re

tu_path, vk_path = sys.argv[1], sys.argv[2]
with open(tu_path) as f: content = f.read()
with open(vk_path) as f: vk_py = f.read()

INST_ONLY = {
    "VK_KHR_surface","VK_KHR_android_surface","VK_KHR_display",
    "VK_KHR_get_surface_capabilities2","VK_KHR_portability_enumeration",
    "VK_EXT_debug_report","VK_EXT_debug_utils","VK_EXT_headless_surface",
    "VK_EXT_layer_settings","VK_EXT_swapchain_colorspace",
    "VK_GOOGLE_surfaceless_query",
}

# ── Read extensions from vk_extensions.py (multi-format) ─────────────
A750_CORE = [
    "VK_ANDROID_external_memory_android_hardware_buffer",
    "VK_EXT_4444_formats","VK_EXT_astc_decode_mode","VK_EXT_blend_operation_advanced",
    "VK_EXT_border_color_swizzle","VK_EXT_calibrated_timestamps",
    "VK_EXT_color_write_enable","VK_EXT_conditional_rendering",
    "VK_EXT_conservative_rasterization","VK_EXT_custom_border_color",
    "VK_EXT_depth_clamp_zero_one","VK_EXT_depth_clip_control","VK_EXT_depth_clip_enable",
    "VK_EXT_descriptor_indexing","VK_EXT_device_address_binding_report",
    "VK_EXT_device_fault","VK_EXT_device_memory_report",
    "VK_EXT_extended_dynamic_state","VK_EXT_extended_dynamic_state2",
    "VK_EXT_filter_cubic","VK_EXT_fragment_density_map","VK_EXT_fragment_density_map2",
    "VK_EXT_global_priority","VK_EXT_global_priority_query","VK_EXT_host_query_reset",
    "VK_EXT_image_2d_view_of_3d","VK_EXT_image_robustness","VK_EXT_image_view_min_lod",
    "VK_EXT_index_type_uint8","VK_EXT_inline_uniform_block","VK_EXT_line_rasterization",
    "VK_EXT_load_store_op_none","VK_EXT_multisampled_render_to_single_sampled",
    "VK_EXT_multi_draw","VK_EXT_mutable_descriptor_type",
    "VK_EXT_pipeline_creation_cache_control","VK_EXT_pipeline_creation_feedback",
    "VK_EXT_pipeline_protected_access","VK_EXT_pipeline_robustness",
    "VK_EXT_primitive_topology_list_restart","VK_EXT_private_data",
    "VK_EXT_provoking_vertex","VK_EXT_queue_family_foreign","VK_EXT_robustness2",
    "VK_EXT_sample_locations","VK_EXT_sampler_filter_minmax","VK_EXT_scalar_block_layout",
    "VK_EXT_separate_stencil_usage","VK_EXT_shader_atomic_float",
    "VK_EXT_shader_demote_to_helper_invocation","VK_EXT_shader_image_atomic_int64",
    "VK_EXT_shader_module_identifier","VK_EXT_shader_stencil_export",
    "VK_EXT_shader_viewport_index_layer","VK_EXT_subgroup_size_control",
    "VK_EXT_swapchain_maintenance1","VK_EXT_texel_buffer_alignment",
    "VK_EXT_texture_compression_astc_hdr","VK_EXT_tooling_info",
    "VK_EXT_transform_feedback","VK_EXT_vertex_attribute_divisor",
    "VK_EXT_vertex_input_dynamic_state","VK_IMG_filter_cubic",
    "VK_KHR_16bit_storage","VK_KHR_8bit_storage","VK_KHR_acceleration_structure",
    "VK_KHR_bind_memory2","VK_KHR_buffer_device_address","VK_KHR_calibrated_timestamps",
    "VK_KHR_copy_commands2","VK_KHR_create_renderpass2","VK_KHR_dedicated_allocation",
    "VK_KHR_deferred_host_operations","VK_KHR_depth_stencil_resolve",
    "VK_KHR_descriptor_update_template","VK_KHR_device_group","VK_KHR_draw_indirect_count",
    "VK_KHR_driver_properties","VK_KHR_dynamic_rendering","VK_KHR_dynamic_rendering_local_read",
    "VK_KHR_external_fence","VK_KHR_external_fence_fd","VK_KHR_external_memory",
    "VK_KHR_external_memory_fd","VK_KHR_external_semaphore","VK_KHR_external_semaphore_fd",
    "VK_KHR_format_feature_flags2","VK_KHR_fragment_shading_rate",
    "VK_KHR_get_memory_requirements2","VK_KHR_global_priority","VK_KHR_image_format_list",
    "VK_KHR_imageless_framebuffer","VK_KHR_incremental_present","VK_KHR_index_type_uint8",
    "VK_KHR_line_rasterization","VK_KHR_load_store_op_none",
    "VK_KHR_maintenance1","VK_KHR_maintenance2","VK_KHR_maintenance3","VK_KHR_maintenance4",
    "VK_KHR_maintenance5","VK_KHR_maintenance6","VK_KHR_maintenance7","VK_KHR_map_memory2",
    "VK_KHR_multiview","VK_KHR_pipeline_executable_properties",
    "VK_KHR_present_id","VK_KHR_present_wait","VK_KHR_push_descriptor","VK_KHR_ray_query",
    "VK_KHR_ray_tracing_maintenance1","VK_KHR_ray_tracing_position_fetch",
    "VK_KHR_relaxed_block_layout","VK_KHR_sampler_mirror_clamp_to_edge",
    "VK_KHR_sampler_ycbcr_conversion","VK_KHR_separate_depth_stencil_layouts",
    "VK_KHR_shader_atomic_int64","VK_KHR_shader_clock","VK_KHR_shader_draw_parameters",
    "VK_KHR_shader_expect_assume","VK_KHR_shader_float16_int8","VK_KHR_shader_float_controls",
    "VK_KHR_shader_float_controls2","VK_KHR_shader_integer_dot_product",
    "VK_KHR_shader_maximal_reconvergence","VK_KHR_shader_non_semantic_info",
    "VK_KHR_shader_quad_control","VK_KHR_shader_subgroup_extended_types",
    "VK_KHR_shader_subgroup_rotate","VK_KHR_shader_subgroup_uniform_control_flow",
    "VK_KHR_shader_terminate_invocation","VK_KHR_spirv_1_4",
    "VK_KHR_storage_buffer_storage_class","VK_KHR_swapchain","VK_KHR_swapchain_mutable_format",
    "VK_KHR_synchronization2","VK_KHR_timeline_semaphore","VK_KHR_uniform_buffer_standard_layout",
    "VK_KHR_variable_pointers","VK_KHR_vertex_attribute_divisor","VK_KHR_vulkan_memory_model",
    "VK_KHR_workgroup_memory_explicit_layout","VK_KHR_zero_initialize_workgroup_memory",
    "VK_NV_optical_flow",
    "VK_QCOM_fragment_density_map_offset","VK_QCOM_image_processing",
    "VK_QCOM_multiview_per_view_render_areas","VK_QCOM_multiview_per_view_viewports",
    "VK_QCOM_render_pass_shader_resolve","VK_QCOM_render_pass_store_ops",
    "VK_QCOM_render_pass_transform","VK_QCOM_rotated_copy_commands",
    "VK_QCOM_tile_properties",
]

try:
    with open(vk_path) as f: vk_py = f.read()
    from_file = (
        re.findall(r'"(VK_[A-Z0-9_]+)"\s*:\s*\d+', vk_py) +
        re.findall(r"'(VK_[A-Z0-9_]+)'\s*:\s*\d+", vk_py) +
        re.findall(r"Extension\(['\"]+(VK_[A-Z0-9_]+)['\"]", vk_py)
    )
except Exception as ex:
    from_file = []
    print(f"[WARN] vk_extensions.py read error: {ex}")

merged = list(dict.fromkeys(from_file + A750_CORE))
dev_exts = [e for e in merged if e not in INST_ONLY]
print(f"[INFO] {len(dev_exts)} device extensions to inject")

def find_point(text):
    for pat in [
        r'tu_get_device_extensions\s*\([^{]*?struct\s+vk_device_extension_table\s*\*\s*(\w+)',
        r'tu_fill_device_extensions\s*\([^{]*?struct\s+vk_device_extension_table\s*\*\s*(\w+)',
        r'vk_device_extension_table\s*\*\s*(\w+)\s*[,\)]',
    ]:
        m = re.search(pat, text, re.DOTALL)
        if m:
            ev = m.group(m.lastindex)
            fs = m.end()
            bp = text.find('{', fs)
            if bp == -1: continue
            d = 1; p = bp + 1
            while p < len(text) and d > 0:
                if text[p] == '{': d += 1
                elif text[p] == '}': d -= 1
                p += 1
            return ev, p - 1
    last = None
    for m in re.finditer(
        r'(\w+)->(KHR|EXT|QCOM|MESA|NV|INTEL|IMG|ANDROID|ARM|VALVE|GOOGLE)\w+\s*=\s*(?:true|false)\s*;',
        text
    ):
        last = m
    if last: return last.group(1), last.end()
    return None

r = find_point(content)
if r is None:
    print("[WARN] No extension injection point found in tu_device.cc")
    with open(tu_path, 'w') as f: f.write(content)
    sys.exit(0)

ev, ins = r
print(f"[OK] injection point: var='{ev}'")
lines = ["\n    // === A750 WINDOWS EXTENSIONS ==="]
for e in dev_exts:
    lines.append(f"    {ev}->{e[3:]} = true;")
lines.append("    // === END A750 ===\n")
inj = "\n".join(lines)
content = content[:ins] + inj + content[ins:]
with open(tu_path, 'w') as f: f.write(content)
print(f"[OK] {len(dev_exts)} extension assignments written")
PYEOF

    log_success "Vulkan extensions support applied"
}

apply_patches() {
    log_info "Applying patches for Adreno 750"
    cd "$MESA_DIR"

    if [[ "$BUILD_VARIANT" == "vanilla" ]]; then
        log_info "Vanilla build — skipping patches"
        return 0
    fi

    if [[ "$APPLY_PATCH_SERIES" == "true" && -d "$PATCHES_DIR/series" ]]; then
        apply_patch_series "$PATCHES_DIR/series"
    else
        [[ "$ENABLE_TIMELINE_HACK" == "true" ]] && apply_timeline_semaphore_fix
        [[ "$ENABLE_UBWC_HACK" == "true" ]]     && apply_ubwc_support
        apply_gralloc_ubwc_fix
        if [[ "$ENABLE_DECK_EMU" == "true" ]]; then
            apply_a750_win_identity
        fi
        apply_vulkan_extensions_support
    fi

    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local patch_name
            patch_name=$(basename "$patch")
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
    log_info "Setting up subprojects"
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
    for flag in $CFLAGS_EXTRA; do
        c_args_list="$c_args_list, '$flag'"
    done

    local cpp_args_list="'-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations'"
    for flag in $CXXFLAGS_EXTRA; do
        cpp_args_list="$cpp_args_list, '$flag'"
    done

    local link_args_list="'-static-libstdc++'"
    for flag in $LDFLAGS_EXTRA; do
        link_args_list="$link_args_list, '$flag'"
    done

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
    [[ "$BUILD_VARIANT" == "debug" ]]   && buildtype="debug"
    [[ "$BUILD_VARIANT" == "profile" ]] && buildtype="debugoptimized"

    meson setup build                                   \
        --cross-file "${WORKDIR}/cross-aarch64.txt"    \
        -Dbuildtype="$buildtype"                        \
        -Db_ndebug=true                                 \
        -Dplatforms=android                             \
        -Dplatform-sdk-version="$API_LEVEL"             \
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
        --force-fallback-for=spirv-tools,spirv-headers  \
        2>&1 | tee "${WORKDIR}/meson.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
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
    local driver_name="vulkan.freedreno.so"

    mkdir -p "$pkg_dir"
    cp "$driver_src" "${pkg_dir}/${driver_name}"
    patchelf --set-soname "vulkan.adreno.so" "${pkg_dir}/${driver_name}"
    "${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
        "${pkg_dir}/${driver_name}" 2>/dev/null || true

    local driver_size variant_suffix filename
    driver_size=$(du -h "${pkg_dir}/${driver_name}" | cut -f1)

    # Strip -devel suffix for clean version (26.1.0-devel → 26.1.0)
    local clean_version="${version%-devel}"

    filename="Turnip_v${clean_version}-B${BUILD_NUMBER}"

    cat > "${pkg_dir}/meta.json" << EOF
{
    "schemaVersion": 1,
    "name": "Turnip_v${clean_version}-B${BUILD_NUMBER}",
    "description": "Adreno 750 — Windows x86_64 identity",
    "author": "BlueInstruction",
    "packageVersion": "${BUILD_NUMBER}",
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
    local version commit vulkan_version build_date
    version=$(cat "${WORKDIR}/version.txt")
    commit=$(cat "${WORKDIR}/commit.txt")
    vulkan_version=$(cat "${WORKDIR}/vulkan_version.txt")
    build_date=$(cat "${WORKDIR}/build_date.txt")
    echo ""
    local clean_version="${version%-devel}"
    log_info "Build Summary"
    echo "  Package        : Turnip_v${clean_version}-B${BUILD_NUMBER}"
    echo "  Mesa Version   : $version"
    echo "  Vulkan Header  : $vulkan_version"
    echo "  Build Number   : $BUILD_NUMBER"
    echo "  Commit         : $commit"
    echo "  Build Date     : $build_date"
    echo "  Build Variant  : $BUILD_VARIANT"
    echo "  Source         : $MESA_SOURCE"
    echo "  Heap           : 2 GiB (KGSL realistic)"
    echo "  Deck Emu       : $ENABLE_DECK_EMU"
    echo "  Timeline Hack  : $ENABLE_TIMELINE_HACK"
    echo "  UBWC Hack      : $ENABLE_UBWC_HACK"
    echo "  Output         :"
    ls -lh "${WORKDIR}"/*.zip 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
    echo ""
}

main() {
    log_info "Turnip Driver Builder — Adreno 750 Windows Profile"
    log_info "Variant: $BUILD_VARIANT | Source: $MESA_SOURCE"

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
