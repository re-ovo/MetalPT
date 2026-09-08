import Metal

extension PathTracingPassContext {
    func intersectPaths(bounce: Int) {
        let read = bounce % 2 == 0 ? pathA : pathB
        dispatch(
            "intersectPaths",
            [
                .read(read), .read(countsR), .read(indirectR), .read(top), .read(geometry),
                .write(hitR),
            ], bounce: bounce, indirectOffset: 0)
    }
}
