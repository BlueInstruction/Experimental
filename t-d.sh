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

# ═══════════════════════════════════════════════════════════════════════════════
# apply_vulkan_extensions_support
#
# Fix 1: vk_extensions.py — handle both single AND double quote styles
#         (Mesa 26.x uses single quotes → was causing "0 extensions known")
# Fix 2: inject ALL extensions AFTER the struct initialiser so they cannot
#         be overridden back to false by the struct assignment
# Fix 3: TARGET_EXTS list is comprehensive (250+ names) → well above 198
# ═══════════════════════════════════════════════════════════════════════════════
apply_vulkan_extensions_support() {
    log_info "Enabling ALL Vulkan extensions via Python injection"
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_exts_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"
    [[ ! -f "$tu_device" ]] && { log_warn "tu_device.cc not found"; return 0; }

    # ── Step 1: patch vk_extensions.py — ONLY lower API levels, nothing else ──
    # CRITICAL: vk_extensions.py is a full Python module with classes, constants
    # (like ANDROID_EXTENSION_WHITELIST_PREFIXES), and methods.
    # Inserting any lines into it breaks the module and causes NameError at build.
    # We ONLY safely lower the ALLOWED_ANDROID_VERSION numbers to 1 here.
    # All extension forcing happens in tu_device.cc (Step 2) which is safe C++ source.
    if [[ -f "$vk_exts_py" ]]; then
        python3 - "$vk_exts_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp, encoding='utf-8', errors='ignore') as f:
    c = f.read()

# Lower ALL API levels to 1 — handle BOTH single-quoted AND double-quoted keys
# Mesa 26.x: 'VK_XXX': 26,   older Mesa: "VK_XXX": 26,
# We ONLY change the number, never add/remove lines or alter file structure.
n1, n2 = 0, 0
def lo(m):
    return m.group(1) + '1' + m.group(3)
c, n1 = re.subn(r'("VK_[A-Z0-9_]+"\s*:\s*)(\d+)(,)', lo, c)
c, n2 = re.subn(r"('VK_[A-Z0-9_]+'\s*:\s*)(\d+)(,)", lo, c)
print(f"[OK] Lowered {n1+n2} API-level entries to 1 ({n1} double-quoted, {n2} single-quoted)")

with open(fp, 'w', encoding='utf-8') as f:
    f.write(c)
PYEOF
        log_success "vk_extensions.py patched"
    fi

    # ── Step 2: inject extensions into tu_device.cc ─────────────────────────────
    python3 - "$tu_device" "$vk_exts_py" << 'PYEOF'
import sys, re

tu_path  = sys.argv[1]
vk_path  = sys.argv[2]

with open(tu_path, encoding='utf-8', errors='ignore') as f:
    content = f.read()
with open(vk_path, encoding='utf-8', errors='ignore') as f:
    vk_py = f.read()

VENDORS = r'(?:KHR|EXT|AMD|AMDX|ARM|ANDROID|FUCHSIA|GGP|GOOGLE|HUAWEI|IMG|INTEL|LUNARG|MESA|MSFT|MVK|NN|NV|NVX|OHOS|QCOM|QNX|SEC|VALVE)'

# ══════════════════════════════════════════════════════════════════════════════
# Pass 1 — force physical device feature booleans (non-extension flags)
# ══════════════════════════════════════════════════════════════════════════════
FEATURE_PATS = [
    (r'(\b\w+->robustBufferAccess\s*=\s*)[^;]+;',            r'\g<1>true;'),
    (r'(\b\w+->multiDrawIndirect\s*=\s*)[^;]+;',             r'\g<1>true;'),
    (r'(\b\w+->drawIndirectFirstInstance\s*=\s*)[^;]+;',     r'\g<1>true;'),
    (r'(\b\w+->multiViewport\s*=\s*)[^;]+;',                 r'\g<1>true;'),
    (r'(\b\w+->shaderInt64\s*=\s*)[^;]+;',                   r'\g<1>true;'),
    (r'(\b\w+->shaderInt16\s*=\s*)[^;]+;',                   r'\g<1>true;'),
    (r'(\b\w+->fragmentStoresAndAtomics\s*=\s*)[^;]+;',      r'\g<1>true;'),
    (r'(\b\w+->independentBlend\s*=\s*)[^;]+;',              r'\g<1>true;'),
    (r'(\b\w+->sampleRateShading\s*=\s*)[^;]+;',             r'\g<1>true;'),
    (r'(\b\w+->tessellationShader\s*=\s*)[^;]+;',            r'\g<1>true;'),
]
nf = 0
for pat, rep in FEATURE_PATS:
    new, n = re.subn(pat, rep, content)
    if n: content = new; nf += n
print(f"[OK] Pass 1: Forced {nf} feature flag assignments")

# ══════════════════════════════════════════════════════════════════════════════
# Pass 2 — force ALL existing extension assignments to true (both syntaxes)
# ══════════════════════════════════════════════════════════════════════════════
forced_exts = set()

# Pointer syntax:  ext->KHR_foo = expr;
ptr_pat = rf'(\b(\w+)->({VENDORS})(_\w+)\s*=\s*)([^;{{}}]+)(;)'
def force_ptr(m):
    forced_exts.add(m.group(3) + m.group(4))
    return m.group(1) + 'true' + m.group(6)
content = re.sub(ptr_pat, force_ptr, content)
cnt_ptr = len(forced_exts)

# Struct-init syntax:  .KHR_foo = expr,
struct_pat = rf'(\.)({VENDORS})(_\w+)(\s*=\s*)([^,\n\}}/]+)(,?)'
struct_set = set()
def force_struct(m):
    name = m.group(2) + m.group(3)
    struct_set.add(name); forced_exts.add(name)
    return m.group(1) + m.group(2) + m.group(3) + m.group(4) + 'true' + m.group(6)
content = re.sub(struct_pat, force_struct, content)
cnt_struct = len(struct_set)

print(f"[OK] Pass 2: Force-set {len(forced_exts)} unique extension fields to true")
print(f"     Pointer-syntax: {cnt_ptr}, Struct-init-syntax: {cnt_struct}")
print(f"     Sample: {sorted(forced_exts)[:5]}")

# ══════════════════════════════════════════════════════════════════════════════
# Pass 3 — parse vk_extensions.py for Mesa-known extensions
#           handle BOTH single-quote ('VK_XXX': N) and double-quote ("VK_XXX": N)
# ══════════════════════════════════════════════════════════════════════════════
mesa_exts = set()
# Format A: Extension('VK_XXX', ...)
for m in re.finditer(r"Extension\s*\(\s*['\"]?(VK_[A-Z0-9_]+)['\"]?", vk_py):
    mesa_exts.add(m.group(1))
# Format B: 'VK_XXX': N,  or  "VK_XXX": N,
for m in re.finditer(r"['\"]?(VK_[A-Z0-9_]+)['\"]?\s*:\s*\d+", vk_py):
    mesa_exts.add(m.group(1))
# Format C: any bare VK_VENDOR_name token (broadest catch)
for m in re.finditer(r'\bVK_([A-Z]+(?:_[A-Z0-9]+)+)\b', vk_py):
    mesa_exts.add('VK_' + m.group(1))

VALID_V = {'KHR','EXT','AMD','AMDX','ARM','ANDROID','FUCHSIA','GGP',
           'GOOGLE','HUAWEI','IMG','INTEL','LUNARG','MESA','MSFT','MVK',
           'NN','NV','NVX','OHOS','QCOM','QNX','SEC','VALVE'}
mesa_exts = {e for e in mesa_exts
             if len(e.split('_')) >= 3 and e.split('_')[1] in VALID_V}
print(f"[INFO] Pass 3: Mesa vk_extensions.py knows {len(mesa_exts)} extensions")

INST_ONLY = {
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
}
mesa_dev_exts = sorted(e for e in mesa_exts if e not in INST_ONLY)

# What's already true (both syntaxes)
already = set()
for m in re.finditer(rf'\b\w+->({VENDORS}_\w+)\s*=\s*true\s*;', content):
    already.add('VK_' + m.group(1))
for m in re.finditer(rf'\.({VENDORS}_\w+)\s*=\s*true\s*,?', content):
    already.add('VK_' + m.group(1))

missing_p3 = [e for e in mesa_dev_exts if e not in already]
print(f"[INFO] {len(already)} already true, {len(missing_p3)} from vk_extensions.py need injection")

# ══════════════════════════════════════════════════════════════════════════════
# Pass 4 — TARGET_EXTS: comprehensive list injected AFTER the struct block
#           so these values CANNOT be overridden back to false
# ══════════════════════════════════════════════════════════════════════════════
TARGET_EXTS = [
# KHR device extensions
"KHR_16bit_storage","KHR_8bit_storage","KHR_acceleration_structure",
"KHR_bind_memory2","KHR_buffer_device_address","KHR_calibrated_timestamps",
"KHR_compute_shader_derivatives","KHR_cooperative_matrix","KHR_copy_commands2",
"KHR_copy_memory_indirect","KHR_create_renderpass2","KHR_dedicated_allocation",
"KHR_deferred_host_operations","KHR_depth_clamp_zero_one","KHR_depth_stencil_resolve",
"KHR_descriptor_update_template","KHR_device_group","KHR_draw_indirect_count",
"KHR_driver_properties","KHR_dynamic_rendering","KHR_dynamic_rendering_local_read",
"KHR_external_fence","KHR_external_fence_fd","KHR_external_memory",
"KHR_external_memory_fd","KHR_external_semaphore","KHR_external_semaphore_fd",
"KHR_format_feature_flags2","KHR_fragment_shader_barycentric","KHR_fragment_shading_rate",
"KHR_global_priority","KHR_image_format_list","KHR_imageless_framebuffer",
"KHR_incremental_present","KHR_index_type_uint8","KHR_line_rasterization",
"KHR_load_store_op_none","KHR_maintenance1","KHR_maintenance2","KHR_maintenance3",
"KHR_maintenance4","KHR_maintenance5","KHR_maintenance6","KHR_maintenance7",
"KHR_maintenance8","KHR_maintenance9","KHR_maintenance10","KHR_map_memory2",
"KHR_multiview","KHR_performance_query","KHR_pipeline_binary",
"KHR_pipeline_executable_properties","KHR_pipeline_library","KHR_portability_subset",
"KHR_present_id","KHR_present_id2","KHR_present_mode_fifo_latest_ready",
"KHR_present_wait","KHR_present_wait2","KHR_push_descriptor",
"KHR_ray_query","KHR_ray_tracing_maintenance1","KHR_ray_tracing_pipeline",
"KHR_ray_tracing_position_fetch","KHR_relaxed_block_layout","KHR_robustness2",
"KHR_sampler_mirror_clamp_to_edge","KHR_sampler_ycbcr_conversion",
"KHR_separate_depth_stencil_layouts","KHR_shader_atomic_int64",
"KHR_shader_bfloat16","KHR_shader_clock","KHR_shader_draw_parameters",
"KHR_shader_expect_assume","KHR_shader_float16_int8","KHR_shader_float_controls",
"KHR_shader_float_controls2","KHR_shader_fma","KHR_shader_integer_dot_product",
"KHR_shader_maximal_reconvergence","KHR_shader_non_semantic_info","KHR_shader_quad_control",
"KHR_shader_relaxed_extended_instruction","KHR_shader_subgroup_extended_types",
"KHR_shader_subgroup_rotate","KHR_shader_subgroup_uniform_control_flow",
"KHR_shader_terminate_invocation","KHR_shader_untyped_pointers",
"KHR_shared_presentable_image","KHR_spirv_1_4","KHR_storage_buffer_storage_class",
"KHR_swapchain","KHR_swapchain_maintenance1","KHR_swapchain_mutable_format",
"KHR_synchronization2","KHR_timeline_semaphore","KHR_uniform_buffer_standard_layout",
"KHR_unified_image_layouts","KHR_variable_pointers","KHR_vertex_attribute_divisor",
"KHR_video_decode_av1","KHR_video_decode_h264","KHR_video_decode_h265",
"KHR_video_decode_queue","KHR_vulkan_memory_model","KHR_workgroup_memory_explicit_layout",
"KHR_zero_initialize_workgroup_memory",
# EXT device extensions
"EXT_4444_formats","EXT_astc_decode_mode",
"EXT_attachment_feedback_loop_dynamic_state","EXT_attachment_feedback_loop_layout",
"EXT_blend_operation_advanced","EXT_border_color_swizzle","EXT_buffer_device_address",
"EXT_calibrated_timestamps","EXT_color_write_enable","EXT_conditional_rendering",
"EXT_conservative_rasterization","EXT_custom_border_color","EXT_depth_bias_control",
"EXT_depth_clamp_control","EXT_depth_clamp_zero_one","EXT_depth_clip_control",
"EXT_depth_clip_enable","EXT_depth_range_unrestricted","EXT_descriptor_buffer",
"EXT_descriptor_indexing","EXT_device_address_binding_report","EXT_device_fault",
"EXT_device_generated_commands","EXT_device_memory_report","EXT_discard_rectangles",
"EXT_dynamic_rendering_unused_attachments","EXT_extended_dynamic_state",
"EXT_extended_dynamic_state2","EXT_extended_dynamic_state3",
"EXT_external_memory_acquire_unmodified","EXT_external_memory_dma_buf",
"EXT_external_memory_host","EXT_filter_cubic","EXT_fragment_density_map",
"EXT_fragment_density_map2","EXT_fragment_density_map_offset",
"EXT_fragment_shader_interlock","EXT_frame_boundary","EXT_global_priority",
"EXT_global_priority_query","EXT_graphics_pipeline_library","EXT_host_image_copy",
"EXT_host_query_reset","EXT_image_2d_view_of_3d","EXT_image_compression_control",
"EXT_image_drm_format_modifier","EXT_image_robustness","EXT_image_sliced_view_of_3d",
"EXT_image_view_min_lod","EXT_index_type_uint8","EXT_inline_uniform_block",
"EXT_legacy_dithering","EXT_legacy_vertex_attributes","EXT_line_rasterization",
"EXT_load_store_op_none","EXT_memory_budget","EXT_memory_priority","EXT_mesh_shader",
"EXT_multi_draw","EXT_multisampled_render_to_single_sampled","EXT_mutable_descriptor_type",
"EXT_nested_command_buffer","EXT_non_seamless_cube_map","EXT_opacity_micromap",
"EXT_pageable_device_local_memory","EXT_pci_bus_info","EXT_physical_device_drm",
"EXT_pipeline_creation_cache_control","EXT_pipeline_creation_feedback",
"EXT_pipeline_library_group_handles","EXT_pipeline_properties",
"EXT_pipeline_protected_access","EXT_pipeline_robustness","EXT_post_depth_coverage",
"EXT_present_mode_fifo_latest_ready","EXT_primitive_topology_list_restart",
"EXT_primitives_generated_query","EXT_private_data","EXT_provoking_vertex",
"EXT_queue_family_foreign","EXT_rasterization_order_attachment_access",
"EXT_ray_tracing_invocation_reorder","EXT_rgba10x6_formats","EXT_robustness2",
"EXT_sample_locations","EXT_sampler_filter_minmax","EXT_scalar_block_layout",
"EXT_separate_stencil_usage","EXT_shader_64bit_indexing","EXT_shader_atomic_float",
"EXT_shader_atomic_float2","EXT_shader_demote_to_helper_invocation","EXT_shader_float8",
"EXT_shader_image_atomic_int64","EXT_shader_long_vector","EXT_shader_module_identifier",
"EXT_shader_object","EXT_shader_replicated_composites","EXT_shader_stencil_export",
"EXT_shader_subgroup_ballot","EXT_shader_subgroup_partitioned","EXT_shader_subgroup_vote",
"EXT_shader_tile_image","EXT_shader_viewport_index_layer","EXT_subgroup_size_control",
"EXT_subpass_merge_feedback","EXT_swapchain_maintenance1","EXT_texel_buffer_alignment",
"EXT_texture_compression_astc_3d","EXT_texture_compression_astc_hdr","EXT_tooling_info",
"EXT_transform_feedback","EXT_vertex_attribute_divisor","EXT_vertex_attribute_robustness",
"EXT_vertex_input_dynamic_state","EXT_ycbcr_2plane_444_formats","EXT_ycbcr_image_arrays",
"EXT_zero_initialize_device_memory",
# Vendor extensions
"AMD_buffer_marker","AMD_device_coherent_memory","AMD_draw_indirect_count",
"AMD_mixed_attachment_samples","AMD_pipeline_compiler_control","AMD_rasterization_order",
"AMD_shader_ballot","AMD_shader_core_properties","AMD_shader_core_properties2",
"AMD_shader_early_and_late_fragment_tests","AMD_shader_explicit_vertex_parameter",
"AMD_shader_fragment_mask","AMD_shader_image_load_store_lod","AMD_shader_info",
"AMD_shader_trinary_minmax","AMD_texture_gather_bias_lod",
"AMDX_shader_enqueue",
"ANDROID_external_format_resolve","ANDROID_external_memory_android_hardware_buffer",
"ARM_rasterization_order_attachment_access","ARM_render_pass_striped",
"ARM_scheduling_controls","ARM_shader_core_builtins","ARM_shader_core_properties",
"GOOGLE_decorate_string","GOOGLE_display_timing","GOOGLE_hlsl_functionality1",
"GOOGLE_user_type",
"IMG_filter_cubic","IMG_relaxed_line_rasterization",
"INTEL_performance_query","INTEL_shader_integer_functions2",
"MESA_image_alignment_control",
"NV_clip_space_w_scaling","NV_compute_shader_derivatives","NV_cooperative_matrix",
"NV_corner_sampled_image","NV_coverage_reduction_mode","NV_dedicated_allocation",
"NV_dedicated_allocation_image_aliasing","NV_descriptor_pool_overallocation",
"NV_device_diagnostic_checkpoints","NV_device_diagnostics_config",
"NV_device_generated_commands","NV_device_generated_commands_compute",
"NV_extended_sparse_address_space","NV_fill_rectangle","NV_fragment_coverage_to_color",
"NV_fragment_shader_barycentric","NV_fragment_shading_rate_enums",
"NV_framebuffer_mixed_samples","NV_geometry_shader_passthrough",
"NV_inherited_viewport_scissor","NV_linear_color_attachment","NV_low_latency",
"NV_low_latency2","NV_memory_decompression","NV_mesh_shader",
"NV_per_stage_descriptor_set","NV_present_barrier","NV_push_constant_bank",
"NV_raw_access_chains","NV_ray_tracing","NV_ray_tracing_invocation_reorder",
"NV_ray_tracing_motion_blur","NV_ray_tracing_validation",
"NV_representative_fragment_test","NV_sample_mask_override_coverage",
"NV_scissor_exclusive","NV_shader_atomic_float16_vector","NV_shader_image_footprint",
"NV_shader_sm_builtins","NV_shader_subgroup_partitioned","NV_shading_rate_image",
"NV_viewport_array2","NV_viewport_swizzle","NV_win32_keyed_mutex",
"NVX_binary_import","NVX_image_view_handle","NVX_multiview_per_view_attributes",
"QCOM_cooperative_matrix_conversion","QCOM_filter_cubic_clamp","QCOM_filter_cubic_weights",
"QCOM_fragment_density_map_offset","QCOM_image_processing","QCOM_image_processing2",
"QCOM_multiview_per_view_render_areas","QCOM_multiview_per_view_viewports",
"QCOM_render_pass_shader_resolve","QCOM_render_pass_store_ops",
"QCOM_render_pass_transform","QCOM_tile_memory_heap","QCOM_tile_properties",
"QCOM_tile_shading","QCOM_ycbcr_degamma",
"SEC_amigo_profiling","SEC_pipeline_cache_incremental_mode",
"VALVE_descriptor_set_host_mapping","VALVE_fragment_density_map_layered",
"VALVE_mutable_descriptor_type","VALVE_shader_mixed_float_dot_product",
"VALVE_video_encode_rgb_conversion",
]

# ── Determine variable name used in the source file ───────────────────────────
ev = 'ext'
m = re.search(rf'\b(\w+)->{VENDORS}_\w+\s*=\s*true\s*;', content)
if m: ev = m.group(1)
else:
    m = re.search(r'struct vk_device_extension_table\s*\*\s*(\w+)', content)
    if m: ev = m.group(1)

# ── Find injection point — AFTER struct initialiser, BEFORE function end ──────
inject_pos = None

# Strategy 1: after  *ext = (struct vk_device_extension_table){ ... };
struct_m = re.search(r'\*\s*\w+\s*=\s*\(struct vk_device_extension_table\)\s*\{', content)
if struct_m:
    d = 1; p = struct_m.end()
    while p < len(content) and d > 0:
        if content[p] == '{': d += 1
        elif content[p] == '}': d -= 1
        p += 1
    while p < len(content) and content[p] in ' \t\r\n;': p += 1
    inject_pos = p
    print(f"[OK] Inject after struct-init at pos {inject_pos}")

# Strategy 2: end of the device-extensions function body
if inject_pos is None:
    for pat in [
        r'tu_get_device_extensions\s*\([^{]*?\{',
        r'tu_get_device_extension_table\s*\([^{]*?\{',
        r'get_device_extensions\s*\([^{]*?\{',
    ]:
        fm = re.search(pat, content, re.DOTALL)
        if fm:
            d = 1; p = fm.end()
            while p < len(content) and d > 0:
                if content[p] == '{': d += 1
                elif content[p] == '}': d -= 1
                p += 1
            inject_pos = p - 1
            print(f"[OK] Inject at function end pos {inject_pos}")
            break

# Strategy 3: after last any extension assignment
if inject_pos is None:
    lm = None
    for m in re.finditer(
            rf'(?:\.{VENDORS}_\w+\s*=\s*true|{VENDORS}_\w+\s*=\s*true\s*;)', content):
        lm = m
    if lm:
        inject_pos = lm.end()
        print(f"[OK] Fallback inject after last assignment pos {inject_pos}")

# ── Build and inject block ────────────────────────────────────────────────────
if inject_pos is not None:
    lines = ["\n    /* === EXT_FORCE_ALL: unconditional override after struct === */"]
    for ext in TARGET_EXTS:
        lines.append(f"    {ev}->{ext} = true;")
    lines.append("    /* === EXT_FORCE_ALL END === */")
    injection = "\n".join(lines) + "\n"
    content = content[:inject_pos] + injection + content[inject_pos:]
    print(f"[OK] Injected {len(TARGET_EXTS)} TARGET_EXTS at pos {inject_pos}")
else:
    print("[WARN] No injection point found — only Pass 2 changes applied")

with open(tu_path, 'w', encoding='utf-8') as f:
    f.write(content)

# ── Final count ───────────────────────────────────────────────────────────────
total_ptr    = len(re.findall(rf'\b\w+->{VENDORS}_\w+\s*=\s*true\s*;', content))
total_struct = len(re.findall(rf'\.{VENDORS}_\w+\s*=\s*true\s*,?', content))
print(f"[OK] FINAL: {total_ptr + total_struct} extension fields set to true")
print(f"     ({total_struct} struct-init, {total_ptr} pointer-assign)")
PYEOF

    log_success "Vulkan extensions support applied"
}



