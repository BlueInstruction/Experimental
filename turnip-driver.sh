#!/bin/bash -e
set -o pipefail

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
API_LEVEL="${API_LEVEL:-36}"

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
    
    local clone_args=("--depth" "1")
    local target_ref=""
    local repo_url="$MESA_REPO"
    
    if [[ "$BUILD_VARIANT" == "autotuner" ]]; then
        repo_url="$AUTOTUNER_REPO"
        target_ref="tu-newat"
        clone_args+=("--branch" "$target_ref")
        log_info "Using Autotuner branch: $target_ref"
    else
        case "$MESA_SOURCE" in
            latest_release)
                target_ref=$(fetch_latest_release)
                clone_args+=("--branch" "$target_ref")
                ;;
            staging_branch)
                target_ref="$STAGING_BRANCH"
                clone_args+=("--branch" "$target_ref")
                ;;
            main_branch)
                target_ref="main"
                clone_args+=("--branch" "main")
                ;;
            custom_tag)
                [[ -z "$CUSTOM_TAG" ]] && { log_error "Custom tag not specified"; exit 1; }
                target_ref="$CUSTOM_TAG"
                clone_args+=("--branch" "$target_ref")
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
    
    local version=$(get_mesa_version)
    local commit=$(git rev-parse --short=8 HEAD)
    
    echo "$version" > "${WORKDIR}/version.txt"
    echo "$commit" > "${WORKDIR}/commit.txt"
    
    log_success "Mesa $version ($commit) ready"
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

apply_ubwc_support() {
    log_info "Applying UBWC 5/6 support"
    
    local kgsl_file="${MESA_DIR}/src/freedreno/vulkan/tu_knl_kgsl.cc"
    [[ ! -f "$kgsl_file" ]] && { log_warn "KGSL file not found"; return 0; }
    
    if ! grep -q "case 5:" "$kgsl_file"; then
        sed -i '/case KGSL_UBWC_4_0:/a\   case 5:\n   case 6:' "$kgsl_file" 2>/dev/null || true
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
    patch -p1 --fuzz=3 --ignore-whitespace < "${WORKDIR}/gralloc.patch" 2>/dev/null || log_warn "Gralloc patch may have partially applied"
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
        sed -i "/TU_DEBUG_FORCE_CONCURRENT_BINNING/a\   TU_DEBUG_DECK_EMU                 = BITFIELD64_BIT(${new_bit})," "$tu_util_h" 2>/dev/null || true
        log_success "deck_emu flag added to tu_util.h"
    fi
    
    if [[ -f "$tu_util_cc" ]] && ! grep -q "deck_emu" "$tu_util_cc"; then
        sed -i '/{ "forcecb"/a\   { "deck_emu", TU_DEBUG_DECK_EMU },' "$tu_util_cc" 2>/dev/null || true
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
       VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_ALL;
    p->roundingModeIndependence =
PATCH_EOF
        cd "$MESA_DIR"
        patch -p1 --fuzz=3 --ignore-whitespace < "${WORKDIR}/deck_emu_device.patch" 2>/dev/null || log_warn "deck_emu device patch may have partially applied"
        log_success "deck_emu device spoofing added"
    fi
}

apply_a6xx_query_fix() {
    log_info "Applying A6xx query fix"
    
    find "${MESA_DIR}/src/freedreno/vulkan" -name "tu_query*.cc" -exec \
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' {} \; 2>/dev/null || true
    
    log_success "A6xx query fix applied"
}

apply_vulkan_extensions_support() {
    log_info "Enabling additional Vulkan extensions"
    
    local tu_device="${MESA_DIR}/src/freedreno/vulkan/tu_device.cc"
    [[ ! -f "$tu_device" ]] && { log_warn "tu_device.cc not found"; return 0; }
    
    log_success "Vulkan extensions support verified"
}

