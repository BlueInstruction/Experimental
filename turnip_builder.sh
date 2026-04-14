#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator patch"
workdir="$(pwd)/turnip_workdir"

ndkver="android-ndk-r28"
target_sdk="36"

base_repo="https://github.com/whitebelyash/mesa-tu8.git"
base_branch="gen8"

bad_commit="f95913e"

commit_hash=""
version_str=""

check_deps(){
    echo "Checking system dependencies ..."
    for dep in $deps; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo -e "$red Missing dependency binary: $dep$nocolor"
            missing=1
        else
            echo -e "$green Found: $dep$nocolor"
        fi
    done
    if [ "$missing" == "1" ]; then
        echo "Please install missing dependencies." && exit 1
    fi

    echo "Updating Meson via pip..."
    pip install meson mako --break-system-packages &> /dev/null || pip install meson mako &> /dev/null || true
}

prepare_ndk(){
    echo "Preparing NDK r28..."
    mkdir -p "$workdir"
    cd "$workdir"
    if [ ! -d "$ndkver" ]; then
        echo "Downloading Android NDK $ndkver..."
        curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
        echo "Extracting NDK..."
        unzip -q "${ndkver}-linux.zip" &> /dev/null
    fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

apply_patch_disable_branch_and_or(){
    echo "Applying patch: disable has_branch_and_or..."
    patch -p1 --no-backup-if-mismatch <<'PATCH'
diff --git a/src/freedreno/ir3/ir3_compiler.c b/src/freedreno/ir3/ir3_compiler.c
--- a/src/freedreno/ir3/ir3_compiler.c
+++ b/src/freedreno/ir3/ir3_compiler.c
@@ -218,7 +218,7 @@ ir3_compiler_create(struct fd_device *dev, const struct fd_dev_id *dev_id,
       compiler->load_inline_uniforms_via_preamble_ldgk = dev_info->a7xx.load_inline_uniforms_via_preamble_ldgk;
       compiler->num_predicates = 4;
       compiler->bitops_can_write_predicates = true;
-      compiler->has_branch_and_or = true;
+      compiler->has_branch_and_or = false;
    } else {
       compiler->max_const_pipeline = 512;
       compiler->max_const_geom = 512;
PATCH
    echo -e "${green}OK: disable has_branch_and_or${nocolor}"
}

apply_patch_disable_workgroup_memory(){
    echo "Applying patch: disable KHR_workgroup_memory_explicit_layout..."
    local f="src/freedreno/vulkan/tu_device.cc"
    sed -i 's/\.KHR_workgroup_memory_explicit_layout = true/.KHR_workgroup_memory_explicit_layout = false/' "$f"
    sed -i 's/features->workgroupMemoryExplicitLayout = true/features->workgroupMemoryExplicitLayout = false/g' "$f"
    sed -i 's/features->workgroupMemoryExplicitLayoutScalarBlockLayout = true/features->workgroupMemoryExplicitLayoutScalarBlockLayout = false/' "$f"
    sed -i 's/features->workgroupMemoryExplicitLayout8BitAccess = true/features->workgroupMemoryExplicitLayout8BitAccess = false/' "$f"
    sed -i 's/features->workgroupMemoryExplicitLayout16BitAccess = true/features->workgroupMemoryExplicitLayout16BitAccess = false/' "$f"
    echo -e "${green}OK: disable KHR_workgroup_memory_explicit_layout${nocolor}"
}

apply_patch_fix_a725_a730(){
    echo "Applying patch: fix a725/a730 compute_constlen_quirk..."
    patch -p1 --no-backup-if-mismatch <<'PATCH'
diff --git a/src/freedreno/common/freedreno_devices.py b/src/freedreno/common/freedreno_devices.py
--- a/src/freedreno/common/freedreno_devices.py
+++ b/src/freedreno/common/freedreno_devices.py
@@ -875,6 +875,7 @@ a7xx_gen1 = A7XXProps(
         fs_must_have_non_zero_constlen_quirk = True,
         enable_tp_ubwc_flag_hint = True,
         reading_shading_rate_requires_smask_quirk = True,
+        compute_constlen_quirk = True,
     )
PATCH
    echo -e "${green}OK: fix a725/a730${nocolor}"
}

apply_patch_force_sysmem(){
    echo "Applying patch: force sysmem rendering..."
    sed -i '/^use_sysmem_rendering(struct tu_cmd_buffer \*cmd,/{
        n
        /^{/a\   return true;\n
    }' src/freedreno/vulkan/tu_cmd_buffer.cc
    # Fallback: check if return true was inserted inside the target function specifically
    if ! sed -n '/use_sysmem_rendering/,/^}/p' src/freedreno/vulkan/tu_cmd_buffer.cc 2>/dev/null | grep -q 'return true;'; then
        sed -i '/use_sysmem_rendering.*autotune_result)/{n;s/^{$/{\n   return true;\n/}' \
            src/freedreno/vulkan/tu_cmd_buffer.cc
    fi
    echo -e "${green}OK: force sysmem${nocolor}"
}

apply_patch_disable_mesh_shader(){
    echo "Applying patch: disable EXT_mesh_shader..."
    python3 - <<'PYEOF'
import re

path = "src/freedreno/vulkan/tu_device.cc"
with open(path, "r") as f:
    content = f.read()

content = re.sub(r'(\.EXT_mesh_shader\s*=\s*)true', r'\1false', content)

for field in ["taskShader", "meshShader", "multiviewMeshShader",
              "primitiveFragmentShadingRateMeshShader", "meshShaderQueries"]:
    content = re.sub(r'(features->' + field + r'\s*=\s*)true', r'\1false', content)

with open(path, "w") as f:
    f.write(content)

print("EXT_mesh_shader disabled")
PYEOF
    echo -e "${green}OK: disable EXT_mesh_shader${nocolor}"
}

apply_patch_quest3(){
    echo "Applying patch: Quest 3 GPU support..."
    python3 - <<'PYEOF'
path = "src/freedreno/common/freedreno_devices.py"
with open(path, "r") as f:
    content = f.read()

old = '        GPUId(chip_id=0x43050B00, name="FD740"), # Quest 3\n        GPUId(chip_id=0xffff43050B00, name="FD740"),'
if old in content:
    content = content.replace(old, "")
    with open(path, "w") as f:
        f.write(content)

quest3_block = '''
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
            SP_CHICKEN_BITS = 0x10001400,
            UCHE_CLIENT_PF = 0x00000084,
            PC_MODE_CNTL = 0x0000003f,
            SP_DBG_ECO_CNTL = 0x10000000,
            RB_DBG_ECO_CNTL = 0x00000000,
            RB_DBG_ECO_CNTL_blit = 0x00000000,
            RB_UNKNOWN_8E01 = 0x0,
            VPC_DBG_ECO_CNTL = 0x02000000,
            UCHE_UNKNOWN_0E12 = 0x00000000,
            RB_UNKNOWN_8E06 = 0x02080000,
        ),
        raw_magic_regs = [
            [A6XXRegs.REG_A6XX_UCHE_CACHE_WAYS, 0x00040004],
            [A6XXRegs.REG_A6XX_TPL1_DBG_ECO_CNTL1, 0x00040724],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE08, 0x00000400],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE09, 0x00430800],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE0A, 0x00000000],
            [A6XXRegs.REG_A7XX_UCHE_UNKNOWN_0E10, 0x00000000],
            [A6XXRegs.REG_A7XX_UCHE_UNKNOWN_0E11, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE6C, 0x00000000],
            [A6XXRegs.REG_A6XX_PC_DBG_ECO_CNTL, 0x00100000],
            [A6XXRegs.REG_A7XX_PC_UNKNOWN_9E24, 0x21585600],
            [A6XXRegs.REG_A7XX_VFD_UNKNOWN_A600, 0x00008000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE06, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE6A, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE6B, 0x00000080],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AE73, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB02, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB01, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB22, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_B310, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8120, 0x09510840],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8121, 0x00000a62],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8009, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_800A, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_800B, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_800C, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE2,   0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE2+1, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE4,   0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE4+1, 0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE6,   0x00000000],
            [A6XXRegs.REG_A7XX_SP_UNKNOWN_0CE6+1, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_80A7, 0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_8E79,   0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_8899,   0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_88F5,   0x00000000],
            [A6XXRegs.REG_A7XX_RB_UNKNOWN_8C34,   0x00000000],
            [A6XXRegs.REG_A6XX_RB_UNKNOWN_88F4,   0x00000000],
            [A6XXRegs.REG_A7XX_HLSQ_UNKNOWN_A9AD, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_8008, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_80F4, 0x00000000],
            [A6XXRegs.REG_A7XX_GRAS_UNKNOWN_80F5, 0x00000000],
        ],
    ))

'''

marker = "# Values from blob v676.0"
with open(path, "r") as f:
    content = f.read()

if marker in content and quest3_block.strip() not in content:
    content = content.replace(marker, quest3_block + marker)
    with open(path, "w") as f:
        f.write(content)
    print("Quest3 block inserted")
else:
    print("Quest3 block already present or marker not found")
PYEOF
    echo -e "${green}OK: Quest 3 support${nocolor}"
}

prepare_source(){
    echo "Preparing Mesa source..."
    cd "$workdir"
    if [ -d mesa ]; then rm -rf mesa; fi

    echo -e "${green}Cloning Mesa (Branch: $base_branch)...${nocolor}"
    git clone --depth 100 --branch "$base_branch" "$base_repo" mesa
    cd mesa

    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    echo "Applying common syntax fixes..."
    perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py
    sed -i '/REG_A8XX_GRAS_UNKNOWN_/d' src/freedreno/common/freedreno_devices.py

    echo "Reverting bad commit ($bad_commit)..."
    if git revert --no-edit "$bad_commit" 2>/dev/null; then
        echo -e "${green}SUCCESS: Reverted $bad_commit${nocolor}"
    else
        echo -e "${red}Git revert failed, applying manual fix...${nocolor}"
        git revert --abort || true
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g'
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g'
    fi

    apply_patch_disable_branch_and_or
    apply_patch_disable_workgroup_memory
    apply_patch_fix_a725_a730
    apply_patch_force_sysmem
    apply_patch_disable_mesh_shader
    apply_patch_quest3

    echo "Cloning SPIRV dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd ..

    commit_hash=$(git rev-parse HEAD)
    version_str="Turnip-Gen8"
    cd "$workdir"
}

compile_mesa(){
    echo -e "${green}Compiling Mesa for SDK $target_sdk...${nocolor}"

    local source_dir="$workdir/mesa"
    local build_dir="$source_dir/build"
    local ndk_bin_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sysroot_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then compiler_ver="34"; fi
    echo "Using compiler: Clang $compiler_ver"

    local cross_file="$source_dir/android-aarch64-crossfile.txt"
    cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cd "$source_dir"

    export CFLAGS="-D__ANDROID__ -Wno-error"
    export CXXFLAGS="-D__ANDROID__ -Wno-error"

    meson setup "$build_dir" --cross-file "$cross_file" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$target_sdk \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Db_lto=true \
        -Dvulkan-beta=true \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers \
        2>&1 | tee "$workdir/meson_log"

    ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
    local source_dir="$workdir/mesa"
    local build_dir="$source_dir/build"
    local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp="$workdir/package_temp"

    if [ ! -f "$lib_path" ]; then
        echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
        exit 1
    fi

    rm -rf "$package_temp"
    mkdir -p "$package_temp"
    cp "$lib_path" "$package_temp/lib_temp.so"

    cd "$package_temp"
    patchelf --set-soname "vulkan.adreno.so" lib_temp.so
    mv lib_temp.so "vulkan.ad07XX.so"

    local short_hash=${commit_hash:0:7}
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip-Gen8-${short_hash}",
  "description": "Turnip Gen8. Commit $short_hash",
  "author": "Mesa",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    local zip_name="Turnip-Gen8-${short_hash}.zip"
    zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
    echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info(){
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local short_hash=${commit_hash:0:7}

    echo "Turnip-Gen8-${date_tag}-${short_hash}" > tag
    echo "Turnip Gen8 - ${date_tag}" > release
    echo "Build from mesa-tu8 branch gen8. Commit $short_hash." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
