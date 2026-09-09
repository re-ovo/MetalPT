import Metal

/// Display-only spatial filtering: never writes the persistent Monte Carlo mean.
enum SpatialDenoisePass {
    struct Resources {
        let source, normalDepth, geometricNormal, albedo, a, b: RenderGraph.Resource
        let scene: SceneBindings
    }
    static func add(to graph: RenderGraph, compute: ComputePass, resources io: Resources, pixels: Int) {
        compute.add(
            to: graph, kernel: "denoiseGuides",
            work: WorkBindings([
                .normalDepth: .write(io.normalDepth), .albedoGuide: .write(io.albedo),
                .geometricNormal: .write(io.geometricNormal),
            ]),
            scene: io.scene, tasks: pixels, label: "Denoise · primary guides")
        for iteration in 0..<3 {
            let source = iteration == 0 ? io.source : (iteration == 1 ? io.a : io.b)
            let destination = iteration == 1 ? io.b : io.a
            compute.add(
                to: graph, kernel: "spatialDenoise",
                work: WorkBindings([
                    .normalDepth: .read(io.normalDepth), .geometricNormal: .read(io.geometricNormal),
                    .albedoGuide: .read(io.albedo),
                    .filterInput: .read(source), .filterOutput: .write(destination),
                ]),
                bounce: iteration, tasks: pixels, label: "Denoise · spatial \(iteration)")
        }
    }
}