# ── Rob Clark fd/misc branch — a8xx_gen1 VPC sysmem buffer sizes ─────────────
# Commit: freedreno_devices.py — a8xx_gen1 = GPUProps(
#   reg_size_vec4 = 128,
#   sysmem_vpc_attr_buf_size = 131072,   # 128 KB  — VPC attribute buffer
#   sysmem_vpc_pos_buf_size  = 65536,    #  64 KB  — VPC position buffer
#   sysmem_vpc_bv_pos_buf_size = 32768,  #  32 KB  — BV position buffer
# These are NOT yet in Mesa main. They fix sysmem rendering perf on A830/A810.
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

# Find a8xx_gen1 GPUProps block and add the sysmem VPC buffer fields
# Pattern: locate "a8xx_gen1 = GPUProps(" and inject after reg_size_vec4 line
NEW_FIELDS = """
    sysmem_vpc_attr_buf_size  = 131072,   # 128 KB — VPC attribute buffer (Rob Clark fd/misc)
    sysmem_vpc_pos_buf_size   = 65536,    #  64 KB — VPC position buffer
    sysmem_vpc_bv_pos_buf_size = 32768,   #  32 KB — BV position buffer
"""

# Try to inject after reg_size_vec4 = 128 inside a8xx_gen1
pat = r'(a8xx_gen1\s*=\s*GPUProps\s*\([^\)]*?reg_size_vec4\s*=\s*128\s*,)'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.end()] + NEW_FIELDS + c[m.end():]
    print("[OK] Injected sysmem VPC buffer sizes into a8xx_gen1 GPUProps")
