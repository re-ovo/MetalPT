import Metal

extension PathTracingPassContext {
    func generateCameraPaths() {
        var initAccess: [RenderGraph.Access] = [.write(pathA), .write(sampleR), .write(countsR)]
        if frame.parameters.reset {
            initAccess.append(.write(meanR))
        }
        dispatch("initialize", initAccess, tasks: n)
    }
}
