import Metal

/// Wires typed pass inputs and outputs. No pass receives the entire frame or scene context.
enum PathTracingPasses {
    static func populate(
        context: MetalContext, scene: BindlessScene, sceneBuilt: Bool,
        frame: FrameResources, shouldTrace: Bool
    ) {
        let graph = frame.graph
        let h = frame.handles
        let sceneHandles = frame.sceneHandles
        let root = sceneHandles[scene.rootHandle]!
        let top = sceneHandles[scene.tlasHandle]!
        // A TLAS indirectly references each mesh BLAS during traversal, even after the build frame.
        let traversal = scene.meshBuilds.map { sceneHandles[$0.output]! }
        let geometry = SceneBindings(
            root: root, dependencies: scene.intersectionResources.map { sceneHandles[$0]! } + traversal,
            acceleration: top)
        let shading = SceneBindings(
            root: root, dependencies: scene.shadingResources.map { sceneHandles[$0]! })
        let compute = ComputePass(
            context: context, bindings: frame.bindings, bindingResources: frame.bindingResources)
        if !sceneBuilt { AccelerationStructurePasses.add(to: graph, scene: scene, handles: sceneHandles) }
        if shouldTrace {
            CameraPathPass.add(
                to: graph, compute: compute,
                resources: .init(
                    paths: h.pathA, sample: h.sample, counts: h.counts, accumulation: frame.accumulation),
                reset: frame.parameters.reset, pixels: frame.parameters.pixelCount)
            let queues = QueueManagementPasses.Resources(counts: h.counts, indirect: h.indirect)
            for bounce in 0..<frame.parameters.maxDepth {
                let input = bounce % 2 == 0 ? h.pathA : h.pathB
                let output = bounce % 2 == 0 ? h.pathB : h.pathA
                QueueManagementPasses.prepareBounce(
                    to: graph, compute: compute, resources: queues, bounce: bounce)
                PathIntersectionPass.add(
                    to: graph, compute: compute,
                    resources: .init(
                        paths: input, counts: h.counts, indirect: h.indirect, hits: h.hits,
                        scene: geometry), bounce: bounce)
                MaterialShadingPass.add(
                    to: graph, compute: compute,
                    resources: .init(
                        paths: input, hits: h.hits, counts: h.counts, indirect: h.indirect, sample: h.sample,
                        nextPaths: output, shadows: h.shadows, scene: shading), bounce: bounce)
                QueueManagementPasses.prepareShadow(
                    to: graph, compute: compute, resources: queues, bounce: bounce)
                ShadowTracePass.add(
                    to: graph, compute: compute,
                    resources: .init(
                        shadows: h.shadows, counts: h.counts,
                        indirect: h.indirect, sample: h.sample,
                        scene: SceneBindings(root: root, dependencies: traversal, acceleration: top)),
                    bounce: bounce)
                QueueManagementPasses.finishBounce(
                    to: graph, compute: compute, resources: queues, bounce: bounce)
            }
            AccumulationPass.add(
                to: graph, compute: compute,
                resources: .init(sample: h.sample, accumulation: frame.accumulation, counts: h.counts),
                pixels: frame.parameters.pixelCount)
        }
        DisplayPass.add(
            to: graph, compute: compute,
            resources: .init(accumulation: frame.accumulation, output: frame.displayColor))
        PresentPass.add(to: graph, source: frame.displayColor, destination: frame.output)
    }
}