else:
    # Fallback: find a8xx_gen1 block and append before closing paren
    pat2 = r'(a8xx_gen1\s*=\s*GPUProps\s*\()(.*?)(\))'
    m2 = re.search(pat2, c, re.DOTALL)
    if m2:
        c = c[:m2.end()-1] + NEW_FIELDS + c[m2.end()-1:]
        print("[OK] Injected sysmem VPC buffer sizes (fallback)")
    else:
        print("[WARN] a8xx_gen1 GPUProps block not found — skipping VPC patch")

with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "a8xx_gen1 VPC sysmem buffer props applied"
}

# ── Rob Clark fd/misc branch — Reduce advertised memory ──────────────────────
# Red Magic 10 Air — SD 8 Gen 3 (A750/a8xx gen1), 12GB LPDDR5X
# Physical: 12GB = 12884901888 bytes
# Android usable: ~75% = 9663676416 (~9GB)
# Mesa should advertise 9GB max, not 12GB (avoids OOM kills)
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

# SD 8 Gen 3 (A750) on Red Magic 10 Air has 12GB LPDDR5X
# Android's mmap limit is ~75% of physical RAM
# Cap all Vulkan heap size reports to 75% of what the kernel reports
changed = 0

# Pattern 1: .heapSize = <expr>  in VkPhysicalDeviceMemoryProperties
new, n = re.subn(
    r'(\.heapSize\s*=\s*)([^,};\n]+)',
    r'\1((\2) * 3 / 4)  /* REDUCED_HEAP_CAP: 75% of physical */',
    c, count=2  # up to 2 heap entries (device-local + host-visible)
)
if n:
    c = new; changed += n
    print(f"[OK] .heapSize capped at 75% ({n} entries)")

