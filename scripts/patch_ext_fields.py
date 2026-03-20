import sys, re
fp = sys.argv[1]
with open(fp) as f: c = f.read()

INJECT = """
   /* EXT_INJECT_APPLIED */
   ext->AMD_anti_lag = true;
   ext->AMD_device_coherent_memory = true;
   ext->AMD_memory_overallocation_behavior = true;
   ext->AMD_shader_core_properties = true;
   ext->AMD_shader_core_properties2 = true;
   ext->AMD_shader_info = true;
   ext->EXT_blend_operation_advanced = true;
   ext->EXT_buffer_device_address = true;
   ext->EXT_depth_bias_control = true;
   ext->EXT_depth_range_unrestricted = true;
   ext->EXT_device_fault = true;
   ext->EXT_discard_rectangles = true;
   ext->EXT_display_control = true;
   ext->EXT_fragment_density_map2 = true;
   ext->EXT_fragment_shader_interlock = true;
   ext->EXT_frame_boundary = true;
   ext->EXT_full_screen_exclusive = true;
   ext->EXT_image_compression_control = true;
   ext->EXT_image_compression_control_swapchain = true;
   ext->EXT_image_sliced_view_of_3d = true;
   ext->EXT_memory_priority = true;
   ext->EXT_mesh_shader = true;
   ext->EXT_opacity_micromap = true;
   ext->EXT_pageable_device_local_memory = true;
   ext->EXT_pipeline_library_group_handles = true;
   ext->EXT_pipeline_protected_access = true;
   ext->EXT_pipeline_robustness = true;
   ext->EXT_post_depth_coverage = true;
   ext->EXT_shader_atomic_float2 = true;
   ext->EXT_shader_object = true;
   ext->EXT_shader_subgroup_ballot = true;
   ext->EXT_shader_subgroup_vote = true;
   ext->EXT_shader_tile_image = true;
   ext->EXT_subpass_merge_feedback = true;
   ext->EXT_swapchain_maintenance1 = true;
   ext->EXT_ycbcr_2plane_444_formats = true;
   ext->EXT_ycbcr_image_arrays = true;
   ext->GOOGLE_user_type = true;
   ext->IMG_relaxed_line_rasterization = true;
   ext->INTEL_performance_query = true;
   ext->INTEL_shader_integer_functions2 = true;
   ext->KHR_compute_shader_derivatives = true;
   ext->KHR_cooperative_matrix = true;
   ext->KHR_depth_clamp_zero_one = true;
   ext->KHR_device_address_commands = true;
   ext->KHR_fragment_shader_barycentric = true;
   ext->KHR_maintenance10 = true;
   ext->KHR_maintenance7 = true;
   ext->KHR_maintenance8 = true;
   ext->KHR_maintenance9 = true;
   ext->KHR_performance_query = true;
   ext->KHR_pipeline_binary = true;
   ext->KHR_present_id = true;
   ext->KHR_present_id2 = true;
   ext->KHR_present_wait = true;
   ext->KHR_present_wait2 = true;
   ext->KHR_ray_tracing_pipeline = true;
   ext->KHR_ray_tracing_position_fetch = true;
   ext->KHR_robustness2 = true;
   ext->KHR_shader_maximal_reconvergence = true;
   ext->KHR_shader_quad_control = true;
   ext->KHR_swapchain_maintenance1 = true;
   ext->KHR_video_decode_av1 = true;
   ext->KHR_video_decode_h264 = true;
   ext->KHR_video_decode_h265 = true;
   ext->KHR_video_decode_queue = true;
   ext->KHR_video_encode_av1 = true;
   ext->KHR_video_encode_h264 = true;
   ext->KHR_video_encode_h265 = true;
   ext->KHR_video_encode_queue = true;
   ext->KHR_video_maintenance1 = true;
   ext->KHR_video_maintenance2 = true;
   ext->KHR_video_queue = true;
   ext->MESA_image_alignment_control = true;
   ext->NVX_image_view_handle = true;
   ext->NV_cooperative_matrix = true;
   ext->NV_device_diagnostic_checkpoints = true;
   ext->NV_device_diagnostics_config = true;
   ext->QCOM_filter_cubic_clamp = true;
   ext->QCOM_filter_cubic_weights = true;
   ext->QCOM_image_processing2 = true;
   ext->QCOM_render_pass_store_ops = true;
   ext->QCOM_render_pass_transform = true;
   ext->QCOM_tile_properties = true;
   ext->QCOM_ycbcr_degamma = true;
   ext->VALVE_descriptor_set_host_mapping = true;
   ext->EXT_zero_initialize_device_memory = true;
   ext->KHR_shader_bfloat16 = true;
   ext->KHR_unified_image_layouts = true;
   ext->QCOM_cooperative_matrix_conversion = true;
   ext->QCOM_data_graph_model = true;
   ext->QCOM_fragment_density_map_offset = true;
   ext->QCOM_image_processing = true;
   ext->QCOM_multiview_per_view_render_areas = true;
   ext->QCOM_multiview_per_view_viewports = true;
   ext->QCOM_render_pass_shader_resolve = true;
   ext->QCOM_rotated_copy_commands = true;
   ext->QCOM_tile_memory_heap = true;
   ext->QCOM_tile_shading = true;
   ext->VALVE_fragment_density_map_layered = true;
   ext->VALVE_shader_mixed_float_dot_product = true;
   ext->VALVE_video_encode_rgb_conversion = true;
"""

# Find get_device_extensions function and inject before its closing brace
m = re.search(r'(get_device_extensions\s*\([^)]*\)\s*\{)', c)
if not m:
    m = re.search(r'(tu_get_device_extensions\s*\([^)]*\)\s*\{)', c)

if m:
    # Find the matching closing brace
    depth = 0
    pos = m.start()
    start_brace = c.find('{', m.start())
    i = start_brace
    while i < len(c):
        if c[i] == '{': depth += 1
        elif c[i] == '}':
            depth -= 1
            if depth == 0:
                c = c[:i] + INJECT + c[i:]
                break
        i += 1
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] EXT injection: added {INJECT.count("ext->")} extensions to get_device_extensions')
else:
    # Fallback: flip false->true pattern
    n = 0
    for pat in [
        r'(\.(?:KHR|EXT|AMD|QCOM|NV|NVX|VALVE|GOOGLE|IMG|INTEL|MESA)_[A-Za-z0-9_]+\s*=\s*)false\b',
    ]:
        for mm in re.finditer(pat, c):
            c = c[:mm.start(2)] + 'true' + c[mm.end(2):]
            n += 1
    c += '\n/* EXT_INJECT_APPLIED */\n'
    with open(fp, 'w') as f: f.write(c)
    print(f'[OK] EXT fallback: flipped {n} bits')
