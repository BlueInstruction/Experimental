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

clone_mesa() {
    log_info "Cloning Mesa source: $MESA_SOURCE"
    local ref=""
    case "$MESA_SOURCE" in
        latest_release)
            ref=$(fetch_latest_release)
            log_info "Latest release: $ref"
            ;;
        staging_branch)
            ref="$STAGING_BRANCH"
            ;;
        main_branch|latest_main)
            ref="main"
            ;;
        custom_tag)
            [[ -z "$CUSTOM_TAG" ]] && { log_error "CUSTOM_TAG is empty"; exit 1; }
            ref="$CUSTOM_TAG"
            ;;
        autotuner)
            log_info "Cloning AutoTuner fork"
            git clone --depth=1 "$AUTOTUNER_REPO" "$MESA_DIR" 2>&1 | tail -1
            local commit
            commit=$(git -C "$MESA_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
            get_mesa_version > "${WORKDIR}/version.txt"
            echo "$commit" > "${WORKDIR}/commit.txt"
            log_success "AutoTuner Mesa cloned"
            return 0
            ;;
        *)
            ref="main"
            ;;
    esac

    if [[ -n "$MESA_LOCAL_PATH" && -d "$MESA_LOCAL_PATH" ]]; then
        log_info "Using local Mesa: $MESA_LOCAL_PATH"
        cp -r "$MESA_LOCAL_PATH" "$MESA_DIR"
    else
        log_info "Cloning Mesa @ $ref"
        git clone --depth=1 --branch "$ref" "$MESA_REPO" "$MESA_DIR" 2>/dev/null || \
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
    [[ ! -f "$tu_sync" ]] && { log_warn "KGSL kernel file not found, skipping timeline fix"; return 0; }
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
    local tu_android="${MESA_DIR}/src/freedreno/vulkan/tu_android.cc"
    [[ ! -f "$tu_android" ]] && tu_android="${MESA_DIR}/src/freedreno/vulkan/tu_android.c"
    if [[ ! -f "$tu_android" ]]; then
        log_warn "tu_android file not found, trying u_gralloc fallback"
        local gralloc_fb="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"
        if [[ -f "$gralloc_fb" ]] && ! grep -q "GRALLOC_UBWC_FIX" "$gralloc_fb"; then
            python3 - "$gralloc_fb" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(get_buffer_basic_info[^{]*\{)'
m = re.search(pat, c)
if m:
    inject = '\n   /* GRALLOC_UBWC_FIX */\n   binfo->modifier = DRM_FORMAT_MOD_QCOM_COMPRESSED;\n'
    ins = m.end()
    c = c[:ins] + inject + c[ins:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] UBWC modifier forced in u_gralloc_fallback.c')
else:
    print('[WARN] get_buffer_basic_info not found in u_gralloc_fallback.c')
PYEOF
        fi
        return 0
    fi
    if grep -q "GRALLOC_UBWC_FIX" "$tu_android"; then
        log_info "Gralloc UBWC fix already applied"
        return 0
    fi
    python3 - "$tu_android" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(GRALLOC1_PRODUCER_USAGE_PRIVATE_ALLOC_UBWC\s*\|\s*)'
if re.search(pat, c):
    print('[OK] UBWC gralloc flag already present')
    with open(fp, 'w') as f: f.write(c)
else:
    pat2 = r'(gralloc_usage\s*=[^;]+)(;)'
    if re.search(pat2, c):
        c = re.sub(pat2,
            r'\1 | GRALLOC1_PRODUCER_USAGE_PRIVATE_ALLOC_UBWC \2',
            c, count=1)
        with open(fp, 'w') as f: f.write(c)
        print('[OK] UBWC flag added to gralloc usage')
    else:
        print('[WARN] Gralloc usage pattern not found, skipping')
        with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "Gralloc UBWC fix applied"
}

apply_a8xx_device_support() {
    log_info "Applying A8xx device support patches"

    local kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    local dev_info_h="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.h"
    local devices_py="${MESA_DIR}/src/freedreno/common/freedreno_devices.py"
    local cmd_buffer="${MESA_DIR}/src/freedreno/vulkan/tu_cmd_buffer.cc"
    local gmem_cache="${MESA_DIR}/src/freedreno/common/fd6_gmem_cache.h"
    local gralloc_fb="${MESA_DIR}/src/util/u_gralloc/u_gralloc_fallback.c"
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
pat = r'(case KGSL_UBWC_4_0:.*?break;\n)([ \t]*default:)'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.start(2)] + inject + c[m.start(2):]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] UBWC 5.0/6.0 cases inserted')
else:
    pat2 = r'(KGSL_UBWC_3_0.*?break;\n)([ \t]*default:)'
    m2 = re.search(pat2, c, re.DOTALL)
    if m2:
        c = c[:m2.start(2)] + inject + c[m2.start(2):]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] UBWC 5.0/6.0 inserted after UBWC_3_0')
    else:
        print('[WARN] UBWC switch pattern not found, skipping')
