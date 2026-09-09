#include "PathQueue.h"
#include "SurfaceTraversal.h"

kernel void intersectPaths(constant PTScene &s [[buffer(0)]],
                           constant PTWork &w [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= inputCount(w))
        return;
    PTPath p = w.inputPaths[id];
    w.hits[id] = traceSurface(s, ray(p.origin.xyz, p.direction.xyz, 0.0f, INFINITY), p.state.y);
}
