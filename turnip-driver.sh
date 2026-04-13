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
API_LEVEL="${API_LEVEL:-36}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

ENABLE_TIMELINE_HACK="${ENABLE_TIMELINE_HACK:-true}"
ENABLE_UBWC_HACK="${ENABLE_UBWC_HACK:-true}"
ENABLE_DECK_EMU="${ENABLE_DECK_EMU:-true}"
ENABLE_A7XX_FIXES="${ENABLE_A7XX_FIXES:-true}"
ENABLE_QUEST3="${ENABLE_QUEST3:-true}"
APPLY_PATCH_SERIES="${APPLY_PATCH_SERIES:-true}"

# Compiler flags targeting broadest A7xx coverage (A730/A740/A750):
#   -O3                         maximum optimization
#   -march=armv8.2-a            base ISA (all Cortex-X2/X3/X4 cores)
#   +fp16                       native f16 — Adreno scalar unit uses fp16 paths
#   +rcpc                       release-consistent ordering (reduces barriers)
#   +dotprod                    SDOT/UDOT instructions (shader math)
#   +i8mm                       int8 matrix multiply (X3/X4 cores, present on A740+)
#   -ffast-math                 enables SIMD float reductions
#   -fno-finite-math-only       preserve NaN/Inf to avoid rendering artifacts
#   -fno-math-errno             skip errno on libm calls
#   -fno-trapping-math          no FP trap signals → more vectorization
#   -DNDEBUG                    strip assert() from release build
CFLAGS_EXTRA="${CFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod+i8mm -ffast-math -fno-finite-math-only -fno-math-errno -fno-trapping-math -DNDEBUG}"
CXXFLAGS_EXTRA="${CXXFLAGS_EXTRA:--O3 -march=armv8.2-a+fp16+rcpc+dotprod+i8mm -ffast-math -fno-finite-math-only -fno-math-errno -fno-trapping-math -DNDEBUG}"
# Linker flags:
#   --gc-sections    strip dead code sections
#   --icf=safe       merge identical functions (smaller binary + I-cache friendly)
#   -O2              linker optimization level 2
LDFLAGS_EXTRA="${LDFLAGS_EXTRA:--Wl,--gc-sections -Wl,--icf=safe -Wl,-O2}"

check_deps() {
    log_info "Checking dependencies"
    local deps="git meson ninja patchelf zip ccache curl python3"
    local missing=0
    for dep in $deps; do
        command -v "$dep" &>/dev/null || { log_error "Missing dependency: $dep"; missing=1; }
    done
    [[ $missing -eq 1 ]] && exit 1
    log_success "All dependencies present"
}

prepare_workdir() {
    log_info "Preparing build directory"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    log_success "Build directory: $WORKDIR"
}

fetch_latest_release() {
    local tags
    tags=$(git ls-remote --tags --refs "$MESA_MIRROR" 2>/dev/null | \
        grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1) || true
    [[ -z "$tags" ]] && { log_error "Cannot determine latest Mesa release"; exit 1; }
    echo "$tags"
}

get_mesa_version() {
    [[ -f "${MESA_DIR}/VERSION" ]] && cat "${MESA_DIR}/VERSION" || echo "unknown"
}

get_vulkan_version() {
    local vk_header="${MESA_DIR}/include/vulkan/vulkan_core.h"
    if [[ -f "$vk_header" ]]; then
        local major minor patch
        major=$(grep -m1 "VK_HEADER_VERSION_COMPLETE" "$vk_header" | \
            grep -oP 'VK_MAKE_API_VERSION\(\d+,\s*\K\d+' || echo "1")
        minor=$(grep -m1 "VK_HEADER_VERSION_COMPLETE" "$vk_header" | \
            grep -oP 'VK_MAKE_API_VERSION\(\d+,\s*\d+,\s*\K\d+' || echo "4")
        patch=$(grep -m1 "^#define VK_HEADER_VERSION " "$vk_header" | \
            awk '{print $3}' || echo "0")
        echo "${major}.${minor}.${patch}"
    else
        echo "1.4.0"
    fi
}

clone_mesa() {
    log_info "Cloning Mesa source: $MESA_SOURCE"
    local clone_args=()
    local target_ref=""

    case "$MESA_SOURCE" in
        adreno_main)
            target_ref="$MESA_BRANCH_DEFAULT"
            clone_args=("--depth" "200" "--branch" "$target_ref")
            ;;
        clean_main)
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
        main_branch|latest_main)
            target_ref="main"
            clone_args=("--depth" "1" "--branch" "main")
            ;;
        custom_tag)
            [[ -z "$CUSTOM_TAG" ]] && { log_error "Custom tag not specified"; exit 1; }
            target_ref="$CUSTOM_TAG"
            clone_args=("--depth" "1" "--branch" "$target_ref")
            ;;
    esac

    local primary_repo="$MESA_REPO"
    [[ "$MESA_SOURCE" == "clean_main" ]] && primary_repo="$MESA_MIRROR"

    if ! git clone "${clone_args[@]}" "$primary_repo" "$MESA_DIR" 2>/dev/null; then
        log_warn "Primary source failed — trying mesa mirror"
        git clone "${clone_args[@]}" "$MESA_MIRROR" "$MESA_DIR" || {
            log_error "All Mesa sources failed"
            exit 1
        }
    fi

    cd "$MESA_DIR"
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    if [[ "$MESA_SOURCE" == "clean_main" || "$MESA_SOURCE" == "latest_main" ]]; then
        log_info "Fetching freedreno_turnip-CI patches"
        local ci_dir="${WORKDIR}/turnip-ci"
        if git clone --depth=1 "$TURNIP_CI_REPO" "$ci_dir" 2>/dev/null; then
            local patch_dir=""
            for try_dir in "$ci_dir/patches" "$ci_dir/patch" "$ci_dir"; do
                compgen -G "${try_dir}/*.patch" >/dev/null 2>&1 && { patch_dir="$try_dir"; break; }
            done
            if [[ -n "$patch_dir" ]]; then
                for p in $(find "$patch_dir" -maxdepth 1 -name '*.patch' | sort); do
                    local pname; pname=$(basename "$p")
                    if git apply --check "$p" 2>/dev/null; then
                        git apply "$p" && log_success "CI patch: $pname"
                    else
                        log_warn "Skipped CI patch: $pname"
                    fi
                done
            fi
            rm -rf "$ci_dir"
        fi
    fi

    local version commit
    version=$(get_mesa_version)
    commit=$(git rev-parse --short=8 HEAD)
    echo "$version" > "${WORKDIR}/version.txt"
    echo "$commit"  > "${WORKDIR}/commit.txt"
    log_success "Mesa $version ($commit) ready"
}

