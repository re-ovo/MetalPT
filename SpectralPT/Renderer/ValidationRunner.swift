import AppKit
import Metal

/// Opt-in integration harness. Runs the production graph/shaders, writes PNGs and
/// machine-readable metrics, and exits. No external assets or screenshot permissions.
enum ValidationRunner {
    static func run(_ renderer: Renderer) async {
        let env = ProcessInfo.processInfo.environment
        let folder = URL(
            fileURLWithPath: env["SPECTRAL_OUTPUT"] ?? "/tmp/SpectralPT-validation", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let samples = Int(env["SPECTRAL_SPP"] ?? "64") ?? 64
            let d = renderer.context.device
            func texture(_ w: Int, _ h: Int) throws -> MTLTexture {
                let td = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                td.storageMode = .shared
                td.usage = [.shaderWrite, .shaderRead]
                guard let t = d.makeTexture(descriptor: td) else {
                    throw RenderFailure("Validation texture allocation failed")
                }
                return t
            }
            let outputWidth = max(16, Int(env["SPECTRAL_WIDTH"] ?? "640") ?? 640)
            let outputHeight = max(16, Int(env["SPECTRAL_HEIGHT"] ?? "480") ?? 480)
            let output = try texture(outputWidth, outputHeight)
            var prismMesh = SceneMesh()
            prismMesh.prism()
            let center: SIMD3<Float> = [0.65 / 3, 0.89, 0]
            for t in prismMesh.triangles {
                let a = prismMesh.vertices[Int(t.indices.x)].position.xyz
                let b = prismMesh.vertices[Int(t.indices.y)].position.xyz
                let c = prismMesh.vertices[Int(t.indices.z)].position.xyz
                guard simd_dot(simd_cross(b - a, c - a), (a + b + c) / 3 - center) > 0 else {
                    throw RenderFailure("Prism inward winding")
                }
            }
            renderer.model.scale = 0.5
            var report: [String: Any] = [
                "device": d.name, "spp": samples, "output": "\(outputWidth)x\(outputHeight)",
                "render": "\(outputWidth/2)x\(outputHeight/2)",
            ]
            let capture = MTLCaptureManager.shared()
            var capturing = false
            var prismPixels: [UInt8] = []
            for kind in DemoScene.allCases {
                renderer.model.scene = kind
                var gpuTimes: [Double] = []
                for i in 0..<samples {
                    if i == 2 && kind == .cornell && env["SPECTRAL_CAPTURE"] != nil {
                        let desc = MTLCaptureDescriptor()
                        desc.captureObject = d

                        desc.destination = .gpuTraceDocument
                        desc.outputURL = folder.appendingPathComponent("SpectralPT.gputrace")
                        try capture.startCapture(with: desc)
                        capturing = true
                    }
                    _ = try renderer.render(to: output)
                    await renderer.waitForGPU()
                    if capturing {
                        capture.stopCapture()
                        capturing = false
                    }
                    if i >= 4 {
                        gpuTimes.append(renderer.model.gpuMilliseconds)
                    }
                    if let error = renderer.model.error {
                        throw RenderFailure(error)
                    }
                }
                let stats = try save(output, to: folder.appendingPathComponent("\(kind).png"))
                report["\(kind)"] = stats
                if kind == .prism {
                    prismPixels = readPixels(output)
                }
                let counts = renderer.lastCounters!.contents().bindMemory(to: UInt32.self, capacity: 8)
                guard counts[3] == 0 && counts[4] == 0 else {
                    throw RenderFailure("GPU overflow / nonfinite diagnostics")
                }
                let sorted = gpuTimes.sorted()
                report["\(kind)GPUms"] =
                    sorted.isEmpty ? renderer.model.gpuMilliseconds : sorted[sorted.count / 2]
                report["\(kind)GPUmsStatistic"] = "median, excluding first 4 frames"
            }
            let spectral = try await renderer.validateSpectral()
            guard abs(spectral[0].y - 1) < 0.0001, spectral[1].x > spectral[1].y,
                spectral[1].z == 1, abs(spectral[1].w - 0.04) < 0.0001,
                simd_length(spectral[2] - spectral[3]) < 0.001,
                simd_length(spectral[4] - SIMD4<Float>(repeating: 0.73)) < 0.0001,
                spectral[5].min() > 0 && spectral[5].max() < 1, abs(spectral[6].x - 1) < 0.002
            else {
                throw RenderFailure("Spectral numerical checks failed: \(spectral)")
            }
            report["spectralChecks"] = spectral.map {
                [$0.x, $0.y, $0.z, $0.w]
            }
            renderer.model.dispersion = false
            for _ in 0..<samples {
                _ = try renderer.render(to: output)
                await renderer.waitForGPU()
            }
            report["prismNoDispersion"] = try save(
                output, to: folder.appendingPathComponent("prism-no-dispersion.png"))
            let noDispersion = readPixels(output)
            let difference =
                zip(prismPixels, noDispersion).map {
                    abs(Double($0) - Double($1))
                }.reduce(0, +)
                / Double(prismPixels.count) / 255
            guard difference > 0.0001 else {
                throw RenderFailure("Dispersion toggle did not affect image")
            }
            report["dispersionMeanAbsoluteDifference"] = difference
            renderer.validationMode = 1
            renderer.model.resetToken += 1
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            let black = readPixels(output)
            guard
                stride(from: 0, to: black.count, by: 4).allSatisfy({
                    black[$0] == 0 && black[$0 + 1] == 0 && black[$0 + 2] == 0
                })
            else {
                throw RenderFailure("Black scene generated energy")
            }
            report["blackScenePassed"] = true
            renderer.validationMode = 0
            renderer.model.resetToken += 1
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            // Exercise history invalidation, display-only exposure, pause/resume, and in-flight resource retirement.
            renderer.model.paused = true
            let oldSamples = renderer.model.samples
            renderer.model.exposure = 1
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            guard renderer.model.samples == oldSamples else {
                throw RenderFailure("Exposure / pause reset accumulation")
            }
            renderer.model.paused = false
            for i in 0..<9 {
                renderer.model.scene = i % 2 == 0 ? .cornell : .prism
                renderer.model.camera.orbit(8, -3)
                let resized = try texture(320 + i * 17, 240 + i * 11)
                _ = try renderer.render(to: resized)
                if i % 3 == 2 {
                    await renderer.waitForGPU()
                }
            }
            await renderer.waitForGPU()
            renderer.model.resetToken += 1
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            guard renderer.model.samples == 1 else {
                throw RenderFailure("Reset failed")
            }
            try renderer.lastGraph.write(
                to: folder.appendingPathComponent("render-graph.txt"), atomically: true, encoding: .utf8)
            report["passed"] = true
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
                to: folder.appendingPathComponent("report.json"))
            print("VALIDATION PASSED: \(folder.path)")
            exit(0)
        } catch {
            print("VALIDATION FAILED: \(error)")
            try? error.localizedDescription.write(
                to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            exit(1)
        }
    }
    static func readPixels(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }
    static func save(_ texture: MTLTexture, to url: URL) throws -> [String: Double] {
        let w = texture.width, h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var total = 0.0, lit = 0.0
        for p in stride(from: 0, to: pixels.count, by: 4) {
            pixels.swapAt(p, p + 2)
            let v = Double(pixels[p]) + Double(pixels[p + 1]) + Double(pixels[p + 2])
            total += v
            if v > 0 {
                lit += 1
            }
        }
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4,
                bitsPerPixel: 32)
        else {
            throw RenderFailure("PNG encoder allocation")
        }
        pixels.withUnsafeBytes {
            bitmap.bitmapData!.update(
                from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: pixels.count)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderFailure("PNG encoding failed")
        }
        try data.write(to: url)
        guard total > 0 else {
            throw RenderFailure("Unexpected black image")
        }
        return ["meanRGB": total / Double(w * h * 3 * 255), "litFraction": lit / Double(w * h)]
    }
}
