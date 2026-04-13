#pragma once

#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <stdint.h>
#include <stdbool.h>

#define WRAPPER_VERSION_MAJOR  2
#define WRAPPER_VERSION_MINOR  0
#define WRAPPER_VERSION_PATCH  0

#define WRAPPER_LAYER_NAME     "VK_LAYER_BIONIC_dx_wrapper"
#define WRAPPER_LAYER_DESC     "DX Wrapper for Winlator Bionic / GameHub / GameNative"

typedef enum WrapperGPUVendor {
    GPU_VENDOR_UNKNOWN  = 0,
    GPU_VENDOR_ADRENO   = 1,
    GPU_VENDOR_MALI     = 2,
    GPU_VENDOR_XCLIPSE  = 3,
    GPU_VENDOR_POWERVR  = 4,
} WrapperGPUVendor;

typedef struct WrapperEnvConfig {
    bool     disable_external_fd;
    bool     force_clip_distance;
    bool     disable_clip_distance;
    bool     one_by_one_bcn;
    bool     check_for_striping;
    bool     depth_format_reduction;
    bool     barrier_optimization;
    bool     dump_bcn_artifacts;
    bool     use_vvl;

    bool     disable_descriptor_buffer;
    bool     force_descriptor_buffer;
    bool     emulate_maintenance5;
    bool     emulate_maintenance7;
    bool     emulate_maintenance8;
    bool     disable_extended_dynamic_state;
    bool     force_gpl;
    bool     disable_gpl;
    bool     bcn_use_compute;
    bool     force_fifo;

    uint32_t max_image_count;
    uint32_t gpu_override_vendor_id;
    uint32_t gpu_override_device_id;
    char     gpu_override_name[256];
} WrapperEnvConfig;

typedef struct WrapperDeviceInfo {
    WrapperGPUVendor vendor;
    uint32_t         vendor_id;
    uint32_t         device_id;
    uint32_t         api_version;
    char             device_name[256];

    bool supports_vulkan_13;
    bool supports_descriptor_buffer;
    bool supports_gpl;
    bool supports_extended_dynamic_state;
    bool supports_extended_dynamic_state2;
    bool supports_extended_dynamic_state3;
    bool supports_maintenance5;
    bool supports_maintenance6;
    bool supports_maintenance7;
    bool supports_maintenance8;
    bool supports_maintenance9;
    bool supports_maintenance10;
    bool supports_clip_distance;
    bool supports_cull_distance;
    bool supports_load_store_op_none;
    bool supports_attachment_feedback_loop;
    bool supports_pageable_device_local_memory;
    bool supports_sync2;
    bool supports_dynamic_rendering;
    bool supports_bcn_textures;
} WrapperDeviceInfo;

typedef struct WrapperDispatch {
    PFN_vkGetInstanceProcAddr               GetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr                 GetDeviceProcAddr;
    PFN_vkDestroyDevice                     DestroyDevice;
    PFN_vkCreateSwapchainKHR                CreateSwapchainKHR;
    PFN_vkQueuePresentKHR                   QueuePresentKHR;
    PFN_vkCreateShaderModule                CreateShaderModule;
    PFN_vkCmdPipelineBarrier                CmdPipelineBarrier;
    PFN_vkCmdPipelineBarrier2               CmdPipelineBarrier2;
    PFN_vkCreateImage                       CreateImage;
    PFN_vkEnumerateDeviceExtensionProperties EnumerateDeviceExtensionProperties;
} WrapperDispatch;

/* WrapperPatchedSPIRV is defined in spirv_patcher.cpp (C++ only).
   The C API uses opaque pointers; C++ callers can include spirv_patcher.cpp's
   definition directly. */
struct WrapperPatchedSPIRV;

#ifdef __cplusplus
extern "C" {
#endif

VkResult wrapper_init(const WrapperEnvConfig *config);
void     wrapper_shutdown(void);
void     wrapper_load_env_config(WrapperEnvConfig *out);

bool     wrapper_format_is_bcn(VkFormat fmt);
VkFormat wrapper_bcn_to_uncompressed(VkFormat bcn);

bool     wrapper_patch_shader(const WrapperDeviceInfo *info,
                               const WrapperEnvConfig  *cfg,
                               const uint32_t *spirv_in,
                               size_t          size_bytes,
                               struct WrapperPatchedSPIRV *out);

void wrapper_free_patched_spirv(struct WrapperPatchedSPIRV *p);

WrapperGPUVendor wrapper_detect_vendor(uint32_t vendor_id);

#ifdef __cplusplus
}
#endif