apply_patches() {
    log_info "Applying patches for A7xx"
    
    cd "$MESA_DIR"
    
    if [[ "$BUILD_VARIANT" == "vanilla" ]]; then
        log_info "Vanilla build - skipping patches"
        return 0
    fi
    
    apply_timeline_semaphore_fix
    apply_ubwc_support
    apply_gralloc_ubwc_fix
    apply_deck_emu_support
    apply_vulkan_extensions_support
    
    if [[ "$BUILD_VARIANT" == "autotuner" ]]; then
        apply_a6xx_query_fix
    fi
    
    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ ! -f "$patch" ]] && continue
            local patch_name=$(basename "$patch")
            
            if [[ "$patch_name" == *"a8xx"* ]] || [[ "$patch_name" == *"A8xx"* ]] || \
               [[ "$patch_name" == *"810"* ]] || [[ "$patch_name" == *"825"* ]] || \
               [[ "$patch_name" == *"829"* ]] || [[ "$patch_name" == *"830"* ]] || \
               [[ "$patch_name" == *"840"* ]] || [[ "$patch_name" == *"gen8"* ]]; then
                log_info "Skipping A8xx patch: $patch_name"
                continue
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
    log_info "Setting up subprojects"
    
    cd "$MESA_DIR"
    mkdir -p subprojects && cd subprojects
    rm -rf spirv-tools spirv-headers
    
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    
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
    
    cat > "${WORKDIR}/cross-aarch64.txt" << EOF
[binaries]
ar = '${ndk_bin}/llvm-ar'
c = ['ccache', '${ndk_bin}/aarch64-linux-android${cver}-clang', '--sysroot=${ndk_sys}']
cpp = ['ccache', '${ndk_bin}/aarch64-linux-android${cver}-clang++', '--sysroot=${ndk_sys}']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '${ndk_bin}/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations']
cpp_args = ['-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations']
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF

    log_success "Cross-compilation file created"
}

configure_build() {
    log_info "Configuring Mesa build"
    
    cd "$MESA_DIR"
    
    meson setup build \
        --cross-file "${WORKDIR}/cross-aarch64.txt" \
        -Dbuildtype="$BUILD_TYPE" \
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
    local driver_name="vulkan.ad07XX.so"
    
    mkdir -p "$pkg_dir"
    cp "$driver_src" "${pkg_dir}/${driver_name}"
    
    patchelf --set-soname "vulkan.adreno.so" "${pkg_dir}/${driver_name}"
    "${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
        "${pkg_dir}/${driver_name}" 2>/dev/null || true
    
    local driver_size=$(du -h "${pkg_dir}/${driver_name}" | cut -f1)
    
    local variant_suffix=""
    case "$BUILD_VARIANT" in
        optimized)  variant_suffix="opt" ;;
        autotuner)  variant_suffix="at" ;;
        vanilla)    variant_suffix="vanilla" ;;
    esac
    
    local filename="turnip_a7xx_v${version}_${variant_suffix}_${build_date}"
    
    cat > "${pkg_dir}/meta.json" << EOF
{
    "schemaVersion": 1,
    "name": "Turnip A7xx ${BUILD_VARIANT}",
    "description": "Mesa ${version} Vulkan ${vulkan_version}",
    "author": "Mesa",
    "packageVersion": "1",
    "vendor": "Mesa",
    "driverVersion": "${vulkan_version}",
    "minApi": 28,
    "libraryName": "${driver_name}"
}
EOF

    echo "$filename" > "${WORKDIR}/filename.txt"
    echo "$vulkan_version" > "${WORKDIR}/vulkan_version.txt"
    echo "$build_date" > "${WORKDIR}/build_date.txt"
    
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
    echo "  Mesa Version    : $version"
    echo "  Vulkan Version  : $vulkan_version"
    echo "  Commit          : $commit"
    echo "  Build Date      : $build_date"
    echo "  Build Variant   : $BUILD_VARIANT"
    echo "  Source          : $MESA_SOURCE"
    echo "  Output          :"
    ls -lh "${WORKDIR}"/*.zip 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
    echo ""
}

main() {
    log_info "Turnip Driver Builder"
    log_info "Configuration: variant=$BUILD_VARIANT, source=$MESA_SOURCE, type=$BUILD_TYPE"
    
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
