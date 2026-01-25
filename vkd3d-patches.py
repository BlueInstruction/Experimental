#!/usr/bin/env python3

import re
import os
import glob
import sys
import argparse
import logging
from datetime import datetime
from concurrent.futures import threadpoolexecutor, as_completed
from threading import lock
from typing import list, tuple, dict, any

logging.basicconfig(level=logging.info, format='[%(levelname)s] %(message)s')
logger = logging.getlogger(__name__)

_lock = lock()
_applied = 0
_skipped = 0
_errors: list[str] = []
_patch_details: list[dict[str, any]] = []


shader_patches: list[tuple[str, str]] = [
    (r'(data->highestshadermodel\s*=\s*)[^;]+;', r'\1d3d_shader_model_6_6;'),
    (r'(info\.highestshadermodel\s*=\s*)[^;]+;', r'\1d3d_shader_model_6_6;'),
    (r'(maxsupportedfeaturelevel\s*=\s*)[^;]+;', r'\1d3d_feature_level_12_2;'),
]

rt_patches: list[tuple[str, str]] = [
    (r'(options5\.raytracingtier\s*=\s*)[^;]+;', r'\1d3d12_raytracing_tier_1_0;'),
]

mesh_patches: list[tuple[str, str]] = [
    (r'(options7\.meshshadertier\s*=\s*)[^;]+;', r'\1d3d12_mesh_shader_tier_1;'),
]

vrs_patches: list[tuple[str, str]] = [
    (r'(options6\.variableshadingratetier\s*=\s*)[^;]+;', r'\1d3d12_variable_shading_rate_tier_2;'),
]

wave_patches: list[tuple[str, str]] = [
    (r'(options1\.waveops\s*=\s*)[^;]+;', r'\1true;'),
    (r'(options1\.wavelanecountmin\s*=\s*)[^;]+;', r'\g<1>32;'),
    (r'(options1\.wavelanecountmax\s*=\s*)[^;]+;', r'\g<1>64;'),
]

resource_patches: list[tuple[str, str]] = [
    (r'(options\.resourcebindingtier\s*=\s*)[^;]+;', r'\1d3d12_resource_binding_tier_3;'),
    (r'(options\.tiledresourcestier\s*=\s*)[^;]+;', r'\1d3d12_tiled_resources_tier_3;'),
    (r'(options\.resourceheaptier\s*=\s*)[^;]+;', r'\1d3d12_resource_heap_tier_2;'),
]

shader_ops_patches: list[tuple[str, str]] = [
    (r'(options\.doubleprecisionfloatshaderops\s*=\s*)[^;]+;', r'\1true;'),
    (r'(options1\.int64shaderops\s*=\s*)[^;]+;', r'\1true;'),
    (r'(options4\.native16bitshaderopssupported\s*=\s*)[^;]+;', r'\1true;'),
]

enhanced_patches: list[tuple[str, str]] = [
    (r'(options12\.enhancedbarrierssupported\s*=\s*)[^;]+;', r'\1true;'),
    (r'(options2\.depthboundstestsupported\s*=\s*)[^;]+;', r'\1true;'),
]

cpu_x86_64_patches: list[tuple[str, str]] = [
    (r'(vkd3d_cpu_supports_sse4_2\s*\(\s*\))', 'true'),
    (r'(vkd3d_cpu_supports_avx\s*\(\s*\))', 'true'),
    (r'(vkd3d_cpu_supports_avx2\s*\(\s*\))', 'true'),
    (r'(vkd3d_cpu_supports_fma\s*\(\s*\))', 'true'),
    (r'#define\s+vkd3d_enable_avx\s+\d+', '#define vkd3d_enable_avx 1'),
    (r'#define\s+vkd3d_enable_avx2\s+\d+', '#define vkd3d_enable_avx2 1'),
    (r'#define\s+vkd3d_enable_fma\s+\d+', '#define vkd3d_enable_fma 1'),
    (r'#define\s+vkd3d_enable_sse4_2\s+\d+', '#define vkd3d_enable_sse4_2 1'),
]

cpu_arm64ec_patches: list[tuple[str, str]] = [
    (r'#define\s+vkd3d_enable_avx\s+\d+', '#define vkd3d_enable_avx 0'),
    (r'#define\s+vkd3d_enable_avx2\s+\d+', '#define vkd3d_enable_avx2 0'),
    (r'#define\s+vkd3d_enable_fma\s+\d+', '#define vkd3d_enable_fma 0'),
    (r'#define\s+vkd3d_enable_sse4_2\s+\d+', '#define vkd3d_enable_sse4_2 0'),
    (r'#define\s+vkd3d_enable_sse\s+\d+', '#define vkd3d_enable_sse 0'),
    (r'(vkd3d_cpu_supports_sse4_2\s*\(\s*\))', 'false'),
    (r'(vkd3d_cpu_supports_avx\s*\(\s*\))', 'false'),
    (r'(vkd3d_cpu_supports_avx2\s*\(\s*\))', 'false'),
    (r'(vkd3d_cpu_supports_fma\s*\(\s*\))', 'false'),
]

