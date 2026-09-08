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
        PTInstance instance = s.instances[hit.instance_id];
        PTMesh mesh = s.meshes[instance.indices.x];
        uint4 tri = mesh.triangles[hit.primitive_id].indices;
        PTVertex a = mesh.vertices[tri.x], b = mesh.vertices[tri.y], c = mesh.vertices[tri.z];
        float4x4 transform(
            instance.transform[0], instance.transform[1], instance.transform[2], instance.transform[3]);
        a.position = transform * a.position;
        b.position = transform * b.position;
        c.position = transform * c.position;
        tri.w = instance.materials[tri.w];
        float3 bary = float3(1 - hit.triangle_barycentric_coord.x - hit.triangle_barycentric_coord.y,
                             hit.triangle_barycentric_coord);
        float3 ng = normalize(cross(b.position.xyz - a.position.xyz, c.position.xyz - a.position.xyz));
        // Use geometric normals for the tessellated primitives, keeping transmission boundaries consistent.
        h.position = float4(p.origin.xyz + p.direction.xyz * hit.distance, hit.distance);
        h.normal = float4(ng, 0);
        h.uv = a.uv * bary.x + b.uv * bary.y + c.uv * bary.z;
        h.info = uint4(tri.w, instance.indices.z, dot(ng, p.direction.xyz) < 0, hit.instance_id);
    }
    w.hits[id] = h;
}
