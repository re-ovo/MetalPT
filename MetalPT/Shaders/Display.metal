#include "../Renderer/Shared.h"

float3 toneMap(float3 x) {
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
    float3 rgb = toneMap(max(0.0f, w.accumulation[p.y * f.size.x + p.x].xyz) * exp2(f.display.x));
    // Drawable is non-sRGB BGRA8; encode exactly once here.
    rgb = select(1.055f * pow(rgb, float3(1 / 2.4f)) - 0.055f, 12.92f * rgb, rgb <= 0.0031308f);
    output.write(float4(rgb, 1), id);
}
