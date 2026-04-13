#version 450
#extension GL_EXT_shader_explicit_arithmetic_types_int8  : require
#extension GL_EXT_shader_explicit_arithmetic_types_int16 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int32 : require

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly buffer InBuffer {
    uint data[];
} u_in;

layout(set = 0, binding = 1) writeonly buffer OutBuffer {
    uint data[];
} u_out;

layout(push_constant) uniform PushConstants {
    uint width;
    uint height;
    uint src_offset;
    uint dst_offset;
    uint mode;
} pc;

#define MODE_BC1_RGB   0u
#define MODE_BC1_RGBA  1u
#define MODE_BC3       2u
#define MODE_BC4       3u
#define MODE_BC5       4u

uvec4 unpack_rgba8(uint v) {
    return uvec4(v & 0xFFu, (v >> 8u) & 0xFFu, (v >> 16u) & 0xFFu, (v >> 24u) & 0xFFu);
}

uint pack_rgba8(uvec4 c) {
    return (c.r & 0xFFu) | ((c.g & 0xFFu) << 8u) |
           ((c.b & 0xFFu) << 16u) | ((c.a & 0xFFu) << 24u);
}

uvec3 unpack_rgb565(uint c) {
    uint r = (c >> 11u) & 0x1Fu; r = (r << 3u) | (r >> 2u);
    uint g = (c >>  5u) & 0x3Fu; g = (g << 2u) | (g >> 4u);
    uint b =  c         & 0x1Fu; b = (b << 3u) | (b >> 2u);
    return uvec3(r, g, b);
}

void decode_bc1(uint block_idx, bool has_alpha,
                out uvec4 pixels[16])
{
    uint base = pc.src_offset + block_idx * 2u;
    uint w0   = u_in.data[base];
    uint w1   = u_in.data[base + 1u];

    uint c0_raw = w0 & 0xFFFFu;
    uint c1_raw = (w0 >> 16u) & 0xFFFFu;
    uint bits   = w1;

    uvec3 c0 = unpack_rgb565(c0_raw);
    uvec3 c1 = unpack_rgb565(c1_raw);
    uvec3 colors[4];
    uint  alphas[4];

    colors[0] = c0; alphas[0] = 255u;
    colors[1] = c1; alphas[1] = 255u;

    if (c0_raw > c1_raw || !has_alpha) {
        colors[2] = (2u*c0 + c1 + 1u) / 3u;
        colors[3] = (c0 + 2u*c1 + 1u) / 3u;
        alphas[2] = alphas[3] = 255u;
    } else {
        colors[2] = (c0 + c1) / 2u;
        colors[3] = uvec3(0u);
        alphas[2] = 255u;
        alphas[3] = 0u;
    }

    for (int i = 0; i < 16; i++) {
        uint idx = (bits >> (2u * uint(i))) & 3u;
        pixels[i] = uvec4(colors[idx], alphas[idx]);
    }
}

void decode_bc4(uint block_idx, out uint vals[16]) {
    uint base = pc.src_offset + block_idx * 2u;
    uint w0 = u_in.data[base];
    uint w1 = u_in.data[base + 1u];

    uint a0 = w0 & 0xFFu;
    uint a1 = (w0 >> 8u) & 0xFFu;

    uint bits_lo = (w0 >> 16u) | (w1 << 16u);
    uint bits_hi = w1 >> 16u;

    uint alpha[8];
    alpha[0] = a0; alpha[1] = a1;
    if (a0 > a1) {
        for (int i = 1; i < 6; i++)
            alpha[i+1] = ((6u - uint(i))*a0 + uint(i)*a1 + 3u) / 7u;
    } else {
        for (int i = 1; i < 4; i++)
            alpha[i+1] = ((4u - uint(i))*a0 + uint(i)*a1 + 2u) / 5u;
        alpha[6] = 0u;
        alpha[7] = 255u;
    }

    for (int i = 0; i < 16; i++) {
        uint bit_offset = uint(i) * 3u;
        uint idx;
        if (bit_offset < 16u)
            idx = (bits_lo >> bit_offset) & 7u;
        else
            idx = (bits_hi >> (bit_offset - 16u)) & 7u;
        vals[i] = alpha[idx];
    }
}

void main() {
    uint bx = gl_GlobalInvocationID.x;
    uint by = gl_GlobalInvocationID.y;
    uint bw = (pc.width  + 3u) / 4u;
    uint bh = (pc.height + 3u) / 4u;

    if (bx >= bw || by >= bh) return;

    uint block_idx = by * bw + bx;

    if (pc.mode == MODE_BC1_RGB || pc.mode == MODE_BC1_RGBA) {
        uvec4 pixels[16];
        decode_bc1(block_idx, pc.mode == MODE_BC1_RGBA, pixels);

        for (uint py = 0u; py < 4u; py++) {
            for (uint px = 0u; px < 4u; px++) {
                uint wx = bx*4u + px;
                uint wy = by*4u + py;
                if (wx >= pc.width || wy >= pc.height) continue;
                uint dst = pc.dst_offset + (wy * pc.width + wx);
                u_out.data[dst] = pack_rgba8(pixels[py*4u + px]);
            }
        }
    }
    else if (pc.mode == MODE_BC4) {
        uint vals[16];
        decode_bc4(block_idx, vals);

        for (uint py = 0u; py < 4u; py++) {
            for (uint px = 0u; px < 4u; px++) {
                uint wx = bx*4u + px;
                uint wy = by*4u + py;
                if (wx >= pc.width || wy >= pc.height) continue;
                uint dst = pc.dst_offset + (wy * pc.width + wx);
                uint v = vals[py*4u + px];
                u_out.data[dst] = pack_rgba8(uvec4(v, 0u, 0u, 255u));
            }
        }
    }
    else if (pc.mode == MODE_BC5) {
        uint r_vals[16];
        uint g_vals[16];
        decode_bc4(block_idx * 2u + 0u, r_vals);
        decode_bc4(block_idx * 2u + 1u, g_vals);

        for (uint py = 0u; py < 4u; py++) {
            for (uint px = 0u; px < 4u; px++) {
                uint wx = bx*4u + px;
                uint wy = by*4u + py;
                if (wx >= pc.width || wy >= pc.height) continue;
                uint dst = pc.dst_offset + (wy * pc.width + wx);
                u_out.data[dst] = pack_rgba8(
                    uvec4(r_vals[py*4u+px], g_vals[py*4u+px], 0u, 255u));
            }
        }
    }
}
