import Metal
import simd

final class BindlessScene {
    let root: MTLBuffer
    let allocations: [MTLAllocation]
    let blas: MTLAccelerationStructure
    let tlas: MTLAccelerationStructure
    let blasDescriptor: MTL4PrimitiveAccelerationStructureDescriptor
    let tlasDescriptor: MTL4InstanceAccelerationStructureDescriptor
    let scratchBLAS: MTLBuffer
    let scratchTLAS: MTLBuffer
    let lightOrigin: SIMD4<Float>, lightU: SIMD4<Float>, lightV: SIMD4<Float>, lightNormal: SIMD4<Float>
    let lightArea: Float
    init(_ context: MetalContext, kind: DemoScene) throws {
        let description = ProceduralScene(kind: kind)
        let mesh = description.mesh
        let materials = description.materials
        lightOrigin = description.lightOrigin
        lightU = description.lightU
        lightV = description.lightV
        lightNormal = description.lightNormal
        lightArea = description.lightArea
        let vb = try context.upload(mesh.vertices, "Scene vertices")
        let tb = try context.upload(mesh.triangles, "Bindless triangle metadata")
        let indices = mesh.triangles.flatMap {
            [$0.indices.x, $0.indices.y, $0.indices.z]
        }
        let ib = try context.upload(indices, "AS indices")
        let mb = try context.upload(materials, "Spectral materials")
        let spectra = try SpectralData()
        let cb = try context.upload(spectra.cie, "CIE 1931 XYZ 1nm")
        let gb = try context.upload(spectra.gold, "Gold n k 1nm")
        var textures: [MTLTexture] = []
        for pattern in 0..<2 {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: 128, height: 128, mipmapped: false)
            td.storageMode = .shared
            td.usage = .shaderRead
            guard let tex = context.device.makeTexture(descriptor: td) else {
                throw RenderFailure("纹理分配失败")
            }
            tex.label = pattern == 0 ? "White" : "Procedural stripes"
            var data = (0..<(128 * 128)).map {
                p -> Float in
                pattern == 0 ? 1 : ((p % 128 / 8 + p / 128 / 32) % 2 == 0 ? 1 : 0.015)
            }
            data.withUnsafeMutableBytes {
                tex.replace(
                    region: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: 128 * 4)
            }
            textures.append(tex)
        }
        let geo = MTL4AccelerationStructureTriangleGeometryDescriptor()
        geo.vertexBuffer = MTL4BufferRange(bufferAddress: vb.gpuAddress, length: UInt64(vb.length))
        geo.vertexStride = MemoryLayout<PTVertex>.stride
        geo.vertexFormat = .float3
        geo.indexBuffer = MTL4BufferRange(bufferAddress: ib.gpuAddress, length: UInt64(ib.length))
        geo.indexType = .uint32
        geo.triangleCount = mesh.triangles.count
        geo.opaque = true
        blasDescriptor = MTL4PrimitiveAccelerationStructureDescriptor()
        blasDescriptor.geometryDescriptors = [geo]
        let bs = context.device.accelerationStructureSizes(descriptor: blasDescriptor)
        guard let bottom = context.device.makeAccelerationStructure(size: bs.accelerationStructureSize) else {
            throw RenderFailure("BLAS 分配失败")
        }
        blas = bottom
        blas.label = "Procedural scene BLAS"
        scratchBLAS = try context.buffer(bs.buildScratchBufferSize, "BLAS scratch")
        var instance = MTLIndirectAccelerationStructureInstanceDescriptor()
        instance.transformationMatrix = MTLPackedFloat4x3(
            columns: (
                MTLPackedFloat3Make(1, 0, 0), MTLPackedFloat3Make(0, 1, 0), MTLPackedFloat3Make(0, 0, 1),
                MTLPackedFloat3Make(0, 0, 0)
            ))
        instance.mask = 255
        instance.accelerationStructureID = blas.gpuResourceID
        let instances = try context.upload([instance], "TLAS instances")
        tlasDescriptor = MTL4InstanceAccelerationStructureDescriptor()
        tlasDescriptor.instanceDescriptorType = .indirect
        tlasDescriptor.instanceDescriptorBuffer = MTL4BufferRange(
            bufferAddress: instances.gpuAddress, length: UInt64(instances.length))
        tlasDescriptor.instanceDescriptorStride =
            MemoryLayout<MTLIndirectAccelerationStructureInstanceDescriptor>.stride
        tlasDescriptor.instanceCount = 1
        let ts = context.device.accelerationStructureSizes(descriptor: tlasDescriptor)
        guard let top = context.device.makeAccelerationStructure(size: ts.accelerationStructureSize) else {
            throw RenderFailure("TLAS 分配失败")
        }
        tlas = top
        tlas.label = "Scene TLAS"
        scratchTLAS = try context.buffer(ts.buildScratchBufferSize, "TLAS scratch")
        var s = PTScene()
        s.vertices = vb.gpuAddress
        s.triangles = tb.gpuAddress
        s.materials = mb.gpuAddress
        s.cie = cb.gpuAddress
        s.gold = gb.gpuAddress
        s.textures = (textures[0].gpuResourceID._impl, textures[1].gpuResourceID._impl)
        s.acceleration = tlas.gpuResourceID._impl
        root = try context.upload([s], "Bindless scene root")
        allocations =
            [vb, tb, ib, mb, cb, gb, instances, blas, tlas, scratchBLAS, scratchTLAS, root]
            + textures.map {
                $0 as MTLAllocation
            }
    }
}
