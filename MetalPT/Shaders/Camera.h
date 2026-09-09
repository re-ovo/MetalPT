#pragma once
#include "Sampling.h"

inline ray cameraRay(constant PTFrame &f, float2 pixel, float2 lensSample) {
    float2 uv = pixel / float2(f.size.xy) * 2 - 1;
    uv.y = -uv.y;
    float3 origin = f.eye.xyz;
    float3 direction = normalize(f.forward.xyz + f.right.xyz * uv.x + f.up.xyz * uv.y);
    if (f.lens.x > 0) {
        // Uniform aperture PDF cancels normalized lens response; exposure is independent.
        float radius = f.lens.x * sqrt(lensSample.x);
        float angle = 2 * M_PI_F * lensSample.y;
        float3 offset = radius * (cos(angle) * normalize(f.right.xyz) + sin(angle) * normalize(f.up.xyz));
        float3 focus = origin + direction * (f.lens.y / dot(direction, f.forward.xyz));
        origin += offset;
        direction = normalize(focus - origin);
    }
    return ray(origin, direction);
}
