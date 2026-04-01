#!/usr/bin/env python3
"""Patch vkd3d-proton capability reporting for ARM64EC packaging workflows."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


GPU_PATCHES = [
    (r"(adapter_id\.vendor_id\s*(?<!=)=(?!=)\s*)[^;]+;", r"\g<1>0x1002;"),
    (r"(adapter_id\.device_id\s*(?<!=)=(?!=)\s*)[^;]+;", r"\g<1>0x163f;"),
    (r"(DedicatedVideoMemory\s*(?<!=)=(?!=)\s*)[^;]+;", r"\g<1>1024ULL * 1024 * 1024;"),
    (r"(SharedSystemMemory\s*(?<!=)=(?!=)\s*)[^;]+;", r"\g<1>16384ULL * 1024 * 1024;"),
]

BALANCED_DEVICE_PATCHES = [
    (r"(\.UMA\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(\.CacheCoherentUMA\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(\.IsolatedMMU\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options1\.WaveOps\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options1\.WaveLaneCountMin\s*=\s*)[^;]+;", r"\g<1>32;"),
    (r"(options1\.WaveLaneCountMax\s*=\s*)[^;]+;", r"\g<1>64;"),
    (r"(options1\.Int64ShaderOps\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options3\.BarycentricsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options4\.Native16BitShaderOpsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options6\.VariableShadingRateTier\s*=\s*)[^;]+;", r"\g<1>D3D12_VARIABLE_SHADING_RATE_TIER_2;"),
    (r"(options6\.AdditionalShadingRatesSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options7\.MeshShaderTier\s*=\s*)[^;]+;", r"\g<1>D3D12_MESH_SHADER_TIER_1;"),
    (r"(options7\.SamplerFeedbackTier\s*=\s*)[^;]+;", r"\g<1>D3D12_SAMPLER_FEEDBACK_TIER_1_0;"),
    (r"(options12\.EnhancedBarriersSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options12\.UnifiedImageLayoutsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options16\.GPUUploadHeapSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
]

AGGRESSIVE_EXTRA_PATCHES = [
    (r"(data->HighestShaderModel\s*=\s*)[^;]+;", r"\g<1>D3D_SHADER_MODEL_6_8;"),
    (r"(info\.HighestShaderModel\s*=\s*)[^;]+;", r"\g<1>D3D_SHADER_MODEL_6_8;"),
    (r"(MaxSupportedFeatureLevel\s*=\s*)[^;]+;", r"\g<1>D3D_FEATURE_LEVEL_12_2;"),
    (r"(D3D12SDKVersion\s*=\s*)[^;]+;", r"\g<1>619;"),
    (r"(options1\.ExpandedComputeResourceStates\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options2\.DepthBoundsTestSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options2\.ProgrammableSamplePositionsTier\s*=\s*)[^;]+;",
        r"\g<1>D3D12_PROGRAMMABLE_SAMPLE_POSITIONS_TIER_2;",
    ),
    (r"(options3\.ThresholdCoefficientsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options4\.MSAAOperationsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options5\.RaytracingTier\s*=\s*)[^;]+;", r"\g<1>D3D12_RAYTRACING_TIER_1_2;"),
    (r"(options5\.RenderPassesTier\s*=\s*)[^;]+;", r"\g<1>D3D12_RENDER_PASS_TIER_2;"),
    (r"(options5\.SRVOnlyTiledResourceTier3\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options6\.ShadingRateImageTileSize\s*=\s*)[^;]+;", r"\g<1>8;"),
    (r"(options6\.BackgroundProcessingSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options6\.PerPrimitiveShadingRateSupportedWithViewportIndexing\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (r"(options9\.AdvancedTextureOpsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options9\.WriteableMSAATexturesSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options9\.MeshShaderSupportsFullRangeRenderTargetArrayIndex\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (
        r"(options10\.VariableRateShadingSumCombinerSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (
        r"(options10\.MeshShaderPerPrimitiveShadingRateSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (
        r"(options11\.AtomicInt64OnDescriptorHeapResourceSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (r"(options11\.AtomicInt64OnGroupSharedSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options11\.AtomicInt64OnTypedResourceSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options11\.DerivativesInMeshAndAmplificationShadersSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (r"(options12\.RelaxedFormatCastingSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options12\.MSPrimitivesPipelineStatisticIncludesCulledPrimitives\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (
        r"(options13\.UnrestrictedBufferTextureCopyPitchSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (
        r"(options13\.UnrestrictedVertexElementAlignmentSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (r"(options13\.InvertedViewportHeightFlipsYSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options13\.InvertedViewportDepthFlipsZSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options13\.TextureCopyBetweenDimensionsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options13\.AlphaBlendFactorSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options16\.MapDefaultHeapAllocationSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options17\.NonNormalizedCoordinateSamplersSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (r"(options17\.ManualWriteTrackingResourceSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options21\.WorkGraphsTier\s*=\s*)[^;]+;", r"\g<1>D3D12_WORK_GRAPHS_TIER_1_0;"),
    (r"(options21\.ExecuteIndirectTier\s*=\s*)[^;]+;", r"\g<1>D3D12_EXECUTE_INDIRECT_TIER_1_1;"),
    (r"(options21\.SampleCmpGradientAndBiasSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options21\.ExtendedCommandInfoSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.ResourceBindingTier\s*=\s*)[^;]+;", r"\g<1>D3D12_RESOURCE_BINDING_TIER_3;"),
    (r"(options\.TiledResourcesTier\s*=\s*)[^;]+;", r"\g<1>D3D12_TILED_RESOURCES_TIER_4;"),
    (r"(options\.ResourceHeapTier\s*=\s*)[^;]+;", r"\g<1>D3D12_RESOURCE_HEAP_TIER_2;"),
    (
        r"(options\.ConservativeRasterizationTier\s*=\s*)[^;]+;",
        r"\g<1>D3D12_CONSERVATIVE_RASTERIZATION_TIER_3;",
    ),
    (r"(options\.ROVsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.DoublePrecisionFloatShaderOps\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.TypedUAVLoadAdditionalFormats\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.OutputMergerLogicOp\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.PSSpecifiedStencilRefSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.CooperativeMatrixSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.GDeflateSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.AntiLagSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.DepthBiasControlSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.ComputeShaderDerivativesSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.PageableDeviceLocalMemorySupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.DestructionNotifierSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options\.SharedResourceCompatibilityTier\s*=\s*)[^;]+;",
        r"\g<1>D3D12_SHARED_RESOURCE_COMPATIBILITY_TIER_2;",
    ),
    (
        r"(options\.IndependentFrontAndBackStencilRefMaskSupported\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
    (r"(options\.TriangleFanSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.DynamicDepthBiasSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.NarrowQuadrilateralLinesSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (r"(options\.MismatchingOutputDimensionsSupported\s*=\s*)[^;]+;", r"\g<1>TRUE;"),
    (
        r"(options\.VPAndRTArrayIndexFromAnyShaderFeedingRasterizerSupportedWithoutGSEmulation\s*=\s*)[^;]+;",
        r"\g<1>TRUE;",
    ),
]

PROFILE_PATCHES = {
    "none": [],
    "balanced": GPU_PATCHES + BALANCED_DEVICE_PATCHES,
    "aggressive": GPU_PATCHES + BALANCED_DEVICE_PATCHES + AGGRESSIVE_EXTRA_PATCHES,
}


def patch_file(path: Path, patches: list[tuple[str, str]]) -> int:
    if not path.exists():
        return 0

    content = path.read_text(encoding="utf-8", errors="ignore")
    updated = content
    replacements = 0

    for pattern, replacement in patches:
        updated, count = re.subn(pattern, replacement, updated, flags=re.MULTILINE)
        replacements += count

    if updated != content:
        path.write_text(updated, encoding="utf-8")

    return replacements


def apply_profile(root: Path, profile: str) -> int:
    patches = PROFILE_PATCHES[profile]
    if not patches:
        return 0

    total = 0
    total += patch_file(root / "libs/vkd3d/device.c", patches)

    if profile == "aggressive":
        for path in (root / "libs/vkd3d").rglob("*"):
            if not path.is_file() or path.suffix not in {".c", ".h"}:
                continue
            if path.name == "device.c":
                continue
            if not any(token in path.name for token in ("adapter", "feature", "caps", "d3d12")):
                continue
            total += patch_file(path, GPU_PATCHES)

    return total


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="Path to cloned vkd3d-proton source tree.")
    parser.add_argument(
        "--profile",
        required=True,
        choices=sorted(PROFILE_PATCHES.keys()),
        help="Patch profile to apply.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    if not root.exists():
        print(f"Missing source root: {root}", file=sys.stderr)
        return 1

    replacements = apply_profile(root, args.profile)
    print(f"profile={args.profile} replacements={replacements}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
