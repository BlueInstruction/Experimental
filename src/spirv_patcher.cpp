#include "include/wrapper.h"
#include <vulkan/vulkan.h>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <android/log.h>

#define LOG_TAG "DXWrapper/SPIRV"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

#define SPIRV_MAGIC                 0x07230203u
#define SPIRV_OP_NOP                1u
#define SPIRV_OP_CAPABILITY         17u
#define SPIRV_OP_DECORATE           71u
#define SPIRV_OP_MEMBER_DECORATE    72u

#define SPIRV_CAP_CLIP_DISTANCE     32u
#define SPIRV_CAP_CULL_DISTANCE     33u
#define SPIRV_DECO_BUILT_IN         11u
#define SPIRV_BUILTIN_CLIP_DISTANCE 3u
#define SPIRV_BUILTIN_CULL_DISTANCE 4u
#define SPIRV_DECO_RELAXED_PRECISION 0u

struct WrapperPatchedSPIRV {
    std::vector<uint32_t> words;
    bool patched;
};

static inline uint32_t op(uint32_t w)   { return w & 0xFFFFu; }
static inline uint32_t len(uint32_t w)  { return w >> 16u;    }
static inline uint32_t make_nop(uint32_t l) { return (l << 16u) | SPIRV_OP_NOP; }

static bool spirv_valid(const uint32_t *w, size_t cnt) {
    return cnt >= 5 && w[0] == SPIRV_MAGIC;
}

static bool spirv_uses_clip_cull(const uint32_t *w, size_t cnt) {
    size_t i = 5;
    while (i < cnt) {
        uint32_t wrd = w[i];
        uint32_t l   = len(wrd);
        if (l == 0 || i + l > cnt) break;
        uint32_t o = op(wrd);
        if (o == SPIRV_OP_CAPABILITY && l >= 2) {
            uint32_t cap = w[i+1];
            if (cap == SPIRV_CAP_CLIP_DISTANCE || cap == SPIRV_CAP_CULL_DISTANCE) return true;
        }
        /* OpDecorate: word layout is [op|len] [target] [decoration] [extra...]
           OpMemberDecorate: [op|len] [struct] [member] [decoration] [extra...]
           BuiltIn decoration (11) has one extra operand: the BuiltIn value */
        if (o == SPIRV_OP_DECORATE && l >= 4 && w[i+2] == SPIRV_DECO_BUILT_IN) {
            uint32_t builtin = w[i+3];
            if (builtin == SPIRV_BUILTIN_CLIP_DISTANCE || builtin == SPIRV_BUILTIN_CULL_DISTANCE)
                return true;
        }
        if (o == SPIRV_OP_MEMBER_DECORATE && l >= 5 && w[i+3] == SPIRV_DECO_BUILT_IN) {
            uint32_t builtin = w[i+4];
            if (builtin == SPIRV_BUILTIN_CLIP_DISTANCE || builtin == SPIRV_BUILTIN_CULL_DISTANCE)
                return true;
        }
        i += l;
    }
    return false;
}

static void spirv_nop_range(uint32_t *w, size_t start, size_t l) {
    w[start] = make_nop(l);
    for (size_t j = 1; j < l; j++) w[start+j] = 0;
}

static bool spirv_strip_clip_cull(std::vector<uint32_t> &words) {
    bool patched = false;
    size_t i = 5;
    while (i < words.size()) {
        uint32_t wrd = words[i];
        uint32_t l   = len(wrd);
        if (l == 0 || i + l > words.size()) break;
        uint32_t o = op(wrd);
        bool strip = false;
        if (o == SPIRV_OP_CAPABILITY && l >= 2) {
            uint32_t cap = words[i+1];
            strip = (cap == SPIRV_CAP_CLIP_DISTANCE || cap == SPIRV_CAP_CULL_DISTANCE);
        }
        if (o == SPIRV_OP_DECORATE && l >= 4 && words[i+2] == SPIRV_DECO_BUILT_IN) {
            uint32_t builtin = words[i+3];
            strip = (builtin == SPIRV_BUILTIN_CLIP_DISTANCE || builtin == SPIRV_BUILTIN_CULL_DISTANCE);
        }
        if (o == SPIRV_OP_MEMBER_DECORATE && l >= 5 && words[i+3] == SPIRV_DECO_BUILT_IN) {
            uint32_t builtin = words[i+4];
            strip = (builtin == SPIRV_BUILTIN_CLIP_DISTANCE || builtin == SPIRV_BUILTIN_CULL_DISTANCE);
        }
        if (strip) {
            LOGD("NOP word[%zu] op=%u len=%u", i, o, l);
            spirv_nop_range(words.data(), i, l);
            patched = true;
        }
        i += l;
    }
    return patched;
}

static bool spirv_strip_relaxed_precision(std::vector<uint32_t> &words) {
    bool patched = false;
    size_t i = 5;
    while (i < words.size()) {
        uint32_t wrd = words[i];
        uint32_t l   = len(wrd);
        if (l == 0 || i + l > words.size()) break;
        uint32_t o = op(wrd);
        if (o == SPIRV_OP_DECORATE && l >= 3 &&
            words[i+2] == SPIRV_DECO_RELAXED_PRECISION)
        {
            spirv_nop_range(words.data(), i, l);
            patched = true;
        }
        i += l;
    }
    return patched;
}

bool wrapper_patch_shader(
    const WrapperDeviceInfo     *info,
    const WrapperEnvConfig      *cfg,
    const uint32_t              *spirv_in,
    size_t                       size_bytes,
    WrapperPatchedSPIRV         *out)
{
    size_t cnt = size_bytes / sizeof(uint32_t);
    if (!spirv_valid(spirv_in, cnt)) { out->patched = false; return false; }

    out->words.assign(spirv_in, spirv_in + cnt);
    out->patched = false;

    bool do_strip_clip = false;
    if (cfg && cfg->disable_clip_distance) {
        do_strip_clip = true;
    } else if (info && info->vendor == GPU_VENDOR_MALI && !info->supports_clip_distance) {
        do_strip_clip = !(cfg && cfg->force_clip_distance);
    }

    if (do_strip_clip && spirv_uses_clip_cull(out->words.data(), cnt)) {
        LOGI("Stripping ClipDistance/CullDistance from shader");
        out->patched |= spirv_strip_clip_cull(out->words);
    }

    return out->patched;
}

void wrapper_free_patched_spirv(WrapperPatchedSPIRV *p) {
    p->words.clear();
    p->words.shrink_to_fit();
    p->patched = false;
}

VkResult wrapper_create_shader_module(
    VkDevice                            device,
    const VkShaderModuleCreateInfo     *ci,
    const VkAllocationCallbacks        *alloc,
    VkShaderModule                     *pModule,
    const WrapperDeviceInfo            *info,
    const WrapperEnvConfig             *cfg,
    PFN_vkCreateShaderModule            next_fn)
{
    if (!ci || !ci->pCode || ci->codeSize < 20 || ci->pCode[0] != SPIRV_MAGIC)
        return next_fn(device, ci, alloc, pModule);

    WrapperPatchedSPIRV patched;
    if (wrapper_patch_shader(info, cfg, ci->pCode, ci->codeSize, &patched) && patched.patched) {
        VkShaderModuleCreateInfo p_ci = *ci;
        p_ci.pCode    = patched.words.data();
        p_ci.codeSize = patched.words.size() * sizeof(uint32_t);
        VkResult r    = next_fn(device, &p_ci, alloc, pModule);
        wrapper_free_patched_spirv(&patched);
        return r;
    }

    return next_fn(device, ci, alloc, pModule);
}