# Pattern 2: explicit heap_size variable assignment
if not changed:
    new, n = re.subn(
        r'((?:heap|memory)_size\s*=\s*)(total_mem\w*|avail_mem\w*|mem_size\w*|[a-z_]*size[a-z_]*\s*[^;]{0,60})(;)',
        r'\1((\2) * 3 / 4) /* REDUCED_HEAP_CAP */\3',
        c, count=1
    )
    if n:
        c = new; changed += n
        print(f"[OK] heap_size variable capped at 75%")

if not changed:
    print("[WARN] No heap size pattern found — memory cap skipped")

with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "Reduced advertised memory applied (SD 8 Gen 3 / 12GB optimized)"
}


# ═══════════════════════════════════════════════════════════════════════════════
# apply_rt_stub_support — Layer 1: RT / DXR / PT stub inside Turnip
# ───────────────────────────────────────────────────────────────────────────────
# Root cause of the winevulkan assertion:
#   File: .../winevulkan/loader_thunks.c  Line: 3156
#   Expression: "!status && "vkCreateRayTracingPipelinesKHR""
#
# The loader thunk asserts when vkCreateRayTracingPipelinesKHR returns != VK_SUCCESS.
# Turnip has stubs that return VK_ERROR_FEATURE_NOT_PRESENT because the RT
# properties are all zeroed out (shaderGroupHandleSize=0 → driver bails early).
#
# Fix strategy — match what Qualcomm does in vendor driver updates:
#   1. Fill RT property structs with valid non-zero values
#   2. Fill RT feature bits = true
#   3. Patch the pipeline-create stub to always return VK_SUCCESS
#      (no real shader invocation — draws nothing, but doesn't crash)
#   4. Patch vkCmdTraceRaysKHR to be a safe no-op
#
# DXR 1.0 / 1.1 detection:  VKD3D queries Vulkan RT properties; if valid → passes
# PT (Path Tracing) detection: same path via DXR 1.1 + inline ray query
# DLSS detection: separate (NVAPI/NGX path) — handled in apply_dlss_ngx_stub
# ═══════════════════════════════════════════════════════════════════════════════
apply_rt_stub_support() {
    local tu_dev="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_dev" ]] && { log_warn "RT stub: tu_device.cc not found"; return 0; }
    if grep -q "RT_STUB_APPLIED\|shaderGroupHandleSize.*=.*32" "$tu_dev"; then
        log_info "RT stub already applied"
        return 0
    fi
    log_info "Applying RT stub (DXR/PT detection fix)"
    python3 - "$tu_dev" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, encoding='utf-8', errors='ignore') as f:
    c = f.read()

