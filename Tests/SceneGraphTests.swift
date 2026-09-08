import simd

enum SceneGraphTests {
    static func run() throws {
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) } catch {}
        }
        var mesh = SceneMesh()
        mesh.quad([-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0], 0)
        mesh.triangles[1].indices.w = 1
        let red = SceneMaterial(surface: .diffuse(reflectance: [1, 0, 0]))
        let green = SceneMaterial(surface: .diffuse(reflectance: [0, 1, 0]))
        var graph = SceneGraph()
        graph.meshes = [mesh]
        graph.materials = [red, green]
        let parent = try graph.add(.init(name: "group"))
        let child = try graph.add(
            .init(
                name: "child", parent: parent, mesh: mesh.id,
                materials: [red.id, green.id]))
        let sibling = try graph.add(.init(name: "sibling", mesh: mesh.id, materials: [green.id, red.id]))
        var transform = matrix_identity_float4x4
        transform.columns.3.x = 2
        try graph.setTransform(transform, for: parent)
        let compiled = try graph.compile()
        precondition(compiled.instances[0].transform.columns.3.x == 2, "Parent transform propagation")
        precondition(compiled.instances[0].materials == [0, 1], "Local material slots")
        _ = try graph.compile()
        precondition(graph.transformedNodeCount == 0, "Unchanged transforms should be cached")
        transform.columns.3.y = 1
        try graph.setTransform(transform, for: parent)
        _ = try graph.compile()
        precondition(graph.transformedNodeCount == 2, "Only dirty subtree should recompute transforms")
        graph.materials.reverse()
        let reordered = try graph.compile()
        precondition(reordered.instances[0].materials == [1, 0], "Material IDs must survive asset reorder")
        rejects("Hierarchy cycle accepted") { try graph.reparent(parent, to: child) }
        try graph.setVisible(false, for: parent)
        let hidden = try graph.compile()
        precondition(hidden.instances.count == 1, "Visibility must propagate to descendants")
        try graph.setVisible(true, for: parent)
        try graph.reparent(child, to: nil)
        let reparented = try graph.compile()
        precondition(
            reparented.instances[0].transform == matrix_identity_float4x4,
            "Reparent invalidates world transform")
        try graph.remove(parent)
        precondition(graph.nodes[child] != nil, "Reparented child should survive old parent removal")
        rejects("Removed node accepted") { try graph.setTransform(transform, for: parent) }
        try graph.setMaterials([red.id], for: child)
        rejects("Incomplete slot table accepted") { _ = try graph.compile() }
        try graph.remove(child)
        try graph.setMaterials([red.id, green.id], for: sibling)
        graph.materials.removeAll { $0.id == red.id }
        rejects("Dangling material ID accepted") { _ = try graph.compile() }
        print("Scene graph tests passed")
    }
}
