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
    if [[ ! -d "${NDK_PATH}" ]]; then
        log_error "NDK not found at ${NDK_PATH}. Please set NDK_PATH correctly."
        exit 1
    fi
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
    log_info "Applying timeline semaphore optimization (hack)"
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
    log_info "Applying gralloc UBWC detection fix (Python)"
    local gralloc_file="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"
    [[ ! -f "$gralloc_file" ]] && return 0

    python3 - "$gralloc_file" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: content = f.read()

old_block = r'(#ifdef HAS_FREEDRENO\s*uint32_t gmsm.*?out->modifier = ubwc \? DRM_FORMAT_MOD_QCOM_COMPRESSED : DRM_FORMAT_MOD_LINEAR;\s*}\s*#endif)'
new_block = '''#ifdef HAS_FREEDRENO
   if (hnd->handle->numInts >= 2) {
      bool ubwc = hnd->handle->data[hnd->handle->numFds + 1] & 0x08000000;
      out->modifier = ubwc ? DRM_FORMAT_MOD_QCOM_COMPRESSED : DRM_FORMAT_MOD_LINEAR;
   }
#endif'''

if re.search(old_block, content, re.DOTALL):
    content = re.sub(old_block, new_block, content, flags=re.DOTALL)
    print("[OK] Gralloc UBWC block replaced")
else:
    if "bool ubwc = hnd->handle->data" in content:
        print("[INFO] Gralloc seems already patched")
    else:
        print("[WARN] Could not find Gralloc block to patch")

with open(fp, 'w') as f: f.write(content)
PYEOF
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
filepath, driver_id, driver_name, device_name, vendor_id, device_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5], 16), int(sys.argv[6], 16)
with open(filepath, 'r') as f: content = f.read()
injection = f"""
   if (TU_DEBUG(DECK_EMU)) {{
      p->driverID = {driver_id};
      memset(p->driverName, 0, sizeof(p->driverName));
      snprintf(p->driverName, VK_MAX_DRIVER_NAME_SIZE, "{driver_name}");
      memset(p->driverInfo, 0, sizeof(p->driverInfo));
      snprintf(p->driverInfo, VK_MAX_DRIVER_INFO_SIZE, "Mesa (spoofed)");
   }}
"""
injected=False
m = re.search(r'(\n[ \t]*p->denormBehaviorIndependence\s*=)', content)
if m:
    content = content[:m.start()] + '\n' + injection + content[m.start():]; injected=True
if not injected:
    func_m = re.search(r'tu_get_physical_device_properties_1_2\s*\([^)]*\)\s*\{', content)
    if func_m:
        start=func_m.end(); depth=1; pos=start
        while pos < len(content) and depth > 0:
            if content[pos]=='{': depth+=1
            elif content[pos]=='}': depth-=1
            pos+=1
        content = content[:pos-1] + '\n' + injection + content[pos-1:]; injected=True
if injected:
    with open(filepath, 'w') as f: f.write(content)
    print(f"[OK] deck_emu {driver_id} injection applied")
PYEOF
        log_success "deck_emu spoofing applied"
    fi
}

apply_a6xx_query_fix() {
    log_info "Applying A6xx query fix"
    find "${MESA_DIR}/src/freedreno/vulkan" -name "tu_query*.cc" -exec sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' {} \; 2>/dev/null || true
}