PYEOF
        log_success "UBWC 5.0/6.0 support applied"
    fi

    if [[ -f "$gralloc_fb" ]] && ! grep -q "UBWC_GRALLOC_FORCED" "$gralloc_fb"; then
        python3 - "$gralloc_fb" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
if 'always_use_ubwc' in c.lower() or 'UBWC_GRALLOC_FORCED' in c:
    print('[OK] u_gralloc UBWC already forced'); sys.exit(0)
pat = r'(static\s+\w+\s+\w*get_buffer\w*\s*\([^)]*\)\s*\{)'
m = re.search(pat, c)
if m:
    inject = '\n   /* UBWC_GRALLOC_FORCED: always use UBWC detection path for a8xx */\n   return false;\n'
    ins = m.end()
    c = c[:ins] + inject + c[ins:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] u_gralloc always-ubwc path forced')
else:
    print('[WARN] get_buffer function not found in u_gralloc_fallback.c')
PYEOF
        log_success "u_gralloc UBWC detection forced"
    fi

    if [[ -f "$dev_info_h" ]] && ! grep -q "disable_gmem" "$dev_info_h"; then
        python3 - "$dev_info_h" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
field = '   bool disable_gmem;\n'
pat = r'(struct\s+fd_dev_info\s*\{[^}]*?)(};)'
m = re.search(pat, c, re.DOTALL)
if m:
    ins = m.start(2)
    c = c[:ins] + field + c[ins:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] disable_gmem field added to fd_dev_info')
else:
    pat2 = r'(bool\s+has_\w+;\s*\n)'
    all_m = list(re.finditer(pat2, c))
    if all_m:
        eol = c.find('\n', all_m[-1].start())
        c = c[:eol+1] + field + c[eol+1:]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] disable_gmem field added after last bool field')
    else:
        print('[WARN] Could not find insertion point for disable_gmem')
PYEOF
        log_success "disable_gmem property added to fd_dev_info"
    fi

    if [[ -f "$cmd_buffer" ]] && ! grep -q "A8XX_DISABLE_GMEM" "$cmd_buffer"; then
        python3 - "$cmd_buffer" "$dev_info_h" << 'PYEOF'
import sys, re
fp = sys.argv[1]
dev_h = sys.argv[2]
with open(fp) as f: c = f.read()
disable_gmem_exists = False
if dev_h and open(dev_h).read().find('disable_gmem') != -1:
    disable_gmem_exists = True
inject = '\n   /* A8XX_DISABLE_GMEM: force sysmem for a8xx GPUs with small cache */\n   if (cmd->device->physical_device->dev_info.disable_gmem)\n      return true;\n'
pat = r'(use_sysmem_rendering\s*\([^)]*\)\s*\{)'
m = re.search(pat, c)
if m:
    brace = c.find('{', m.start())
    ins = c.find('\n', brace) + 1
    c = c[:ins] + inject + c[ins:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] disable_gmem guard added to use_sysmem_rendering')