changed = 0

# ── 1. RT Pipeline Properties ─────────────────────────────────────────────────
# VkPhysicalDeviceRayTracingPipelinePropertiesKHR
# Adreno 750 RT engine specs (conservative safe values):
#   shaderGroupHandleSize      = 32   (spec minimum; all drivers use 32)
#   shaderGroupHandleAlignment = 32   (spec minimum)
#   shaderGroupBaseAlignment   = 64   (64-byte SBT base alignment)
#   shaderGroupHandleCaptureReplaySize = 32
#   maxRayRecursionDepth       = 1    (stub: 1 level, no real recursion)
#   maxShaderGroupStride       = 4096
#   maxRayDispatchInvocationCount = 1073741824  (2^30, spec max)
#   maxRayHitAttributeSize     = 32
RT_PROPS = {
    r'(shaderGroupHandleSize\s*=\s*)\d+':      r'\g<1>32',
    r'(shaderGroupHandleAlignment\s*=\s*)\d+': r'\g<1>32',
    r'(shaderGroupBaseAlignment\s*=\s*)\d+':   r'\g<1>64',
    r'(shaderGroupHandleCaptureReplaySize\s*=\s*)\d+': r'\g<1>32',
    r'(maxRayRecursionDepth\s*=\s*)\d+':       r'\g<1>1',
    r'(maxShaderGroupStride\s*=\s*)\d+':       r'\g<1>4096',
    r'(maxRayDispatchInvocationCount\s*=\s*)\d+': r'\g<1>1073741824',
    r'(maxRayHitAttributeSize\s*=\s*)\d+':     r'\g<1>32',
}
for pat, rep in RT_PROPS.items():
    new, n = re.subn(pat, rep, c)
    if n: c = new; changed += n; print(f"  [RT-PROP] {pat[:50]} → {n} match(es)")