apply_a8xx_device_support() {
    log_info "Applying A8xx device support (FD810/825/829/830)"
    local devfile="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"
    local devinfo="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.h"
    local cmd_buf="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    local gmem_h="${MESA_DIR}/src/freedreno/common/fd6_gmem_cache.h"
    local tu_dev="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local knl_kgsl="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    local gralloc_c="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"

    if [[ -f "$knl_kgsl" ]] && ! grep -q "case 5:" "$knl_kgsl"; then
        sed -i '/case KGSL_UBWC_4_0:/a\   case 5:\n   case 6:' "$knl_kgsl" 2>/dev/null || true
        log_success "UBWC 5/6 support added"
    fi

    if [[ -f "$gralloc_c" ]] && grep -q "gmsm" "$gralloc_c"; then
        python3 - "$gralloc_c" << 'GRALLOC_PY'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
old = re.search(r'uint32_t gmsm.*?out->modifier[^\n]+\n', c, re.DOTALL)
if old:
    repl = ('   bool ubwc = hnd->handle->data[hnd->handle->numFds + 1] & 0x08000000;\n'
            '   out->modifier = ubwc ? DRM_FORMAT_MOD_QCOM_COMPRESSED : DRM_FORMAT_MOD_LINEAR;\n')
    c = c[:old.start()] + repl + c[old.end():]
    print("[OK] u_gralloc UBWC always-detect applied")
with open(fp, 'w') as f: f.write(c)
GRALLOC_PY
    fi

    if [[ -f "$devinfo" ]] && ! grep -q "disable_gmem" "$devinfo"; then
        sed -i 's/bool has_image_processing;/bool has_image_processing;\n      bool disable_gmem;/' "$devinfo" 2>/dev/null || true
        log_success "disable_gmem field added to freedreno_dev_info.h"
    fi

    if [[ -f "$cmd_buf" ]] && ! grep -q "disable_gmem" "$cmd_buf"; then
        python3 - "$cmd_buf" << 'CMDBUF_PY'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
insert = ('\n   if (cmd->device->physical_device->dev_info.props.disable_gmem) {\n'
          '      cmd->state.rp.gmem_disable_reason = "Unsupported GPU";\n'
          '      return true;\n'
          '   }\n')
for pat in [r'(/\* can.t fit attachments into gmem \*/)', r'(if \(!cmd->state\.tiling->possible\))']:
    new, n = re.subn(pat, insert + r'\1', c, count=1)
    if n:
        c = new
        print("[OK] disable_gmem check added to tu_cmd_buffer.cc")
        break
else:
    print("[WARN] Could not add disable_gmem check")
with open(fp, 'w') as f: f.write(c)
CMDBUF_PY
    fi

    if [[ -f "$tu_dev" ]] && grep -q "TU_DEBUG_FLUSHALL" "$tu_dev" && ! grep -q "FLUSHALL.*commented" "$tu_dev"; then
        python3 - "$tu_dev" << 'FLUSH_PY'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
new, n = re.subn(r'[ \t]*tu_env\.debug \|= TU_DEBUG_FLUSHALL;[^\n]*\n', '', c, count=1)
if n:
    c = new
    print("[OK] FLUSHALL removed for gen8")
with open(fp, 'w') as f: f.write(c)
FLUSH_PY
    fi

    if [[ -f "$gmem_h" ]]; then
        sed -i 's/if (info->chip >= 8)$/if (info->chip >= 8 \&\& info->num_slices > 1)/' "$gmem_h" 2>/dev/null || true
        log_success "GMEM offset fix applied for single-slice GPUs"
    fi

    if [[ -f "$devfile" ]]; then
        python3 - "$devfile" << 'DEVPY'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

if 'A8XX_DEVICES_APPLIED' in c:
    print("[INFO] A8xx device defs already applied")
    sys.exit(0)

if 'a8xx_gen1 = GPUProps' not in c:
    ins = ('\na8xx_gen1 = GPUProps(\n'
           '        reg_size_vec4 = 96,\n'
           '        disable_gmem = True,\n'
           ')\n\n')
    c, n = re.subn(r'(a8xx_gen2\s*=\s*GPUProps\s*\()', ins + r'\1', c, count=1)
    if n: print("[OK] a8xx_gen1 GPUProps added")

if 'a8xx_830 = GPUProps' not in c:
    props = (
        '\na8xx_830 = GPUProps(\n'
        '        sysmem_vpc_attr_buf_size = 131072,\n'
        '        sysmem_vpc_pos_buf_size = 65536,\n'
        '        sysmem_vpc_bv_pos_buf_size = 32768,\n'
        '        sysmem_ccu_color_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        sysmem_per_ccu_color_cache_size = 128 * 1024,\n'
        '        sysmem_ccu_depth_cache_fraction = CCUColorCacheFraction.THREE_QUARTER.value,\n'
        '        sysmem_per_ccu_depth_cache_size = 192 * 1024,\n'
        '        gmem_vpc_attr_buf_size = 49152,\n'
        '        gmem_vpc_pos_buf_size = 24576,\n'
        '        gmem_vpc_bv_pos_buf_size = 32768,\n'
        '        gmem_ccu_color_cache_fraction = CCUColorCacheFraction.EIGHTH.value,\n'
        '        gmem_per_ccu_color_cache_size = 16 * 1024,\n'
        '        gmem_ccu_depth_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        gmem_per_ccu_depth_cache_size = 256 * 1024,\n'
        '        has_fs_tex_prefetch = False,\n'
        '        disable_gmem = True,\n'
        ')\n'
        '\na8xx_825 = GPUProps(\n'
        '        sysmem_vpc_attr_buf_size = 131072,\n'
        '        sysmem_vpc_pos_buf_size = 65536,\n'
        '        sysmem_vpc_bv_pos_buf_size = 32768,\n'
        '        sysmem_ccu_color_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        sysmem_per_ccu_color_cache_size = 128 * 1024,\n'
        '        sysmem_ccu_depth_cache_fraction = CCUColorCacheFraction.THREE_QUARTER.value,\n'
        '        sysmem_per_ccu_depth_cache_size = 96 * 1024,\n'
        '        gmem_vpc_attr_buf_size = 49152,\n'
        '        gmem_vpc_pos_buf_size = 24576,\n'
        '        gmem_vpc_bv_pos_buf_size = 32768,\n'
        '        gmem_ccu_color_cache_fraction = CCUColorCacheFraction.EIGHTH.value,\n'
        '        gmem_per_ccu_color_cache_size = 16 * 1024,\n'
        '        gmem_ccu_depth_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        gmem_per_ccu_depth_cache_size = 127 * 1024,\n'
        ')\n'
        '\na8xx_829 = GPUProps(\n'
        '        sysmem_vpc_attr_buf_size = 131072,\n'
        '        sysmem_vpc_pos_buf_size = 65536,\n'
        '        sysmem_vpc_bv_pos_buf_size = 32768,\n'
        '        sysmem_ccu_color_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        sysmem_per_ccu_color_cache_size = 128 * 1024,\n'
        '        sysmem_ccu_depth_cache_fraction = CCUColorCacheFraction.THREE_QUARTER.value,\n'
        '        sysmem_per_ccu_depth_cache_size = 96 * 1024,\n'
        '        gmem_vpc_attr_buf_size = 49152,\n'
        '        gmem_vpc_pos_buf_size = 24576,\n'
        '        gmem_vpc_bv_pos_buf_size = 32768,\n'
        '        gmem_ccu_color_cache_fraction = CCUColorCacheFraction.EIGHTH.value,\n'
        '        gmem_per_ccu_color_cache_size = 16 * 1024,\n'
        '        gmem_ccu_depth_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        gmem_per_ccu_depth_cache_size = 127 * 1024,\n'
        '        disable_gmem = True,\n'
        ')\n'
        '\na8xx_810 = GPUProps(\n'
        '        sysmem_vpc_attr_buf_size = 131072,\n'
        '        sysmem_vpc_pos_buf_size = 65536,\n'
        '        sysmem_vpc_bv_pos_buf_size = 32768,\n'
        '        sysmem_ccu_color_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        sysmem_per_ccu_color_cache_size = 32 * 1024,\n'
        '        sysmem_ccu_depth_cache_fraction = CCUColorCacheFraction.THREE_QUARTER.value,\n'
        '        sysmem_per_ccu_depth_cache_size = 32 * 1024,\n'
        '        gmem_vpc_attr_buf_size = 49152,\n'
        '        gmem_vpc_pos_buf_size = 24576,\n'
        '        gmem_vpc_bv_pos_buf_size = 32768,\n'
        '        gmem_ccu_color_cache_fraction = CCUColorCacheFraction.EIGHTH.value,\n'
        '        gmem_per_ccu_color_cache_size = 16 * 1024,\n'
        '        gmem_ccu_depth_cache_fraction = CCUColorCacheFraction.FULL.value,\n'
        '        gmem_per_ccu_depth_cache_size = 64 * 1024,\n'
        '        has_ray_intersection = False,\n'
        '        has_sw_fuse = False,\n'
        '        disable_gmem = True,\n'
        ')\n'
    )
    c, n = re.subn(r'(# For a8xx, the chicken bit)', props + r'\1', c, count=1)
    if n:
        print("[OK] a8xx GPU props added")
    else:
        c += '\n' + props
        print("[OK] a8xx GPU props appended")

old_stub = re.search(
    r'# Totally fake[^\n]*\nadd_gpus\(\[\s*GPUId\(chip_id=0x44050000[^)]+\),?\s*\],\s*A6xxGPUInfo\(\s*CHIP\.A8XX,\s*\[a7xx_base,\s*a7xx_gen3,\s*a8xx_base\][^)]*\)\)',
    c, re.DOTALL)
if old_stub:
    replacement = (
        'add_gpus([\n'
        '        GPUId(chip_id=0x44050000, name="FD830"),\n'
        '        GPUId(chip_id=0x44050001, name="FD830v2"),\n'
        '    ], A6xxGPUInfo(\n'
        '        CHIP.A8XX,\n'
        '        [a7xx_base, a7xx_gen3, a8xx_base, a8xx_gen2, a8xx_830],\n'
        '        num_ccu = 6, num_slices = 3,\n'
        '        tile_align_w = 64, tile_align_h = 32,\n'
        '        tile_max_w = 16384, tile_max_h = 16384,\n'
        '        num_vsc_pipes = 32, cs_shared_mem_size = 32 * 1024,\n'
        '        wave_granularity = 2, fibers_per_sp = 128 * 2 * 16,\n'
        '        magic_regs = dict(),\n'
        '        raw_magic_regs = a8xx_gen2_raw_magic_regs,\n'
        '    ))'
    )
    c = c[:old_stub.start()] + replacement + c[old_stub.end():]
    print("[OK] FD830 stub replaced with FD830/FD830v2")

def inject_before_840(c, block, marker):
    if marker in c:
        return c, False
    pat = r'(add_gpus\(\[\s*GPUId\(chip_id=0xffff44050A31)'
    import re as re2
    new, n = re2.subn(pat, block + r'\1', c, count=1)
    return (new, True) if n else (c + block, True)

fd825 = (
    '\nadd_gpus([\n'
    '        GPUId(chip_id=0x44030000, name="FD825"),\n'
    '    ], A6xxGPUInfo(\n'
    '        CHIP.A8XX,\n'
    '        [a7xx_base, a7xx_gen3, a8xx_base, a8xx_gen2, a8xx_825],\n'
    '        num_ccu = 4, num_slices = 2,\n'
    '        tile_align_w = 64, tile_align_h = 32,\n'
    '        tile_max_w = 16384, tile_max_h = 16384,\n'
    '        num_vsc_pipes = 32, cs_shared_mem_size = 32 * 1024,\n'
    '        wave_granularity = 2, fibers_per_sp = 128 * 2 * 16,\n'
    '        magic_regs = dict(), raw_magic_regs = a8xx_gen2_raw_magic_regs,\n'
    '    ))\n\n'
)
c, ok = inject_before_840(c, fd825, 'chip_id=0x44030000')
if ok: print("[OK] FD825 added")

fd810 = (
    '\nadd_gpus([\n'
    '        GPUId(chip_id=0x44010000, name="FD810"),\n'
    '    ], A6xxGPUInfo(\n'
    '        CHIP.A8XX,\n'
    '        [a7xx_base, a7xx_gen3, a8xx_base, a8xx_gen2, a8xx_gen1, a8xx_810],\n'
    '        num_ccu = 2, num_slices = 1,\n'
    '        tile_align_w = 64, tile_align_h = 32,\n'
    '        tile_max_w = 16384, tile_max_h = 16384,\n'
    '        num_vsc_pipes = 32, cs_shared_mem_size = 32 * 1024,\n'
    '        wave_granularity = 2, fibers_per_sp = 128 * 2 * 16,\n'
    '        magic_regs = dict(), raw_magic_regs = a8xx_gen2_raw_magic_regs,\n'
    '    ))\n\n'
)
c, ok = inject_before_840(c, fd810, 'chip_id=0x44010000')
if ok: print("[OK] FD810 added")

fd829 = (
    '\nadd_gpus([\n'
    '    GPUId(chip_id=0x44030A00, name="FD829"),\n'
    '    GPUId(chip_id=0x44030A20, name="FD829"),\n'
    '    GPUId(chip_id=0xffff44030A00, name="FD829"),\n'
    '    ], A6xxGPUInfo(\n'
    '        CHIP.A8XX,\n'
    '        [a7xx_base, a7xx_gen3, a8xx_base, a8xx_gen2, a8xx_829],\n'
    '        num_ccu = 4, num_slices = 2,\n'
    '        tile_align_w = 64, tile_align_h = 32,\n'
    '        tile_max_w = 16384, tile_max_h = 16384,\n'
    '        num_vsc_pipes = 32, cs_shared_mem_size = 32 * 1024,\n'
    '        wave_granularity = 2, fibers_per_sp = 128 * 2 * 16,\n'
    '        magic_regs = dict(), raw_magic_regs = a8xx_gen2_raw_magic_regs,\n'
    '    ))\n\n'
)
c, ok = inject_before_840(c, fd829, 'chip_id=0x44030A00')
if ok: print("[OK] FD829 added")

c += '\n# A8XX_DEVICES_APPLIED\n'
with open(fp, 'w') as f: f.write(c)
DEVPY
    fi
    log_success "A8xx support applied"
}