else:
    print('[WARN] use_sysmem_rendering not found in tu_cmd_buffer.cc')
PYEOF
        log_success "A8xx disable_gmem guard added to tu_cmd_buffer.cc"
    fi

    if [[ -f "$gmem_cache" ]] && ! grep -q "A8XX_GMEM_OFFSET_FIX" "$gmem_cache"; then
        python3 - "$gmem_cache" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(if\s*\(info->chip\s*>=\s*8\s*&&\s*info->num_slices\s*>\s*1\s*\)[^}]*\})'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.start()] + '/* A8XX_GMEM_OFFSET_FIX: removed - causes assertion with <2MB cache */' + c[m.end():]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] A8xx gmem cache offset guard removed')
else:
    print('[INFO] gmem offset block not found (may already be patched or absent)')
PYEOF
        log_success "A8xx gmem cache offset fix applied"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "A8XX_FLUSHALL_REMOVED" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
pat = r'(if\s*\([^)]*chip\s*==\s*A8XX[^)]*\)[^{]*\{[^}]*TU_DEBUG_FLUSHALL[^}]*\})'
m = re.search(pat, c, re.DOTALL)
if m:
    c = c[:m.start()] + '/* A8XX_FLUSHALL_REMOVED */' + c[m.end():]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] A8xx forced FLUSHALL removed')
else:
    pat2 = r'(TU_DEBUG_FLUSHALL[^;]+;)'
    m2 = re.search(pat2, c)
    if m2:
        c = c[:m2.start()] + '/* A8XX_FLUSHALL_REMOVED */' + c[m2.end():]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] FLUSHALL flag removed (generic pattern)')
    else:
        print('[INFO] FLUSHALL block not found (may be absent in this Mesa version)')
PYEOF
        log_success "A8xx FLUSHALL removed"
    fi

    if [[ -f "$devices_py" ]] && ! grep -q "A8XX_DEVICES_INJECTED" "$devices_py"; then
        python3 - "$devices_py" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

has_830 = '0x44050000' in c
has_825 = '0x44030000' in c
has_829 = '0x44030A00' in c or '0x44030a00' in c
has_810 = '0x44010000' in c

missing = []
if not has_830: missing.append('830')
if not has_825: missing.append('825')
if not has_829: missing.append('829')
if not has_810: missing.append('810')

if not missing:
    print('[OK] All a8xx GPU entries already present')
    sys.exit(0)

inject = '\n# A8XX_DEVICES_INJECTED\n'

if not has_830:
    inject += '''
add_gpus([
        GPUId(chip_id=0x44050000, name="FD830"),
        GPUId(chip_id=0x44050001, name="FD830"),
        GPUId(chip_id=0xffff44050000, name="FD830"),
    ], A6xxGPUInfo(
        CHIP.A8XX,
        [a7xx_base, a7xx_gen3, a8xx_base],
        num_ccu = 6,
        num_slices = 2,
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

if not has_825:
    inject += '''
