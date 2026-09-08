#include "PathQueue.h"

kernel void traceShadows(constant PTScene &s [[buffer(0)]],
                         constant PTWork &w [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    if (id >= atomic_load_explicit(w.counts + 2, memory_order_relaxed))
        return;
    PTShadow sh = w.shadows[id];
    intersector<triangle_data, instancing> query;
    query.assume_geometry_type(geometry_type::triangle);
    query.force_opacity(forced_opacity::opaque);
    query.accept_any_intersection(true);
    auto hit =
        query.intersect(ray(sh.origin.xyz, sh.direction.xyz, 0.0f, sh.direction.w), s.acceleration, 255);
    if (hit.type == intersection_type::none)
        addContribution(w, sh.info.x, sh.contribution.xyz);
}
