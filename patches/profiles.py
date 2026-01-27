from typing import List, Tuple
from .core import mk_asgn, mk_def

PT = Tuple[str, str, str]

SM_P: List[PT] = [
    (mk_asgn('data->HighestShaderModel'), r'\g<1>D3D_SHADER_MODEL_6_9;', 'sm69'),
    (mk_asgn('info.HighestShaderModel'), r'\g<1>D3D_SHADER_MODEL_6_9;', 'sm69i'),
    (mk_asgn('MaxSupportedFeatureLevel'), r'\g<1>D3D_FEATURE_LEVEL_12_2;', 'fl122'),
]

WV_P: List[PT] = [
    (mk_asgn('options1.WaveOps'), r'\g<1>TRUE;', 'wv0'),
    (mk_asgn('options1.WaveLaneCountMin'), r'\g<1>32;', 'wv1'),
    (mk_asgn('options1.WaveLaneCountMax'), r'\g<1>128;', 'wv2'),
    (mk_asgn('options9.WaveMMATier'), r'\g<1>D3D12_WAVE_MMA_TIER_1_0;', 'wv3'),
]

RB_P: List[PT] = [
    (mk_asgn('options.ResourceBindingTier'), r'\g<1>D3D12_RESOURCE_BINDING_TIER_3;', 'rb0'),
    (mk_asgn('options.TiledResourcesTier'), r'\g<1>D3D12_TILED_RESOURCES_TIER_4;', 'rb1'),
    (mk_asgn('options.ResourceHeapTier'), r'\g<1>D3D12_RESOURCE_HEAP_TIER_2;', 'rb2'),
    (mk_asgn('options19.MaxSamplerDescriptorHeapSize'), r'\g<1>4096;', 'rb3'),
    (mk_asgn('options19.MaxViewDescriptorHeapSize'), r'\g<1>1000000;', 'rb4'),
]

SO_P: List[PT] = [
    (mk_asgn('options.DoublePrecisionFloatShaderOps'), r'\g<1>TRUE;', 'so0'),
    (mk_asgn('options1.Int64ShaderOps'), r'\g<1>TRUE;', 'so1'),
    (mk_asgn('options4.Native16BitShaderOpsSupported'), r'\g<1>TRUE;', 'so2'),
    (mk_asgn('options9.AtomicInt64OnTypedResourceSupported'), r'\g<1>TRUE;', 'so3'),
    (mk_asgn('options9.AtomicInt64OnGroupSharedSupported'), r'\g<1>TRUE;', 'so4'),
    (mk_asgn('options11.AtomicInt64OnDescriptorHeapResourceSupported'), r'\g<1>TRUE;', 'so5'),
]

MS_P: List[PT] = [
    (mk_asgn('options7.MeshShaderTier'), r'\g<1>D3D12_MESH_SHADER_TIER_1;', 'ms0'),
    (mk_asgn('options9.MeshShaderPipelineStatsSupported'), r'\g<1>TRUE;', 'ms1'),
    (mk_asgn('options9.MeshShaderSupportsFullRangeRenderTargetArrayIndex'), r'\g<1>TRUE;', 'ms2'),
    (mk_asgn('options9.DerivativesInMeshAndAmplificationShadersSupported'), r'\g<1>TRUE;', 'ms3'),
    (mk_asgn('options10.MeshShaderPerPrimitiveShadingRateSupported'), r'\g<1>TRUE;', 'ms4'),
    (mk_asgn('options21.ExecuteIndirectTier'), r'\g<1>D3D12_EXECUTE_INDIRECT_TIER_1_1;', 'ms5'),
    (mk_asgn('options21.WorkGraphsTier'), r'\g<1>D3D12_WORK_GRAPHS_TIER_1_0;', 'ms6'),
    (mk_asgn('options12.EnhancedBarriersSupported'), r'\g<1>TRUE;', 'ms7'),
    (mk_asgn('options20.ComputeOnlyWriteWatchSupported'), r'\g<1>TRUE;', 'ms8'),
]

