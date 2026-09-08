import simd

enum DemoScene: Int, CaseIterable, Identifiable {
    case cornell, prism
    var id: Int {
        rawValue
    }
    var title: String {
        self == .cornell ? "Cornell · 光谱材质" : "Prism · 玻璃色散"
    }
}

/// CPU-only geometry, material and light description for the built-in demos.
struct ProceduralScene {
    var mesh = SceneMesh()
    let materials: [PTMaterial]
    let lightOrigin: SIMD4<Float>
    let lightU: SIMD4<Float>
    let lightV: SIMD4<Float>
    let lightNormal: SIMD4<Float>
    let lightArea: Float

    init(kind: DemoScene) {
        materials = [
            PTMaterial(color: [0.73, 0.73, 0.73, 0], optics: [0, 0, 0, 0], flags: [0, 0, 0, 0]),
            PTMaterial(color: [0.72, 0.08, 0.045, 0], optics: [0, 0, 0, 0], flags: [0, 0, 0, 0]),
            PTMaterial(color: [0.07, 0.52, 0.14, 0], optics: [0, 0, 0, 0], flags: [0, 0, 0, 0]),
            PTMaterial(color: [1, 1, 1, 0], optics: [0.22, 0, 0, 0], flags: [1, 0, 0, 0]),
            PTMaterial(color: [1, 1, 1, 0], optics: [0, 0, 0, 0], flags: [2, 0, 0, 0]),
            PTMaterial(color: [1, 1, 1, 0], optics: [12, 0, 0, 0], flags: [3, 0, 0, 0]),
            PTMaterial(color: [0.8, 0.8, 0.8, 0], optics: [0, 0, 0, 0], flags: [0, 1, 0, 0]),
            PTMaterial(color: [1, 1, 1, 0], optics: [4, 0, 0, 0], flags: [3, 1, 0, 0]),
        ]
        mesh.quad([-2, 0, 2], [2, 0, 2], [2, 0, -2], [-2, 0, -2], 6)
        mesh.quad([-2, 0, -2], [2, 0, -2], [2, 3, -2], [-2, 3, -2], kind == .prism ? 7 : 0)
        mesh.quad([-2, 3, -2], [2, 3, -2], [2, 3, 2], [-2, 3, 2], 0)
        mesh.quad([-2, 0, 2], [-2, 0, -2], [-2, 3, -2], [-2, 3, 2], 1)
        mesh.quad([2, 0, -2], [2, 0, 2], [2, 3, 2], [2, 3, -2], 2)
        lightOrigin = [-0.6, 2.97, -0.65, 0]
        lightU = [1.2, 0, 0, 0]
        lightV = [0, 0, 1.1, 0]
        lightNormal = [0, -1, 0, 0]
        lightArea = 1.32
        let o = lightOrigin.xyz
        let u = lightU.xyz
        let v = lightV.xyz
        mesh.quad(o, o + u, o + u + v, o + v, 5)
        if kind == .cornell {
            mesh.sphere([-0.78, 0.67, -0.25], radius: 0.67, material: 3)
            mesh.sphere([0.72, 0.75, 0.55], radius: 0.75, material: 4)
            mesh.box([-0.35, 0, -1.55], [0.65, 1.2, -0.85], 0)
        } else {
            mesh.prism()
        }
    }
}
