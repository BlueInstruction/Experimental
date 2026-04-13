#include "include/wrapper.h"
#include <vulkan/vulkan.h>
#include <cstring>
#include <algorithm>
#include <android/log.h>

#define LOG_TAG "DXWrapper/Present"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

extern WrapperEnvConfig g_cfg;

static const char *present_mode_str(VkPresentModeKHR m) {
    switch (m) {
    case VK_PRESENT_MODE_IMMEDIATE_KHR:    return "IMMEDIATE";
    case VK_PRESENT_MODE_MAILBOX_KHR:      return "MAILBOX";
    case VK_PRESENT_MODE_FIFO_KHR:         return "FIFO";
    case VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "FIFO_RELAXED";
    default:                                return "UNKNOWN";
    }
}

VkResult wrapper_create_swapchain(
    VkDevice                            device,
    const VkSwapchainCreateInfoKHR     *ci,
    const VkAllocationCallbacks        *alloc,
    VkSwapchainKHR                     *pSwapchain,
    PFN_vkCreateSwapchainKHR            next_fn)
{
    VkSwapchainCreateInfoKHR patched = *ci;

    LOGI("Swapchain request: min=%u mode=%s format=%d",
         patched.minImageCount,
         present_mode_str(patched.presentMode),
         (int)patched.imageFormat);

    if (g_cfg.force_fifo) {
        patched.presentMode = VK_PRESENT_MODE_FIFO_KHR;
        LOGI("Force FIFO present mode");
    }

    if (patched.presentMode == VK_PRESENT_MODE_IMMEDIATE_KHR) {
        LOGI("IMMEDIATE mode: forcing minImageCount=1");
        patched.minImageCount = 1;
    } else {
        uint32_t cap = g_cfg.max_image_count;
        if (cap > 0 && patched.minImageCount > cap) {
            LOGI("Clamping minImageCount %u -> %u", patched.minImageCount, cap);
            patched.minImageCount = cap;
        }
    }

    return next_fn(device, &patched, alloc, pSwapchain);
}

VkResult wrapper_queue_present(
    VkQueue                     queue,
    const VkPresentInfoKHR     *pi,
    PFN_vkQueuePresentKHR       next_fn)
{
    return next_fn(queue, pi);
}
