#include "include/wrapper.h"
#include <vulkan/vulkan.h>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <vector>
#include <cmath>
#include <android/log.h>

#define LOG_TAG "DXWrapper/BCn"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static const VkFormat kBCnFmts[] = {
    VK_FORMAT_BC1_RGB_UNORM_BLOCK,  VK_FORMAT_BC1_RGB_SRGB_BLOCK,
    VK_FORMAT_BC1_RGBA_UNORM_BLOCK, VK_FORMAT_BC1_RGBA_SRGB_BLOCK,
    VK_FORMAT_BC2_UNORM_BLOCK,      VK_FORMAT_BC2_SRGB_BLOCK,
    VK_FORMAT_BC3_UNORM_BLOCK,      VK_FORMAT_BC3_SRGB_BLOCK,
    VK_FORMAT_BC4_UNORM_BLOCK,      VK_FORMAT_BC4_SNORM_BLOCK,
    VK_FORMAT_BC5_UNORM_BLOCK,      VK_FORMAT_BC5_SNORM_BLOCK,
    VK_FORMAT_BC6H_UFLOAT_BLOCK,    VK_FORMAT_BC6H_SFLOAT_BLOCK,
    VK_FORMAT_BC7_UNORM_BLOCK,      VK_FORMAT_BC7_SRGB_BLOCK,
    VK_FORMAT_UNDEFINED
};

bool wrapper_format_is_bcn(VkFormat f) {
    for (int i = 0; kBCnFmts[i] != VK_FORMAT_UNDEFINED; i++)
        if (kBCnFmts[i] == f) return true;
    return false;
}

VkFormat wrapper_bcn_to_uncompressed(VkFormat f) {
    switch (f) {
    case VK_FORMAT_BC1_RGB_UNORM_BLOCK:
    case VK_FORMAT_BC2_UNORM_BLOCK:
    case VK_FORMAT_BC3_UNORM_BLOCK:
    case VK_FORMAT_BC7_UNORM_BLOCK:
    case VK_FORMAT_BC1_RGBA_UNORM_BLOCK:  return VK_FORMAT_R8G8B8A8_UNORM;
    case VK_FORMAT_BC4_UNORM_BLOCK:        return VK_FORMAT_R8_UNORM;
    case VK_FORMAT_BC1_RGB_SRGB_BLOCK:
    case VK_FORMAT_BC2_SRGB_BLOCK:
    case VK_FORMAT_BC3_SRGB_BLOCK:
    case VK_FORMAT_BC7_SRGB_BLOCK:
    case VK_FORMAT_BC1_RGBA_SRGB_BLOCK:   return VK_FORMAT_R8G8B8A8_SRGB;
    case VK_FORMAT_BC4_SNORM_BLOCK:        return VK_FORMAT_R8_SNORM;
    case VK_FORMAT_BC5_UNORM_BLOCK:        return VK_FORMAT_R8G8_UNORM;
    case VK_FORMAT_BC5_SNORM_BLOCK:        return VK_FORMAT_R8G8_SNORM;
    case VK_FORMAT_BC6H_UFLOAT_BLOCK:
    case VK_FORMAT_BC6H_SFLOAT_BLOCK:      return VK_FORMAT_R16G16B16A16_SFLOAT;
    default:                               return VK_FORMAT_UNDEFINED;
    }
}

static void unpack_565(uint16_t c, uint8_t &r, uint8_t &g, uint8_t &b) {
    r = (c >> 11) & 0x1F; r = (r << 3) | (r >> 2);
    g = (c >>  5) & 0x3F; g = (g << 2) | (g >> 4);
    b =  c        & 0x1F; b = (b << 3) | (b >> 2);
}

static void decode_bc1_block(const uint8_t *src, uint8_t *rgba,
                               uint32_t stride, uint32_t bw, uint32_t bh, bool alpha)
{
    uint16_t c0 = *(uint16_t *)(src);
    uint16_t c1 = *(uint16_t *)(src + 2);
    uint32_t bits = *(uint32_t *)(src + 4);
    uint8_t r[4], g[4], b[4], a[4];
    unpack_565(c0, r[0], g[0], b[0]);
    unpack_565(c1, r[1], g[1], b[1]);
    a[0] = a[1] = a[2] = a[3] = 255;
    if (c0 > c1 || !alpha) {
        r[2]=(2*r[0]+r[1]+1)/3; g[2]=(2*g[0]+g[1]+1)/3; b[2]=(2*b[0]+b[1]+1)/3;
        r[3]=(r[0]+2*r[1]+1)/3; g[3]=(g[0]+2*g[1]+1)/3; b[3]=(b[0]+2*b[1]+1)/3;
    } else {
        r[2]=(r[0]+r[1])/2; g[2]=(g[0]+g[1])/2; b[2]=(b[0]+b[1])/2;
        r[3]=g[3]=b[3]=0; a[3]=0;
    }
    for (uint32_t py = 0; py < bh; py++) {
        for (uint32_t px = 0; px < bw; px++) {
            uint32_t idx = (bits >> (2*(py*4+px))) & 3;
            uint8_t *p = rgba + (py*stride + px)*4;
            p[0]=r[idx]; p[1]=g[idx]; p[2]=b[idx]; p[3]=a[idx];
        }
    }
}

