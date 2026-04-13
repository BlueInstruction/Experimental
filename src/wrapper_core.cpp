#include "include/wrapper.h"
#include <vulkan/vulkan_android.h>
#include <sys/system_properties.h>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <mutex>
#include <vector>
#include <unordered_map>
#include <android/log.h>

#define LOG_TAG "DXWrapper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)

static std::mutex              g_lock;
WrapperEnvConfig               g_cfg;
static std::unordered_map<VkDevice, WrapperDeviceInfo> g_dev_info;
static std::unordered_map<VkDevice, WrapperDispatch>   g_dispatch;

static const struct { uint32_t id; WrapperGPUVendor v; } kVendors[] = {
    { 0x5143, GPU_VENDOR_ADRENO  },
    { 0x13B5, GPU_VENDOR_MALI    },
    { 0x1099, GPU_VENDOR_XCLIPSE },
    { 0x1AEE, GPU_VENDOR_POWERVR },
};

WrapperGPUVendor wrapper_detect_vendor(uint32_t vid) {
    for (auto &e : kVendors)
        if (e.id == vid) return e.v;
    return GPU_VENDOR_UNKNOWN;
}

void wrapper_load_env_config(WrapperEnvConfig *c) {
    memset(c, 0, sizeof(*c));

    auto gbool = [](const char *k) { const char *v = getenv(k); return v && v[0]=='1'; };
    auto guint = [](const char *k, uint32_t d) -> uint32_t {
        const char *v = getenv(k); return v ? (uint32_t)strtoul(v,nullptr,0) : d; };
    auto gstr  = [](const char *k, char *buf, size_t n) {
        const char *v = getenv(k); if (v) strncpy(buf, v, n-1); };

    c->disable_external_fd        = gbool("WRAPPER_DISABLE_EXTERNAL_FD");
    c->force_clip_distance         = gbool("WRAPPER_FORCE_CLIP_DISTANCE");
    c->disable_clip_distance       = gbool("WRAPPER_DISABLE_CLIP_DISTANCE");
    c->one_by_one_bcn              = gbool("WRAPPER_ONE_BY_ONE");
    c->check_for_striping          = gbool("WRAPPER_CHECK_FOR_STRIPING");
    c->depth_format_reduction      = gbool("WRAPPER_DEPTH_FORMAT_REDUCTION");
    c->barrier_optimization        = gbool("WRAPPER_BARRIER_OPTIMIZATION");
    c->dump_bcn_artifacts          = gbool("WRAPPER_DUMP_BCN_ARTIFACTS");
    c->use_vvl                     = gbool("WRAPPER_USE_VVL");
    c->disable_descriptor_buffer   = gbool("WRAPPER_DISABLE_DESCRIPTOR_BUFFER");
    c->force_descriptor_buffer     = gbool("WRAPPER_FORCE_DESCRIPTOR_BUFFER");
    c->emulate_maintenance5        = gbool("WRAPPER_EMULATE_MAINTENANCE5");
    c->emulate_maintenance7        = gbool("WRAPPER_EMULATE_MAINTENANCE7");
    c->emulate_maintenance8        = gbool("WRAPPER_EMULATE_MAINTENANCE8");
    c->disable_extended_dynamic_state = gbool("WRAPPER_DISABLE_EDS");
    c->force_gpl                   = gbool("WRAPPER_FORCE_GPL");
    c->disable_gpl                 = gbool("WRAPPER_DISABLE_GPL");
    c->bcn_use_compute             = gbool("WRAPPER_BCN_COMPUTE");
    c->force_fifo                  = gbool("WRAPPER_FORCE_FIFO");
    c->max_image_count             = guint("WRAPPER_MAX_IMAGE_COUNT", 3);
    c->gpu_override_vendor_id      = guint("WRAPPER_GPU_VENDOR_ID", 0);
    c->gpu_override_device_id      = guint("WRAPPER_GPU_DEVICE_ID", 0);
    gstr("WRAPPER_GPU_NAME", c->gpu_override_name, sizeof(c->gpu_override_name));

    LOGI("DX Wrapper v%d.%d.%d config loaded — max_img=%u gpl=%d/%d desc_buf=%d/%d maint5=%d",
         WRAPPER_VERSION_MAJOR, WRAPPER_VERSION_MINOR, WRAPPER_VERSION_PATCH,
         c->max_image_count,
         (int)c->force_gpl, (int)c->disable_gpl,
         (int)c->force_descriptor_buffer, (int)c->disable_descriptor_buffer,
         (int)c->emulate_maintenance5);
}

