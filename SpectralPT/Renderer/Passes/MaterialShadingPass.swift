import Metal

extension PathTracingPassContext {
    func shadePaths(bounce: Int) {
        let read = bounce % 2 == 0 ? pathA : pathB
        let write = bounce % 2 == 0 ? pathB : pathA
        dispatch(
            "shadePaths",
            [
                .read(read), .read(hitR), .read(geometry), .read(countsR), .read(indirectR),
                .read(sampleR), .write(write), .write(shadowR), .write(countsR), .write(sampleR),
            ], bounce: bounce, indirectOffset: 0)
    }
}