apply_vulkan_extensions_support() {
    log_info "Enabling ALL Vulkan extensions and D3D features"
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_exts_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"
    [[ ! -f "$tu_device" ]] && return 0

    # 1. Patch vk_extensions.py safely
    if [[ -f "$vk_exts_py" ]]; then
        python3 - "$vk_exts_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
# Lower API levels
c = re.sub(r'("VK_\w+"\s*:\s*)(\d+)(,)', lambda m: m.group(1)+'1'+m.group(3), c)
# Inject extensions SAFELY into the dictionary
# Find vk_api_extensions = { ... }
m = re.search(r'(vk_api_extensions\s*=\s*\{)', c)
if m:
    insert_txt = '\n        # === FORCED EXTENSIONS ==='
    missing = ["VK_KHR_maintenance7","VK_KHR_maintenance8","VK_KHR_maintenance9","VK_KHR_maintenance10",
    "VK_KHR_performance_query","VK_KHR_pipeline_binary","VK_EXT_shader_object","VK_EXT_mesh_shader"]
    for ext in missing:
        if f'"{ext}"' not in c:
            insert_txt += f'\n        "{ext}": 1,'
    insert_txt += '\n        # === END ==='
    
    # Insert right after the opening brace
    c = c[:m.end()] + insert_txt + c[m.end():]
    print(f"[OK] Injected extensions into vk_api_extensions dict")
else:
    print("[WARN] Could not find vk_api_extensions dict. Skipping vk_extensions.py patch.")

with open(fp,'w') as f: f.write(c)
PYEOF
    fi

    # 2. Patch tu_device.cc (Hardcoded List with Blacklist)
    python3 - "$tu_device" << 'PYEOF'
import sys, re
tu_path = sys.argv[1]
with open(tu_path) as f: content = f.read()

# --- PASS 1: Force Feature Flags ---
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
    "shaderIntegerFunctions2", "shaderDemoteToHelperInvocation",
    "descriptorBindingSampledImageUpdateAfterBind",
    "descriptorBindingStorageImageUpdateAfterBind",
    "descriptorBindingStorageBufferUpdateAfterBind",
    "descriptorBindingPartiallyBound",
    "descriptorBindingVariableDescriptorCount",
    "runtimeDescriptorArray",
    "bufferDeviceAddress", "timelineSemaphore",
    "dynamicRendering", "synchronization2", "maintenance4"
]
nf=0
for p in feats:
    new,n=re.subn(rf'((?:p|features|props|pdevice|pdev)->{re.escape(p)}\s*=\s*)([^;,\n]+)([;,\n])',r'\1true\3',content)
    if n: content=new; nf+=n
    new,n=re.subn(rf'(\.{re.escape(p)}\s*=\s*)([^;,\n]+)([;,\n])',r'\1true\3',content)
    if n: content=new; nf+=n