VkResult wrapper_init(const WrapperEnvConfig *cfg) {
    if (cfg) g_cfg = *cfg;
    else wrapper_load_env_config(&g_cfg);
    return VK_SUCCESS;
}

void wrapper_shutdown(void) {
    std::lock_guard<std::mutex> lk(g_lock);
    g_dev_info.clear();
    g_dispatch.clear();
}

static void query_device_caps(VkPhysicalDevice pd, WrapperDeviceInfo *info) {
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    info->vendor_id   = props.vendorID;
    info->device_id   = props.deviceID;
    info->api_version = props.apiVersion;
    strncpy(info->device_name, props.deviceName, 255);
    info->vendor = wrapper_detect_vendor(props.vendorID);
    info->supports_vulkan_13 = (VK_VERSION_MAJOR(props.apiVersion) >= 1 &&
                                 VK_VERSION_MINOR(props.apiVersion) >= 3);

    uint32_t cnt = 0;
    vkEnumerateDeviceExtensionProperties(pd, nullptr, &cnt, nullptr);
    std::vector<VkExtensionProperties> exts(cnt);
    vkEnumerateDeviceExtensionProperties(pd, nullptr, &cnt, exts.data());

    auto has = [&](const char *n) {
        for (auto &e : exts) if (strcmp(e.extensionName, n) == 0) return true;
        return false;
    };

    info->supports_descriptor_buffer         = has("VK_EXT_descriptor_buffer");
    info->supports_gpl                       = has("VK_EXT_graphics_pipeline_library");
    info->supports_extended_dynamic_state    = has("VK_EXT_extended_dynamic_state");
    info->supports_extended_dynamic_state2   = has("VK_EXT_extended_dynamic_state2");
    info->supports_extended_dynamic_state3   = has("VK_EXT_extended_dynamic_state3");
    info->supports_maintenance5              = has("VK_KHR_maintenance5");
    info->supports_maintenance6              = has("VK_KHR_maintenance6");
    info->supports_maintenance7              = has("VK_KHR_maintenance7");
    info->supports_maintenance8              = has("VK_KHR_maintenance8");
    info->supports_maintenance9              = has("VK_KHR_maintenance9");
    info->supports_maintenance10             = has("VK_KHR_maintenance10");
    info->supports_load_store_op_none        = has("VK_KHR_load_store_op_none") ||
                                               has("VK_EXT_load_store_op_none");
    info->supports_attachment_feedback_loop  = has("VK_EXT_attachment_feedback_loop_layout");
    info->supports_pageable_device_local_memory = has("VK_EXT_pageable_device_local_memory");
    info->supports_sync2                     = has("VK_KHR_synchronization2");
    info->supports_dynamic_rendering         = has("VK_KHR_dynamic_rendering");

    VkPhysicalDeviceFeatures feats;
    vkGetPhysicalDeviceFeatures(pd, &feats);
    info->supports_clip_distance = feats.shaderClipDistance;
    info->supports_cull_distance = feats.shaderCullDistance;

    VkFormatProperties fp;
    vkGetPhysicalDeviceFormatProperties(pd, VK_FORMAT_BC1_RGB_UNORM_BLOCK, &fp);
    info->supports_bcn_textures = (fp.optimalTilingFeatures &
                                    VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) != 0;

    LOGI("Device: [%s] vendor=0x%04x device=0x%04x vk13=%d bcn=%d gpl=%d maint5=%d desc_buf=%d",
         info->device_name, info->vendor_id, info->device_id,
         info->supports_vulkan_13, info->supports_bcn_textures,
         info->supports_gpl, info->supports_maintenance5,
         info->supports_descriptor_buffer);
}

