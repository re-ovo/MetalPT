#pragma once
#include "../Renderer/Shared.h"
constant float PI = 3.14159265358979323846f;

inline uint hash32(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    return x ^ (x >> 16);
}

inline float random(thread uint &s) {
    s = s * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return float(((w >> 22u) ^ w) >> 8u) * 0x1p-24f;
}

inline float powerMIS(float a, float b) {
    return a * a / max(a * a + b * b, 1e-30f);
}

inline float3 localToWorld(float3 v, float3 n) {
    float3 t = normalize(cross(abs(n.z) < 0.999f ? float3(0, 0, 1) : float3(0, 1, 0), n));
    return v.x * t + v.y * cross(n, t) + v.z * n;
}

inline float3 offsetPoint(float3 p, float3 n, float3 d) {
    // Scale-aware offset. Scene units are metres; preserve the selected side at grazing angles.
    return p + (dot(n, d) >= 0 ? n : -n) * (2e-5f * max(1.0f, max(abs(p.x), max(abs(p.y), abs(p.z)))));
}
