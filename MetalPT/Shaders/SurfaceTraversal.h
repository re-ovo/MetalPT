#pragma once
#include "Sampling.h"
#include "SurfaceGeometry.h"

// Half-open ownership prevents adjacent triangles from applying alpha twice on an exact shared edge.
// Positions (rather than vertex indices) also handle duplicated seam vertices in imported primitives.
inline bool orderedEndpoint(float3 a, float3 b) {
    if (a.x != b.x)
        return a.x < b.x;
    if (a.y != b.y)
        return a.y < b.y;
    return a.z < b.z;
}

inline bool ownsBoundary(constant PTScene &s, uint instanceID, uint primitiveID, float2 uv) {
    float3 bary = float3(1 - uv.x - uv.y, uv);
    if (all(bary != 0))
        return true;
    PTMesh mesh = s.meshes[s.instances[instanceID].indices.x];
    uint4 indices = mesh.triangles[primitiveID].indices;
    float3 a = mesh.vertices[indices.x].position.xyz;
    float3 b = mesh.vertices[indices.y].position.xyz;
    float3 c = mesh.vertices[indices.z].position.xyz;
    return (bary.x != 0 || orderedEndpoint(b, c)) && (bary.y != 0 || orderedEndpoint(c, a)) &&
           (bary.z != 0 || orderedEndpoint(a, b));
}

enum class SurfaceTraceMode {
    stochasticCoverage,
    denoiseGuide
};

inline PTHit traceSurface(constant PTScene &s,
                          ray r,
                          uint seed,
                          SurfaceTraceMode mode = SurfaceTraceMode::stochasticCoverage) {
    intersection_params params;
    params.assume_geometry_type(geometry_type::triangle);
    params.force_opacity(forced_opacity::non_opaque);
    intersection_query<triangle_data, instancing> query(r, s.acceleration, 255, params);
    while (query.next()) {
        uint instance = query.get_candidate_instance_id(), primitive = query.get_candidate_primitive_id();
        if (!ownsBoundary(s, instance, primitive, query.get_candidate_triangle_barycentric_coord()))
            continue;
        PTHit candidate = surfaceHit(s,
                                     instance,
                                     primitive,
                                     query.get_candidate_triangle_barycentric_coord(),
                                     query.get_candidate_triangle_distance(),
                                     r.direction);
        PTMaterial material = s.materials[candidate.info.x];
        float coverage = surfaceCoverage(s, material, candidate);
        // Per-face random decisions are independent of hardware traversal order.
        uint rng = seed ^ (instance * 0x9e3779b9u) ^ (primitive * 0x85ebca6bu);
        // Guides must see nonzero BLEND foreground consistently; transport retains stochastic coverage.
        bool accepted = mode == SurfaceTraceMode::denoiseGuide
                            ? coverage > 0
                            : (coverage == 1 || (coverage > 0 && random(rng) < coverage));
        if (acceptsSide(material, candidate) && accepted)
            query.commit_triangle_intersection();
    }
    PTHit hit = {};
    hit.info.x = 0xffffffffu;
    if (query.get_committed_intersection_type() != intersection_type::none)
        hit = surfaceHit(s,
                         query.get_committed_instance_id(),
                         query.get_committed_primitive_id(),
                         query.get_committed_triangle_barycentric_coord(),
                         query.get_committed_distance(),
                         r.direction);
    return hit;
}

inline float traceVisibility(constant PTScene &s, ray r) {
    intersection_params params;
    params.assume_geometry_type(geometry_type::triangle);
    params.force_opacity(forced_opacity::non_opaque);
    intersection_query<triangle_data, instancing> query(r, s.acceleration, 255, params);
    float transmittance = 1;
    while (query.next()) {
        if (!ownsBoundary(s,
                          query.get_candidate_instance_id(),
                          query.get_candidate_primitive_id(),
                          query.get_candidate_triangle_barycentric_coord()))
            continue;
        PTHit hit = surfaceHit(s,
                               query.get_candidate_instance_id(),
                               query.get_candidate_primitive_id(),
                               query.get_candidate_triangle_barycentric_coord(),
                               query.get_candidate_triangle_distance(),
                               r.direction);
        PTMaterial material = s.materials[hit.info.x];
        if (acceptsSide(material, hit)) {
            transmittance *= 1 - surfaceCoverage(s, material, hit);
            if (transmittance == 0) {
                query.abort();
                break;
            }
        }
    }
    return transmittance;
}
