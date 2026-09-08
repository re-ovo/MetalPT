import Metal

extension PathTracingPassContext {
    func traceShadows(bounce: Int) {
        dispatch(
            "traceShadows",
            [
                .read(shadowR), .read(top), .read(countsR), .read(indirectR), .read(sampleR),
                .write(sampleR),
            ], bounce: bounce, indirectOffset: 12)
    }
}
