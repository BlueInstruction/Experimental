#!/usr/bin/env python3

import re
import os
import glob
import sys
import argparse
import logging
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock
from typing import List, Tuple, Dict, Any

logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

_lock = Lock()
_applied = 0
_skipped = 0
_errors: List[str] = []
_patch_details: List[Dict[str, Any]] = []


SHADER_PATCHES: List[Tuple[str, str]] = [
    (r'(data->HighestShaderModel\s*=\s*)[^;]+;', r'\1D3D_SHADER_MODEL_6_6;'),
    (r'(info\.HighestShaderModel\s*=\s*)[^;]+;', r'\1D3D_SHADER_MODEL_6_6;'),
    (r'(MaxSupportedFeatureLevel\s*=\s*)[^;]+;', r'\1D3D_FEATURE_LEVEL_12_2;'),
]

RT_PATCHES: List[Tuple[str, str]] = [
    (r'(options5\.RaytracingTier\s*=\s*)[^;]+;', r'\1D3D12_RAYTRACING_TIER_1_0;'),
]

MESH_PATCHES: List[Tuple[str, str]] = [
    (r'(options7\.MeshShaderTier\s*=\s*)[^;]+;', r'\1D3D12_MESH_SHADER_TIER_1;'),
]

VRS_PATCHES: List[Tuple[str, str]] = [
    (r'(options6\.VariableShadingRateTier\s*=\s*)[^;]+;', r'\1D3D12_VARIABLE_SHADING_RATE_TIER_2;'),
]

WAVE_PATCHES: List[Tuple[str, str]] = [
    (r'(options1\.WaveOps\s*=\s*)[^;]+;', r'\1TRUE;'),
    (r'(options1\.WaveLaneCountMin\s*=\s*)[^;]+;', r'\g<1>32;'),
    (r'(options1\.WaveLaneCountMax\s*=\s*)[^;]+;', r'\g<1>64;'),
]

RESOURCE_PATCHES: List[Tuple[str, str]] = [
    (r'(options\.ResourceBindingTier\s*=\s*)[^;]+;', r'\1D3D12_RESOURCE_BINDING_TIER_3;'),
    (r'(options\.TiledResourcesTier\s*=\s*)[^;]+;', r'\1D3D12_TILED_RESOURCES_TIER_3;'),
    (r'(options\.ResourceHeapTier\s*=\s*)[^;]+;', r'\1D3D12_RESOURCE_HEAP_TIER_2;'),
]

SHADER_OPS_PATCHES: List[Tuple[str, str]] = [
    (r'(options\.DoublePrecisionFloatShaderOps\s*=\s*)[^;]+;', r'\1TRUE;'),
    (r'(options1\.Int64ShaderOps\s*=\s*)[^;]+;', r'\1TRUE;'),
    (r'(options4\.Native16BitShaderOpsSupported\s*=\s*)[^;]+;', r'\1TRUE;'),
]

ENHANCED_PATCHES: List[Tuple[str, str]] = [
    (r'(options12\.EnhancedBarriersSupported\s*=\s*)[^;]+;', r'\1TRUE;'),
    (r'(options2\.DepthBoundsTestSupported\s*=\s*)[^;]+;', r'\1TRUE;'),
]

CPU_X86_64_PATCHES: List[Tuple[str, str]] = [
    (r'(vkd3d_cpu_supports_sse4_2\s*\(\s*\))', 'true'),
    (r'(vkd3d_cpu_supports_avx\s*\(\s*\))', 'true'),
    (r'(vkd3d_cpu_supports_avx2\s*\(\s*\))', 'true'),
    (r'(vkd3d_cpu_supports_fma\s*\(\s*\))', 'true'),
    (r'#define\s+VKD3D_ENABLE_AVX\s+\d+', '#define VKD3D_ENABLE_AVX 1'),
    (r'#define\s+VKD3D_ENABLE_AVX2\s+\d+', '#define VKD3D_ENABLE_AVX2 1'),
    (r'#define\s+VKD3D_ENABLE_FMA\s+\d+', '#define VKD3D_ENABLE_FMA 1'),
    (r'#define\s+VKD3D_ENABLE_SSE4_2\s+\d+', '#define VKD3D_ENABLE_SSE4_2 1'),
]

