import Metal

/// Orders the wavefront passes; implementations and dependencies live in Passes/.
enum PathTracingPasses {
    static func populate(
        context: MetalContext, scene: BindlessScene, sceneBuilt: Bool,
        frame: FrameResources, accumulation: MTLBuffer, output: MTLTexture,
        shouldTrace: Bool
    ) {
        let passes = PathTracingPassContext(
            context: context, scene: scene, sceneBuilt: sceneBuilt,
            frame: frame, accumulation: accumulation, output: output)
        if !sceneBuilt {
            passes.buildAccelerationStructures()
        }
        if shouldTrace {
            passes.generateCameraPaths()
            for bounce in 0..<frame.parameters.maxDepth {
                passes.prepareBounce(bounce: bounce)
                passes.intersectPaths(bounce: bounce)
                passes.shadePaths(bounce: bounce)
                passes.prepareShadow(bounce: bounce)
                passes.traceShadows(bounce: bounce)
                passes.finishBounce(bounce: bounce)
            }
            passes.accumulate()
        }
        passes.display()
    }
}
