#pragma once
#include "../Renderer/Shared.h"
constant float CIE_Y_INTEGRAL = 106.856895f;

inline float4 lookup(device const float4 *table, float4 lambda, uint component) {
    float4 result;
    for (uint i = 0; i < 4; i++) {
        float x = clamp(lambda[i] - 360, 0.0f, 470.0f);
        uint j = min(uint(x), 469u);
        result[i] = mix(table[j][component], table[j + 1][component], x - float(j));
    }
    return result;
}

inline float3
toXYZ(float4 value, float4 lambda, constant PTScene &scene, float4 wavelengthPDF = float4(1.0f / 470)) {
    value = select(value / max(wavelengthPDF, 1e-30f), float4(0), wavelengthPDF == 0);
    return float3(dot(value, lookup(scene.cie, lambda, 0)),
                  dot(value, lookup(scene.cie, lambda, 1)),
                  dot(value, lookup(scene.cie, lambda, 2))) *
           (1.0f / (4 * CIE_Y_INTEGRAL));
}

// Original, bounded analytic pigment basis, not an RGB colorimetric upsampling algorithm.
inline float4 rgbSpectrum(float3 coefficients, float4 lambda) {
    float4 r = exp(-0.5f * pow((lambda - 610) / 45, 2.0f));
    float4 g = exp(-0.5f * pow((lambda - 545) / 38, 2.0f));
    float4 b = exp(-0.5f * pow((lambda - 450) / 30, 2.0f));
    float low = min(coefficients.x, min(coefficients.y, coefficients.z));
    return clamp(low + (coefficients.x - low) * r + (coefficients.y - low) * g + (coefficients.z - low) * b,
                 0.0f,
                 1.0f);
}

inline float4 reflectance(float3 coefficients, float4 lambda) {
    return min(rgbSpectrum(coefficients, lambda), float4(0.98f));
}

// Nonnegative approximate RGB emission upsampling; no unique measured spectrum is implied.
inline float4 emissionSpectrum(float3 rgb, float4 lambda) {
    float scale = max(rgb.x, max(rgb.y, rgb.z));
    return scale > 0 ? rgbSpectrum(rgb / scale, lambda) * scale : float4(0);
}

inline float bk7(float nm) {
    float l2 = nm * nm * 1e-6f;
    return sqrt(1 + 1.03961212f * l2 / (l2 - 0.00600069867f) + 0.231792344f * l2 / (l2 - 0.0200179144f) +
                1.01046945f * l2 / (l2 - 103.560653f));
}