CPU_ARM64EC_PATCHES: List[Tuple[str, str]] = [
    (r'#define\s+VKD3D_ENABLE_AVX\s+\d+', '#define VKD3D_ENABLE_AVX 0'),
    (r'#define\s+VKD3D_ENABLE_AVX2\s+\d+', '#define VKD3D_ENABLE_AVX2 0'),
    (r'#define\s+VKD3D_ENABLE_FMA\s+\d+', '#define VKD3D_ENABLE_FMA 0'),
    (r'#define\s+VKD3D_ENABLE_SSE4_2\s+\d+', '#define VKD3D_ENABLE_SSE4_2 0'),
    (r'#define\s+VKD3D_ENABLE_SSE\s+\d+', '#define VKD3D_ENABLE_SSE 0'),
    (r'(vkd3d_cpu_supports_sse4_2\s*\(\s*\))', 'false'),
    (r'(vkd3d_cpu_supports_avx\s*\(\s*\))', 'false'),
    (r'(vkd3d_cpu_supports_avx2\s*\(\s*\))', 'false'),
    (r'(vkd3d_cpu_supports_fma\s*\(\s*\))', 'false'),
]

PERF_PATCHES: List[Tuple[str, str]] = [
    (r'#define\s+VKD3D_DEBUG\s+1', '#define VKD3D_DEBUG 0'),
    (r'#define\s+VKD3D_PROFILING\s+1', '#define VKD3D_PROFILING 0'),
]


