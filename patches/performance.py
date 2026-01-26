#!/usr/bin/env python3

import re
import os
import glob
import sys
import argparse
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock
from typing import List, Tuple, Dict, Any
from dataclasses import dataclass, field

logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)


@dataclass
class PatchResult:
    applied: int = 0
    skipped: int = 0
    errors: List[str] = field(default_factory=list)
    details: List[Dict[str, Any]] = field(default_factory=list)


CAPABILITY_PATCHES: List[Tuple[str, str, str]] = [
    (r'(data->HighestShaderModel\s*=\s*)[^;]+;', r'\1D3D_SHADER_MODEL_6_8;', 'shader_model_6_8'),
    (r'(info\.HighestShaderModel\s*=\s*)[^;]+;', r'\1D3D_SHADER_MODEL_6_8;', 'shader_model_6_8_info'),
    (r'(MaxSupportedFeatureLevel\s*=\s*)[^;]+;', r'\1D3D_FEATURE_LEVEL_12_2;', 'feature_level_12_2'),
    (r'(options1\.WaveOps\s*=\s*)[^;]+;', r'\1TRUE;', 'wave_ops'),
    (r'(options1\.WaveLaneCountMin\s*=\s*)[^;]+;', r'\g<1>32;', 'wave_lane_min'),
    (r'(options1\.WaveLaneCountMax\s*=\s*)[^;]+;', r'\g<1>128;', 'wave_lane_max'),
    (r'(options\.ResourceBindingTier\s*=\s*)[^;]+;', r'\1D3D12_RESOURCE_BINDING_TIER_3;', 'resource_binding_tier'),
    (r'(options\.TiledResourcesTier\s*=\s*)[^;]+;', r'\1D3D12_TILED_RESOURCES_TIER_4;', 'tiled_resources_tier'),
    (r'(options\.ResourceHeapTier\s*=\s*)[^;]+;', r'\1D3D12_RESOURCE_HEAP_TIER_2;', 'resource_heap_tier'),
    (r'(options\.DoublePrecisionFloatShaderOps\s*=\s*)[^;]+;', r'\1TRUE;', 'double_precision'),
    (r'(options1\.Int64ShaderOps\s*=\s*)[^;]+;', r'\1TRUE;', 'int64_ops'),
    (r'(options4\.Native16BitShaderOpsSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'native_16bit'),
    (r'(options12\.EnhancedBarriersSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'enhanced_barriers'),
    (r'(options2\.DepthBoundsTestSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'depth_bounds'),
    (r'(options7\.MeshShaderTier\s*=\s*)[^;]+;', r'\1D3D12_MESH_SHADER_TIER_1;', 'mesh_shader'),
    (r'(options6\.VariableShadingRateTier\s*=\s*)[^;]+;', r'\1D3D12_VARIABLE_SHADING_RATE_TIER_2;', 'vrs'),
    (r'(options6\.ShadingRateImageTileSize\s*=\s*)[^;]+;', r'\g<1>16;', 'vrs_tile_size'),
    (r'(options6\.BackgroundProcessingSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'background_processing'),
    (r'(options7\.SamplerFeedbackTier\s*=\s*)[^;]+;', r'\1D3D12_SAMPLER_FEEDBACK_TIER_1_0;', 'sampler_feedback'),
    (r'(options8\.UnalignedBlockTexturesSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'unaligned_block_textures'),
    (r'(options9\.MeshShaderPipelineStatsSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'mesh_shader_pipeline_stats'),
    (r'(options9\.MeshShaderSupportsFullRangeRenderTargetArrayIndex\s*=\s*)[^;]+;', r'\1TRUE;', 'mesh_shader_full_range_rt'),
    (r'(options9\.AtomicInt64OnTypedResourceSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'atomic_int64_typed'),
    (r'(options9\.AtomicInt64OnGroupSharedSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'atomic_int64_groupshared'),
    (r'(options9\.DerivativesInMeshAndAmplificationShadersSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'derivatives_mesh_amp'),
    (r'(options9\.WaveMMATier\s*=\s*)[^;]+;', r'\1D3D12_WAVE_MMA_TIER_1_0;', 'wave_mma'),
    (r'(options10\.VariableRateShadingSumCombinerSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'vrs_sum_combiner'),
    (r'(options10\.MeshShaderPerPrimitiveShadingRateSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'mesh_shader_per_primitive_vrs'),
    (r'(options11\.AtomicInt64OnDescriptorHeapResourceSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'atomic_int64_descriptor_heap'),
    (r'(options12\.MSPrimitivesPipelineStatisticIncludesCulledPrimitives\s*=\s*)[^;]+;', r'\1D3D12_TRI_STATE_TRUE;', 'ms_primitives_culled'),
    (r'(options13\.UnrestrictedBufferTextureCopyPitchSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'unrestricted_buffer_texture_copy'),
    (r'(options13\.UnrestrictedVertexElementAlignmentSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'unrestricted_vertex_alignment'),
    (r'(options13\.InvertedViewportHeightFlipsYSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'inverted_viewport_height'),
    (r'(options13\.InvertedViewportDepthFlipsZSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'inverted_viewport_depth'),
    (r'(options13\.TextureCopyBetweenDimensionsSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'texture_copy_between_dimensions'),
    (r'(options13\.AlphaBlendFactorSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'alpha_blend_factor'),
    (r'(options14\.AdvancedTextureOpsSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'advanced_texture_ops'),
    (r'(options14\.WriteableMSAATexturesSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'writeable_msaa_textures'),
    (r'(options14\.IndependentFrontAndBackStencilRefMaskSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'independent_stencil_ref_mask'),
    (r'(options15\.TriangleFanSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'triangle_fan'),
    (r'(options15\.DynamicIndexBufferStripCutSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'dynamic_index_buffer_strip_cut'),
    (r'(options16\.GPUUploadHeapSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'gpu_upload_heap'),
    (r'(options17\.NonNormalizedCoordinateSamplersSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'non_normalized_samplers'),
    (r'(options18\.RenderPassesValid\s*=\s*)[^;]+;', r'\1TRUE;', 'render_passes_valid'),
    (r'(options19\.MismatchingOutputDimensionsSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'mismatching_output_dimensions'),
    (r'(options19\.SupportedSampleCountsWithNoOutputs\s*=\s*)[^;]+;', r'\g<1>0x1F;', 'sample_counts_no_outputs'),
    (r'(options19\.PointSamplingAddressesNeverRoundUp\s*=\s*)[^;]+;', r'\1TRUE;', 'point_sampling_never_round_up'),
    (r'(options19\.RasterizerDesc2Supported\s*=\s*)[^;]+;', r'\1TRUE;', 'rasterizer_desc2'),
    (r'(options19\.NarrowQuadrilateralLinesSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'narrow_quadrilateral_lines'),
    (r'(options19\.AnisoFilterWithPointMipSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'aniso_filter_point_mip'),
    (r'(options19\.MaxSamplerDescriptorHeapSize\s*=\s*)[^;]+;', r'\g<1>4096;', 'max_sampler_descriptor_heap'),
    (r'(options19\.MaxSamplerDescriptorHeapSizeWithStaticSamplers\s*=\s*)[^;]+;', r'\g<1>4096;', 'max_sampler_descriptor_heap_static'),
    (r'(options19\.MaxViewDescriptorHeapSize\s*=\s*)[^;]+;', r'\g<1>1000000;', 'max_view_descriptor_heap'),
    (r'(options20\.ComputeOnlyWriteWatchSupported\s*=\s*)[^;]+;', r'\1TRUE;', 'compute_only_write_watch'),
    (r'(options21\.ExecuteIndirectTier\s*=\s*)[^;]+;', r'\1D3D12_EXECUTE_INDIRECT_TIER_1_1;', 'execute_indirect_tier'),
    (r'(options21\.WorkGraphsTier\s*=\s*)[^;]+;', r'\1D3D12_WORK_GRAPHS_TIER_1_0;', 'work_graphs_tier'),
]

DESCRIPTOR_CACHE_PATCHES: List[Tuple[str, str, str]] = [
    (r'(struct d3d12_descriptor_heap\s*\{[^}]*)(VkDescriptorSet\s+vk_descriptor_sets;)',
     r'\1\2\n    uint64_t last_descriptor_hash;\n    bool descriptor_cache_valid;',
     'descriptor_heap_cache_fields'),
]

COMMAND_BATCH_PATCHES: List[Tuple[str, str, str]] = [
    (r'(struct d3d12_command_queue\s*\{[^}]*)(VkQueue\s+vk_queue;)',
     r'\1\2\n    uint32_t pending_submits;\n    uint32_t submit_threshold;',
     'command_queue_batch_fields'),
]

BARRIER_OPT_PATCHES: List[Tuple[str, str, str]] = [
    (r'(struct d3d12_command_list\s*\{[^}]*)(VkCommandBuffer\s+vk_command_buffer;)',
     r'\1\2\n    struct { uint32_t pending_barriers; VkPipelineStageFlags2 last_dst_stage; } barrier_state;',
     'command_list_barrier_state'),
]

PIPELINE_CACHE_PATCHES: List[Tuple[str, str, str]] = [
    (r'(struct d3d12_device\s*\{[^}]*)(VkDevice\s+vk_device;)',
     r'\1\2\n    struct { uint64_t *hashes; VkPipeline *pipelines; size_t count; size_t capacity; pthread_mutex_t lock; } pipeline_cache;',
     'device_pipeline_cache'),
]

CPU_X86_64_PATCHES: List[Tuple[str, str, str]] = [
    (r'(vkd3d_cpu_supports_sse4_2\s*\(\s*\))', 'true', 'force_sse4_2'),
    (r'(vkd3d_cpu_supports_avx\s*\(\s*\))', 'true', 'force_avx'),
    (r'(vkd3d_cpu_supports_avx2\s*\(\s*\))', 'true', 'force_avx2'),
    (r'(vkd3d_cpu_supports_fma\s*\(\s*\))', 'true', 'force_fma'),
    (r'(vkd3d_cpu_supports_avx512\s*\(\s*\))', 'true', 'force_avx512'),
    (r'#define\s+VKD3D_ENABLE_AVX\s+\d+', '#define VKD3D_ENABLE_AVX 1', 'enable_avx'),
    (r'#define\s+VKD3D_ENABLE_AVX2\s+\d+', '#define VKD3D_ENABLE_AVX2 1', 'enable_avx2'),
    (r'#define\s+VKD3D_ENABLE_FMA\s+\d+', '#define VKD3D_ENABLE_FMA 1', 'enable_fma'),
    (r'#define\s+VKD3D_ENABLE_SSE4_2\s+\d+', '#define VKD3D_ENABLE_SSE4_2 1', 'enable_sse4_2'),
    (r'#define\s+VKD3D_ENABLE_AVX512\s+\d+', '#define VKD3D_ENABLE_AVX512 1', 'enable_avx512'),
]

CPU_ARM64EC_PATCHES: List[Tuple[str, str, str]] = [
    (r'#define\s+VKD3D_ENABLE_AVX\s+\d+', '#define VKD3D_ENABLE_AVX 0', 'disable_avx'),
    (r'#define\s+VKD3D_ENABLE_AVX2\s+\d+', '#define VKD3D_ENABLE_AVX2 0', 'disable_avx2'),
    (r'#define\s+VKD3D_ENABLE_FMA\s+\d+', '#define VKD3D_ENABLE_FMA 0', 'disable_fma'),
    (r'#define\s+VKD3D_ENABLE_SSE4_2\s+\d+', '#define VKD3D_ENABLE_SSE4_2 0', 'disable_sse4_2'),
    (r'#define\s+VKD3D_ENABLE_SSE\s+\d+', '#define VKD3D_ENABLE_SSE 0', 'disable_sse'),
    (r'#define\s+VKD3D_ENABLE_AVX512\s+\d+', '#define VKD3D_ENABLE_AVX512 0', 'disable_avx512'),
    (r'(vkd3d_cpu_supports_sse4_2\s*\(\s*\))', 'false', 'disable_sse4_2_check'),
    (r'(vkd3d_cpu_supports_avx\s*\(\s*\))', 'false', 'disable_avx_check'),
    (r'(vkd3d_cpu_supports_avx2\s*\(\s*\))', 'false', 'disable_avx2_check'),
    (r'(vkd3d_cpu_supports_fma\s*\(\s*\))', 'false', 'disable_fma_check'),
    (r'(vkd3d_cpu_supports_avx512\s*\(\s*\))', 'false', 'disable_avx512_check'),
    (r'#define\s+VKD3D_ENABLE_NEON\s+\d+', '#define VKD3D_ENABLE_NEON 1', 'enable_neon'),
]

PERFORMANCE_PATCHES: List[Tuple[str, str, str]] = [
    (r'#define\s+VKD3D_DEBUG\s+1', '#define VKD3D_DEBUG 0', 'disable_debug'),
    (r'#define\s+VKD3D_PROFILING\s+1', '#define VKD3D_PROFILING 0', 'disable_profiling'),
    (r'#define\s+VKD3D_SHADER_DEBUG\s+1', '#define VKD3D_SHADER_DEBUG 0', 'disable_shader_debug'),
]

TURNIP_PATCHES: List[Tuple[str, str, str]] = [
    (r'(maxSets\s*=\s*)\d+', r'\g<1>16384', 'increase_descriptor_pool'),
    (r'(maxDescriptorSetSamplers\s*=\s*)\d+', r'\g<1>4096', 'increase_sampler_limit'),
    (r'(maxDescriptorSetUniformBuffers\s*=\s*)\d+', r'\g<1>16384', 'increase_uniform_buffer_limit'),
    (r'(maxDescriptorSetStorageBuffers\s*=\s*)\d+', r'\g<1>16384', 'increase_storage_buffer_limit'),
    (r'(maxDescriptorSetSampledImages\s*=\s*)\d+', r'\g<1>16384', 'increase_sampled_image_limit'),
    (r'(maxDescriptorSetStorageImages\s*=\s*)\d+', r'\g<1>4096', 'increase_storage_image_limit'),
]

DXR_PATCHES: List[Tuple[str, str, str]] = [
    (r'(options5\.RaytracingTier\s*=\s*)[^;]+;', r'\1D3D12_RAYTRACING_TIER_1_1;', 'raytracing_tier'),
    (r'(options5\.RenderPassesTier\s*=\s*)[^;]+;', r'\1D3D12_RENDER_PASS_TIER_2;', 'render_passes_tier'),
]


class VKD3DPatcher:
    FORBIDDEN_TYPES = ['pthread_rwlock_t', 'pthread_spinlock_t', 'pthread_barrier_t']

    def __init__(self, arch: str = 'x86_64', dry_run: bool = False):
        self.arch = arch
        self.dry_run = dry_run
        self.result = PatchResult()
        self._lock = Lock()

    def _validate_patches(self, patches: List[Tuple[str, str, str]]) -> List[str]:
        warnings = []
        for pattern, replacement, name in patches:
            for forbidden in self.FORBIDDEN_TYPES:
                if forbidden in replacement:
                    warnings.append(f'Patch "{name}" uses potentially unsupported type: {forbidden}')
        return warnings

    def _apply_patches_to_file(self, filepath: str, patches: List[Tuple[str, str, str]]) -> Tuple[int, int, List[str], List[Dict]]:
        local_applied = 0
        local_skipped = 0
        local_errors: List[str] = []
        local_details: List[Dict] = []

        if not os.path.exists(filepath):
            return local_applied, local_skipped, local_errors, local_details

        try:
            with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
        except Exception as e:
            local_errors.append(f'read error {filepath}: {e}')
            return local_applied, local_skipped, local_errors, local_details

        original = content
        file_changes: List[Dict[str, Any]] = []

        for pattern, replacement, name in patches:
            try:
                matches = len(re.findall(pattern, content, re.MULTILINE | re.DOTALL))
                if matches > 0:
                    if not self.dry_run:
                        content = re.sub(pattern, replacement, content, flags=re.MULTILINE | re.DOTALL)
                    local_applied += matches
                    file_changes.append({'name': name, 'matches': matches})
                else:
                    local_skipped += 1
            except re.error as e:
                local_errors.append(f'regex error in {filepath} ({name}): {e}')

        if content != original and not self.dry_run:
            try:
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(content)
            except Exception as e:
                local_errors.append(f'write error {filepath}: {e}')

        if file_changes:
            local_details.append({'file': os.path.basename(filepath), 'changes': file_changes})

        return local_applied, local_skipped, local_errors, local_details

    def apply_all(self, src_dir: str) -> int:
        logger.info(f'source: {src_dir}')
        logger.info(f'arch: {self.arch}')
        logger.info(f'mode: {"dry-run" if self.dry_run else "apply"}')

        all_patch_sets = [
            CAPABILITY_PATCHES, DESCRIPTOR_CACHE_PATCHES, COMMAND_BATCH_PATCHES,
            BARRIER_OPT_PATCHES, PIPELINE_CACHE_PATCHES, TURNIP_PATCHES,
            PERFORMANCE_PATCHES, DXR_PATCHES
        ]
        for patches in all_patch_sets:
            warnings = self._validate_patches(patches)
            for w in warnings:
                logger.warning(w)

        device_files = glob.glob(os.path.join(src_dir, 'libs/vkd3d/*.[ch]'))
        if not device_files:
            device_files = glob.glob(os.path.join(src_dir, 'src/**/*.[ch]'), recursive=True)

        all_files = [f for f in glob.glob(os.path.join(src_dir, '**/*.[ch]'), recursive=True)
                     if 'tests' not in f and 'demos' not in f]

        logger.info(f'device files: {len(device_files)}')
        logger.info(f'total files: {len(all_files)}')

        tasks: List[Tuple[str, List[Tuple[str, str, str]]]] = []

        for f in device_files:
            tasks.append((f, CAPABILITY_PATCHES))
            tasks.append((f, DESCRIPTOR_CACHE_PATCHES))
            tasks.append((f, COMMAND_BATCH_PATCHES))
            tasks.append((f, BARRIER_OPT_PATCHES))
            tasks.append((f, PIPELINE_CACHE_PATCHES))
            tasks.append((f, TURNIP_PATCHES))
            tasks.append((f, DXR_PATCHES))

        cpu_patches = CPU_X86_64_PATCHES if self.arch == 'x86_64' else CPU_ARM64EC_PATCHES
        for f in all_files:
            tasks.append((f, cpu_patches))

        for f in all_files:
            tasks.append((f, PERFORMANCE_PATCHES))

        max_workers = min(os.cpu_count() or 4, 8)
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = [executor.submit(self._apply_patches_to_file, path, patches) for path, patches in tasks]
            for future in as_completed(futures):
                applied, skipped, errors, details = future.result()
                with self._lock:
                    self.result.applied += applied
                    self.result.skipped += skipped
                    self.result.errors.extend(errors)
                    self.result.details.extend(details)

        logger.info(f'applied: {self.result.applied}')
        logger.info(f'skipped: {self.result.skipped}')
        logger.info(f'errors: {len(self.result.errors)}')

        if self.result.errors:
            for err in self.result.errors[:10]:
                logger.error(err)

        return 1 if self.result.errors else 0

    def generate_report(self, output_path: str) -> None:
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(f'arch: {self.arch}\n')
            f.write(f'applied: {self.result.applied}\n')
            f.write(f'skipped: {self.result.skipped}\n')
            f.write(f'errors: {len(self.result.errors)}\n\n')

            if self.result.details:
                f.write('changes:\n')
                for detail in self.result.details:
                    f.write(f'  {detail["file"]}:\n')
                    for change in detail['changes']:
                        f.write(f'    {change["name"]}: {change["matches"]}\n')

            if self.result.errors:
                f.write('\nerrors:\n')
                for e in self.result.errors:
                    f.write(f'  {e}\n')

        logger.info(f'report: {output_path}')


def main() -> None:
    parser = argparse.ArgumentParser(description='vkd3d-proton performance patcher')
    parser.add_argument('src_dir', help='vkd3d-proton source directory')
    parser.add_argument('--arch', choices=['x86_64', 'arm64ec'], default='x86_64')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--report', action='store_true')

    args = parser.parse_args()

    if not os.path.isdir(args.src_dir):
        logger.error(f'directory not found: {args.src_dir}')
        sys.exit(1)

    patcher = VKD3DPatcher(args.arch, args.dry_run)
    result = patcher.apply_all(args.src_dir)

    if args.report:
        patcher.generate_report('patch-report.txt')

    sys.exit(result)


if __name__ == '__main__':
    main()
