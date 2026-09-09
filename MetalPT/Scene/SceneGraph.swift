import Foundation
import simd

/// Authoring hierarchy. Array indices exist only in the compiled render snapshot.
nonisolated struct SceneGraph {
    struct Emitter {
        var materialSlot: Int
        var origin, u, v: SIMD3<Float>
    }
    struct Node {
        let id = NodeID()
        var name: String
        fileprivate(set) var parent: NodeID?
        fileprivate(set) var localTransform = matrix_identity_float4x4
        fileprivate(set) var visible = true
        var mesh: MeshID?
        var materials: [MaterialID] = []
        var emitter: Emitter?
    }

    var meshes: [SceneMesh] = []
    var materials: [SceneMaterial] = []
    var images: [SceneImage] = []
    var samplers: [SceneSampler] = [.nearest]
    var textures: [SceneTexture] = [.white, .checker]
    private(set) var nodes: [NodeID: Node] = [:]
    private var order: [NodeID] = []
    private var worldTransforms: [NodeID: simd_float4x4] = [:]
    private(set) var transformedNodeCount = 0

    init() {}

    init(description: SceneDescription) throws {
        try description.validate()
        meshes = description.meshes
        materials = description.materials
        textures = description.textures
        images = description.images
        samplers = description.samplers
        for (index, instance) in description.instances.enumerated() {
            var node = Node(
                name: "Instance \(index)", mesh: meshes[instance.mesh].id,
                materials: instance.materials.map { materials[$0].id })
            node.localTransform = instance.transform
            if let light = description.lights.first(where: { $0.instance == index }) {
                guard let slot = instance.materials.firstIndex(of: light.material) else {
                    throw RenderFailure("面积灯缺少材质绑定")
                }
                node.emitter = Emitter(materialSlot: slot, origin: light.origin, u: light.u, v: light.v)
            }
            try add(node)
        }
    }

    @discardableResult
    mutating func add(_ node: Node) throws -> NodeID {
        guard nodes[node.id] == nil, node.parent.map({ nodes[$0] != nil }) ?? true else {
            throw RenderFailure("节点重复或父节点不存在")
        }
        nodes[node.id] = node
        order.append(node.id)
        return node.id
    }

    mutating func setTransform(_ transform: simd_float4x4, for id: NodeID) throws {
        guard nodes[id] != nil else { throw RenderFailure("节点不存在") }
        nodes[id]!.localTransform = transform
        invalidate(id)
    }

    mutating func setVisible(_ visible: Bool, for id: NodeID) throws {
        guard nodes[id] != nil else { throw RenderFailure("节点不存在") }
        nodes[id]!.visible = visible
    }

    /// Reparent preserves the local transform. Reject cycles before changing the hierarchy.
    mutating func reparent(_ id: NodeID, to parent: NodeID?) throws {
        guard nodes[id] != nil, parent.map({ nodes[$0] != nil }) ?? true else {
            throw RenderFailure("节点或父节点不存在")
        }
        var ancestor = parent
        while let current = ancestor {
            guard current != id else { throw RenderFailure("场景节点形成环") }
            ancestor = nodes[current]!.parent
        }
        nodes[id]!.parent = parent
        invalidate(id)
    }

    mutating func setMaterials(_ bindings: [MaterialID], for id: NodeID) throws {
        guard nodes[id] != nil else { throw RenderFailure("节点不存在") }
        nodes[id]!.materials = bindings
    }

    /// Removing a node removes its entire subtree; IDs are never recycled.
    mutating func remove(_ id: NodeID) throws {
        guard nodes[id] != nil else { throw RenderFailure("节点不存在") }
        for child in order.filter({ nodes[$0]?.parent == id }) { try remove(child) }
        nodes.removeValue(forKey: id)
        worldTransforms.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    private mutating func invalidate(_ id: NodeID) {
        worldTransforms.removeValue(forKey: id)
        for child in order.filter({ nodes[$0]?.parent == id }) { invalidate(child) }
    }

    private mutating func world(_ id: NodeID) -> simd_float4x4 {
        if let cached = worldTransforms[id] { return cached }
        let node = nodes[id]!
        let parent = node.parent.map { world($0) } ?? matrix_identity_float4x4
        let result = parent * node.localTransform
        worldTransforms[id] = result
        transformedNodeCount += 1
        return result
    }

    mutating func compile() throws -> SceneDescription {
        guard Set(meshes.map(\.id)).count == meshes.count,
            Set(materials.map(\.id)).count == materials.count
        else {
            throw RenderFailure("场景资产 ID 重复")
        }
        let meshIndices = Dictionary(uniqueKeysWithValues: meshes.enumerated().map { ($1.id, $0) })
        let materialIndices = Dictionary(uniqueKeysWithValues: materials.enumerated().map { ($1.id, $0) })
        var result = SceneDescription()
        result.meshes = meshes
        result.materials = materials
        result.textures = textures
        result.images = images
        result.samplers = samplers
        transformedNodeCount = 0
        for id in order {
            let node = nodes[id]!
            var ancestor: NodeID? = id
            var visible = true
            while let current = ancestor {
                visible = visible && nodes[current]!.visible
                ancestor = nodes[current]!.parent
            }
            guard let meshID = node.mesh else { continue }
            guard let mesh = meshIndices[meshID] else { throw RenderFailure("节点引用已删除的 Mesh") }
            let bindings = try node.materials.map { id -> Int in
                guard let index = materialIndices[id] else { throw RenderFailure("节点引用已删除的材质") }
                return index
            }
            guard bindings.count == meshes[mesh].materialSlotCount else {
                throw RenderFailure("节点材质绑定与 Mesh 槽位数量不符")
            }
            guard visible else { continue }
            let instance = result.instances.count
            result.instances.append(SceneInstance(mesh: mesh, transform: world(id), materials: bindings))
            if let emitter = node.emitter {
                guard bindings.indices.contains(emitter.materialSlot) else {
                    throw RenderFailure("面积灯材质槽越界")
                }
                result.lights.append(
                    SceneLight(
                        instance: instance, material: bindings[emitter.materialSlot],
                        origin: emitter.origin, u: emitter.u, v: emitter.v))
            }
        }
        try result.validate()
        return result
    }
}