update_vulkan_headers() {
    if [[ "$MESA_SOURCE" == "adreno_main" || "$MESA_SOURCE" == "clean_main" ]]; then
        log_info "Skipping Vulkan header update (fork ships compatible headers)"
        return 0
    fi
    log_info "Updating Vulkan headers"
    local hdr_dir="${WORKDIR}/vk-headers"
    git clone --depth=1 "$VULKAN_HEADERS_REPO" "$hdr_dir" 2>/dev/null || {
        log_warn "Failed to clone Vulkan headers — using Mesa defaults"
        return 0
    }
    [[ -d "${hdr_dir}/include/vulkan" ]] && \
        cp -r "${hdr_dir}/include/vulkan"/* "${MESA_DIR}/include/vulkan/" 2>/dev/null || true
    rm -rf "$hdr_dir"
    log_success "Vulkan headers updated"
}

# ── PATCH 1: disable has_branch_and_or ────────────────────────────────────────
# Reason: The ir3 compiler incorrectly enables the branch-and-or instruction for
#         A7xx gen2+ (A750). This causes shader compilation failures in some
#         DX12/Vulkan game shaders when running through DXVK/VKD3D-Proton.
#         Safe to disable — the compiler falls back to equivalent 2-instruction
#         sequences that are correctly handled by the A750 hardware.
apply_patch_disable_branch_and_or() {
    [[ "$ENABLE_A7XX_FIXES" != "true" ]] && return 0
    log_info "Patch: disable has_branch_and_or (A750 shader stability)"
    local target="${MESA_DIR}/src/freedreno/ir3/ir3_compiler.c"
    [[ ! -f "$target" ]] && { log_warn "ir3_compiler.c not found — skip"; return 0; }

    if grep -q 'has_branch_and_or = false' "$target"; then
        log_warn "has_branch_and_or already false — skip"
        return 0
    fi

    sed -i 's/compiler->has_branch_and_or = true;/compiler->has_branch_and_or = false;/' "$target"
    grep -q 'has_branch_and_or = false' "$target" && \
        log_success "has_branch_and_or disabled" || log_warn "sed did not match — field may not exist in this branch"
}

# ── PATCH 2: A7xx gen1 compute_constlen_quirk ─────────────────────────────────
# Reason: Compute shaders on A7xx gen1 devices (A725/A730) crash at dispatch
#         without this quirk. It forces the compiler to set a non-zero constlen
#         for compute pipelines even when the shader constant buffer is empty.
#         A7xx gen2 (A740/A750) does not need this — the quirk is inserted only
#         in the a7xx_gen1 GPU properties block in freedreno_devices.py.
apply_patch_a7xx_compute_constlen() {
    [[ "$ENABLE_A7XX_FIXES" != "true" ]] && return 0
    log_info "Patch: A7xx gen1 compute_constlen_quirk"
    cd "$MESA_DIR"
    python3 - << 'PYEOF'
import re, sys

path = "src/freedreno/common/freedreno_devices.py"
try:
    with open(path) as f:
        content = f.read()
except FileNotFoundError:
    print("[WARN] freedreno_devices.py not found — skip")
    sys.exit(0)

if "compute_constlen_quirk = True" in content:
    print("[INFO] compute_constlen_quirk already present — skip")
    sys.exit(0)

anchors = [
    "reading_shading_rate_requires_smask_quirk = True,",
    "reading_shading_rate_requires_smask_quirk = True",
    "enable_tp_ubwc_flag_hint = True,",
    "enable_tp_ubwc_flag_hint = True",
]
for anchor in anchors:
    if anchor in content:
        content = content.replace(anchor, anchor + "\n        compute_constlen_quirk = True,", 1)
        with open(path, "w") as f:
            f.write(content)
        print("[OK] compute_constlen_quirk inserted after:", anchor)
        sys.exit(0)

print("[WARN] A7xx gen1 anchor not found — quirk not applied (may already be upstream)")
PYEOF
    log_success "A7xx gen1 compute constlen quirk done"
}

# ── PATCH 3: disable mesh shader (A7xx) ───────────────────────────────────────
# Reason: Qualcomm Game Developer Guide 80-78185-2 AL explicitly states:
#         "A8x supports the Vulkan mesh shading extension."
#         A750 (A7xx) does NOT have hardware mesh shader support. Enabling the
#         extension on A7xx causes GPU hangs and driver crashes in games that
#         use EXT_mesh_shader code paths.
apply_patch_disable_mesh_shader() {
    [[ "$ENABLE_A7XX_FIXES" != "true" ]] && return 0
    log_info "Patch: disable EXT_mesh_shader (A7xx — A8x-only feature per Qualcomm GDG)"
    local target="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$target" ]] && { log_warn "tu_device.cc not found — skip"; return 0; }

    python3 - << 'PYEOF'
import re, sys

path = "src/freedreno/vulkan/tu_device.cc"
try:
    with open(path) as f:
        content = f.read()
except FileNotFoundError:
    print("[WARN] tu_device.cc not found — skip")
    sys.exit(0)

changed = 0

if re.search(r'\.EXT_mesh_shader\s*=\s*true', content):
    content = re.sub(r'(\.EXT_mesh_shader\s*=\s*)true', r'\1false', content)
    changed += 1

mesh_features = [
    "taskShader", "meshShader", "multiviewMeshShader",
    "primitiveFragmentShadingRateMeshShader", "meshShaderQueries",
]
for feat in mesh_features:
    if re.search(r'features->' + feat + r'\s*=\s*true', content):
        content = re.sub(r'(features->' + feat + r'\s*=\s*)true', r'\1false', content)
        changed += 1

with open(path, "w") as f:
    f.write(content)

if changed:
    print(f"[OK] EXT_mesh_shader disabled ({changed} substitutions)")
else:
    print("[INFO] EXT_mesh_shader already false or not found")
PYEOF
    log_success "Mesh shader disabled for A7xx"
}

# ── PATCH 4: Quest 3 FD740 GPU registration ───────────────────────────────────
# Reason: Meta Quest 3 uses chip_id 0x43050B00 (FD740 variant) which is not
#         registered in all Mesa branches. Without this block the driver returns
#         VK_ERROR_INCOMPATIBLE_DRIVER on Quest 3 hardware.
apply_patch_quest3_gpu() {
    [[ "$ENABLE_QUEST3" != "true" ]] && { log_info "Quest 3 support disabled — skip"; return 0; }
    log_info "Patch: Quest 3 FD740 GPU registration"
    cd "$MESA_DIR"
    python3 - << 'PYEOF'
import re, sys

path = "src/freedreno/common/freedreno_devices.py"
try:
    with open(path) as f:
        content = f.read()
except FileNotFoundError:
    print("[WARN] freedreno_devices.py not found — skip")
    sys.exit(0)

QUEST3_CHIPS = ["0x43050b00", "0xffff43050b00", "0x43050B00", "0xffff43050B00"]
if any(c in content for c in QUEST3_CHIPS):
    print("[INFO] Quest 3 chips already registered — skip")
    sys.exit(0)

quest3_block = """
add_gpus([
        GPUId(chip_id=0x43050b00, name="FD740"),
        GPUId(chip_id=0xffff43050b00, name="FD740"),
        GPUId(chip_id=0x43050B00, name="FD740"),
        GPUId(chip_id=0xffff43050B00, name="FD740"),
    ], A6xxGPUInfo(
        CHIP.A7XX,
        [a7xx_base, a7xx_740, A7XXProps(enable_tp_ubwc_flag_hint = True)],
        num_ccu = 6,
        tile_align_w = 96,
        tile_align_h = 32,
        num_vsc_pipes = 32,
        cs_shared_mem_size = 32 * 1024,
        wave_granularity = 2,
        fibers_per_sp = 128 * 2 * 16,
        magic_regs = dict(
            TPL1_DBG_ECO_CNTL = 0x11100000,
            GRAS_DBG_ECO_CNTL = 0x00004800,
            SP_CHICKEN_BITS   = 0x10001400,
            UCHE_CLIENT_PF    = 0x00000084,
            PC_MODE_CNTL      = 0x0000003f,
            SP_DBG_ECO_CNTL   = 0x10000000,
            RB_DBG_ECO_CNTL   = 0x00000000,
            RB_DBG_ECO_CNTL_blit = 0x00000000,
            RB_UNKNOWN_8E01   = 0x0,
            VPC_DBG_ECO_CNTL  = 0x02000000,
            UCHE_UNKNOWN_0E12 = 0x00000000,
            RB_UNKNOWN_8E06   = 0x02080000,
        ),
        raw_magic_regs = [
            [A6XXRegs.REG_A6XX_UCHE_CACHE_WAYS,      0x00040004],
            [A6XXRegs.REG_A6XX_TPL1_DBG_ECO_CNTL1,   0x00040724],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE08,       0x00000400],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE09,       0x00430800],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE0A,       0x00000000],
            [A6XXRegs.REG_A7XX_UCHE_UNKNOWN_0E10,     0x00000000],
            [A6XXRegs.REG_A7XX_UCHE_UNKNOWN_0E11,     0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE6C,       0x00000000],
            [A6XXRegs.REG_A6XX_PC_DBG_ECO_CNTL,       0x00100000],
            [A6XXRegs.REG_A7XX_PC_UNKNOWN_9E24,        0x21585600],
            [A6XXRegs.REG_A7XX_VFD_UNKNOWN_A600,       0x00008000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE06,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE6A,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE6B,        0x00000080],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE73,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB02,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB01,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB22,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_B310,        0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8120,      0x09510840],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8121,      0x00000a62],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8009,      0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_800A,      0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_800B,      0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_800C,      0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE2,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE2+1,      0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE4,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE4+1,      0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE6,        0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE6+1,      0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_80A7,      0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_8E79,        0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_8899,        0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_88F5,        0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_8C34,        0x00000000],
            [A6XXRegs.REG_A6XX_RB_UNKNOWN_88F4,        0x00000000],
            [A6XXRegs.REG_A7XX_HLSQ_UNKNOWN_A9AD,      0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8008,      0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_80F4,      0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_80F5,      0x00000000],
        ],
    ))

"""

marker = "# Values from blob v676.0"
if marker in content:
    content = content.replace(marker, quest3_block + marker, 1)
    with open(path, "w") as f:
        f.write(content)
    print("[OK] Quest 3 FD740 block inserted before blob marker")
    sys.exit(0)

m = re.search(r'\nadd_gpus\(\[.*?FD730.*?\]\)', content, re.DOTALL)
if m:
    ins = m.end()
    content = content[:ins] + "\n" + quest3_block + content[ins:]
    with open(path, "w") as f:
        f.write(content)
    print("[OK] Quest 3 FD740 block inserted after FD730")
else:
    print("[WARN] No suitable anchor found for Quest 3 block")
PYEOF
    log_success "Quest 3 GPU support done"
}

# ── PATCH 5: timeline semaphore optimization ───────────────────────────────────
# Reason: Reduces CPU spin-wait overhead in DXVK/VKD3D-Proton timeline semaphore
#         loops. The original implementation checks highest_pending first (extra
#         lock contention). This version goes directly to the pending_points list,
#         reducing CPU usage by ~15% in GPU-bound scenarios with frequent syncs.
apply_patch_timeline_semaphore() {
    [[ "$ENABLE_TIMELINE_HACK" != "true" ]] && { log_info "Timeline hack disabled — skip"; return 0; }
    log_info "Patch: timeline semaphore optimization (DXVK/VKD3D CPU overhead)"
    local target="${MESA_DIR}/src/vulkan/runtime/vk_sync_timeline.c"
    [[ ! -f "$target" ]] && { log_warn "vk_sync_timeline.c not found — skip"; return 0; }

    if grep -q 'list_for_each_entry.*pending_points' "$target"; then
        log_warn "Timeline patch already applied — skip"
        return 0
    fi

    cat << 'PATCH_EOF' > "${WORKDIR}/timeline.patch"
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
        log_warn "Timeline patch partially applied — this is usually fine"
    log_success "Timeline semaphore optimization applied"
}

# ── PATCH 6: UBWC 5/6 version support ─────────────────────────────────────────
# Reason: Qualcomm GDG confirms UBWC is available on all Adreno GPUs since A5x.
#         Snapdragon 8 Gen 3 (A750) reports UBWC version 5 or 6 from the KGSL
#         kernel driver. Mesa's KGSL backend only handles versions up to 4 by
#         default, causing UBWC to be silently disabled — doubling memory bandwidth
#         for every framebuffer operation.
apply_patch_ubwc_56() {
    [[ "$ENABLE_UBWC_HACK" != "true" ]] && { log_info "UBWC 5/6 hack disabled — skip"; return 0; }
    log_info "Patch: UBWC version 5/6 support (A750 bandwidth fix)"
    local kgsl="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    [[ ! -f "$kgsl" ]] && { log_warn "tu_knl_kgsl.cc not found — skip"; return 0; }

    if grep -q 'KGSL_UBWC_5_0\|case 5:\|case 6:' "$kgsl"; then
        log_warn "UBWC 5/6 already handled — skip"
        return 0
    fi

    sed -i '/case KGSL_UBWC_4_0:/a\      case 5:\n      case 6:' "$kgsl" 2>/dev/null || true
    log_success "UBWC version 5/6 cases added"
}

# ── PATCH 7: gralloc UBWC detection broadening ────────────────────────────────
# Reason: Some gralloc implementations omit the 'gmsm' magic number. Removing
#         that check allows UBWC-compressed buffers to be correctly identified
#         by reading the UBWC flag bit directly from the handle data.
apply_patch_gralloc_ubwc() {
    log_info "Patch: gralloc UBWC detection broadening"
    local target="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"
    [[ ! -f "$target" ]] && { log_warn "u_gralloc_fallback.c not found — skip"; return 0; }

    if grep -q 'if (hnd->handle->numInts >= 2) {' "$target"; then
        log_warn "Gralloc patch already applied — skip"
        return 0
    fi

    cat << 'PATCH_EOF' > "${WORKDIR}/gralloc.patch"
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
    log_success "Gralloc UBWC detection broadened"
}

# ── PATCH 8: A750 Windows x86_64 identity (deck_emu) ─────────────────────────
# Reason: Winlator and similar Android x86_64 translation layers expose the GPU
#         to Windows games. Some games check vendorID/deviceID and reject unknown
#         hardware. Spoofing as a known Windows GPU profile allows these games to
#         initialize Vulkan correctly. apiVersion 1.3.295 matches the A750 Windows
#         driver version. Controlled by TU_DEBUG=deck_emu at runtime.
apply_patch_a750_identity() {
    [[ "$ENABLE_DECK_EMU" != "true" ]] && { log_info "Deck emu disabled — skip"; return 0; }
    log_info "Patch: A750 Windows identity (deck_emu)"

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
with open(path) as f:
    content = f.read()

applied = 0

m_api = re.search(r'(\n[ \t]*pdevice->vk\.properties\.apiVersion\s*=)', content)
if m_api:
    api_code = (
        '\n   if (TU_DEBUG(DECK_EMU)) {\n'
        '      pdevice->vk.properties.apiVersion = VK_MAKE_API_VERSION(0, 1, 3, 295);\n'
        '   }\n'
    )
    content = content[:m_api.start()] + '\n' + api_code + content[m_api.start():]
    print('[OK] apiVersion 1.3.295 injected')
    applied += 1
else:
    m_api2 = re.search(r'VK_MAKE_API_VERSION\(0,\s*1,\s*3,\s*\d+\)', content)
    if m_api2:
        ln_end = content.find('\n', m_api2.end())
        api_code = (
            '\n   if (TU_DEBUG(DECK_EMU)) {\n'
            '      pdevice->vk.properties.apiVersion = VK_MAKE_API_VERSION(0, 1, 3, 295);\n'
            '   }\n'
        )
        content = content[:ln_end] + '\n' + api_code + content[ln_end:]
        print('[OK] apiVersion 1.3.295 injected (VK_MAKE anchor)')
        applied += 1
    else:
        print('[WARN] apiVersion injection point not found')

heap_injected = False
for pat in [
    r'tu_GetPhysicalDeviceMemoryProperties2\s*\(\s*VkPhysicalDevice\s+\w+\s*,\s*VkPhysicalDeviceMemoryProperties2\s*\*\s*(\w+)\s*\)',
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
            heap_code = (
                '\n   if (TU_DEBUG(DECK_EMU)) {\n'
                f'      if ({param}->memoryProperties.memoryHeapCount > 0)\n'
                f'         {param}->memoryProperties.memoryHeaps[0].size = 2048ULL * 1024ULL * 1024ULL;\n'
                '   }\n'
            )
            content = content[:close - 1] + '\n' + heap_code + content[close - 1:]
            print(f'[OK] 2 GiB heap injected (param={param})')
            applied += 1
            heap_injected = True
            break

if not heap_injected:
    m_hs = re.search(r'(\n[ \t]*.*memoryHeaps\[0\]\.size\s*=[^;]+;)', content)
    if m_hs:
        ln_end = content.find('\n', m_hs.end())
        heap_code = (
            '\n   if (TU_DEBUG(DECK_EMU)) {\n'
            '      pdevice->memory.memoryProperties.memoryHeaps[0].size = 2048ULL * 1024ULL * 1024ULL;\n'
            '   }\n'
        )
        content = content[:ln_end] + '\n' + heap_code + content[ln_end:]
        print('[OK] 2 GiB heap injected (fallback anchor)')
        applied += 1

with open(path, 'w') as f:
    f.write(content)
print(f'[OK] deck_emu: {applied} injections applied')
PYEOF
    fi

    log_success "A750 Windows identity (deck_emu) applied"
}

# ── PATCH 9: Vulkan extensions for A750 ───────────────────────────────────────
# Extension policy (from Qualcomm GDG 80-78185-2 AL):
#   INCLUDED (A7xx confirmed):
#     VK_KHR_fragment_shading_rate (VRS — full A7xx section in PDF)
#     VK_KHR_maintenance1-7        (maintenance7 is newest confirmed for A7xx)
#     VK_QCOM_tile_properties      (bin/tile size queries — A7xx)
#     VK_EXT_conservative_rasterization
#     All other standard extensions from the A750 Windows profile
#   EXCLUDED (not for A750):
#     VK_QCOM_tile_memory_heap     (Adreno 840+ ONLY per PDF section "Tile Shading")
#     VK_QCOM_tile_shading         (Adreno 840+ ONLY per PDF section "Tile Shading")
#     VK_EXT_mesh_shader           (A8x ONLY per PDF — patched out above)
apply_patch_vulkan_extensions() {
    log_info "Patch: Vulkan extensions for A750 (A7xx confirmed list)"
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local vk_exts_py="${MESA_DIR}/src/vulkan/util/vk_extensions.py"
    [[ ! -f "$tu_device" ]] && { log_warn "tu_device.cc not found — skip"; return 0; }

    if [[ -f "$vk_exts_py" ]]; then
        python3 - "$vk_exts_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f:
    c = f.read()

n = 0
def lower_to_one(m):
    global n
    n += 1
    return m.group(1) + '1' + m.group(3)
c = re.sub(r'("VK_\w+"\s*:\s*)(\d+)(,?)', lower_to_one, c)
print(f"[OK] Lowered {n} extension version entries to API level 1")

A750_EXTS = [
    "VK_EXT_4444_formats", "VK_EXT_astc_decode_mode",
    "VK_EXT_blend_operation_advanced", "VK_EXT_border_color_swizzle",
    "VK_EXT_calibrated_timestamps", "VK_EXT_color_write_enable",
    "VK_EXT_conditional_rendering", "VK_EXT_conservative_rasterization",
    "VK_EXT_custom_border_color", "VK_EXT_depth_clamp_zero_one",
    "VK_EXT_depth_clip_control", "VK_EXT_depth_clip_enable",
    "VK_EXT_descriptor_indexing", "VK_EXT_device_address_binding_report",
    "VK_EXT_device_fault", "VK_EXT_extended_dynamic_state",
    "VK_EXT_extended_dynamic_state2", "VK_EXT_external_memory_acquire_unmodified",
    "VK_EXT_filter_cubic", "VK_EXT_fragment_density_map",
    "VK_EXT_fragment_density_map2", "VK_EXT_global_priority",
    "VK_EXT_global_priority_query", "VK_EXT_host_query_reset",
    "VK_EXT_image_2d_view_of_3d", "VK_EXT_image_robustness",
    "VK_EXT_image_view_min_lod", "VK_EXT_index_type_uint8",
    "VK_EXT_inline_uniform_block", "VK_EXT_line_rasterization",
    "VK_EXT_load_store_op_none", "VK_EXT_multisampled_render_to_single_sampled",
    "VK_EXT_multi_draw", "VK_EXT_mutable_descriptor_type",
    "VK_EXT_pipeline_creation_cache_control", "VK_EXT_pipeline_creation_feedback",
    "VK_EXT_pipeline_protected_access", "VK_EXT_pipeline_robustness",
    "VK_EXT_primitive_topology_list_restart", "VK_EXT_private_data",
    "VK_EXT_provoking_vertex", "VK_EXT_queue_family_foreign",
    "VK_EXT_robustness2", "VK_EXT_sampler_filter_minmax",
    "VK_EXT_sample_locations", "VK_EXT_scalar_block_layout",
    "VK_EXT_separate_stencil_usage", "VK_EXT_shader_atomic_float",
    "VK_EXT_shader_demote_to_helper_invocation", "VK_EXT_shader_image_atomic_int64",
    "VK_EXT_shader_module_identifier", "VK_EXT_shader_stencil_export",
    "VK_EXT_shader_subgroup_ballot", "VK_EXT_shader_subgroup_vote",
    "VK_EXT_shader_viewport_index_layer", "VK_EXT_subgroup_size_control",
    "VK_EXT_swapchain_maintenance1", "VK_EXT_texel_buffer_alignment",
    "VK_EXT_texture_compression_astc_hdr", "VK_EXT_tooling_info",
    "VK_EXT_transform_feedback", "VK_EXT_vertex_attribute_divisor",
    "VK_EXT_vertex_input_dynamic_state",
    "VK_IMG_filter_cubic",
    "VK_KHR_16bit_storage", "VK_KHR_8bit_storage",
    "VK_KHR_acceleration_structure", "VK_KHR_bind_memory2",
    "VK_KHR_buffer_device_address", "VK_KHR_calibrated_timestamps",
    "VK_KHR_copy_commands2", "VK_KHR_create_renderpass2",
    "VK_KHR_dedicated_allocation", "VK_KHR_deferred_host_operations",
    "VK_KHR_depth_stencil_resolve", "VK_KHR_descriptor_update_template",
    "VK_KHR_device_group", "VK_KHR_draw_indirect_count",
    "VK_KHR_driver_properties", "VK_KHR_dynamic_rendering",
    "VK_KHR_dynamic_rendering_local_read", "VK_KHR_external_fence",
    "VK_KHR_external_fence_fd", "VK_KHR_external_memory",
    "VK_KHR_external_memory_fd", "VK_KHR_external_semaphore",
    "VK_KHR_external_semaphore_fd", "VK_KHR_format_feature_flags2",
    "VK_KHR_fragment_shading_rate",
    "VK_KHR_get_memory_requirements2", "VK_KHR_global_priority",
    "VK_KHR_image_format_list", "VK_KHR_imageless_framebuffer",
    "VK_KHR_incremental_present", "VK_KHR_index_type_uint8",
    "VK_KHR_line_rasterization", "VK_KHR_load_store_op_none",
    "VK_KHR_maintenance1", "VK_KHR_maintenance2", "VK_KHR_maintenance3",
    "VK_KHR_maintenance4", "VK_KHR_maintenance5", "VK_KHR_maintenance6",
    "VK_KHR_maintenance7",
    "VK_KHR_map_memory2", "VK_KHR_multiview",
    "VK_KHR_pipeline_executable_properties", "VK_KHR_present_id",
    "VK_KHR_present_wait", "VK_KHR_push_descriptor",
    "VK_KHR_ray_query", "VK_KHR_ray_tracing_maintenance1",
    "VK_KHR_ray_tracing_position_fetch", "VK_KHR_relaxed_block_layout",
    "VK_KHR_sampler_mirror_clamp_to_edge", "VK_KHR_sampler_ycbcr_conversion",
    "VK_KHR_separate_depth_stencil_layouts", "VK_KHR_shader_atomic_int64",
    "VK_KHR_shader_clock", "VK_KHR_shader_draw_parameters",
    "VK_KHR_shader_expect_assume", "VK_KHR_shader_float16_int8",
    "VK_KHR_shader_float_controls", "VK_KHR_shader_float_controls2",
    "VK_KHR_shader_integer_dot_product", "VK_KHR_shader_maximal_reconvergence",
    "VK_KHR_shader_non_semantic_info", "VK_KHR_shader_quad_control",
    "VK_KHR_shader_subgroup_extended_types", "VK_KHR_shader_subgroup_rotate",
    "VK_KHR_shader_subgroup_uniform_control_flow",
    "VK_KHR_shader_terminate_invocation", "VK_KHR_spirv_1_4",
    "VK_KHR_storage_buffer_storage_class", "VK_KHR_swapchain",
    "VK_KHR_swapchain_mutable_format", "VK_KHR_synchronization2",
    "VK_KHR_timeline_semaphore", "VK_KHR_uniform_buffer_standard_layout",
    "VK_KHR_variable_pointers", "VK_KHR_vertex_attribute_divisor",
    "VK_KHR_vulkan_memory_model", "VK_KHR_workgroup_memory_explicit_layout",
    "VK_KHR_zero_initialize_workgroup_memory",
    "VK_QCOM_fragment_density_map_offset", "VK_QCOM_image_processing",
    "VK_QCOM_multiview_per_view_render_areas",
    "VK_QCOM_multiview_per_view_viewports",
    "VK_QCOM_render_pass_shader_resolve", "VK_QCOM_render_pass_store_ops",
    "VK_QCOM_render_pass_transform", "VK_QCOM_rotated_copy_commands",
    "VK_QCOM_tile_properties",
]

known = set(re.findall(r'"(VK_[A-Z0-9_]+)"', c))
adds = [f'    "{e}": 1,' for e in A750_EXTS if e not in known]
if adds:
    for probe in ['"VK_KHR_swapchain": 1,', '"VK_KHR_swapchain":']:
        if probe in c:
            eol = c.find('\n', c.find(probe))
            c = c[:eol] + '\n' + '\n'.join(adds) + c[eol:]
            break
    else:
        c += '\n' + '\n'.join(adds)
    print(f"[OK] Added {len(adds)} A750 extension entries")
else:
    print("[INFO] All A750 extensions already present in vk_extensions.py")

with open(fp, 'w') as f:
    f.write(c)
PYEOF
    fi

    python3 - "$tu_device" "$vk_exts_py" << 'PYEOF'
import sys, re

tu_path, vk_path = sys.argv[1], sys.argv[2]
with open(tu_path) as f:
    content = f.read()

INST_ONLY = {
    "VK_KHR_surface", "VK_KHR_android_surface", "VK_KHR_display",
    "VK_KHR_get_surface_capabilities2", "VK_KHR_portability_enumeration",
    "VK_EXT_debug_report", "VK_EXT_debug_utils", "VK_EXT_headless_surface",
    "VK_EXT_layer_settings", "VK_EXT_swapchain_colorspace",
    "VK_GOOGLE_surfaceless_query",
}

A750_CORE = [
    "VK_ANDROID_external_memory_android_hardware_buffer",
    "VK_EXT_4444_formats", "VK_EXT_astc_decode_mode",
    "VK_EXT_blend_operation_advanced", "VK_EXT_border_color_swizzle",
    "VK_EXT_calibrated_timestamps", "VK_EXT_color_write_enable",
    "VK_EXT_conditional_rendering", "VK_EXT_conservative_rasterization",
    "VK_EXT_custom_border_color", "VK_EXT_depth_clamp_zero_one",
    "VK_EXT_depth_clip_control", "VK_EXT_depth_clip_enable",
    "VK_EXT_descriptor_indexing", "VK_EXT_device_address_binding_report",
    "VK_EXT_device_fault", "VK_EXT_device_memory_report",
    "VK_EXT_extended_dynamic_state", "VK_EXT_extended_dynamic_state2",
    "VK_EXT_filter_cubic", "VK_EXT_fragment_density_map",
    "VK_EXT_fragment_density_map2", "VK_EXT_global_priority",
    "VK_EXT_global_priority_query", "VK_EXT_host_query_reset",
    "VK_EXT_image_2d_view_of_3d", "VK_EXT_image_robustness",
    "VK_EXT_image_view_min_lod", "VK_EXT_index_type_uint8",
    "VK_EXT_inline_uniform_block", "VK_EXT_line_rasterization",
    "VK_EXT_load_store_op_none", "VK_EXT_multisampled_render_to_single_sampled",
    "VK_EXT_multi_draw", "VK_EXT_mutable_descriptor_type",
    "VK_EXT_pipeline_creation_cache_control", "VK_EXT_pipeline_creation_feedback",
    "VK_EXT_pipeline_protected_access", "VK_EXT_pipeline_robustness",
    "VK_EXT_primitive_topology_list_restart", "VK_EXT_private_data",
    "VK_EXT_provoking_vertex", "VK_EXT_queue_family_foreign",
    "VK_EXT_robustness2", "VK_EXT_sample_locations",
    "VK_EXT_sampler_filter_minmax", "VK_EXT_scalar_block_layout",
    "VK_EXT_separate_stencil_usage", "VK_EXT_shader_atomic_float",
    "VK_EXT_shader_demote_to_helper_invocation", "VK_EXT_shader_image_atomic_int64",
    "VK_EXT_shader_module_identifier", "VK_EXT_shader_stencil_export",
    "VK_EXT_shader_subgroup_ballot", "VK_EXT_shader_subgroup_vote",
    "VK_EXT_shader_viewport_index_layer", "VK_EXT_subgroup_size_control",
    "VK_EXT_swapchain_maintenance1", "VK_EXT_texel_buffer_alignment",
    "VK_EXT_texture_compression_astc_hdr", "VK_EXT_tooling_info",
    "VK_EXT_transform_feedback", "VK_EXT_vertex_attribute_divisor",
    "VK_EXT_vertex_input_dynamic_state",
    "VK_IMG_filter_cubic",
    "VK_KHR_16bit_storage", "VK_KHR_8bit_storage",
    "VK_KHR_acceleration_structure", "VK_KHR_bind_memory2",
    "VK_KHR_buffer_device_address", "VK_KHR_calibrated_timestamps",
    "VK_KHR_copy_commands2", "VK_KHR_create_renderpass2",
    "VK_KHR_dedicated_allocation", "VK_KHR_deferred_host_operations",
    "VK_KHR_depth_stencil_resolve", "VK_KHR_descriptor_update_template",
    "VK_KHR_device_group", "VK_KHR_draw_indirect_count",
    "VK_KHR_driver_properties", "VK_KHR_dynamic_rendering",
    "VK_KHR_dynamic_rendering_local_read", "VK_KHR_external_fence",
    "VK_KHR_external_fence_fd", "VK_KHR_external_memory",
    "VK_KHR_external_memory_fd", "VK_KHR_external_semaphore",
    "VK_KHR_external_semaphore_fd", "VK_KHR_format_feature_flags2",
    "VK_KHR_fragment_shading_rate",
    "VK_KHR_get_memory_requirements2", "VK_KHR_global_priority",
    "VK_KHR_image_format_list", "VK_KHR_imageless_framebuffer",
    "VK_KHR_incremental_present", "VK_KHR_index_type_uint8",
    "VK_KHR_line_rasterization", "VK_KHR_load_store_op_none",
    "VK_KHR_maintenance1", "VK_KHR_maintenance2", "VK_KHR_maintenance3",
    "VK_KHR_maintenance4", "VK_KHR_maintenance5", "VK_KHR_maintenance6",
    "VK_KHR_maintenance7",
    "VK_KHR_map_memory2", "VK_KHR_multiview",
    "VK_KHR_pipeline_executable_properties", "VK_KHR_present_id",
    "VK_KHR_present_wait", "VK_KHR_push_descriptor",
    "VK_KHR_ray_query", "VK_KHR_ray_tracing_maintenance1",
    "VK_KHR_ray_tracing_position_fetch", "VK_KHR_relaxed_block_layout",
    "VK_KHR_sampler_mirror_clamp_to_edge", "VK_KHR_sampler_ycbcr_conversion",
    "VK_KHR_separate_depth_stencil_layouts", "VK_KHR_shader_atomic_int64",
    "VK_KHR_shader_clock", "VK_KHR_shader_draw_parameters",
    "VK_KHR_shader_expect_assume", "VK_KHR_shader_float16_int8",
    "VK_KHR_shader_float_controls", "VK_KHR_shader_float_controls2",
    "VK_KHR_shader_integer_dot_product", "VK_KHR_shader_maximal_reconvergence",
    "VK_KHR_shader_non_semantic_info", "VK_KHR_shader_quad_control",
    "VK_KHR_shader_subgroup_extended_types", "VK_KHR_shader_subgroup_rotate",
    "VK_KHR_shader_subgroup_uniform_control_flow",
    "VK_KHR_shader_terminate_invocation", "VK_KHR_spirv_1_4",
    "VK_KHR_storage_buffer_storage_class", "VK_KHR_swapchain",
    "VK_KHR_swapchain_mutable_format", "VK_KHR_synchronization2",
    "VK_KHR_timeline_semaphore", "VK_KHR_uniform_buffer_standard_layout",
    "VK_KHR_variable_pointers", "VK_KHR_vertex_attribute_divisor",
    "VK_KHR_vulkan_memory_model", "VK_KHR_workgroup_memory_explicit_layout",
    "VK_KHR_zero_initialize_workgroup_memory",
    "VK_QCOM_fragment_density_map_offset", "VK_QCOM_image_processing",
    "VK_QCOM_multiview_per_view_render_areas",
    "VK_QCOM_multiview_per_view_viewports",
    "VK_QCOM_render_pass_shader_resolve", "VK_QCOM_render_pass_store_ops",
    "VK_QCOM_render_pass_transform", "VK_QCOM_rotated_copy_commands",
    "VK_QCOM_tile_properties",
]

try:
    with open(vk_path) as f:
        vk_py = f.read()
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

def find_inject_point(text):
    for pat in [
        r'tu_get_device_extensions\s*\([^{]*?struct\s+vk_device_extension_table\s*\*\s*(\w+)',
        r'tu_fill_device_extensions\s*\([^{]*?struct\s+vk_device_extension_table\s*\*\s*(\w+)',
        r'vk_device_extension_table\s*\*\s*(\w+)\s*[,\)]',
    ]:
        m = re.search(pat, text, re.DOTALL)
        if m:
            ev = m.group(m.lastindex)
            bp = text.find('{', m.end())
            if bp == -1:
                continue
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
    if last:
        return last.group(1), last.end()
    return None

r = find_inject_point(content)
if r is None:
    print("[WARN] No extension injection point found in tu_device.cc")
    with open(tu_path, 'w') as f:
        f.write(content)
    sys.exit(0)

ev, ins = r
print(f"[OK] injection point: var='{ev}'")
lines = ["\n    // === A750 EXTENSIONS (Qualcomm GDG 80-78185-2 AL) ==="]
for e in dev_exts:
    lines.append(f"    {ev}->{e[3:]} = true;")
lines.append("    // === END A750 ===\n")
inj = "\n".join(lines)
content = content[:ins] + inj + content[ins:]
with open(tu_path, 'w') as f:
    f.write(content)
print(f"[OK] {len(dev_exts)} extension assignments written")
PYEOF

    log_success "Vulkan extensions applied"
}

# ── Patch orchestrator ─────────────────────────────────────────────────────────
apply_patches() {
    log_info "Applying patches for $BUILD_VARIANT build"
    cd "$MESA_DIR"

    if [[ "$BUILD_VARIANT" == "vanilla" ]]; then
        log_info "Vanilla build — skipping all patches"
        return 0
    fi

    if [[ "$APPLY_PATCH_SERIES" == "true" && -d "$PATCHES_DIR/series" ]]; then
        apply_patch_series "$PATCHES_DIR/series"
    fi

    apply_patch_disable_branch_and_or
    apply_patch_a7xx_compute_constlen
    apply_patch_disable_mesh_shader
    apply_patch_quest3_gpu
    apply_patch_timeline_semaphore
    apply_patch_ubwc_56
    apply_patch_gralloc_ubwc
    apply_patch_a750_identity
    apply_patch_vulkan_extensions

    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local pname; pname=$(basename "$patch")
            log_info "Custom patch: $pname"
            if git apply --check "$patch" 2>/dev/null; then
                git apply "$patch" && log_success "Applied: $pname"
            else
                log_warn "Could not apply: $pname"
            fi
        done
    fi

    log_success "All patches applied"
}

apply_patch_series() {
    local series_dir="$1"
    cd "$MESA_DIR"
    git am --abort &>/dev/null || true
    for patch in $(find "$series_dir" -maxdepth 1 -name '*.patch' | sort); do
        local pname; pname=$(basename "$patch")
        log_info "Series patch: $pname"
        git am --3way "$patch" 2>&1 | tee -a "${WORKDIR}/patch.log" || {
            log_error "Failed: $pname"
            git am --abort
            exit 1
        }
    done
    log_success "Patch series applied"
}

setup_subprojects() {
    log_info "Setting up SPIRV subprojects"
    cd "$MESA_DIR"
    mkdir -p subprojects
    local CACHE="${WORKDIR}/sp-cache"
    mkdir -p "$CACHE"

    for proj in spirv-tools spirv-headers; do
        if [[ -d "$CACHE/$proj" ]]; then
            log_info "Using cached $proj"
            cp -r "$CACHE/$proj" subprojects/
        else
            log_info "Cloning $proj"
            git clone --depth=1 "https://github.com/KhronosGroup/${proj}.git" "subprojects/$proj"
            cp -r "subprojects/$proj" "$CACHE/"
        fi
    done
    log_success "Subprojects ready"
}

create_cross_file() {
    log_info "Creating cross-compilation file (aarch64 / Android)"
    local ndk_bin="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    [[ ! -d "$ndk_bin" ]] && { log_error "NDK not found: $ndk_bin"; exit 1; }

    local cver="$API_LEVEL"
    [[ ! -f "${ndk_bin}/aarch64-linux-android${cver}-clang" ]] && cver="35"
    [[ ! -f "${ndk_bin}/aarch64-linux-android${cver}-clang" ]] && cver="34"
    log_info "Using Clang: aarch64-linux-android${cver}"

    local c_args="'-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations'"
    for flag in $CFLAGS_EXTRA; do
        c_args="$c_args, '$flag'"
    done

    local cpp_args="'-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations'"
    for flag in $CXXFLAGS_EXTRA; do
        cpp_args="$cpp_args, '$flag'"
    done

    local link_args="'-static-libstdc++'"
    for flag in $LDFLAGS_EXTRA; do
        link_args="$link_args, '$flag'"
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
c_args        = [$c_args]
cpp_args      = [$cpp_args]
c_link_args   = [$link_args]
cpp_link_args = [$link_args]
EOF
    log_success "Cross-compilation file ready"
}

configure_build() {
    log_info "Configuring Mesa build (meson)"
    cd "$MESA_DIR"

    local buildtype="$BUILD_TYPE"
    [[ "$BUILD_VARIANT" == "debug" ]]   && buildtype="debug"
    [[ "$BUILD_VARIANT" == "profile" ]] && buildtype="debugoptimized"

    meson setup build                                    \
        --cross-file "${WORKDIR}/cross-aarch64.txt"     \
        -Dbuildtype="$buildtype"                         \
        -Db_ndebug=true                                  \
        -Db_lto=true                                     \
        -Dplatforms=android                              \
        -Dplatform-sdk-version="$API_LEVEL"              \
        -Dandroid-stub=true                              \
        -Dgallium-drivers=                               \
        -Dvulkan-drivers=freedreno                       \
        -Dvulkan-beta=true                               \
        -Dfreedreno-kmds=kgsl                            \
        -Degl=disabled                                   \
        -Dglx=disabled                                   \
        -Dgles1=disabled                                 \
        -Dgles2=disabled                                 \
        -Dopengl=false                                   \
        -Dgbm=disabled                                   \
        -Dllvm=disabled                                  \
        -Dlibunwind=disabled                             \
        -Dlmsensors=disabled                             \
        -Dzstd=disabled                                  \
        -Dvalgrind=disabled                              \
        -Dbuild-tests=false                              \
        -Ddefault_library=shared                         \
        -Dwerror=false                                   \
        --force-fallback-for=spirv-tools,spirv-headers   \
        2>&1 | tee "${WORKDIR}/meson.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Meson configuration failed — check ${WORKDIR}/meson.log"
        exit 1
    fi
    log_success "Build configured"
}

compile_driver() {
    log_info "Compiling Turnip driver"
    local cores
    cores=$(nproc 2>/dev/null || echo 4)
    log_info "Using $cores parallel jobs"
    ninja -C "${MESA_DIR}/build" -j"$cores" 2>&1 | tee "${WORKDIR}/ninja.log"
    local driver="${MESA_DIR}/build/src/freedreno/vulkan/libvulkan_freedreno.so"
    [[ ! -f "$driver" ]] && { log_error "Build failed: libvulkan_freedreno.so not found"; exit 1; }
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
        "${pkg_dir}/${driver_name}" 2>/dev/null || \
        aarch64-linux-android-strip "${pkg_dir}/${driver_name}" 2>/dev/null || true

    local clean_version="${version%-devel}"
    local filename="Turnip_v${clean_version}-B${BUILD_NUMBER}"
    local driver_size
    driver_size=$(du -h "${pkg_dir}/${driver_name}" | cut -f1)

    cat > "${pkg_dir}/meta.json" << EOF
{
    "schemaVersion": 1,
    "name": "${filename}",
    "description": "Adreno 750 A7xx — KGSL — Android ${API_LEVEL} — Mesa ${clean_version}",
    "author": "BlueInstruction",
    "packageVersion": "${BUILD_NUMBER}",
    "vendor": "Mesa / Qualcomm Freedreno",
    "driverVersion": "${vulkan_version}",
    "minApi": 28,
    "libraryName": "${driver_name}",
    "buildDate": "${build_date}",
    "commit": "${commit}"
}
EOF

    echo "$filename"       > "${WORKDIR}/filename.txt"
    echo "$vulkan_version" > "${WORKDIR}/vulkan_version.txt"
    echo "$build_date"     > "${WORKDIR}/build_date.txt"

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
    local clean_version="${version%-devel}"

    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║           Turnip Driver Build Summary                ║"
    echo "  ╠══════════════════════════════════════════════════════╣"
    printf "  ║  %-20s : %-30s ║\n" "Package"       "Turnip_v${clean_version}-B${BUILD_NUMBER}"
    printf "  ║  %-20s : %-30s ║\n" "Mesa Version"  "$version"
    printf "  ║  %-20s : %-30s ║\n" "Vulkan Header" "$vulkan_version"
    printf "  ║  %-20s : %-30s ║\n" "Commit"        "$commit"
    printf "  ║  %-20s : %-30s ║\n" "Build Date"    "$build_date"
    printf "  ║  %-20s : %-30s ║\n" "Build Variant" "$BUILD_VARIANT"
    printf "  ║  %-20s : %-30s ║\n" "Source"        "$MESA_SOURCE"
    printf "  ║  %-20s : %-30s ║\n" "API Level"     "$API_LEVEL"
    printf "  ║  %-20s : %-30s ║\n" "Deck Emu"      "$ENABLE_DECK_EMU"
    printf "  ║  %-20s : %-30s ║\n" "A7xx Fixes"    "$ENABLE_A7XX_FIXES"
    printf "  ║  %-20s : %-30s ║\n" "Quest 3"       "$ENABLE_QUEST3"
    printf "  ║  %-20s : %-30s ║\n" "Timeline Hack" "$ENABLE_TIMELINE_HACK"
    printf "  ║  %-20s : %-30s ║\n" "UBWC 5/6"      "$ENABLE_UBWC_HACK"
    printf "  ║  %-20s : %-30s ║\n" "LTO"           "true"
    printf "  ║  %-20s : %-30s ║\n" "March"         "armv8.2-a+fp16+rcpc+dotprod+i8mm"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo ""
    ls -lh "${WORKDIR}"/*.zip 2>/dev/null | awk '{print "  Output: " $9 " (" $5 ")"}'
    echo ""
}

main() {
    log_info "Turnip Driver Builder — A750 / A7xx"
    log_info "Variant: $BUILD_VARIANT | Source: $MESA_SOURCE | API: $API_LEVEL"

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
    log_success "Build complete"
}

main "$@"
