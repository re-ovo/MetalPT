import Metal
import simd

/// Immutable upload snapshot. Mesh BLASes are shared by all instances referencing that mesh.
final class BindlessScene {
    struct Build {
        let destination: MTLAccelerationStructure
        let descriptor: MTL4PrimitiveAccelerationStructureDescriptor
        let scratch: MTLBuffer
        let inputs: [ResourceRegistry.Handle]
        let output: ResourceRegistry.Handle
        let scratchHandle: ResourceRegistry.Handle
    }
    let resources: [ResourceRegistry.Entry]
    let root: MTLBuffer
    let rootHandle: ResourceRegistry.Handle
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

    init(_ context: MetalContext, description: SceneDescription) throws {
        try description.validate()
        let registry = ResourceRegistry()
        func upload<T>(_ values: [T], _ name: String) throws -> (MTLBuffer, ResourceRegistry.Handle) {
            let buffer = try context.upload(values, name)
            return (buffer, registry.insert(buffer, name: name))
        }
        var builds: [Build] = []
        var meshes: [PTMesh] = []
        var intersection: [ResourceRegistry.Handle] = []
        for (index, mesh) in description.meshes.enumerated() {
            let (vb, vh) = try upload(mesh.vertices, "Mesh \(index) vertices")
            let (tb, th) = try upload(mesh.triangles, "Mesh \(index) triangles")
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
                    destination: blas, descriptor: descriptor, scratch: scratch, inputs: [vh, ih],
                    output: registry.insert(blas, name: blas.label!, kind: .accelerationStructure),
                    scratchHandle: registry.insert(scratch, name: scratch.label!)))
        }
        meshBuilds = builds
        var instances: [PTInstance] = []
        var asInstances: [MTLIndirectAccelerationStructureInstanceDescriptor] = []
        for (index, instance) in description.instances.enumerated() {
            let t = instance.transform
            let light = description.lights.firstIndex { $0.instance == index }
            instances.append(
                PTInstance(
                    transform: (t.columns.0, t.columns.1, t.columns.2, t.columns.3),
                    indices: [
                        UInt32(instance.mesh), instance.materialOverride.map(UInt32.init) ?? UInt32.max,
                        light.map(UInt32.init) ?? UInt32.max, 0,
                    ]))
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
        var textureIDs: [UInt64] = []
        var shading: [ResourceRegistry.Handle] = []
        for (index, pattern) in description.textures.enumerated() {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: 128, height: 128, mipmapped: false)
            td.storageMode = .shared
            td.usage = .shaderRead
            guard let texture = context.device.makeTexture(descriptor: td) else {
                throw RenderFailure("纹理分配失败")
            }
            texture.label = "Scene texture \(index)"
            let data: [Float] = (0..<(128 * 128)).map { p in
                switch pattern {
                case .white: return 1
                case .checker: return (p % 128 / 8 + p / 128 / 32) % 2 == 0 ? 1 : 0.015
                case .stripes: return p % 128 / 8 % 2 == 0 ? 1 : 0.015
                }
            }
            data.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: 128 * 4)
            }
            textureIDs.append(texture.gpuResourceID._impl)
            shading.append(registry.insert(texture, name: texture.label!, kind: .texture))
        }
        let lights: [PTLight] = description.lights.map { light in
            let t = description.instances[light.instance].transform
            let o = t * SIMD4(light.origin, 1), u = t * SIMD4(light.u, 0), v = t * SIMD4(light.v, 0)
            let cross = simd_cross(u.xyz, v.xyz), area = simd_length(cross)
            return PTLight(
                origin: o, u: u, v: v, normalArea: SIMD4(cross / area, area),
                indices: [UInt32(light.material), UInt32(light.instance), 0, 0])
        }
        let spectra = try SpectralData()
        let (meshTable, mh) = try upload(meshes, "Mesh table")
        let (instanceTable, insth) = try upload(instances, "Instance table")
        let (materials, math) = try upload(description.materials.map(\.gpu), "Material table")
        let (cie, ch) = try upload(spectra.cie, "CIE table")
        let (gold, gh) = try upload(spectra.gold, "Gold table")
        let (textures, th) = try upload(textureIDs, "Texture resource ID table")
        let (lightTable, lh) = try upload(lights, "Light table")
        var scene = PTScene()
        scene.meshes = meshTable.gpuAddress
        scene.instances = instanceTable.gpuAddress
        scene.materials = materials.gpuAddress
        scene.cie = cie.gpuAddress
        scene.gold = gold.gpuAddress
        scene.textures = textures.gpuAddress
        scene.lights = lightTable.gpuAddress
        scene.acceleration = tlas.gpuResourceID._impl
        scene.counts = [
            UInt32(meshes.count), UInt32(instances.count), UInt32(textureIDs.count), UInt32(lights.count),
        ]
        let (root, rootHandle) = try upload([scene], "Bindless scene root")
        self.root = root
        self.rootHandle = rootHandle
        intersectionResources = intersection + [mh, insth, rootHandle]
        shadingResources = shading + [math, ch, gh, th, lh, rootHandle]
        resources = registry.snapshot()
    }
}