VK_LAYER_EXPORT VkResult VKAPI_CALL
Bionic_vkCreateDevice(VkPhysicalDevice          physdev,
                       const VkDeviceCreateInfo *ci,
                       const VkAllocationCallbacks *alloc,
                       VkDevice *pDevice)
{
    auto *chain = reinterpret_cast<const VkLayerDeviceCreateInfo *>(ci->pNext);
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                      chain->function == VK_LAYER_LINK_INFO))
        chain = reinterpret_cast<const VkLayerDeviceCreateInfo *>(chain->pNext);
    if (!chain) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next_gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr   next_gdpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    const_cast<VkLayerDeviceCreateInfo *>(chain)->u.pLayerInfo = chain->u.pLayerInfo->pNext;

    auto next_create = reinterpret_cast<PFN_vkCreateDevice>(
        next_gipa(VK_NULL_HANDLE, "vkCreateDevice"));
    if (!next_create) return VK_ERROR_INITIALIZATION_FAILED;

    VkResult r = next_create(physdev, ci, alloc, pDevice);
    if (r != VK_SUCCESS) return r;

    WrapperDeviceInfo info{};
    query_device_caps(physdev, &info);

    WrapperDispatch disp{};
    disp.GetInstanceProcAddr  = next_gipa;
    disp.GetDeviceProcAddr    = next_gdpa;
    disp.DestroyDevice        = reinterpret_cast<PFN_vkDestroyDevice>(
        next_gdpa(*pDevice, "vkDestroyDevice"));
    disp.CreateSwapchainKHR   = reinterpret_cast<PFN_vkCreateSwapchainKHR>(
        next_gdpa(*pDevice, "vkCreateSwapchainKHR"));
    disp.QueuePresentKHR      = reinterpret_cast<PFN_vkQueuePresentKHR>(
        next_gdpa(*pDevice, "vkQueuePresentKHR"));
    disp.CreateShaderModule   = reinterpret_cast<PFN_vkCreateShaderModule>(
        next_gdpa(*pDevice, "vkCreateShaderModule"));
    disp.CmdPipelineBarrier   = reinterpret_cast<PFN_vkCmdPipelineBarrier>(
        next_gdpa(*pDevice, "vkCmdPipelineBarrier"));
    disp.CmdPipelineBarrier2  = reinterpret_cast<PFN_vkCmdPipelineBarrier2>(
        next_gdpa(*pDevice, "vkCmdPipelineBarrier2"));
    disp.CreateImage          = reinterpret_cast<PFN_vkCreateImage>(
        next_gdpa(*pDevice, "vkCreateImage"));

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_dev_info[*pDevice] = info;
        g_dispatch[*pDevice] = disp;
    }
    return VK_SUCCESS;
}

VK_LAYER_EXPORT void VKAPI_CALL
Bionic_vkDestroyDevice(VkDevice device, const VkAllocationCallbacks *alloc)
{
    PFN_vkDestroyDevice next = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        auto it = g_dispatch.find(device);
        if (it != g_dispatch.end()) {
            next = reinterpret_cast<PFN_vkDestroyDevice>(
                it->second.GetDeviceProcAddr(device, "vkDestroyDevice"));
            g_dispatch.erase(it);
            g_dev_info.erase(device);
        }
    }
    if (next) next(device, alloc);
}

VK_LAYER_EXPORT PFN_vkVoidFunction VKAPI_CALL
Bionic_vkGetDeviceProcAddr(VkDevice device, const char *name)
{
    if (strcmp(name, "vkCreateDevice")          == 0) return (PFN_vkVoidFunction)Bionic_vkCreateDevice;
    if (strcmp(name, "vkDestroyDevice")         == 0) return (PFN_vkVoidFunction)Bionic_vkDestroyDevice;
    if (strcmp(name, "vkGetDeviceProcAddr")     == 0) return (PFN_vkVoidFunction)Bionic_vkGetDeviceProcAddr;

    std::lock_guard<std::mutex> lk(g_lock);
    auto it = g_dispatch.find(device);
    if (it == g_dispatch.end()) return nullptr;
    return it->second.GetDeviceProcAddr(device, name);
}

VK_LAYER_EXPORT PFN_vkVoidFunction VKAPI_CALL
Bionic_vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
    if (strcmp(name, "vkCreateDevice")          == 0) return (PFN_vkVoidFunction)Bionic_vkCreateDevice;
    if (strcmp(name, "vkDestroyDevice")         == 0) return (PFN_vkVoidFunction)Bionic_vkDestroyDevice;
    if (strcmp(name, "vkGetDeviceProcAddr")     == 0) return (PFN_vkVoidFunction)Bionic_vkGetDeviceProcAddr;
    if (strcmp(name, "vkGetInstanceProcAddr")   == 0) return (PFN_vkVoidFunction)Bionic_vkGetInstanceProcAddr;
    return nullptr;
}

extern "C" VK_LAYER_EXPORT VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *pVersionStruct)
{
    if (pVersionStruct->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
    if (pVersionStruct->loaderLayerInterfaceVersion > 2) pVersionStruct->loaderLayerInterfaceVersion = 2;
    pVersionStruct->pfnGetInstanceProcAddr = Bionic_vkGetInstanceProcAddr;
    pVersionStruct->pfnGetDeviceProcAddr   = Bionic_vkGetDeviceProcAddr;
    return VK_SUCCESS;
}