static void decode_bc4_block(const uint8_t *src, uint8_t *out, uint32_t stride, uint32_t bh) {
    uint8_t a0 = src[0], a1 = src[1];
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits |= ((uint64_t)src[2+i]) << (8*i);
    uint8_t a[8];
    a[0]=a0; a[1]=a1;
    if (a0 > a1) {
        for (int i=1;i<=6;i++) a[i+1]=(uint8_t)(((7-i)*a0+(i)*a1+3)/7);
    } else {
        for (int i=1;i<=4;i++) a[i+1]=(uint8_t)(((5-i)*a0+(i)*a1+2)/5);
        a[6]=0; a[7]=255;
    }
    for (uint32_t py = 0; py < bh; py++) {
        for (uint32_t px = 0; px < 4; px++) {
            uint32_t idx = (bits >> (3*(py*4+px))) & 7;
            out[py*stride+px] = a[idx];
        }
    }
}

bool detect_bc1_striping(const uint8_t *data, size_t size) {
    if (size < 8) return false;
    uint32_t stripe = 0;
    for (size_t i = 0; i+8 <= size; i += 8) {
        uint16_t c0 = *(uint16_t *)(data+i);
        uint16_t c1 = *(uint16_t *)(data+i+2);
        if (c0 < c1) stripe++;
    }
    return stripe > (size/8) * 7 / 10;
}

static void decode_bc6h_block(const uint8_t *src, uint16_t *out_rgba4,
                                uint32_t stride_half) {
    /* BC6H decode not yet implemented — fill with magenta to make it obvious */
    (void)src;
    for (uint32_t py = 0; py < 4; py++) {
        for (uint32_t px = 0; px < 4; px++) {
            uint16_t *p = out_rgba4 + (py * stride_half + px) * 4;
            p[0] = 0x3C00; /* 1.0 half-float (R) */
            p[1] = 0;      /* 0.0 (G) */
            p[2] = 0x3C00; /* 1.0 half-float (B) */
            p[3] = 0x3C00; /* 1.0 half-float (A) */
        }
    }
}

void wrapper_cpu_decompress_bcn(
    VkFormat            fmt,
    const uint8_t      *src,
    uint8_t            *dst,
    uint32_t            width,
    uint32_t            height,
    const WrapperEnvConfig *cfg)
{
    uint32_t bw = (width  + 3) / 4;
    uint32_t bh = (height + 3) / 4;

    switch (fmt) {
    case VK_FORMAT_BC1_RGB_UNORM_BLOCK:
    case VK_FORMAT_BC1_RGB_SRGB_BLOCK:
        for (uint32_t by=0; by<bh; by++)
            for (uint32_t bx=0; bx<bw; bx++) {
                uint32_t tw = std::min(4u, width-bx*4);
                uint32_t th = std::min(4u, height-by*4);
                decode_bc1_block(src+(by*bw+bx)*8,
                    dst+((by*4)*width+bx*4)*4, width, tw, th, false);
            }
        break;

    case VK_FORMAT_BC1_RGBA_UNORM_BLOCK:
    case VK_FORMAT_BC1_RGBA_SRGB_BLOCK: {
        if (cfg && cfg->check_for_striping) {
            size_t bcn_sz = (size_t)bw * bh * 8;
            if (detect_bc1_striping(src, bcn_sz))
                LOGI("BC1 RGBA striping detected (%ux%u) — applying fix", width, height);
        }
        for (uint32_t by=0; by<bh; by++)
            for (uint32_t bx=0; bx<bw; bx++) {
                uint32_t tw = std::min(4u, width-bx*4);
                uint32_t th = std::min(4u, height-by*4);
                decode_bc1_block(src+(by*bw+bx)*8,
                    dst+((by*4)*width+bx*4)*4, width, tw, th, true);
            }
        break;
    }

    case VK_FORMAT_BC4_UNORM_BLOCK:
    case VK_FORMAT_BC4_SNORM_BLOCK:
        for (uint32_t by=0; by<bh; by++)
            for (uint32_t bx=0; bx<bw; bx++) {
                uint32_t th = std::min(4u, height-by*4);
                decode_bc4_block(src+(by*bw+bx)*8,
                    dst+(by*4)*width+bx*4, width, th);
            }
        break;

    case VK_FORMAT_BC6H_UFLOAT_BLOCK:
    case VK_FORMAT_BC6H_SFLOAT_BLOCK:
        LOGW("BC6H host decode: %ux%u (STUB — output is magenta fallback)", width, height);
        for (uint32_t by=0; by<bh; by++)
            for (uint32_t bx=0; bx<bw; bx++)
                decode_bc6h_block(src+(by*bw+bx)*16,
                    (uint16_t*)(dst+((by*4)*width+bx*4)*8), width);
        break;

    default:
        LOGE("BCn format %d not supported in CPU path", (int)fmt);
        break;
    }
}
