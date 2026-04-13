#include "include/wrapper.h"
#include <vulkan/vulkan.h>
#include <cstring>
#include <vector>
#include <algorithm>
#include <android/log.h>

#define LOG_TAG "DXWrapper/DXVK"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)

extern WrapperEnvConfig g_cfg;

static const char *kDXVK271Required[] = {
    "VK_KHR_maintenance5",
    "VK_KHR_synchronization2",
    "VK_KHR_dynamic_rendering",
    "VK_EXT_extended_dynamic_state",
    "VK_EXT_extended_dynamic_state2",
    "VK_KHR_format_feature_flags2",
    "VK_KHR_shader_float_controls",
    "VK_KHR_spirv_1_4",
    "VK_KHR_sampler_mirror_clamp_to_edge",
    "VK_KHR_image_format_list",
    "VK_EXT_robustness2",
    "VK_EXT_depth_clip_enable",
    "VK_EXT_shader_demote_to_helper_invocation",
    "VK_EXT_4444_formats",
    nullptr,
};

static const char *kDXVK271Recommended[] = {
    "VK_EXT_graphics_pipeline_library",
    "VK_EXT_attachment_feedback_loop_layout",
    "VK_KHR_load_store_op_none",
    "VK_EXT_load_store_op_none",
    "VK_EXT_conservative_rasterization",
    "VK_EXT_descriptor_buffer",
    "VK_EXT_pageable_device_local_memory",
    "VK_KHR_maintenance6",
    nullptr,
};

static const char *kVKD3DProton3Required[] = {
    "VK_KHR_maintenance5",
    "VK_KHR_synchronization2",
    "VK_KHR_dynamic_rendering",
    "VK_EXT_extended_dynamic_state",
    "VK_EXT_extended_dynamic_state2",
    "VK_EXT_extended_dynamic_state3",
    "VK_EXT_graphics_pipeline_library",
    "VK_EXT_mesh_shader",
    "VK_KHR_ray_tracing_pipeline",
    nullptr,
};

static bool ext_in_list(const std::vector<VkExtensionProperties> &exts,
                         const char *name)
{
    for (auto &e : exts) if (strcmp(e.extensionName, name) == 0) return true;
    return false;
}

static void add_ext(std::vector<const char *> &list, const char *name)
{
    for (auto *e : list) if (strcmp(e, name) == 0) return;
    list.push_back(name);
    LOGI("  inject extension: %s", name);
}

static void remove_ext(std::vector<const char *> &list, const char *name)
{
    list.erase(std::remove_if(list.begin(), list.end(),
        [&](const char *e){ return strcmp(e, name) == 0; }), list.end());
}

void dxvk_filter_descriptor_buffer(
    const WrapperDeviceInfo *info,
    std::vector<const char *> &exts)
{
    bool expose = info->supports_descriptor_buffer;

    if (g_cfg.force_descriptor_buffer)   expose = true;
    if (g_cfg.disable_descriptor_buffer) expose = false;

    if (info->vendor == GPU_VENDOR_ADRENO && !g_cfg.force_descriptor_buffer) {
        LOGI("Adreno: gating VK_EXT_descriptor_buffer (DXVK 2.7 disabled on some mobile)");
        expose = false;
    }

    if (!expose) remove_ext(exts, "VK_EXT_descriptor_buffer");
}

void dxvk_filter_gpl(
    const WrapperDeviceInfo *info,
    std::vector<const char *> &exts)
{
    bool expose = info->supports_gpl;

    if (g_cfg.force_gpl)   expose = true;
    if (g_cfg.disable_gpl) expose = false;

    if (!expose) {
        remove_ext(exts, "VK_EXT_graphics_pipeline_library");
        LOGI("GPL disabled");
    } else {
        LOGI("GPL enabled");
    }
}

void dxvk_emulate_maintenance5(
    const WrapperDeviceInfo *info,
    std::vector<const char *> &exts)
{
    if (info->supports_maintenance5) return;
    if (!g_cfg.emulate_maintenance5) {
        LOGW("DXVK 2.7 requires VK_KHR_maintenance5 but driver doesn't support it!");
        LOGW("Set WRAPPER_EMULATE_MAINTENANCE5=1 to inject a stub");
        return;
    }
    add_ext(exts, "VK_KHR_maintenance5");
    LOGI("Emulating VK_KHR_maintenance5 (stub)");
}

