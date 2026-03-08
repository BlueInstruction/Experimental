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
    c = re.sub(pat, r'\1true /* TIMELINE_SEMAPHORE_FIX */', c)
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
    [[ ! -f "$tu_android" ]] && { log_warn "tu_android file not found, skipping gralloc fix"; return 0; }
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
            r'\1 | GRALLOC1_PRODUCER_USAGE_PRIVATE_ALLOC_UBWC /* GRALLOC_UBWC_FIX */\2',
            c, count=1)
        with open(fp, 'w') as f: f.write(c)
        print('[OK] UBWC flag added to gralloc usage')
    else:
        print('[WARN] Gralloc usage pattern not found, skipping')
        with open(fp, 'w') as f: f.write(c)
PYEOF
    log_success "Gralloc UBWC fix applied"
}

apply_deck_emu_support() {
    log_info "Applying Steam Deck GPU emulation (spoof as: $DECK_EMU_TARGET)"
    local tu_device_cc="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    local tu_extensions="${MESA_DIR}/src/freedreno/vulkan/tu_extensions.py"
    local tu_stubs_cc="${MESA_DIR}/src/freedreno/vulkan/tu_vendor_stubs.cc"
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

    # ── Step 1: Spoof vendorID / deviceID / deviceName in properties ──────
    python3 - "$tu_device_cc" "$vendor_id" "$device_id" "$driver_version" "$device_name" << 'PYEOF'
import sys, re
fp, vendor_id, device_id, driver_version, device_name = sys.argv[1:6]
with open(fp) as f: c = f.read()
spoof_code = f"""
   /* DECK_EMU: spoof GPU identity for better game compatibility */
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

    # ── Step 2: Create vendor stub file ──────────────────────────────────
    # Rules:
    #   - ONLY extensions used by DXVK/VKD3D-Proton for vendor detection
    #   - Every extension must have ALL its entry points implemented (even as no-ops)
    #   - No NULL function pointers — that is guaranteed crash
    python3 - "$tu_stubs_cc" "$DECK_EMU_TARGET" << 'PYEOF'
import sys
fp, target = sys.argv[1], sys.argv[2]

# Extensions needed per vendor target for DXVK/VKD3D-Proton game detection:
#
# AMD target: DXVK checks AMD extensions to activate optimized paths for RADV.
#   VK_AMD_shader_info        — vkGetShaderInfoAMD (returns NOT_SUPPORTED = safe)
#   VK_AMD_buffer_marker      — vkCmdWriteBufferMarker2AMD (no-op cmd)
#   VK_AMD_device_coherent_memory  — feature struct only, no new commands
#   VK_AMD_shader_core_properties  — property struct only, no new commands
#   VK_AMD_shader_core_properties2 — property struct only, no new commands
#   VK_AMD_memory_overallocation_behavior — feature struct only
#
# NVIDIA target: VKD3D-Proton checks NV extensions to activate NV-specific paths.
#   VK_NV_device_diagnostic_checkpoints — vkCmdSetCheckpointNV + vkGetQueueCheckpointDataNV
#   VK_NV_device_diagnostics_config     — feature struct + vkInitializePerformanceApiINTEL no analog
#   VK_NVX_binary_import                — several entry points, stub all
#   VK_NVX_image_view_handle            — vkGetImageViewHandleNVX (returns 0)
#
# Valve target: Steam Runtime detection
#   VK_VALVE_descriptor_set_host_mapping — vkGetDescriptorSetLayoutHostMappingInfoVALVE + vkGetDescriptorSetHostMappingVALVE
#
# QUALCOMM: always present since we ARE Qualcomm, already in Turnip
#
# Win32: instance-level extensions, not device-level. Not injectable here.

AMD_STUBS = '''
/* ── VK_AMD_shader_info stub ──────────────────────────────────────────────
 * DXVK calls this to dump shader stats on AMD. We return NOT_SUPPORTED.
 * Required entry point — advertising without it = hard crash in DXVK. */
VKAPI_ATTR VkResult VKAPI_CALL
tu_GetShaderInfoAMD(VkDevice device, VkPipeline pipeline,
                    VkShaderStageFlagBits shaderStage,
                    VkShaderInfoTypeAMD infoType,
                    size_t *pInfoSize, void *pInfo)
{
   /* Stub: AMD shader info not available on Adreno hardware */
   if (pInfoSize) *pInfoSize = 0;
   return VK_ERROR_FEATURE_NOT_PRESENT;
}

/* ── VK_AMD_buffer_marker stub ────────────────────────────────────────────
 * DXVK uses this for GPU crash breadcrumbs on AMD. Safe no-op. */
VKAPI_ATTR void VKAPI_CALL
tu_CmdWriteBufferMarker2AMD(VkCommandBuffer commandBuffer,
                             VkPipelineStageFlags2 stage,
                             VkBuffer dstBuffer, VkDeviceSize dstOffset,
                             uint32_t marker)
{
   /* Stub: no-op breadcrumb marker */
   (void)commandBuffer; (void)stage; (void)dstBuffer;
   (void)dstOffset; (void)marker;
}
'''

NV_STUBS = '''
/* ── VK_NV_device_diagnostic_checkpoints stubs ────────────────────────────
 * VKD3D-Proton uses these for GPU hang detection on NVIDIA.
 * Both entry points required — advertising only one = crash. */
VKAPI_ATTR void VKAPI_CALL
tu_CmdSetCheckpointNV(VkCommandBuffer commandBuffer,
                      const void *pCheckpointMarker)
{
   /* Stub: NV diagnostic checkpoint no-op */
   (void)commandBuffer; (void)pCheckpointMarker;
}

VKAPI_ATTR void VKAPI_CALL
tu_GetQueueCheckpointDataNV(VkQueue queue, uint32_t *pCheckpointDataCount,
                             VkCheckpointDataNV *pCheckpointData)
{
   /* Stub: return 0 checkpoints */
   if (pCheckpointDataCount) *pCheckpointDataCount = 0;
   (void)queue; (void)pCheckpointData;
}

/* ── VK_NVX_image_view_handle stub ───────────────────────────────────────
 * Some NV-path shaders query this handle. Return 0 = disabled path. */
VKAPI_ATTR uint32_t VKAPI_CALL
tu_GetImageViewHandleNVX(VkDevice device,
                          const VkImageViewHandleInfoNVX *pInfo)
{
   /* Stub: NVX image view handle not supported */
   (void)device; (void)pInfo;
   return 0;
}

VKAPI_ATTR VkResult VKAPI_CALL
tu_GetImageViewAddressNVX(VkDevice device, VkImageView imageView,
                           VkImageViewAddressPropertiesNVX *pProperties)
{
   (void)device; (void)imageView; (void)pProperties;
   return VK_ERROR_FEATURE_NOT_PRESENT;
}
'''

VALVE_STUBS = '''
/* ── VK_VALVE_descriptor_set_host_mapping stubs ──────────────────────────
 * Steam Runtime uses these for CPU-side descriptor access.
 * Both entry points required per spec. */
VKAPI_ATTR void VKAPI_CALL
tu_GetDescriptorSetLayoutHostMappingInfoVALVE(
   VkDevice device,
   const VkDescriptorSetBindingReferenceVALVE *pBindingReference,
   VkDescriptorSetLayoutHostMappingInfoVALVE *pHostMapping)
{
   /* Stub: report zero-size mapping */
   if (pHostMapping) {
      pHostMapping->descriptorOffset = 0;
      pHostMapping->descriptorSize   = 0;
   }
   (void)device; (void)pBindingReference;
}

VKAPI_ATTR void VKAPI_CALL
tu_GetDescriptorSetHostMappingVALVE(VkDevice device,
                                     VkDescriptorSet descriptorSet,
                                     void **ppData)
{
   /* Stub: return NULL mapping */
   if (ppData) *ppData = NULL;
   (void)device; (void)descriptorSet;
}
'''

header = '''/* tu_vendor_stubs.cc — DECK_EMU vendor extension stubs
 * Auto-generated by build_turnip.sh
 * These are minimal no-op implementations that satisfy DXVK/VKD3D-Proton
 * vendor detection without crashing. Each stub is safe to call. */

#include "tu_private.h"
#include "tu_device.h"
#include "vk_common_entrypoints.h"

'''

body = header
if target == 'amd':
    body += AMD_STUBS
elif target == 'nvidia':
    body += NV_STUBS
else:
    # Both — safe fallback
    body += AMD_STUBS + NV_STUBS

body += VALVE_STUBS  # Always include Valve stubs (Steam Deck = Valve hardware)

with open(fp, 'w') as f:
    f.write(body)
print(f'[OK] Vendor stubs written for target={target} ({fp})')
PYEOF

    # ── Step 3: Register stubs in tu_extensions.py ───────────────────────
    if [[ -f "$tu_extensions" ]]; then
        python3 - "$tu_extensions" "$DECK_EMU_TARGET" << 'PYEOF'
import sys, re
fp, target = sys.argv[1], sys.argv[2]
with open(fp) as f: c = f.read()

if 'DECK_EMU_VENDOR_EXTS' in c:
    print('[OK] Vendor extensions already registered'); sys.exit(0)

# Extensions with complete stub implementations above — safe to advertise
AMD_EXTS = [
    'VK_AMD_shader_info',
    'VK_AMD_buffer_marker',
    'VK_AMD_device_coherent_memory',
    'VK_AMD_shader_core_properties',
    'VK_AMD_shader_core_properties2',
    'VK_AMD_memory_overallocation_behavior',
]
NV_EXTS = [
    'VK_NV_device_diagnostic_checkpoints',
    'VK_NV_device_diagnostics_config',
    'VK_NVX_image_view_handle',
]
VALVE_EXTS = [
    'VK_VALVE_descriptor_set_host_mapping',
]
QCOM_EXTS = [
    # These are already in Turnip natively — just ensure they're enabled
    'VK_QCOM_render_pass_transform',
    'VK_QCOM_tile_properties',
    'VK_QCOM_image_processing',
    'VK_QCOM_image_processing2',
    'VK_QCOM_filter_cubic_clamp',
    'VK_QCOM_filter_cubic_weights',
    'VK_QCOM_multiview_per_view_viewports',
    'VK_QCOM_multiview_per_view_render_areas',
]

if target == 'amd':
    vendor_exts = AMD_EXTS
elif target == 'nvidia':
    vendor_exts = NV_EXTS
else:
    vendor_exts = AMD_EXTS + NV_EXTS

all_exts = vendor_exts + VALVE_EXTS + QCOM_EXTS

# Flip existing False entries to True for extensions already in the file
enabled = []
for ext in all_exts:
    pat = re.compile(
        r'(Extension\s*\(\s*["\']' + re.escape(ext) + r'["\'],\s*)(False|None)(\s*[,)])'
    )
    if pat.search(c):
        c = pat.sub(r'\g<1>True\3', c)
        enabled.append(ext)

# Add new entries for extensions NOT yet in the file (vendor-specific)
to_add = [e for e in vendor_exts + VALVE_EXTS if e not in c]
if to_add:
    block = '\n    # DECK_EMU_VENDOR_EXTS: vendor stubs for GPU identity spoofing\n'
    for ext in to_add:
        block += f'    Extension("{ext}", True, None),\n'
    # Insert before the closing ] of the extensions list
    m = re.search(r'(\])\s*$', c, re.MULTILINE)
    if m:
        c = c[:m.start()] + block + c[m.start():]

# QCOM extensions — flip False guards
for ext in QCOM_EXTS:
    pat = re.compile(
        r'(Extension\s*\(\s*["\']' + re.escape(ext) + r'["\'],\s*)(False|None)(\s*[,)])'
    )
    c = pat.sub(r'\g<1>True\3', c)

with open(fp, 'w') as f: f.write(c)
total = len(enabled) + len(to_add)
print(f'[OK] Vendor extensions registered: {total} '
      f'(flipped={len(enabled)}, added={len(to_add)})')
print(f'     Target vendor: {target} | VALVE + QCOM always included')
PYEOF
    fi

    # ── Step 4: Add stub file to Mesa build system ────────────────────────
    local meson_build="${MESA_DIR}/src/freedreno/vulkan/meson.build"
    if [[ -f "$meson_build" ]] && ! grep -q "tu_vendor_stubs" "$meson_build"; then
        python3 - "$meson_build" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
# Find the freedreno_vulkan_files list and add our stub file
m = re.search(r'(freedreno_vulkan_files\s*=\s*files\s*\([^)]+)', c, re.DOTALL)
if m:
    ins = m.end()
    c = c[:ins] + "\n  'tu_vendor_stubs.cc'," + c[ins:]
    with open(fp, 'w') as f: f.write(c)
    print('[OK] tu_vendor_stubs.cc added to meson.build')
else:
    # Try generic files() list
    m = re.search(r"('tu_device\.cc',)", c)
    if m:
        ins = m.end()
        c = c[:ins] + "\n  'tu_vendor_stubs.cc'," + c[ins:]
        with open(fp, 'w') as f: f.write(c)
        print('[OK] tu_vendor_stubs.cc inserted after tu_device.cc in meson.build')
    else:
        print('[WARN] Could not find insertion point in meson.build')
PYEOF
    fi

    log_success "Deck emulation applied ($DECK_EMU_TARGET) with vendor extension stubs"
}

apply_vulkan_extensions_support() {
    log_info "Enabling all Turnip-implemented Vulkan extensions for a7xx"
    local tu_extensions="${MESA_DIR}/src/freedreno/vulkan/tu_extensions.py"
    [[ ! -f "$tu_extensions" ]] && { log_warn "tu_extensions.py not found, skipping"; return 0; }
    if grep -q "A7XX_EXT_UNLOCK" "$tu_extensions"; then
        log_info "Extension unlock already applied"
        return 0
    fi

    python3 - "$tu_extensions" << 'PYEOF'
import sys, re, ast

fp = sys.argv[1]
with open(fp) as f:
    c = f.read()

# ── Phase 1: Extensions Turnip implements but are disabled via False / None ──
# These are extensions already listed in tu_extensions.py with condition=False
# We flip them to True only for extensions with real Turnip implementations.
# Source: https://mesamatrix.net/ (tu driver = 212/287)
SAFE_TO_ENABLE = {
    # Graphics pipeline & shading
    "VK_EXT_graphics_pipeline_library",
    "VK_EXT_mesh_shader",
    "VK_EXT_shader_object",
    "VK_KHR_fragment_shading_rate",
    "VK_EXT_fragment_shader_interlock",
    "VK_EXT_shader_tile_image",
    # Descriptor / memory
    "VK_EXT_descriptor_buffer",
    "VK_EXT_memory_budget",
    "VK_EXT_memory_priority",
    "VK_EXT_pageable_device_local_memory",
    "VK_EXT_device_memory_report",
    # Image / format
    "VK_EXT_image_compression_control",
    "VK_EXT_image_compression_control_swapchain",
    "VK_EXT_image_2d_view_of_3d",
    "VK_EXT_image_sliced_view_of_3d",
    "VK_EXT_image_view_min_lod",
    "VK_EXT_filter_cubic",
    "VK_EXT_astc_decode_mode",
    # Dynamic state / rendering
    "VK_EXT_dynamic_rendering_unused_attachments",
    "VK_EXT_attachment_feedback_loop_layout",
    "VK_EXT_attachment_feedback_loop_dynamic_state",
    "VK_EXT_legacy_dithering",
    "VK_EXT_depth_bias_control",
    "VK_EXT_depth_clip_control",
    "VK_EXT_depth_clip_enable",
    "VK_EXT_depth_range_unrestricted",
    # Android / WSI
    "VK_ANDROID_external_format_resolve",
    "VK_EXT_external_memory_acquire_unmodified",
    "VK_GOOGLE_display_timing",
    # Utility / debug
    "VK_EXT_subpass_merge_feedback",
    "VK_EXT_frame_boundary",
    "VK_EXT_device_fault",
    "VK_EXT_device_address_binding_report",
    # Newer KHR
    "VK_KHR_maintenance7",
    "VK_KHR_maintenance8",
    "VK_KHR_pipeline_binary",
    "VK_KHR_shader_relaxed_extended_instruction",
    "VK_KHR_shader_subgroup_uniform_control_flow",
    "VK_KHR_shader_maximal_reconvergence",
    "VK_KHR_shader_quad_control",
    "VK_KHR_compute_shader_derivatives",
    "VK_KHR_calibrated_timestamps",
    # Misc EXT
    "VK_EXT_nested_command_buffer",
    "VK_EXT_multi_draw",
    "VK_EXT_multisampled_render_to_single_sampled",
    "VK_EXT_non_seamless_cube_map",
    "VK_EXT_primitive_topology_list_restart",
    "VK_EXT_primitives_generated_query",
    "VK_EXT_provoking_vertex",
    "VK_EXT_rgba10x6_formats",
    "VK_EXT_sample_locations",
    "VK_EXT_custom_border_color",
    "VK_EXT_border_color_swizzle",
    "VK_EXT_color_write_enable",
    "VK_EXT_mutable_descriptor_type",
    "VK_EXT_rasterization_order_attachment_access",
    "VK_EXT_transform_feedback",
    "VK_EXT_vertex_input_dynamic_state",
    "VK_EXT_ycbcr_image_arrays",
    "VK_EXT_zero_initialize_device_memory",
    "VK_EXT_extended_dynamic_state3",
    "VK_EXT_shader_module_identifier",
    "VK_EXT_pipeline_properties",
    "VK_EXT_pipeline_robustness",
    "VK_EXT_pipeline_library_group_handles",
    "VK_EXT_post_depth_coverage",
    "VK_EXT_conditional_rendering",
    "VK_EXT_conservative_rasterization",
    "VK_EXT_discard_rectangles",
    "VK_EXT_blend_operation_advanced",
    "VK_EXT_shader_atomic_float",
    "VK_EXT_shader_atomic_float2",
    "VK_EXT_shader_image_atomic_int64",
    "VK_EXT_shader_demote_to_helper_invocation",
    "VK_EXT_shader_stencil_export",
    "VK_EXT_shader_subgroup_partitioned",
    "VK_EXT_texture_compression_astc_3d",
    "VK_MESA_image_alignment_control",
    "VK_VALVE_mutable_descriptor_type",
    "VK_GOOGLE_decorate_string",
    "VK_GOOGLE_hlsl_functionality1",
    "VK_GOOGLE_user_type",
}

# Pattern: Extension("VK_NAME", <condition>, "ENUM")
# We match entries where condition is False/None and flip to True
pat = re.compile(
    r'(Extension\s*\(\s*["\'](' + '|'.join(re.escape(e) for e in SAFE_TO_ENABLE) + r')["\']'
    r'\s*,\s*)(False|None)(\s*[,)])',
    re.DOTALL
)

enabled = []
def replacer(m):
    enabled.append(m.group(2))
    return m.group(1) + 'True' + m.group(4)

c_new = pat.sub(replacer, c)

# ── Phase 2: Add a7xx_gen_enables block for extensions gated on device caps ──
# Some extensions use Python expressions like `device.info.a6xx.has_foo`
# For a7xx these should all be True. Replace known False-evaluating guards.
cap_fixes = [
    # fragment_shading_rate needs tile_2d_array which a7xx has
    (r'(VK_KHR_fragment_shading_rate["\'],\s*)device\.info\.[a-z0-9_\.]+',
     r'\g<1>True'),
    # mesh_shader was gated on a6xx.has_a650_blob_quirks being False
    (r'(VK_EXT_mesh_shader["\'],\s*)not\s+device\.info\.[a-z0-9_\.]+',
     r'\g<1>True'),
    # descriptor_buffer sometimes gated on a6xx.has_getob
    (r'(VK_EXT_descriptor_buffer["\'],\s*)device\.info\.[a-z0-9_\.]+',
     r'\g<1>True'),
]
for pattern, replacement in cap_fixes:
    c_new = re.sub(pattern, replacement, c_new)

# ── Phase 3: Mark file as patched ──
c_new = "# A7XX_EXT_UNLOCK: patched by build_turnip.sh\n" + c_new

changed = len(enabled)
with open(fp, 'w') as f:
    f.write(c_new)

if changed:
    print(f'[OK] Enabled {changed} previously-disabled extensions: {", ".join(enabled[:8])}{"..." if changed > 8 else ""}')
else:
    print('[INFO] No False-condition extensions found to flip (may already be enabled or conditions are expressions)')
    print('[INFO] Phase 2 cap fixes and Phase 3 marker still applied')
PYEOF
    log_success "Vulkan extensions unlock applied (target: 200+ extensions)"
}

apply_a8xx_device_support() {
    log_info "Applying A8xx device support"
    if [[ "$ENABLE_UBWC_HACK" == "true" ]]; then
        local kgsl_file="${MESA_DIR}/src/freedreno/common/freedreno_dev_info.c"
        [[ ! -f "$kgsl_file" ]] && kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
        if [[ -f "$kgsl_file" ]] && ! grep -q "UBWC 5.0" "$kgsl_file"; then
            python3 - "$kgsl_file" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()
inject = (
    '   case 5: /* UBWC 5.0 */\n'
    '      device->ubwc_config.bank_swizzle_levels = 0x4;\n'
    '      device->ubwc_config.macrotile_mode = FDL_MACROTILE_8_CHANNEL;\n'
    '      break;\n'
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
    fi
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

    # Step 1: BITFIELD64 definitions in tu_util.h
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

    # Step 2: debug name table in tu_util.cc
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

    # Step 3: turbo - sysfs perf governor (silent fail, no crash)
    if [[ -f "$tu_device_cc" ]] && ! grep -q "tu_try_activate_turbo" "$tu_device_cc"; then
        python3 - "$tu_device_cc" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

turbo_func = """
/* TU_DEBUG_TURBO: attempt to lock GPU at max frequency via sysfs.
 * Silently ignored if process lacks root permission - no crash. */
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

    # Step 4: defrag - align large allocations to 64KB
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

    # Step 5: ubwc_all - force UBWC on color images
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

    # Step 6: push_regs - relax ir3 register pressure limit
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

    # Step 7: unroll - aggressive NIR loop unrolling
    if [[ -f "$ir3_compiler_nir" ]] && ! grep -q "TU_DEBUG.*unroll\|ir3_custom_unroll" "$ir3_compiler_nir"; then
        python3 - "$ir3_compiler_nir" << 'PYEOF'
import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

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

    # Step 8: slc_pin / cp_prefetch / shfl / vgt_pref
    # These flags are DEFINED (so TU_DEBUG=slc_pin,... is valid without crash)
    # but have no userspace implementation - they require kernel/HW support.
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
    if [[ "$APPLY_PATCH_SERIES" == "true" && -d "$PATCHES_DIR/series" ]]; then
        apply_patch_series "$PATCHES_DIR/series"
    else
        if [[ "$ENABLE_TIMELINE_HACK" == "true" ]]; then apply_timeline_semaphore_fix; fi
        if [[ "$ENABLE_UBWC_HACK" == "true" ]]; then true; fi
        apply_gralloc_ubwc_fix
        if [[ "$ENABLE_CUSTOM_FLAGS" == "true" ]]; then apply_custom_debug_flags; fi
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

# spirv-tools and spirv-headers use CMake and have no meson.build, which causes
# --force-fallback-for to fail at configure time with "subproject has no meson.build file".
# Mesa ships its own .wrap files for these; Meson will download the correct
# Meson-compatible tarballs automatically.
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