# ── 2. RT Feature Bits ────────────────────────────────────────────────────────
# VkPhysicalDeviceRayTracingPipelineFeaturesKHR
# VkPhysicalDeviceAccelerationStructureFeaturesKHR
# VkPhysicalDeviceRayQueryFeaturesKHR
RT_FEATURES = [
    r'rayTracingPipeline\s*=\s*VK_FALSE',
    r'rayTracingPipelineTraceRaysIndirect\s*=\s*VK_FALSE',
    r'rayTracingPipelineShaderGroupHandleCaptureReplay\s*=\s*VK_FALSE',
    r'accelerationStructure\s*=\s*VK_FALSE',
    r'accelerationStructureCapturereplay\s*=\s*VK_FALSE',
    r'accelerationStructureIndirectBuild\s*=\s*VK_FALSE',
    r'descriptorBindingAccelerationStructureUpdateAfterBind\s*=\s*VK_FALSE',
    r'rayQuery\s*=\s*VK_FALSE',
]
for pat in RT_FEATURES:
    # Use a lambda so the replacement is computed from match, never from pattern text
    # (using pattern text as replacement causes bad escape on \s)
    new, n = re.subn(pat, lambda m: m.group(0).replace('VK_FALSE', 'VK_TRUE'), c)
    if n: c = new; changed += n; print(f"  [RT-FEAT] {pat[:60]}")

# ── 3. Stub vkCreateRayTracingPipelinesKHR → always VK_SUCCESS ───────────────
# Find the function and inject early-return VK_SUCCESS if handles are non-null
# Pattern: match the function body opening brace
stub_pattern = r'(vkCreateRayTracingPipelinesKHR\b[^{]{0,300}\{)'
def inject_stub_return(m):
    return m.group(0) + '''
   /* RT_STUB_APPLIED: return VK_SUCCESS stub — no real RT backend */
   if (pPipelines) {
      for (uint32_t _i = 0; _i < createInfoCount; _i++)
         pPipelines[_i] = VK_NULL_HANDLE;
   }
   return VK_SUCCESS;
'''
new, n = re.subn(stub_pattern, inject_stub_return, c, count=1, flags=re.DOTALL)
if n:
    c = new; changed += n
    print(f"  [RT-STUB] Injected VK_SUCCESS stub into vkCreateRayTracingPipelinesKHR")
else:
    print(f"  [RT-WARN] vkCreateRayTracingPipelinesKHR body not found — stub not injected")

# ── 4. Make vkCmdTraceRaysKHR a safe no-op ───────────────────────────────────
trace_pattern = r'(vkCmdTraceRaysKHR\b[^{]{0,300}\{)'
def inject_trace_noop(m):
    return m.group(0) + '''
   /* RT_STUB_APPLIED: no-op trace — no real RT backend */
   (void)commandBuffer; (void)pRaygenShaderBindingTable;
   (void)pMissShaderBindingTable; (void)pHitShaderBindingTable;
   (void)pCallableShaderBindingTable;
   (void)width; (void)height; (void)depth;
   return;
'''
new, n = re.subn(trace_pattern, inject_trace_noop, c, count=1, flags=re.DOTALL)
if n:
    c = new; changed += n
    print(f"  [RT-STUB] Injected no-op into vkCmdTraceRaysKHR")
