#include "../Renderer/Shared.h"

inline float3 toneMap(float3 x) {
    return clamp((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f), 0.0f, 1.0f);
}

kernel void displayImage(constant PTWork &w [[buffer(1)]],
                         constant PTFrame &f [[buffer(2)]],
                         texture2d<float, access::write> output [[texture(0)]],
                         uint2 id [[thread_position_in_grid]]) {
    if (id.x >= output.get_width() || id.y >= output.get_height())
        return;
    uint2 p = min(uint2(float2(id) * float2(f.size.xy) / float2(output.get_width(), output.get_height())),
                  f.size.xy - 1);
    float3 rgb = w.accumulation[p.y * f.size.x + p.x].xyz * exp2(f.display.x);
    rgb = float3(dot(f.whiteBalanceR.xyz, rgb), dot(f.whiteBalanceG.xyz, rgb), dot(f.whiteBalanceB.xyz, rgb));
    rgb = max(rgb, 0.0f);
    uint mode = uint(f.whiteBalanceR.w);
    if (mode == 0) {
        rgb = toneMap(rgb);
    } else if (mode == 1) {
        float luminance = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
        rgb /= 1 + luminance;
        // Compress toward neutral at fixed luminance to fit the SDR gamut without channel clipping.
        float gray = luminance / (1 + luminance);
        float peak = max(rgb.x, max(rgb.y, rgb.z));
        if (peak > 1) {
            rgb = gray + (rgb - gray) * ((1 - gray) / (peak - gray));
        }
    }
    rgb = clamp(rgb, 0.0f, 1.0f);
    // Drawable is non-sRGB BGRA8; encode exactly once here.
    rgb = select(1.055f * pow(rgb, float3(1 / 2.4f)) - 0.055f, 12.92f * rgb, rgb <= 0.0031308f);
    output.write(float4(rgb, 1), id);
}