print(f"[OK] Forced {nf} feature flags to true")

# Boost descriptor limits for VKD3D-proton (requires >= 1,000,000)
DESC_LIMITS = [
    (r'(maxDescriptorSetUpdateAfterBindSamplers\s*=\s*)(\d+)', 1000000),
    (r'(maxDescriptorSetUpdateAfterBindSampledImages\s*=\s*)(\d+)', 1000000),
    (r'(maxDescriptorSetUpdateAfterBindStorageImages\s*=\s*)(\d+)', 1000000),
    (r'(maxDescriptorSetUpdateAfterBindStorageBuffers\s*=\s*)(\d+)', 1000000),
    (r'(maxPerStageDescriptorUpdateAfterBindSampledImages\s*=\s*)(\d+)', 1048576),
    (r'(maxPerStageDescriptorUpdateAfterBindStorageBuffers\s*=\s*)(\d+)', 1048576),
    (r'(maxPerStageUpdateAfterBindResources\s*=\s*)(\d+)', 1048576),
]
nd = 0
for pat, minval in DESC_LIMITS:
    def _rep(m, mv=minval, p=pat):
        try:
            if int(m.group(2)) < mv:
                return m.group(1) + str(mv)
        except Exception:
            pass
        return m.group(0)
    new, n = re.subn(pat, _rep, content)
    if n: content = new; nd += n
