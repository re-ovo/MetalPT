import simd

struct SceneMesh {
    struct Vertex: Equatable {
        var position, normal, uv: SIMD4<Float>
        var tangent: SIMD4<Float> = [1, 0, 0, 1]
        var color = SIMD4<Float>(repeating: 1)
        // normal, tangent, UV0, UV1, color. Missing normals fall back to geometry.
        var attributes: UInt32 = 5
        var gpu: PTVertex {
            PTVertex(
                position: position, normal: normal, uv: uv, tangent: tangent, color: color,
                attributes: [attributes, 0, 0, 0])
        }
    }
    struct Triangle: Equatable {
        var indices: SIMD4<UInt32>
        var gpu: PTTriangle { PTTriangle(indices: indices) }
    }
    var id = MeshID()
    /// Explicit import boundaries are retained even when adjacent primitives share a material.
    var primitiveStarts: Set<Int> = []
    /// Triangles reference these local slots, never scene material indices.
    var materialSlotCount: Int {
        Int(triangles.reduce(UInt32(0)) { max($0, $1.indices.w) }) + 1
    }

    func hasSameGeometry(as other: SceneMesh) -> Bool {
        vertices.count == other.vertices.count && triangles.count == other.triangles.count
            && zip(vertices, other.vertices).allSatisfy {
                $0 == $1
            }
            && zip(triangles, other.triangles).allSatisfy { $0.indices == $1.indices }
    }
    var vertices: [Vertex] = []
    var triangles: [Triangle] = []
    mutating func triangle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, material: UInt32,
        normals: [SIMD3<Float>]? = nil, uv: [SIMD2<Float>]? = nil, tangents: [SIMD4<Float>]? = nil
    ) {
        let normal = simd_normalize(simd_cross(b - a, c - a))
        guard normal.x.isFinite else {
            return
        }
        let base = UInt32(vertices.count)
        for (i, p) in [a, b, c].enumerated() {
            let t = uv?[i] ?? [i == 1 ? 1 : 0, i == 2 ? 1 : 0]
            vertices.append(
                Vertex(
                    position: SIMD4(p, 1), normal: SIMD4(normals?[i] ?? normal, 0), uv: [t.x, t.y, 0, 0],
                    tangent: tangents?[i] ?? [1, 0, 0, 1], attributes: tangents == nil ? 5 : 7))
        }
        triangles.append(Triangle(indices: [base, base + 1, base + 2, material]))
    }
    mutating func quad(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ m: UInt32
    ) {
        triangle(a, b, c, material: m, uv: [[0, 0], [1, 0], [1, 1]])
        triangle(a, c, d, material: m, uv: [[0, 0], [1, 1], [0, 1]])
    }
    mutating func sphere(_ center: SIMD3<Float>, radius: Float, material: UInt32) {
        let rows = 40
        let cols = 80
        func n(_ y: Int, _ x: Int) -> SIMD3<Float> {
            let theta = Float(y) / Float(rows) * .pi
            let phi = Float(x) / Float(cols) * 2 * .pi
            return [sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)]
        }
        func uv(_ y: Int, _ x: Int) -> SIMD2<Float> { [Float(x) / Float(cols), Float(y) / Float(rows)] }
        func tangent(_ x: Int) -> SIMD4<Float> {
            let phi = Float(x) / Float(cols) * 2 * .pi
            return [-sin(phi), 0, cos(phi), 1]
        }
        for y in 0..<rows {
            for x in 0..<cols {
                let a = n(y, x)
                let b = n(y + 1, x)
                let c = n(y + 1, x + 1)
                let d = n(y, x + 1)
                if y > 0 {
                    triangle(
                        center + a * radius, center + d * radius, center + b * radius, material: material,
                        normals: [a, d, b], uv: [uv(y, x), uv(y, x + 1), uv(y + 1, x)],
                        tangents: [tangent(x), tangent(x + 1), tangent(x)])
                }
                if y < rows - 1 {
                    triangle(
                        center + b * radius, center + d * radius, center + c * radius, material: material,
                        normals: [b, d, c], uv: [uv(y + 1, x), uv(y, x + 1), uv(y + 1, x + 1)],
                        tangents: [tangent(x), tangent(x + 1), tangent(x + 1)])
                }
            }
        }
    }
    mutating func box(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ m: UInt32) {
        quad([a.x, a.y, b.z], [b.x, a.y, b.z], [b.x, b.y, b.z], [a.x, b.y, b.z], m)
        quad([b.x, a.y, a.z], [a.x, a.y, a.z], [a.x, b.y, a.z], [b.x, b.y, a.z], m)
        quad([a.x, a.y, a.z], [a.x, a.y, b.z], [a.x, b.y, b.z], [a.x, b.y, a.z], m)
        quad([b.x, a.y, b.z], [b.x, a.y, a.z], [b.x, b.y, a.z], [b.x, b.y, b.z], m)
        quad([a.x, b.y, b.z], [b.x, b.y, b.z], [b.x, b.y, a.z], [a.x, b.y, a.z], m)
        quad([a.x, a.y, a.z], [b.x, a.y, a.z], [b.x, a.y, b.z], [a.x, a.y, b.z], m)
    }
    mutating func prism(material: UInt32 = 0) {
        // Closed, outward-wound triangular prism. Oblique side faces face the camera.
        let a: SIMD3<Float> = [0.65, 0.04, 0.35]
        let b: SIMD3<Float> = [0.65, 0.04, -0.35]
        let c: SIMD3<Float> = [-0.65, 0.04, 0]
        let h: SIMD3<Float> = [0, 1.7, 0]
        triangle(a, c, b, material: material)
        triangle(a + h, b + h, c + h, material: material)
        quad(a, b, b + h, a + h, material)
        quad(b, c, c + h, b + h, material)
        quad(c, a, a + h, c + h, material)
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}
