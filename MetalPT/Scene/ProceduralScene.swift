import simd

enum DemoScene: Int, CaseIterable, Identifiable {
    case cornell, prism
    var id: Int {
        rawValue
    }
    var title: String {
        self == .cornell ? "Cornell · RGB 材质" : "Prism · 玻璃折射"
    }
}

/// CPU-only geometry, material and light description for the built-in demos.
struct ProceduralScene {
    let description: SceneDescription

    init(kind: DemoScene) {
        var scene = SceneDescription()
        scene.materials = [
            SceneMaterial(),
            SceneMaterial(surface: .diffuse(reflectance: [0.72, 0.08, 0.045])),
            SceneMaterial(surface: .diffuse(reflectance: [0.07, 0.52, 0.14])),
            SceneMaterial(surface: .gold(roughness: 0.22)),
            SceneMaterial(surface: .dielectric),
            SceneMaterial(surface: .absorbing, emission: .init(strength: 12)),
            SceneMaterial(
                surface: .diffuse(reflectance: [0.8, 0.8, 0.8]),
                baseColorTexture: .init(texture: SceneTexture.checker.id)),
            SceneMaterial(
                surface: .absorbing, emission: .init(strength: 4),
                emissiveTexture: .init(texture: SceneTexture.checker.id)),
        ]
        var room = SceneMesh()
        room.quad([-2, 0, 2], [2, 0, 2], [2, 0, -2], [-2, 0, -2], 0)
        room.quad([-2, 0, -2], [2, 0, -2], [2, 3, -2], [-2, 3, -2], 1)
        room.quad([-2, 3, -2], [2, 3, -2], [2, 3, 2], [-2, 3, 2], 2)
        room.quad([-2, 0, 2], [-2, 0, -2], [-2, 3, -2], [-2, 3, 2], 3)
        room.quad([2, 0, -2], [2, 0, 2], [2, 3, 2], [2, 3, -2], 4)
        _ = scene.addMesh(room, materials: [6, kind == .prism ? 7 : 0, 0, 1, 2])
        let o: SIMD3<Float> = [-0.6, 2.97, -0.65]
        let u: SIMD3<Float> = [1.2, 0, 0]
        let v: SIMD3<Float> = [0, 0, 1.1]
        var lamp = SceneMesh()
        lamp.quad(o, o + u, o + u + v, o + v, 0)
        let lampInstance = scene.addMesh(lamp, materials: [5])
        scene.lights.append(SceneLight(instance: lampInstance, material: 5, origin: o, u: u, v: v))
        if kind == .cornell {
            var gold = SceneMesh()
            gold.sphere([-0.78, 0.67, -0.25], radius: 0.67, material: 0)
            _ = scene.addMesh(gold, materials: [3])
            var glass = SceneMesh()
            glass.sphere([0.72, 0.75, 0.55], radius: 0.75, material: 0)
            _ = scene.addMesh(glass, materials: [4])
            var box = SceneMesh()
            box.box([-0.35, 0, -1.55], [0.65, 1.2, -0.85], 0)
            _ = scene.addMesh(box, materials: [0])
        } else {
            var prism = SceneMesh()
            prism.prism()
            _ = scene.addMesh(prism, materials: [4])
        }
        description = scene
    }
}