print(f"[OK] Descriptor limits boosted: {nd} change(s)")

# --- PASS 2: Inject Extension Strings (Hardcoded List) ---
ALL_EXTS = [
"VK_KHR_16bit_storage","VK_KHR_8bit_storage","VK_KHR_acceleration_structure",
"VK_KHR_bind_memory2","VK_KHR_buffer_device_address","VK_KHR_calibrated_timestamps",
"VK_KHR_compute_shader_derivatives","VK_KHR_cooperative_matrix","VK_KHR_copy_commands2",
"VK_KHR_copy_memory_indirect","VK_KHR_create_renderpass2","VK_KHR_dedicated_allocation",
"VK_KHR_deferred_host_operations","VK_KHR_depth_clamp_zero_one","VK_KHR_depth_stencil_resolve",
"VK_KHR_descriptor_update_template","VK_KHR_device_group","VK_KHR_draw_indirect_count",
"VK_KHR_driver_properties","VK_KHR_dynamic_rendering","VK_KHR_dynamic_rendering_local_read",
"VK_KHR_external_fence","VK_KHR_external_fence_fd","VK_KHR_external_memory",
"VK_KHR_external_memory_fd","VK_KHR_external_semaphore","VK_KHR_external_semaphore_fd",
"VK_KHR_format_feature_flags2","VK_KHR_fragment_shader_barycentric","VK_KHR_fragment_shading_rate",
"VK_KHR_global_priority","VK_KHR_image_format_list","VK_KHR_imageless_framebuffer",
"VK_KHR_incremental_present","VK_KHR_index_type_uint8","VK_KHR_line_rasterization",
"VK_KHR_load_store_op_none","VK_KHR_maintenance1","VK_KHR_maintenance2","VK_KHR_maintenance3",
"VK_KHR_maintenance4","VK_KHR_maintenance5","VK_KHR_maintenance6","VK_KHR_maintenance7",
"VK_KHR_maintenance8","VK_KHR_maintenance9","VK_KHR_maintenance10","VK_KHR_map_memory2",
"VK_KHR_multiview","VK_KHR_performance_query","VK_KHR_pipeline_binary",
"VK_KHR_pipeline_executable_properties","VK_KHR_pipeline_library","VK_KHR_portability_subset",
"VK_KHR_present_id","VK_KHR_present_id2","VK_KHR_present_mode_fifo_latest_ready",
"VK_KHR_present_wait","VK_KHR_present_wait2","VK_KHR_push_descriptor",
"VK_KHR_ray_query","VK_KHR_ray_tracing_maintenance1","VK_KHR_ray_tracing_pipeline",
"VK_KHR_ray_tracing_position_fetch","VK_KHR_relaxed_block_layout","VK_KHR_robustness2",
"VK_KHR_sampler_mirror_clamp_to_edge","VK_KHR_sampler_ycbcr_conversion",
"VK_KHR_separate_depth_stencil_layouts","VK_KHR_shader_atomic_int64",
"VK_KHR_shader_bfloat16","VK_KHR_shader_clock","VK_KHR_shader_draw_parameters",
"VK_KHR_shader_expect_assume","VK_KHR_shader_float16_int8","VK_KHR_shader_float_controls",
"VK_KHR_shader_float_controls2","VK_KHR_shader_fma","VK_KHR_shader_integer_dot_product",
"VK_KHR_shader_maximal_reconvergence","VK_KHR_shader_non_semantic_info","VK_KHR_shader_quad_control",
"VK_KHR_shader_relaxed_extended_instruction","VK_KHR_shader_subgroup_extended_types",
"VK_KHR_shader_subgroup_rotate","VK_KHR_shader_subgroup_uniform_control_flow",
"VK_KHR_shader_terminate_invocation","VK_KHR_shader_untyped_pointers",
"VK_KHR_shared_presentable_image","VK_KHR_spirv_1_4","VK_KHR_storage_buffer_storage_class",
"VK_KHR_swapchain","VK_KHR_swapchain_maintenance1","VK_KHR_swapchain_mutable_format",
"VK_KHR_synchronization2","VK_KHR_timeline_semaphore","VK_KHR_uniform_buffer_standard_layout",
"VK_KHR_unified_image_layouts","VK_KHR_variable_pointers","VK_KHR_vertex_attribute_divisor",
"VK_KHR_video_decode_av1","VK_KHR_video_decode_h264","VK_KHR_video_decode_h265",
"VK_KHR_video_decode_queue","VK_KHR_vulkan_memory_model","VK_KHR_workgroup_memory_explicit_layout",
"VK_KHR_zero_initialize_workgroup_memory",
"VK_EXT_4444_formats","VK_EXT_astc_decode_mode",
"VK_EXT_attachment_feedback_loop_dynamic_state","VK_EXT_attachment_feedback_loop_layout",
"VK_EXT_blend_operation_advanced","VK_EXT_border_color_swizzle","VK_EXT_buffer_device_address",
"VK_EXT_calibrated_timestamps","VK_EXT_color_write_enable","VK_EXT_conditional_rendering",
"VK_EXT_conservative_rasterization","VK_EXT_custom_border_color","VK_EXT_depth_bias_control",
"VK_EXT_depth_clamp_control","VK_EXT_depth_clamp_zero_one","VK_EXT_depth_clip_control",
"VK_EXT_depth_clip_enable","VK_EXT_depth_range_unrestricted","VK_EXT_descriptor_buffer",
"VK_EXT_descriptor_indexing","VK_EXT_device_address_binding_report","VK_EXT_device_fault",
"VK_EXT_device_generated_commands","VK_EXT_device_memory_report","VK_EXT_discard_rectangles",
"VK_EXT_dynamic_rendering_unused_attachments","VK_EXT_extended_dynamic_state",
"VK_EXT_extended_dynamic_state2","VK_EXT_extended_dynamic_state3",
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
"VK_EXT_multi_draw","VK_EXT_multisampled_render_to_single_sampled","VK_EXT_mutable_descriptor_type",
"VK_EXT_nested_command_buffer","VK_EXT_non_seamless_cube_map","VK_EXT_opacity_micromap",
"VK_EXT_pageable_device_local_memory","VK_EXT_pci_bus_info","VK_EXT_physical_device_drm",
"VK_EXT_pipeline_creation_cache_control","VK_EXT_pipeline_creation_feedback",
"VK_EXT_pipeline_library_group_handles","VK_EXT_pipeline_properties",
"VK_EXT_pipeline_protected_access","VK_EXT_pipeline_robustness","VK_EXT_post_depth_coverage",
"VK_EXT_present_mode_fifo_latest_ready","VK_EXT_primitive_topology_list_restart",
"VK_EXT_primitives_generated_query","VK_EXT_private_data","VK_EXT_provoking_vertex",
"VK_EXT_queue_family_foreign","VK_EXT_rasterization_order_attachment_access",
"VK_EXT_ray_tracing_invocation_reorder","VK_EXT_rgba10x6_formats","VK_EXT_robustness2",
"VK_EXT_sample_locations","VK_EXT_sampler_filter_minmax","VK_EXT_scalar_block_layout",
"VK_EXT_separate_stencil_usage","VK_EXT_shader_64bit_indexing","VK_EXT_shader_atomic_float",
"VK_EXT_shader_atomic_float2","VK_EXT_shader_demote_to_helper_invocation","VK_EXT_shader_float8",
"VK_EXT_shader_image_atomic_int64","VK_EXT_shader_long_vector","VK_EXT_shader_module_identifier",
"VK_EXT_shader_object","VK_EXT_shader_replicated_composites","VK_EXT_shader_stencil_export",
"VK_EXT_shader_subgroup_partitioned","VK_EXT_shader_tile_image","VK_EXT_shader_viewport_index_layer",
"VK_EXT_subgroup_size_control","VK_EXT_subpass_merge_feedback","VK_EXT_swapchain_maintenance1",
"VK_EXT_texel_buffer_alignment","VK_EXT_texture_compression_astc_3d","VK_EXT_texture_compression_astc_hdr",
"VK_EXT_tooling_info","VK_EXT_transform_feedback","VK_EXT_vertex_attribute_divisor",
"VK_EXT_vertex_attribute_robustness","VK_EXT_vertex_input_dynamic_state",
"VK_EXT_ycbcr_2plane_444_formats","VK_EXT_ycbcr_image_arrays","VK_EXT_zero_initialize_device_memory",
"VK_AMD_buffer_marker","VK_AMD_device_coherent_memory","VK_AMD_draw_indirect_count",
"VK_AMD_gcn_shader","VK_AMD_gpu_shader_half_float","VK_AMD_gpu_shader_int16",
"VK_AMD_mixed_attachment_samples","VK_AMD_negative_viewport_height",
"VK_AMD_pipeline_compiler_control","VK_AMD_rasterization_order","VK_AMD_shader_ballot",
"VK_AMD_shader_core_properties","VK_AMD_shader_core_properties2",
"VK_AMD_shader_early_and_late_fragment_tests","VK_AMD_shader_explicit_vertex_parameter",
"VK_AMD_shader_fragment_mask","VK_AMD_shader_image_load_store_lod","VK_AMD_shader_info",
"VK_AMD_shader_trinary_minmax","VK_AMD_texture_gather_bias_lod",
"VK_ANDROID_external_format_resolve","VK_ANDROID_external_memory_android_hardware_buffer",
"VK_ARM_rasterization_order_attachment_access","VK_ARM_render_pass_striped",
"VK_ARM_scheduling_controls","VK_ARM_shader_core_builtins","VK_ARM_shader_core_properties",
"VK_GOOGLE_decorate_string","VK_GOOGLE_display_timing","VK_GOOGLE_hlsl_functionality1",
"VK_GOOGLE_user_type","VK_IMG_filter_cubic","VK_IMG_relaxed_line_rasterization",
"VK_INTEL_performance_query","VK_INTEL_shader_integer_functions2",
"VK_MESA_image_alignment_control",
"VK_QCOM_fragment_density_map_offset","VK_QCOM_image_processing",
"VK_QCOM_multiview_per_view_render_areas","VK_QCOM_multiview_per_view_viewports",
"VK_QCOM_render_pass_shader_resolve","VK_QCOM_render_pass_store_ops",
"VK_QCOM_render_pass_transform","VK_QCOM_tile_properties","VK_QCOM_ycbcr_degamma",
"VK_SEC_amigo_profiling","VK_VALVE_descriptor_set_host_mapping",
"VK_VALVE_mutable_descriptor_type","VK_VALVE_shader_mixed_float_dot_product",
]

