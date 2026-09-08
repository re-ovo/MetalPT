import Metal

extension PathTracingPassContext {
    func prepareBounce(bounce: Int) {
        dispatch("prepareBounce", [.read(countsR), .write(countsR), .write(indirectR)], bounce: bounce)
    }

    func prepareShadow(bounce: Int) {
        dispatch("prepareShadow", [.read(countsR), .write(indirectR)], bounce: bounce)
    }

    func finishBounce(bounce: Int) {
        dispatch("finishBounce", [.read(countsR), .write(countsR)], bounce: bounce)
    }
}