void vkd3d_emulate_maintenance7_10(
    const WrapperDeviceInfo *info,
    std::vector<const char *> &exts)
{
    if (g_cfg.emulate_maintenance7 && !info->supports_maintenance7)
        add_ext(exts, "VK_KHR_maintenance7");
    if (g_cfg.emulate_maintenance8 && !info->supports_maintenance8)
        add_ext(exts, "VK_KHR_maintenance8");
}

void dxvk_filter_extended_dynamic_state(
    const WrapperDeviceInfo *info,
    std::vector<const char *> &exts)
{
    if (!g_cfg.disable_extended_dynamic_state) return;
    remove_ext(exts, "VK_EXT_extended_dynamic_state");
    remove_ext(exts, "VK_EXT_extended_dynamic_state2");
    remove_ext(exts, "VK_EXT_extended_dynamic_state3");
    LOGI("EDS disabled by config");
}

void dxvk_apply_mali_workarounds(
    const WrapperDeviceInfo *info,
    std::vector<const char *> &exts)
{
    if (info->vendor != GPU_VENDOR_MALI) return;

    remove_ext(exts, "VK_EXT_extended_dynamic_state");
    LOGI("Mali: removed EDS (DXVK 2.x compatibility)");

    remove_ext(exts, "VK_EXT_descriptor_buffer");
    LOGI("Mali: removed descriptor_buffer");
}

void wrapper_patch_extensions_for_dxvk(
    const WrapperDeviceInfo *info,
    std::vector<const char *> &exts)
{
    LOGI("Patching extensions for DXVK 2.7.1 / VKD3D-Proton v3 — vendor=%d", (int)info->vendor);

    dxvk_emulate_maintenance5(info, exts);
    vkd3d_emulate_maintenance7_10(info, exts);
    dxvk_filter_descriptor_buffer(info, exts);
    dxvk_filter_gpl(info, exts);
    dxvk_filter_extended_dynamic_state(info, exts);

    if (info->vendor == GPU_VENDOR_MALI)
        dxvk_apply_mali_workarounds(info, exts);

    if (info->supports_load_store_op_none)
        add_ext(exts, "VK_KHR_load_store_op_none");
    if (info->supports_attachment_feedback_loop)
        add_ext(exts, "VK_EXT_attachment_feedback_loop_layout");
    if (info->supports_sync2)
        add_ext(exts, "VK_KHR_synchronization2");

    LOGI("Extension count after patching: %zu", exts.size());
}

VkResult wrapper_enumerate_extensions_patched(
    VkPhysicalDevice                    pd,
    const char                         *layer,
    uint32_t                           *pCount,
    VkExtensionProperties              *pProps,
    const WrapperDeviceInfo            *info,
    PFN_vkEnumerateDeviceExtensionProperties next_fn)
{
    /* Always query the real extensions and compute the patched list so that
       the count returned on the pProps==nullptr call matches the count we
       write on the pProps!=nullptr call.  This avoids the buffer overflow
       that occurred when patching ADDS extensions beyond the original count. */
    uint32_t real_count = 0;
    next_fn(pd, layer, &real_count, nullptr);
    std::vector<VkExtensionProperties> real_exts(real_count);
    next_fn(pd, layer, &real_count, real_exts.data());

    std::vector<const char *> names;
    for (auto &e : real_exts) names.push_back(e.extensionName);

    wrapper_patch_extensions_for_dxvk(info, names);

    uint32_t patched_count = (uint32_t)names.size();

    if (!pProps) {
        *pCount = patched_count;
        return VK_SUCCESS;
    }

    /* Respect the caller-provided buffer size per Vulkan spec */
    uint32_t to_write = std::min(*pCount, patched_count);
    for (uint32_t i = 0; i < to_write; i++) {
        memset(pProps[i].extensionName, 0, VK_MAX_EXTENSION_NAME_SIZE);
        strncpy(pProps[i].extensionName, names[i],
                VK_MAX_EXTENSION_NAME_SIZE - 1);
        /* Preserve the real specVersion for driver-reported extensions,
           use 1 for synthetically injected extensions */
        pProps[i].specVersion = 1;
        for (auto &re : real_exts) {
            if (strcmp(re.extensionName, names[i]) == 0) {
                pProps[i].specVersion = re.specVersion;
                break;
            }
        }
    }
    *pCount = patched_count;
    return (to_write < patched_count) ? VK_INCOMPLETE : VK_SUCCESS;
}