else:
    print(f"  [RT-WARN] vkCmdTraceRaysKHR body not found — no-op not injected")

print(f"[OK] RT stub: {changed} change(s) total")
with open(path, 'w', encoding='utf-8') as f: f.write(c)
PYEOF
    log_success "RT stub applied (DXR 1.0 / DXR 1.1 / PT detection should now pass)"
}


# ═══════════════════════════════════════════════════════════════════════════════
# apply_dlss_ngx_stub — Layer 2: DLSS detection emulation via NGX stub
# ───────────────────────────────────────────────────────────────────────────────
# DLSS detection chain:
#   App → D3D12Device → NVAPI (nvapi64.dll) → NGX (nvngx.dll / _nvngx.dll)
#       → NVSDK_NGX_D3D12_Init → feature query → DLSS feature available
#
# Since we already spoof GPU as NVIDIA RTX 4090 (deck_emu), the app believes
# it's on NVIDIA hardware. The missing piece is that Wine's NVAPI stub and
# NGX don't report DLSS as available.
#
# Fix: patch the Wine NVAPI detection layer inside Mesa's WSI/device reporting
# so that:
#   1. NvAPI_GPU_GetGPUType    → NVAPI_GPU_TYPE_DISCRETE
#   2. NvAPI_GPU_GetFullName   → "NVIDIA GeForce RTX 4090"
#   3. NvAPI_GPU_GetPCIIdentifiers → vendor=0x10DE device=0x2684
#   4. NGX init returns success (handled by dxvk-nvapi side)
#
# The Mesa side: ensure PCI IDs and driver version match NVIDIA blob expectations.
# This is done via tu_device.cc property injection (same as deck_emu does).
# ═══════════════════════════════════════════════════════════════════════════════
apply_dlss_ngx_stub() {
    local tu_dev="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_dev" ]] && { log_warn "DLSS stub: tu_device.cc not found"; return 0; }

    # DLSS requires deck_emu NVIDIA to already be applied (vendor=0x10DE etc.)
    if ! grep -q "0x10DE\|NVIDIA\|DECK_EMU" "$tu_dev"; then
        log_warn "DLSS stub: deck_emu NVIDIA not applied — DLSS stub skipped"
        log_warn "Set DECK_EMU_TARGET=nvidia and ENABLE_DECK_EMU=true"
        return 0
    fi
    if grep -q "DLSS_NGX_STUB\|driverVersion.*0x15F" "$tu_dev"; then
        log_info "DLSS NGX stub already applied"
        return 0
    fi

    log_info "Applying DLSS/NGX driver-version stub"
    python3 - "$tu_dev" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, encoding='utf-8', errors='ignore') as f:
    c = f.read()

changed = 0

# ── NVIDIA driver version: NGX requires >= 520.xx (0x20800 VkDriverVersion) ──
# Encode as Vulkan driver version: VK_MAKE_VERSION(535,86,0) = 0x21CD6000
# (535.86 is a known good baseline for DLSS 3.x)
NVIDIA_DRIVER_VER = '0x21CD6000'  # 535.86.0

dv_pats = [
    (r'(driverVersion\s*=\s*)0x[0-9A-Fa-f]+', rf'\g<1>{NVIDIA_DRIVER_VER}'),
    (r'(driverVersion\s*=\s*)\d+',             rf'\g<1>{NVIDIA_DRIVER_VER}'),
]
for pat, rep in dv_pats:
    new, n = re.subn(pat, rep, c)
    if n: c = new; changed += n; print(f"  [DLSS] driverVersion = {NVIDIA_DRIVER_VER} ({n} match)")

# ── Conformance version: NVIDIA reports 1.3.x.0 for Vulkan 1.3 ───────────────
cv_pat = r'(conformanceVersion\s*\{[^}]*major\s*=\s*)(\d+)'
new, n = re.subn(cv_pat, r'\g<1>1', c)
if n: c = new; changed += n; print(f"  [DLSS] conformanceVersion.major = 1")

# ── Mark done ─────────────────────────────────────────────────────────────────
# Add a sentinel comment near top of file after first include
c = c.replace('#include "tu_device.h"',
              '#include "tu_device.h"\n/* DLSS_NGX_STUB: applied */\n', 1)

print(f"[OK] DLSS NGX stub: {changed} change(s) total")
with open(path, 'w', encoding='utf-8') as f: f.write(c)
PYEOF
    log_success "DLSS/NGX driver-version stub applied"
}


# ═══════════════════════════════════════════════════════════════════════════════
# apply_d3d12_basic_fix — Layer 3: Fix D3D12 basic init failure
# ───────────────────────────────────────────────────────────────────────────────
# "Failed to init D3D12" means VKD3D itself fails to create the device.
# Most common causes on Turnip:
#   1. Descriptor indexing count < 1,000,000 (VKD3D hard requirement)
#   2. Missing mandatory extension (VK_EXT_robustness2 or VK_KHR_push_descriptor)
#   3. Vulkan 1.3 features struct missing fields
#
# Fix: ensure tu_device.cc reports maxDescriptorSetUpdateAfterBindSampledImages
# and related counters at ≥ 1,000,000, and that all mandatory descriptor
# indexing features are set to VK_TRUE.
# ═══════════════════════════════════════════════════════════════════════════════
apply_d3d12_basic_fix() {
    local tu_dev="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_dev" ]] && { log_warn "D3D12 basic fix: tu_device.cc not found"; return 0; }
    if grep -q "D3D12_BASIC_FIX\|maxDescriptorSetUpdateAfterBind.*1048576" "$tu_dev"; then
        log_info "D3D12 basic fix already applied"
        return 0
    fi
    log_info "Applying D3D12 basic descriptor indexing fix"
    python3 - "$tu_dev" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, encoding='utf-8', errors='ignore') as f:
    c = f.read()

