import Metal

extension PathTracingPassContext {
    func display() {
        let display = context.pipelines["displayImage"]!
        let table = tables[0]
        graph.pass("Display · XYZ → sRGB", accesses: [.read(meanR), .write(outputR)], sideEffect: true) {

            [output] command in
            let e = command.makeComputeCommandEncoder()!
            e.label = "Display · XYZ → sRGB"
            e.setComputePipelineState(display)
            e.setArgumentTable(table)
            e.dispatchThreadgroups(
                threadgroupsPerGrid: MTLSize(
                    width: (output.width + 7) / 8, height: (output.height + 7) / 8, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e.endEncoding()
        }
    }
}
