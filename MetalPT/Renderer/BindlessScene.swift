import Metal
import simd

/// Immutable upload snapshot. Mesh BLASes are shared by all instances referencing that mesh.
final class BindlessScene {
    struct Build {
        let required: Bool
        let destination: MTLAccelerationStructure
        let descriptor: MTL4PrimitiveAccelerationStructureDescriptor
        let scratch: MTLBuffer
        let inputs: [ResourceRegistry.Handle]
        let output: ResourceRegistry.Handle
        let scratchHandle: ResourceRegistry.Handle
    }
    struct MeshUpload {
        let description: SceneMesh
        let mesh: PTMesh
        let build: Build
        let handles: [ResourceRegistry.Handle]
    }
    let samplers: [MTLSamplerState]
    let meshUploads: [MeshUpload]
    let reusedAccelerationStructures: Set<ResourceRegistry.Handle>
    let resources: [ResourceRegistry.Entry]
    let root: MTLBuffer
    let rootHandle: ResourceRegistry.Handle
    private let lightHandle: ResourceRegistry.Handle
    let intersectionResources: [ResourceRegistry.Handle]
    let shadingResources: [ResourceRegistry.Handle]
    let meshBuilds: [Build]
    let tlas: MTLAccelerationStructure
    let tlasDescriptor: MTL4InstanceAccelerationStructureDescriptor
    let scratchTLAS: MTLBuffer
    let tlasHandle: ResourceRegistry.Handle
    let instanceHandle: ResourceRegistry.Handle
    let scratchHandle: ResourceRegistry.Handle
    var allocations: [MTLAllocation] { resources.map(\.allocation) }

    convenience init(_ context: MetalContext, kind: DemoScene) throws {
        try self.init(context, description: ProceduralScene(kind: kind).description)
    }

