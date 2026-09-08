import Foundation
import Metal

/// Exercises the same asynchronous installation path used by native drag and drop.
enum GLTFValidation {
    static func run(_ renderer: Renderer, url: URL, output: MTLTexture, samples: Int, folder: URL)
        async throws
    {
        let importer = renderer.model.importer
        importer.renderer = renderer
        importer.load(url)
        importer.showDemo()  // Invalidate an in-flight request.
        importer.load(url)
        while importer.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        guard importer.error == nil, importer.filename == url.lastPathComponent else {
            throw RenderFailure(importer.error ?? "导入未安装")
        }
        var times: [Double] = []
        var firstGraph = ""
        let capture = MTLCaptureManager.shared()
        for sample in 0..<max(samples, 1) {
            let capturing = sample == 0 && ProcessInfo.processInfo.environment["SPECTRAL_CAPTURE"] != nil
            if capturing {
                let descriptor = MTLCaptureDescriptor()
                descriptor.captureObject = renderer.context.device
                descriptor.destination = .gpuTraceDocument
                descriptor.outputURL = folder.appendingPathComponent("GLTF.gputrace")
                try capture.startCapture(with: descriptor)
            }
            defer { if capturing { capture.stopCapture() } }
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            times.append(renderer.model.gpuMilliseconds)
            if sample == 0 { firstGraph = renderer.lastGraph }
        }
        let blasPasses = firstGraph.split(separator: "\n").filter { $0.contains(": Build BLAS") }.count
        guard blasPasses == 1, firstGraph.contains(": Build TLAS [barrier]") else {
            throw RenderFailure("BLAS 必须批量构建且 TLAS 必须有依赖屏障")
        }
        let stats = try ValidationRunner.save(output, to: folder.appendingPathComponent("gltf.png"))
        let counters = renderer.lastCounters!.contents().bindMemory(to: UInt32.self, capacity: 8)
        guard counters[3] == 0, counters[4] == 0 else { throw RenderFailure("glTF GPU diagnostics") }
        let previous = importer.filename
        importer.load(url.deletingLastPathComponent().appendingPathComponent("missing-model.glb"))
        while importer.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        guard importer.error != nil, importer.filename == previous, renderer.model.error == nil else {
            throw RenderFailure("导入失败污染了当前场景")
        }
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        let report: [String: Any] = [
            "device": renderer.context.device.name, "spp": samples,
            "resolution": renderer.model.resolution, "depth": renderer.model.maxDepth,
            "gpuMsMedian": times.sorted()[times.count / 2], "image": stats,
            "queueOverflow": counters[3], "nonFinite": counters[4],
            "meshCount": renderer.lastFrameStats["meshCount"] ?? 0,
            "instanceCount": renderer.lastFrameStats["instanceCount"] ?? 0,
            "blasBuildPasses": blasPasses,
            "staleRequestDiscarded": true, "failedImportPreservedScene": true,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("gltf.json"))
        print("GLTF GPU validation passed: \(folder.path)")
    }
}
