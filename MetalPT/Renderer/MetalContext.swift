import Foundation
import MetalKit

final class MetalContext {
    let device: MTLDevice
    let queue: MTL4CommandQueue
    let compiler: MTL4Compiler
    let event: MTLSharedEvent
    let library: MTLLibrary
    var pipelines: [String: MTLComputePipelineState] = [:]
    var sequence: UInt64 = 0

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw RenderFailure("未找到 Metal GPU")
        }
        guard d.supportsFamily(.metal4), d.supportsFamily(.apple9), d.supportsRaytracing,
            d.argumentBuffersSupport == .tier2
        else {
            throw RenderFailure("需要支持 Metal 4、硬件光追与 Tier 2 argument buffer 的 M3 或更新 Mac")
        }
        device = d
        guard let q = d.makeMTL4CommandQueue(), let e = d.makeSharedEvent(), let l = d.makeDefaultLibrary()
        else {
            throw RenderFailure("无法创建 Metal 4 队列或加载着色器")
        }
        queue = q
        event = e
        library = l
        compiler = try d.makeCompiler(descriptor: MTL4CompilerDescriptor())
        for name in [
            "initialize", "prepareBounce", "intersectPaths", "shadePaths", "prepareShadow", "traceShadows",
            "finishBounce", "accumulate", "displayImage", "validateRGB", "validateSurfaceAssets",
            "validateCoverage", "validateTransmission",
        ] {
            let f = MTL4LibraryFunctionDescriptor()
            f.library = l
            f.name = name
            let p = MTL4ComputePipelineDescriptor()
            p.label = name
            p.computeFunctionDescriptor = f
            pipelines[name] = try compiler.makeComputePipelineState(descriptor: p, compilerTaskOptions: nil)
        }
        precondition(MemoryLayout<PTVertex>.stride == 96 && MemoryLayout<PTMaterial>.stride == 432)
        precondition(MemoryLayout<PTPath>.stride == 80 && MemoryLayout<PTFrame>.stride == 112)
        precondition(MemoryLayout<PTScene>.stride == 80 && MemoryLayout<PTWork>.stride == 64)
    }
    func buffer(_ length: Int, _ label: String, shared: Bool = false) throws -> MTLBuffer {
        guard
            let b = device.makeBuffer(
                length: max(16, length), options: shared ? .storageModeShared : .storageModePrivate)
        else {
            throw RenderFailure("GPU 内存分配失败：\(label)")
        }
        b.label = label
        return b
    }
    func upload<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
        let b = try buffer(values.count * MemoryLayout<T>.stride, label, shared: true)
        values.withUnsafeBytes {
            if let p = $0.baseAddress {
                b.contents().copyMemory(from: p, byteCount: $0.count)
            }
        }
        return b
    }
    func residency(_ allocations: [MTLAllocation]) throws -> MTLResidencySet {
        let d = MTLResidencySetDescriptor()
        d.initialCapacity = allocations.count
        let set = try device.makeResidencySet(descriptor: d)
        set.addAllocations(allocations)
        set.commit()
        return set
    }
    func table(
        scene: MTLBuffer, work: MTLBuffer, frame: MTLBuffer, offset: Int = 0, output: MTLTexture? = nil
    ) throws -> MTL4ArgumentTable {
        try table(
            sceneAddress: scene.gpuAddress, workAddress: work.gpuAddress,
            frameAddress: frame.gpuAddress + UInt64(offset), output: output)
    }
    func table(
        sceneAddress: UInt64, workAddress: UInt64, frameAddress: UInt64,
        output: MTLTexture? = nil
    ) throws -> MTL4ArgumentTable {
        let desc = MTL4ArgumentTableDescriptor()
        desc.maxBufferBindCount = 3
        desc.maxTextureBindCount = 1
        let table = try device.makeArgumentTable(descriptor: desc)
        table.setAddress(sceneAddress, index: 0)
        table.setAddress(workAddress, index: 1)
        table.setAddress(frameAddress, index: 2)
        if let output {
            table.setTexture(output.gpuResourceID, index: 0)
        }
        return table
    }
}