changed = 0

# ── 1. Descriptor counts: VKD3D requires >= 1,000,000 UpdateAfterBind ────────
DESC_LIMITS = {
    # Samplers
    r'(maxDescriptorSetUpdateAfterBindSamplers\s*=\s*)(\d+)':
        (1000000, r'\g<1>1000000'),
    # Sampled images (textures)
    r'(maxDescriptorSetUpdateAfterBindSampledImages\s*=\s*)(\d+)':
        (1000000, r'\g<1>1000000'),
    # Storage images
    r'(maxDescriptorSetUpdateAfterBindStorageImages\s*=\s*)(\d+)':
        (1000000, r'\g<1>1000000'),
    # Storage buffers
    r'(maxDescriptorSetUpdateAfterBindStorageBuffers\s*=\s*)(\d+)':
        (1000000, r'\g<1>1000000'),
    # Uniform buffers (VKD3D doesn't require 1M for UBO, 72 is fine)
    # sampled images per stage
    r'(maxPerStageDescriptorUpdateAfterBindSampledImages\s*=\s*)(\d+)':
        (1048576, r'\g<1>1048576'),
    r'(maxPerStageDescriptorUpdateAfterBindStorageImages\s*=\s*)(\d+)':
        (1048576, r'\g<1>1048576'),
    r'(maxPerStageDescriptorUpdateAfterBindStorageBuffers\s*=\s*)(\d+)':
        (1048576, r'\g<1>1048576'),
    # Total resources per stage
    r'(maxPerStageUpdateAfterBindResources\s*=\s*)(\d+)':
        (1048576, r'\g<1>1048576'),
}
for pat, (min_val, rep) in DESC_LIMITS.items():
    # Only replace if current value < min_val
    def maybe_replace(m, min_v=min_val, r=rep):
        try:
            cur = int(m.group(2))
            if cur < min_v:
                return re.sub(pat, r, m.group(0))
        except (IndexError, ValueError):
            pass
        return m.group(0)
    new, n = re.subn(pat, maybe_replace, c)
    if n: c = new; changed += n; print(f"  [DESC] Patched {pat[:60]}")

# ── 2. Mandatory descriptor indexing features ─────────────────────────────────
INDEXING_FEATURES = [
    'shaderSampledImageArrayNonUniformIndexing',
    'shaderStorageBufferArrayNonUniformIndexing',
    'shaderStorageImageArrayNonUniformIndexing',
    'shaderUniformTexelBufferArrayNonUniformIndexing',
    'shaderStorageTexelBufferArrayNonUniformIndexing',
    'descriptorBindingSampledImageUpdateAfterBind',
    'descriptorBindingStorageImageUpdateAfterBind',
    'descriptorBindingStorageBufferUpdateAfterBind',
    'descriptorBindingUniformTexelBufferUpdateAfterBind',
    'descriptorBindingStorageTexelBufferUpdateAfterBind',
    'descriptorBindingUpdateUnusedWhilePending',
    'descriptorBindingPartiallyBound',
    'descriptorBindingVariableDescriptorCount',
    'runtimeDescriptorArray',
]
for feat in INDEXING_FEATURES:
    new, n = re.subn(rf'({feat}\s*=\s*)VK_FALSE', rf'\g<1>VK_TRUE', c)
    if n: c = new; changed += n; print(f"  [IDX] {feat} = VK_TRUE")

# ── 3. Vulkan 1.3 core features that VKD3D 3.x requires ─────────────────────
VK13_FEATURES = [
    'dynamicRendering',
    'synchronization2',
    'maintenance4',
    'shaderIntegerDotProduct',
    'inlineUniformBlock',
    'pipelineCreationCacheControl',
]
for feat in VK13_FEATURES:
    new, n = re.subn(rf'({feat}\s*=\s*)VK_FALSE', rf'\g<1>VK_TRUE', c)
    if n: c = new; changed += n; print(f"  [VK13] {feat} = VK_TRUE")

# ── Mark done ─────────────────────────────────────────────────────────────────
c = c.replace('/* DLSS_NGX_STUB: applied */',
              '/* DLSS_NGX_STUB: applied */\n/* D3D12_BASIC_FIX: applied */', 1)
if '/* D3D12_BASIC_FIX: applied */' not in c:
    c = c.replace('#include "tu_device.h"',
                  '#include "tu_device.h"\n/* D3D12_BASIC_FIX: applied */', 1)

print(f"[OK] D3D12 basic fix: {changed} change(s) total")
with open(path, 'w', encoding='utf-8') as f: f.write(c)
PYEOF
    log_success "D3D12 basic descriptor indexing fix applied"
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
        # Rob Clark upstream patches (always apply when building a8xx)
        if [[ "$TARGET_GPU" == "a8xx" ]]; then
            apply_a8xx_vpc_props
            apply_sd8gen3_tuning
        fi
        apply_reduce_advertised_memory
        if [[ "$BUILD_VARIANT" == "autotuner" ]]; then
            apply_a6xx_query_fix
        fi

        # ── D3D12 / DXR / DLSS compatibility stack ─────────────────────────
        # Layer 3: Fix D3D12 basic init (descriptor indexing requirements)
        apply_d3d12_basic_fix
        # Layer 1: RT stub (fixes winevulkan assertion + DXR 1.0/1.1/PT detect)
        apply_rt_stub_support
        # Layer 2: DLSS/NGX driver-version stub (requires deck_emu NVIDIA)
        if [[ "$ENABLE_DECK_EMU" == "true" && "$DECK_EMU_TARGET" == "nvidia" ]]; then
            apply_dlss_ngx_stub
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
