#pragma once
#include "MaterialTextures.h"

inline float3 safeNormal(float3 v, float3 fallback) {
    float magnitude = dot(v, v);
    return magnitude > 1e-20f && isfinite(magnitude) ? v * rsqrt(magnitude) : fallback;
}

inline PTHit surfaceHit(constant PTScene &s,
                        uint instanceID,
                        uint primitiveID,
                        float2 coordinates,
                        float distance,
                        float3 direction) {
    PTInstance instance = s.instances[instanceID];
    PTMesh mesh = s.meshes[instance.indices.x];
    uint4 tri = mesh.triangles[primitiveID].indices;
    PTVertex a = mesh.vertices[tri.x], b = mesh.vertices[tri.y], c = mesh.vertices[tri.z];
    float3 bary = float3(1 - coordinates.x - coordinates.y, coordinates);
    float4x4 transform(
        instance.transform[0], instance.transform[1], instance.transform[2], instance.transform[3]);
    float3x3 linear(transform[0].xyz, transform[1].xyz, transform[2].xyz);
    float determinant = dot(linear[0], cross(linear[1], linear[2]));
    float3x3 normalMatrix(cross(linear[1], linear[2]) / determinant,
                          cross(linear[2], linear[0]) / determinant,
                          cross(linear[0], linear[1]) / determinant);
    float3 p0 = (transform * a.position).xyz, p1 = (transform * b.position).xyz,
           p2 = (transform * c.position).xyz;
    // A mirrored instance changes winding; the outward normal follows inverse-transpose instead.
    float3 ng = safeNormal(cross(p1 - p0, p2 - p0) * sign(determinant), float3(0, 1, 0));
    uint attributes = a.attributes.x & b.attributes.x & c.attributes.x;
    float3 ns =
        (attributes & 1)
            ? safeNormal(
                  normalMatrix * (a.normal.xyz * bary.x + b.normal.xyz * bary.y + c.normal.xyz * bary.z), ng)
            : ng;
    if (dot(ns, ng) < 0)
        ns = -ns;
    PTHit result = {};
    result.position = float4(p0 * bary.x + p1 * bary.y + p2 * bary.z, distance);
    result.normal = float4(ng, 0);
    result.uv = a.uv * bary.x + b.uv * bary.y + c.uv * bary.z;
    result.color = attributes & 16 ? a.color * bary.x + b.color * bary.y + c.color * bary.z : float4(1);
    uint material = instance.materials[tri.w];
    PTMaterial m = s.materials[material];
    if (m.normalTexture.indices.w) {
        float3 tangent, bitangent;
        PTTextureBinding binding = m.normalTexture;
        bool nativeFrame = (attributes & 2) && binding.indices.z == 0 && binding.rotationLOD.y == 0 &&
                           all(binding.transform.zw == float2(1));
        if (nativeFrame) {
            float4 localTangent = a.tangent * bary.x + b.tangent * bary.y + c.tangent * bary.z;
            tangent = linear * localTangent.xyz;
            tangent = safeNormal(tangent - ns * dot(ns, tangent), float3(0));
            bitangent = cross(ns, tangent) * sign(localTangent.w) * sign(determinant);
        } else {
            float2 uv0 = textureUV(binding, a.uv), uv1 = textureUV(binding, b.uv),
                   uv2 = textureUV(binding, c.uv);
            float2 d1 = uv1 - uv0, d2 = uv2 - uv0;
            float uvDet = d1.x * d2.y - d1.y * d2.x;
            tangent = abs(uvDet) > 1e-12f ? ((p1 - p0) * d2.y - (p2 - p0) * d1.y) / uvDet : float3(0);
            bitangent = abs(uvDet) > 1e-12f ? ((p2 - p0) * d1.x - (p1 - p0) * d2.x) / uvDet : float3(0);
            tangent = safeNormal(tangent - ns * dot(ns, tangent), float3(0));
            bitangent = cross(ns, tangent) * (dot(cross(ns, tangent), bitangent) < 0 ? -1.0f : 1.0f);
        }
        if (dot(tangent, tangent) > 0) {
            float3 normal = sampleTexture(s, binding, result.uv, false).xyz * 2 - 1;
            normal.xy *= m.optics.z;
            float3 mapped = safeNormal(tangent * normal.x + bitangent * normal.y + ns * normal.z, ns);
            if (dot(mapped, ng) > 1e-5f)
                ns = mapped;
        }
        result.tangent = float4(tangent, 0);
    }
    result.shadingNormal = float4(ns, 0);
    result.info = uint4(material, instance.indices.z, dot(ng, direction) < 0, instanceID);
    return result;
}

inline bool acceptsSide(PTMaterial material, PTHit hit) {
    // Ideal glass models a closed interface: exiting rays must also see its back face.
    return hit.info.z || material.flags.z || material.flags.x == 2;
}