    init(
        _ context: MetalContext, description: SceneDescription, reusing previous: BindlessScene? = nil,
        preparedTextures: SceneTextureUpload.Prepared? = nil
    )
        throws
    {
        try description.validate()
        let registry = ResourceRegistry()
        func upload<T>(_ values: [T], _ name: String) throws -> (MTLBuffer, ResourceRegistry.Handle) {
            let buffer = try context.upload(values, name)
            return (buffer, registry.insert(buffer, name: name))
        }
        var uploads: [MeshUpload] = []
        var reused = Set<ResourceRegistry.Handle>()
        var builds: [Build] = []
        var meshes: [PTMesh] = []
        var intersection: [ResourceRegistry.Handle] = []
        for (index, mesh) in description.meshes.enumerated() {
            if let previous,
                let cached = previous.meshUploads.first(where: {
                    $0.description.id == mesh.id && $0.description.hasSameGeometry(as: mesh)
                })
            {
                var remapped: [ResourceRegistry.Handle: ResourceRegistry.Handle] = [:]
                for handle in cached.handles {
                    let entry = previous.resources.first { $0.handle == handle }!
                    remapped[handle] = registry.insert(entry.allocation, name: entry.name, kind: entry.kind)
                }
                let old = cached.build
                let build = Build(
                    required: false, destination: old.destination, descriptor: old.descriptor,
                    scratch: old.scratch, inputs: old.inputs.map { remapped[$0]! },
                    output: remapped[old.output]!, scratchHandle: remapped[old.scratchHandle]!)
                let handles = cached.handles.map { remapped[$0]! }
                builds.append(build)
                meshes.append(cached.mesh)
                intersection += Array(handles.prefix(2))
                uploads.append(
                    MeshUpload(description: mesh, mesh: cached.mesh, build: build, handles: handles))
                reused.insert(build.output)
                continue
            }
            let (vb, vh) = try upload(mesh.vertices.map(\.gpu), "Mesh \(index) vertices")
            let (tb, th) = try upload(mesh.triangles.map(\.gpu), "Mesh \(index) triangles")
            let (ib, ih) = try upload(
                mesh.triangles.flatMap { [$0.indices.x, $0.indices.y, $0.indices.z] }, "Mesh \(index) indices"
            )
            meshes.append(PTMesh(vertices: vb.gpuAddress, triangles: tb.gpuAddress))
            intersection += [vh, th]
            let geo = MTL4AccelerationStructureTriangleGeometryDescriptor()
            geo.vertexBuffer = MTL4BufferRange(bufferAddress: vb.gpuAddress, length: UInt64(vb.length))
            geo.vertexStride = MemoryLayout<PTVertex>.stride
            geo.vertexFormat = .float3
            geo.indexBuffer = MTL4BufferRange(bufferAddress: ib.gpuAddress, length: UInt64(ib.length))
            geo.indexType = .uint32
            geo.triangleCount = mesh.triangles.count
            geo.opaque = true
            let descriptor = MTL4PrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [geo]
            let sizes = context.device.accelerationStructureSizes(descriptor: descriptor)
            guard let blas = context.device.makeAccelerationStructure(size: sizes.accelerationStructureSize)
            else {
                throw RenderFailure("BLAS 分配失败")
            }
            blas.label = "Mesh \(index) BLAS"
            let scratch = try context.buffer(sizes.buildScratchBufferSize, "Mesh \(index) scratch")
            builds.append(
                Build(
                    required: true, destination: blas, descriptor: descriptor, scratch: scratch,
                    inputs: [vh, ih],
                    output: registry.insert(blas, name: blas.label!, kind: .accelerationStructure),
                    scratchHandle: registry.insert(scratch, name: scratch.label!)))
            uploads.append(
                MeshUpload(
                    description: mesh, mesh: meshes.last!, build: builds.last!,
                    handles: [vh, th, ih, builds.last!.output, builds.last!.scratchHandle]))
        }
        meshUploads = uploads
        reusedAccelerationStructures = reused
        meshBuilds = builds
        var instances: [PTInstance] = []
        var asInstances: [MTLIndirectAccelerationStructureInstanceDescriptor] = []
        for (index, instance) in description.instances.enumerated() {
            let (bindings, bindingHandle) = try upload(
                instance.materials.map(UInt32.init), "Instance material slots \(index)")
            intersection.append(bindingHandle)
            let t = instance.transform
            let light = description.lights.firstIndex { $0.instance == index }
            instances.append(
                PTInstance(
                    transform: (t.columns.0, t.columns.1, t.columns.2, t.columns.3),
                    indices: [
                        UInt32(instance.mesh), UInt32(instance.materials.count),
                        light.map(UInt32.init) ?? UInt32.max, 0,
                    ], materials: bindings.gpuAddress))
            var descriptor = MTLIndirectAccelerationStructureInstanceDescriptor()
            func packed(_ v: SIMD4<Float>) -> MTLPackedFloat3 { MTLPackedFloat3Make(v.x, v.y, v.z) }
            descriptor.transformationMatrix = MTLPackedFloat4x3(
                columns: (packed(t.columns.0), packed(t.columns.1), packed(t.columns.2), packed(t.columns.3)))
            descriptor.mask = 255
            descriptor.accelerationStructureID = builds[instance.mesh].destination.gpuResourceID
            asInstances.append(descriptor)
        }
        let (instanceBuffer, instanceHandle) = try upload(asInstances, "TLAS instance descriptors")
        self.instanceHandle = instanceHandle
        tlasDescriptor = MTL4InstanceAccelerationStructureDescriptor()
        tlasDescriptor.instanceDescriptorType = .indirect
        tlasDescriptor.instanceDescriptorBuffer = MTL4BufferRange(
            bufferAddress: instanceBuffer.gpuAddress, length: UInt64(instanceBuffer.length))
        tlasDescriptor.instanceDescriptorStride =
            MemoryLayout<MTLIndirectAccelerationStructureInstanceDescriptor>.stride
        tlasDescriptor.instanceCount = asInstances.count
        let sizes = context.device.accelerationStructureSizes(descriptor: tlasDescriptor)
        guard let tlas = context.device.makeAccelerationStructure(size: sizes.accelerationStructureSize)
        else {
            throw RenderFailure("TLAS 分配失败")
        }
        self.tlas = tlas
        tlas.label = "Scene TLAS"
        tlasHandle = registry.insert(tlas, name: "TLAS", kind: .accelerationStructure)
        scratchTLAS = try context.buffer(sizes.buildScratchBufferSize, "TLAS scratch")
        scratchHandle = registry.insert(scratchTLAS, name: "TLAS scratch")
        let textureUpload = try SceneTextureUpload(
            context: context, scene: description, registry: registry, prepared: preparedTextures)
        samplers = textureUpload.samplers
        var shading = textureUpload.handles
        let lights: [PTLight] =
            Self.rectangleLights(description) + description.punctualLights.map { $0.gpu() }
        let (meshTable, mh) = try upload(meshes, "Mesh table")
        let (instanceTable, insth) = try upload(instances, "Instance table")
        let textureIndices = Dictionary(
            uniqueKeysWithValues: description.textures.enumerated().map { ($1.id, $0) })
        let samplerIndices = Dictionary(
            uniqueKeysWithValues: description.samplers.enumerated().map { ($1.id, $0) })
        let (materials, math) = try upload(
            description.materials.map { $0.gpu(textures: textureIndices, samplers: samplerIndices) },
            "Material table")
        let (textures, th) = try upload(textureUpload.textures, "Texture resource ID table")
        let (samplerTable, sah) = try upload(
            samplers.map { PTSampler(value: $0.gpuResourceID._impl) }, "Sampler ID table")
        let (lightTable, lh) = try upload(lights, "Light table")
        lightHandle = lh
        var scene = PTScene()
        scene.meshes = meshTable.gpuAddress
        scene.instances = instanceTable.gpuAddress
        scene.materials = materials.gpuAddress
        scene.textures = textures.gpuAddress
        scene.samplers = samplerTable.gpuAddress
        scene.lights = lightTable.gpuAddress
        scene.acceleration = tlas.gpuResourceID._impl
        scene.counts = [
            UInt32(meshes.count), UInt32(instances.count), UInt32(textureUpload.textures.count),
            UInt32(lights.count),
        ]
        let (root, rootHandle) = try upload([scene], "Bindless scene root")
        self.root = root
        self.rootHandle = rootHandle
        shading += [math, th, sah, lh, rootHandle]
        intersectionResources = intersection + [mh, insth] + shading
        shadingResources = shading
        resources = registry.snapshot()
    }
    private static func rectangleLights(_ description: SceneDescription) -> [PTLight] {
        description.lights.map { light in
            let t = description.instances[light.instance].transform
            let o = t * SIMD4(light.origin, 1), u = t * SIMD4(light.u, 0), v = t * SIMD4(light.v, 0)
            let cross = simd_cross(u.xyz, v.xyz), area = simd_length(cross)
            return PTLight(
                origin: o, u: u, v: v,
                normalArea: SIMD4(cross / area * (simd_determinant(t) < 0 ? -1 : 1), area),
                indices: [UInt32(light.material), UInt32(light.instance), 0, 0])
        }
    }

