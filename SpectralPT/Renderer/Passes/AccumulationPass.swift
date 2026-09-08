import Metal

extension PathTracingPassContext {
    func accumulate() {
        dispatch(
            "accumulate", [.read(sampleR), .read(meanR), .read(countsR), .write(countsR), .write(meanR)],
            tasks: n, effect: true)
    }
}