def patch_file(path: str, patches: List[Tuple[str, str]], dry_run: bool = False) -> Tuple[int, int, List[str], List[Dict[str, Any]]]:
    local_applied = 0
    local_skipped = 0
    local_errors: List[str] = []
    local_details: List[Dict[str, Any]] = []

    if not os.path.exists(path):
        return local_applied, local_skipped, local_errors, local_details

    try:
        with open(path, "r", encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        local_errors.append(f"read error {path}: {e}")
        return local_applied, local_skipped, local_errors, local_details

    original = content
    file_changes: List[Dict[str, Any]] = []

    for pattern, replacement in patches:
        try:
            matches = len(re.findall(pattern, content, re.MULTILINE))
            if matches > 0:
                match = re.search(pattern, original, re.MULTILINE)
                example = match.group(0) if match else 'n/a'
                if not dry_run:
                    content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
                local_applied += matches
                file_changes.append({
                    'pattern': pattern[:50] + "..." if len(pattern) > 50 else pattern,
                    'matches': matches,
                    'example': example[:80] if len(example) > 80 else example
                })
            else:
                local_skipped += 1
        except re.error as e:
            local_errors.append(f"regex error in {path}: {e}")

    if content != original and not dry_run:
        try:
            with open(path, "w", encoding='utf-8') as f:
                f.write(content)
        except Exception as e:
            local_errors.append(f"write error {path}: {e}")

    if file_changes:
        local_details.append({'file': os.path.basename(path), 'path': path, 'changes': file_changes})

    return local_applied, local_skipped, local_errors, local_details


def generate_report(output_path: str, arch: str, dry_run: bool,
                    applied: int, skipped: int, errors: List[str],
                    details: List[Dict[str, Any]]) -> None:
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(f"vkd3d-proton patch report\n")
        f.write(f"generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"architecture: {arch}\n")
        f.write(f"mode: {'dry-run' if dry_run else 'applied'}\n\n")
        f.write(f"summary:\n")
        f.write(f"  applied: {applied}\n")
        f.write(f"  skipped: {skipped}\n")
        f.write(f"  errors: {len(errors)}\n\n")

        if arch == "x86_64":
            f.write(f"configuration:\n")
            f.write(f"  sse4.2: enabled\n")
            f.write(f"  avx/avx2/fma: enabled\n\n")
        else:
            f.write(f"configuration:\n")
            f.write(f"  x86 simd: disabled\n")
            f.write(f"  arm64ec: native\n\n")

        if details:
            f.write("changes:\n")
            for detail in details:
                f.write(f"\n  {detail['file']}:\n")
                for change in detail['changes']:
                    f.write(f"    - {change['matches']} match(es): {change['pattern']}\n")

        if errors:
            f.write("\nerrors:\n")
            for e in errors:
                f.write(f"  - {e}\n")

    logger.info(f"report saved: {output_path}")


def apply_patches(src_dir: str, arch: str, dry_run: bool = False,
                  report: bool = False, max_workers: int = None) -> int:
    global _applied, _skipped, _errors, _patch_details

    if max_workers is None:
        max_workers = os.cpu_count() or 4

    _applied, _skipped, _errors, _patch_details = 0, 0, [], []

    logger.info(f"vkd3d-proton patcher")
    logger.info(f"source: {src_dir} | arch: {arch} | mode: {'dry-run' if dry_run else 'apply'}")

    device_patches = (
        SHADER_PATCHES + RT_PATCHES + MESH_PATCHES + VRS_PATCHES +
        WAVE_PATCHES + RESOURCE_PATCHES + SHADER_OPS_PATCHES + ENHANCED_PATCHES
    )

    device_files = glob.glob(os.path.join(src_dir, "libs/vkd3d/*.[ch]"))
    if not device_files:
        device_files = glob.glob(os.path.join(src_dir, "src/**/*.[ch]"), recursive=True)

    all_files = [f for f in glob.glob(os.path.join(src_dir, "**/*.[ch]"), recursive=True) if 'tests' not in f]

    logger.info(f"files: {len(device_files)} device, {len(all_files)} total")

    tasks = []

    for f in device_files:
        tasks.append((f, device_patches))

    for f in all_files:
        tasks.append((f, PERF_PATCHES))

    if arch == "x86_64":
        logger.info("applying x86_64 optimizations (sse4.2/avx/avx2/fma enabled)")
        for f in all_files:
            tasks.append((f, CPU_X86_64_PATCHES))
    else:
        logger.info("applying arm64ec configuration (x86 simd disabled)")
        for f in all_files:
            tasks.append((f, CPU_ARM64EC_PATCHES))

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(patch_file, path, patches, dry_run) for path, patches in tasks]
        for future in as_completed(futures):
            a, s, e, d = future.result()
            with _lock:
                _applied += a
                _skipped += s
                _errors.extend(e)
                _patch_details.extend(d)

    logger.info(f"results: {_applied} applied, {_skipped} skipped, {len(_errors)} errors")

    if report:
        generate_report("patch-report.txt", arch, dry_run, _applied, _skipped, _errors, _patch_details)

    return 1 if _errors else 0


def main() -> None:
    parser = argparse.ArgumentParser(description="vkd3d-proton patcher")
    parser.add_argument("src_dir", help="path to vkd3d-proton source")
    parser.add_argument("--arch", choices=["x86_64", "arm64ec"], default="x86_64")
    parser.add_argument("--dry-run", action="store_true", help="preview without applying")
    parser.add_argument("--report", action="store_true", help="generate report")
    parser.add_argument("--max-workers", type=int, default=None)

    args = parser.parse_args()

    if not os.path.isdir(args.src_dir):
        logger.error(f"directory not found: {args.src_dir}")
        sys.exit(1)

    sys.exit(apply_patches(args.src_dir, args.arch, args.dry_run, args.report, args.max_workers))


if __name__ == "__main__":
    main()
