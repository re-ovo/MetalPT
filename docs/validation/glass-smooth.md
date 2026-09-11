# Smooth glass shading

Validated on 2026-09-11 using Apple M4, Debug, Metal API Validation and Shader Validation enabled.

Ideal dielectric reflection and refraction now use interpolated shading normals, as other surfaces do.
Geometric normals still determine entry/exit, ray offsets, and outgoing hemisphere rejection. Shading
normals that face away from the incoming direction still fall back to the geometric normal. Fresnel
probabilities and radiance eta-squared weights are unchanged; invalid outgoing directions remain null
events, without resampling or PDF renormalization.

Command: `METALPT_OUTPUT=/tmp/MetalPT-glass-smooth METALPT_SPP=128 scripts/validate-gpu.sh validation`.
Passed at 320x240 internal resolution, 640x480 output, 128 spp, maximum depth 8, denoising disabled.
Inspected `cornell.png`: glass reflection/refraction appears smooth; sampling noise remains visible.
The sphere is still a triangle mesh, so its silhouette is still limited by tessellation.
Full GPU integration validation passed, including dielectric Fresnel, transmission, and total internal
reflection checks. Report and images are in `/tmp/MetalPT-glass-smooth`.

`scripts/test-graph.sh` passed all camera, scene, surface asset, Render Graph, and ABI checks.
`git diff --check` passed. `scripts/format.sh` could not run because `clang-format` is not installed.