    /// Replace only immutable light/root buffers; in-flight frames retain the previous snapshot.
    init(_ context: MetalContext, updatingLights description: SceneDescription, from previous: BindlessScene)
        throws
    {
        for light in description.punctualLights { try light.validate() }
        let registry = ResourceRegistry()
        let lights = Self.rectangleLights(description) + description.punctualLights.map { $0.gpu() }
        let table = try context.upload(lights, "Light table")
        lightHandle = registry.insert(table, name: "Light table")
        var header = previous.root.contents().load(as: PTScene.self)
        header.lights = table.gpuAddress
        header.counts.w = UInt32(lights.count)
        root = try context.upload([header], "Bindless scene root")
        rootHandle = registry.insert(root, name: "Bindless scene root")
        let newRoot = rootHandle, newLight = lightHandle
        func remap(_ handles: [ResourceRegistry.Handle]) -> [ResourceRegistry.Handle] {
            handles.map {
                $0 == previous.rootHandle ? newRoot : ($0 == previous.lightHandle ? newLight : $0)
            }
        }
        samplers = previous.samplers
        meshUploads = previous.meshUploads
        reusedAccelerationStructures = previous.reusedAccelerationStructures
        meshBuilds = previous.meshBuilds
        tlas = previous.tlas
        tlasDescriptor = previous.tlasDescriptor
        scratchTLAS = previous.scratchTLAS
        tlasHandle = previous.tlasHandle
        instanceHandle = previous.instanceHandle
        scratchHandle = previous.scratchHandle
        intersectionResources = remap(previous.intersectionResources)
        shadingResources = remap(previous.shadingResources)
        resources =
            previous.resources.filter {
                $0.handle != previous.rootHandle && $0.handle != previous.lightHandle
            }
            + registry.snapshot()
    }
}
