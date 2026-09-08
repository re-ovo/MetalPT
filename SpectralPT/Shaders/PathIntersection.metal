#include "PathQueue.h"

kernel void intersectPaths(constant PTScene &s [[buffer(0)]],
                           constant PTWork &w [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= inputCount(w))
        return;
    PTPath p = w.inputPaths[id];
    ray r(p.origin.xyz, p.direction.xyz, 0.0f, INFINITY);
    intersector<triangle_data, instancing> query;
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    auto hit = query.intersect(r, s.acceleration, 255);
    PTHit h = {};
    h.info.x = 0xffffffffu;
    if (hit.type != intersection_type::none) {
        uint4 tri = s.triangles[hit.primitive_id].indices;
        PTVertex a = s.vertices[tri.x], b = s.vertices[tri.y], c = s.vertices[tri.z];
        float3 bary = float3(1 - hit.triangle_barycentric_coord.x - hit.triangle_barycentric_coord.y,
                             hit.triangle_barycentric_coord);
        float3 ng = normalize(cross(b.position.xyz - a.position.xyz, c.position.xyz - a.position.xyz));
        // Use geometric normals for the tessellated primitives, keeping transmission boundaries consistent.
        h.position = float4(p.origin.xyz + p.direction.xyz * hit.distance, hit.distance);
        h.normal = float4(ng, 0);
        h.uv = a.uv * bary.x + b.uv * bary.y + c.uv * bary.z;
        h.info = uint4(tri.w, hit.primitive_id, dot(ng, p.direction.xyz) < 0, 0);
    }
    w.hits[id] = h;
}