perf_patches: list[tuple[str, str]] = [
    (r'#define\s+vkd3d_debug\s+1', '#define vkd3d_debug 0'),
    (r'#define\s+vkd3d_profiling\s+1', '#define vkd3d_profiling 0'),
]


def patch_file(path: str, patches: list[tuple[str, str]], dry_run: bool = false) -> tuple[int, int, list[str], list[dict[str, any]]]:
    local_applied = 0
    local_skipped = 0
    local_errors: list[str] = []
    local_details: list[dict[str, any]] = []

    if not os.path.exists(path):
        return local_applied, local_skipped, local_errors, local_details

    try:
        with open(path, "r", encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except exception as e:
        local_errors.append(f"read error {path}: {e}")
        return local_applied, local_skipped, local_errors, local_details

    original = content
    file_changes: list[dict[str, any]] = []

    for pattern, replacement in patches:
        try:
            matches = len(re.findall(pattern, content, re.multiline))
            if matches > 0:
                match = re.search(pattern, original, re.multiline)
                example = match.group(0) if match else 'n/a'
                if not dry_run:
                    content = re.sub(pattern, replacement, content, flags=re.multiline)
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
        except exception as e:
            local_errors.append(f"write error {path}: {e}")

    if file_changes:
        local_details.append({'file': os.path.basename(path), 'path': path, 'changes': file_changes})

    return local_applied, local_skipped, local_errors, local_details


def generate_report(output_path: str, arch: str, dry_run: bool,
                    applied: int, skipped: int, errors: list[str],
                    details: list[dict[str, any]]) -> none:
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(f"vkd3d-proton patch report\n")
        f.write(f"generated: {datetime.now().strftime('%y-%m-%d %h:%m:%s')}\n")
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


def apply_patches(src_dir: str, arch: str, dry_run: bool = false,
                  report: bool = false, max_workers: int = none) -> int:
    global _applied, _skipped, _errors, _patch_details

    if max_workers is none:
        max_workers = os.cpu_count() or 4

    _applied, _skipped, _errors, _patch_details = 0, 0, [], []

    logger.info(f"vkd3d-proton patcher")
    logger.info(f"source: {src_dir} | arch: {arch} | mode: {'dry-run' if dry_run else 'apply'}")

    device_patches = (
        shader_patches + rt_patches + mesh_patches + vrs_patches +
        wave_patches + resource_patches + shader_ops_patches + enhanced_patches
    )

    device_files = glob.glob(os.path.join(src_dir, "libs/vkd3d/*.[ch]"))
    if not device_files:
        device_files = glob.glob(os.path.join(src_dir, "src/**/*.[ch]"), recursive=true)

    all_files = [f for f in glob.glob(os.path.join(src_dir, "**/*.[ch]"), recursive=true) if 'tests' not in f]

    logger.info(f"files: {len(device_files)} device, {len(all_files)} total")

    tasks = []

    for f in device_files:
        tasks.append((f, device_patches))

    for f in all_files:
        tasks.append((f, perf_patches))

    if arch == "x86_64":
        logger.info("applying x86_64 optimizations (sse4.2/avx/avx2/fma enabled)")
        for f in all_files:
            tasks.append((f, cpu_x86_64_patches))
    else:
        logger.info("applying arm64ec configuration (x86 simd disabled)")
        for f in all_files:
            tasks.append((f, cpu_arm64ec_patches))

    with threadpoolexecutor(max_workers=max_workers) as executor:
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


def main() -> none:
    parser = argparse.argumentparser(description="vkd3d-proton patcher")
    parser.add_argument("src_dir", help="path to vkd3d-proton source")
    parser.add_argument("--arch", choices=["x86_64", "arm64ec"], default="x86_64")
    parser.add_argument("--dry-run", action="store_true", help="preview without applying")
    parser.add_argument("--report", action="store_true", help="generate report")
    parser.add_argument("--max-workers", type=int, default=none)

    args = parser.parse_args()

    if not os.path.isdir(args.src_dir):
        logger.error(f"directory not found: {args.src_dir}")
        sys.exit(1)

    sys.exit(apply_patches(args.src_dir, args.arch, args.dry_run, args.report, args.max_workers))


if __name__ == "__main__":
    main()