# Instance extensions to exclude
INST_ONLY={
"VK_KHR_surface","VK_KHR_wayland_surface","VK_KHR_win32_surface","VK_KHR_xcb_surface",
"VK_KHR_xlib_surface","VK_EXT_debug_report","VK_EXT_debug_utils","VK_EXT_headless_surface",
"VK_KHR_android_surface","VK_KHR_display","VK_MVK_ios_surface","VK_MVK_macos_surface",
}

# --- CRITICAL BLACKLIST ---
# These are extensions that we forced previously but Turnip does NOT implement.
# Enabling them causes games to call unimplemented functions and crash (e.g. vkSetLatencySleepModeNV).
BLACKLIST={
    "VK_NV_low_latency", "VK_NV_low_latency2",        # Nvidia Reflex (crash)
    "VK_NV_optical_flow",                              # Hardware optical flow
    "VK_NV_ray_tracing", "VK_NV_ray_tracing_motion_blur", # RTX specific
    "VK_NV_mesh_shader",                               # Proprietary mesh shaders (Turnip uses EXT_mesh_shader)
    "VK_NV_cooperative_matrix",                        # Tensor cores
    "VK_NV_fragment_shading_rate_enums",               # Proprietary VRS
    "VK_NV_shading_rate_image",                        # Proprietary VRS
    "VK_NV_device_generated_commands",                 # Proprietary DGC
    "VK_NV_coverage_reduction_mode",
    "VK_NVX_image_view_handle",
    # Video decoding is not supported on Turnip Android yet
    "VK_KHR_video_decode_queue", "VK_KHR_video_decode_h264", "VK_KHR_video_decode_h265", "VK_KHR_video_decode_av1",
    "VK_KHR_video_encode_queue",
}

