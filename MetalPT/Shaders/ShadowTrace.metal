#include "PathQueue.h"
#include "SurfaceTraversal.h"

kernel void traceShadows(constant PTScene &s [[buffer(0)]],
                         constant PTWork &w [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
    if (id >= atomic_load_explicit(w.counts + 2, memory_order_relaxed))
        return;
    PTShadow sh = w.shadows[id];
    float transmittance = traceVisibility(s, ray(sh.origin.xyz, sh.direction.xyz, 0.0f, sh.direction.w));
    if (transmittance > 0)
        addContribution(w, sh.info.x, sh.contribution.xyz * transmittance);
}