RT_P: List[PT] = [
    (mk_asgn('options5.RaytracingTier'), r'\g<1>D3D12_RAYTRACING_TIER_1_1;', 'rt0'),
    (mk_asgn('options5.RenderPassesTier'), r'\g<1>D3D12_RENDER_PASS_TIER_2;', 'rt1'),
    (mk_asgn('options6.VariableShadingRateTier'), r'\g<1>D3D12_VARIABLE_SHADING_RATE_TIER_2;', 'rt2'),
    (mk_asgn('options6.ShadingRateImageTileSize'), r'\g<1>8;', 'rt3'),
    (mk_asgn('options6.BackgroundProcessingSupported'), r'\g<1>TRUE;', 'rt4'),
    (mk_asgn('options10.VariableRateShadingSumCombinerSupported'), r'\g<1>TRUE;', 'rt5'),
]

SF_P: List[PT] = [
    (mk_asgn('options7.SamplerFeedbackTier'), r'\g<1>D3D12_SAMPLER_FEEDBACK_TIER_1_0;', 'sf0'),
    (mk_asgn('options2.DepthBoundsTestSupported'), r'\g<1>TRUE;', 'sf1'),
    (mk_asgn('options14.AdvancedTextureOpsSupported'), r'\g<1>TRUE;', 'sf2'),
    (mk_asgn('options14.WriteableMSAATexturesSupported'), r'\g<1>TRUE;', 'sf3'),
]

TX_P: List[PT] = [
    (mk_asgn('options8.UnalignedBlockTexturesSupported'), r'\g<1>TRUE;', 'tx0'),
    (mk_asgn('options13.UnrestrictedBufferTextureCopyPitchSupported'), r'\g<1>TRUE;', 'tx1'),
    (mk_asgn('options13.TextureCopyBetweenDimensionsSupported'), r'\g<1>TRUE;', 'tx2'),
    (mk_asgn('options16.GPUUploadHeapSupported'), r'\g<1>TRUE;', 'tx3'),
]

RN_P: List[PT] = [
    (mk_asgn('options13.UnrestrictedVertexElementAlignmentSupported'), r'\g<1>TRUE;', 'rn0'),
    (mk_asgn('options13.InvertedViewportHeightFlipsYSupported'), r'\g<1>TRUE;', 'rn1'),
    (mk_asgn('options13.InvertedViewportDepthFlipsZSupported'), r'\g<1>TRUE;', 'rn2'),
    (mk_asgn('options13.AlphaBlendFactorSupported'), r'\g<1>TRUE;', 'rn3'),
    (mk_asgn('options15.TriangleFanSupported'), r'\g<1>TRUE;', 'rn4'),
    (mk_asgn('options15.DynamicIndexBufferStripCutSupported'), r'\g<1>TRUE;', 'rn5'),
    (mk_asgn('options19.RasterizerDesc2Supported'), r'\g<1>TRUE;', 'rn6'),
    (mk_asgn('options19.NarrowQuadrilateralLinesSupported'), r'\g<1>TRUE;', 'rn7'),
]

PF_P: List[PT] = [
    (mk_def('VKD3D_DEBUG') + r'\s+1', '#define VKD3D_DEBUG 0', 'pf0'),
    (mk_def('VKD3D_PROFILING') + r'\s+1', '#define VKD3D_PROFILING 0', 'pf1'),
    (mk_def('VKD3D_SHADER_DEBUG') + r'\s+1', '#define VKD3D_SHADER_DEBUG 0', 'pf2'),
]

CP_P: List[PT] = [
    (r'#define\s+VKD3D_ENABLE_AVX\s+\d+', '#define VKD3D_ENABLE_AVX 1', 'cp0'),
    (r'#define\s+VKD3D_ENABLE_AVX2\s+\d+', '#define VKD3D_ENABLE_AVX2 1', 'cp1'),
    (r'#define\s+VKD3D_ENABLE_FMA\s+\d+', '#define VKD3D_ENABLE_FMA 1', 'cp2'),
    (r'#define\s+VKD3D_ENABLE_SSE4_2\s+\d+', '#define VKD3D_ENABLE_SSE4_2 1', 'cp3'),
]
