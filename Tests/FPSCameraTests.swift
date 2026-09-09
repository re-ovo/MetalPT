import simd

enum FPSCameraTests {
    static func run() {
        var camera = FPSCamera()
        let start = camera.position
        camera.look(100, 50)
        precondition(camera.position == start, "FPS look must rotate around the eye")
        camera.look(0, 100_000)
        precondition(camera.pitch == 1.55, "Pitch clamp prevents inverted camera")
        camera.yaw = 0
        camera.move([0, 0, 1], distance: 2)
        precondition(
            simd_distance(camera.position, start + SIMD3(0, 0, -2)) < 0.0001,
            "Forward movement stays level even when looking down")
        let before = camera.position
        camera.move([1, 1, 1], distance: 1)
        precondition(
            abs(simd_distance(camera.position, before) - 1) < 0.0001,
            "Diagonal motion must not be faster")
        var frame = PTFrame()
        camera.fill(&frame, aspect: 2)
        precondition(
            abs(simd_dot(frame.forward.xyz, frame.right.xyz)) < 0.0001,
            "Camera basis remains orthogonal")
        precondition(
            abs(simd_length(frame.right.xyz) / simd_length(frame.up.xyz) - 2) < 0.0001,
            "Projection respects viewport aspect")
        print("FPS camera tests passed")
    }
}