add_gpus([
        GPUId(chip_id=0x44030000, name="FD825"),
    ], A6xxGPUInfo(
        CHIP.A8XX,
        [a7xx_base, a7xx_gen3, a8xx_base],
        num_ccu = 4,
        num_slices = 2,
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

if not has_829:
    inject += '''
add_gpus([
        GPUId(chip_id=0x44030A00, name="FD829"),
        GPUId(chip_id=0x44030A20, name="FD829"),
        GPUId(chip_id=0xffff44030A00, name="FD829"),
    ], A6xxGPUInfo(
        CHIP.A8XX,
        [a7xx_base, a7xx_gen3, a8xx_base],
        num_ccu = 4,
        num_slices = 2,
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

if not has_810:
    inject += '''
add_gpus([
        GPUId(chip_id=0x44010000, name="FD810"),
    ], A6xxGPUInfo(
        CHIP.A8XX,
        [a7xx_base, a7xx_gen3, a8xx_base],
        num_ccu = 2,
        num_slices = 1,
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

m = re.search(r'(# Values from blob.*?\n)', c)
if m:
    ins = m.start()
    c = c[:ins] + inject + c[ins:]
else:
    c = c + inject

with open(fp, 'w') as f: f.write(c)
print(f'[OK] Injected a8xx GPU entries: {missing}')
PYEOF
        log_success "A8xx GPU device entries injected (830/825/829/810)"
    fi

    log_success "A8xx full support applied"
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
            log_warn "Unknown deck emu target: $DECK_EMU_TARGET, using nvidia"
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
    ins = m.end()
    c = c[:ins] + spoof_code + c[ins:]
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] Deck emu ({device_name}) applied')
else:
    print('[WARN] Could not find properties function for deck emu')
    with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "Deck emulation applied ($DECK_EMU_TARGET)"
}

apply_vulkan_extensions_support() {
    log_info "Applying Vulkan extension spoofing"
    local tu_extensions="${MESA_DIR}/src/freedreno/vulkan/tu_extensions.py"
    [[ ! -f "$tu_extensions" ]] && { log_warn "tu_extensions.py not found, skipping ext spoof"; return 0; }
    if grep -q "EXT_SPOOF" "$tu_extensions"; then
        log_info "Extension spoof already applied"
        return 0
    fi
    python3 - "$tu_extensions" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
extra_exts = [
    "VK_EXT_descriptor_buffer",
    "VK_EXT_mesh_shader",
    "VK_KHR_ray_query",
    "VK_KHR_acceleration_structure",
]
to_add = [e for e in extra_exts if e not in c]
if to_add:
    spoof_block = "\n# EXT_SPOOF: additional extensions\n"
    for ext in to_add:
        spoof_block += f'    Extension("{ext}", True, None),\n'
    m = re.search(r'(extensions\s*=\s*\[.*?\])', c, re.DOTALL)
    if m:
        ins = m.end() - 1
        c = c[:ins] + spoof_block + c[ins:]
        with open(fp, 'w') as f: f.write(c)
        print(f'[OK] Added {len(to_add)} spoofed extensions')
    else:
        with open(fp, 'w') as f: f.write(c)
        print('[WARN] Extension list not found')
else:
    print('[OK] All target extensions already present')
PYEOF
    log_success "Vulkan extension spoofing applied"
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

turbo_call = """
   
   if (TU_DEBUG(TURBO))
      tu_try_activate_turbo();
"""

m_func = re.search(r'\n(static |VkResult |void )', c)
if m_func and 'tu_try_activate_turbo' not in c:
    c = c[:m_func.start()+1] + turbo_func + '\n' + c[m_func.start()+1:]

m_call = re.search(r'(result\s*=\s*tu_physical_device_init\([^;]+;\s*\n\s*if\s*\([^)]+\)[^{]*\{[^}]*\}\s*\n)', c, re.DOTALL)
if not m_call:
    m_call = re.search(r'(tu_physical_device_init\([^;]+;\s*\n)', c)
if m_call:
    c = c[:m_call.end()] + turbo_call + c[m_call.end():]

with open(fp, 'w') as f: f.write(c)
print('[OK] turbo mode injected into tu_device.cc')
PYEOF
        log_success "TU_DEBUG_TURBO implementation added"
    fi

    if [[ -f "$tu_device_cc" ]] && ! grep -q "TU_DEBUG_DEFRAG" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

defrag_code = """
   if (TU_DEBUG(DEFRAG) && size > (1u << 20))
      size = ALIGN(size, 64 * 1024);
"""

m = re.search(r'(VkResult\s+\w*bo_init_new\w*\s*\([^{]+\{)', c)
if m:
    body_start = m.end()
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
    func_start = m.end()
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
    print('[OK] push_regs helper added to ir3_ra.c')
else:
    print('[WARN] push_regs: no includes found in ir3_ra.c')
PYEOF
        log_success "TU_DEBUG_PUSH_REGS helper added"
    fi

    if [[ -f "$ir3_compiler_nir" ]] && ! grep -q "TU_DEBUG.*unroll\|ir3_custom_unroll" "$ir3_compiler_nir"; then
        python3 - "$ir3_compiler_nir" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

unroll_code = """
   
   {
      const char *_dbg = getenv("TU_DEBUG");
      if (_dbg && strstr(_dbg, "unroll"))
         NIR_PASS(progress, nir, nir_opt_loop_unroll);
   }
"""

m = re.search(r'(NIR_PASS[^;]+nir_opt_loop_unroll[^;]+;\s*\n)', c)
if not m:
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

    log_info "slc_pin / cp_prefetch / shfl / vgt_pref: flags registered (kernel-side implementation required)"
    log_success "All custom TU_DEBUG flags applied"
}

apply_patch_series() {
    local series_dir="$1"
    log_info "Applying patch series from: $series_dir"
    local series_file="${series_dir}/series"
    if [[ ! -f "$series_file" ]]; then
        log_warn "No series file found at $series_file"
        return 0
    fi
    while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
        [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
        local patch_path="${series_dir}/${patch_name}"
        if [[ ! -f "$patch_path" ]]; then
            log_warn "Patch not found: $patch_name"
            continue
        fi
        log_info "Applying series patch: $patch_name"
        if git apply --check "$patch_path" 2>/dev/null; then
            git apply "$patch_path"
            log_success "Applied: $patch_name"
        else
            log_warn "Could not apply: $patch_name (skipping)"
        fi
    done < "$series_file"
    log_success "Patch series applied"
}

apply_patches() {
    log_info "Applying patches for $TARGET_GPU"
    cd "$MESA_DIR"
    if [[ "$BUILD_VARIANT" == "vanilla" ]]; then
        log_info "Vanilla build - skipping all patches"
        return 0
    fi

    if [[ "$APPLY_PATCH_SERIES" == "true" ]]; then
        if [[ "$TARGET_GPU" == "a8xx" && -d "$PATCHES_DIR/a8xx" && -f "$PATCHES_DIR/a8xx/series" ]]; then
            log_info "Applying a8xx patch series"
            apply_patch_series "$PATCHES_DIR/a8xx"
        fi
        if [[ -f "$PATCHES_DIR/series" ]]; then
            log_info "Applying common patch series"
            apply_patch_series "$PATCHES_DIR"
        fi
    fi

    if [[ "$ENABLE_TIMELINE_HACK" == "true" ]]; then apply_timeline_semaphore_fix; fi
    apply_gralloc_ubwc_fix
    if [[ "$ENABLE_CUSTOM_FLAGS" == "true" ]]; then apply_custom_debug_flags; fi
    if [[ "$ENABLE_DECK_EMU" == "true" ]]; then apply_deck_emu_support; fi
    if [[ "$ENABLE_EXT_SPOOF" == "true" ]]; then apply_vulkan_extensions_support; fi
    if [[ "$TARGET_GPU" == "a8xx" ]]; then
        apply_a8xx_device_support
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

    local extra_opts=""
    if [[ "$TARGET_GPU" == "a8xx" ]]; then
        extra_opts="-Dfreedreno-a8xx=true"
    fi

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
        ${extra_opts} \
        2>&1 | tee "${WORKDIR}/meson.log"
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_warn "meson failed with extra_opts, retrying without a8xx flag"
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
            --wipe \
            2>&1 | tee "${WORKDIR}/meson.log"
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            log_error "Meson configuration failed"
            exit 1
        fi
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
    local driver_name

    if [[ "$TARGET_GPU" == "a8xx" ]]; then
        driver_name="vulkan.adreno.so"
    else
        local name_suffix="${TARGET_GPU:1}"
        driver_name="vulkan.ad0${name_suffix}.so"
    fi

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
    echo "  Target GPU     : $TARGET_GPU"
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