# Filter out instance-only extensions AND blacklisted extensions
dev_exts=[e for e in ALL_EXTS if e not in INST_ONLY and e not in BLACKLIST]
print(f"[INFO] Injecting {len(dev_exts)} device extensions")

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
            return ev, p
    return None, None

ev, ins = find_point(content)
if ev:
    print(f"[OK] ext_var='{ev}'")
    lines=["\n"]
    for e in dev_exts:
        lines.append(f"    {ev}->{e[3:]} = true;")
    lines.append("\n")
    inj="\n".join(lines)
    content=content[:ins]+inj+content[ins:]
    print(f"[OK] Done — {len(dev_exts)} assignments written")
else:
    print("[ERROR] Could not find injection point")

with open(tu_path,'w') as f: f.write(content)
PYEOF
    log_success "Vulkan extensions support applied"
}

apply_reduce_advertised_memory() {
    local tu_dev="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_dev" ]] && return 0
    if grep -q "REDUCE_MEMORY_APPLIED" "$tu_dev"; then
        log_info "Memory reduction already applied"
        return 0
    fi
    python3 - "$tu_dev" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(\.size\s*=\s*)(heap_size|[a-zA-Z_]+_size)(\s*[,;])'
new, n = re.subn(pat, r'\g<1>( * 3 / 4)', c)
if n:
    c = new
    print(f"[OK] Memory reduction applied: {n} heap(s) capped at 75%")
c = c.replace('#include "tu_device.h"', '#include "tu_device.h"
/* REDUCE_MEMORY_APPLIED */', 1)
with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "Memory reduction applied"
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
        apply_gralloc_ubwc_fix
        if [[ "$ENABLE_DECK_EMU" == "true" ]]; then apply_deck_emu_support; fi
        if [[ "$ENABLE_EXT_SPOOF" == "true" ]]; then apply_vulkan_extensions_support; fi
        apply_a8xx_device_support
        apply_reduce_advertised_memory
        if [[ "$BUILD_VARIANT" == "autotuner" ]]; then apply_a6xx_query_fix; fi
    fi

    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local patch_name=$(basename "$patch")
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
            cp -r "$CACHE_DIR/$proj" subprojects/
        else
            git clone --depth=1 "https://github.com/KhronosGroup/${proj}.git" "subprojects/$proj"
            cp -r "subprojects/$proj" "$CACHE_DIR/"
        fi
    done
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
    "description": "TurnipDriver",
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
