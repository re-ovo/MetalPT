import AppKit
import Metal
import simd

/// Opt-in integration harness. Runs the production graph/shaders, writes PNGs and
/// machine-readable metrics, and exits. No external assets or screenshot permissions.
enum ValidationRunner {
    static func run(_ renderer: Renderer) async {
        renderer.model.denoiseEnabled = false  // Existing reference tests inspect unfiltered transport.
        let env = ProcessInfo.processInfo.environment
        let folder = URL(
            fileURLWithPath: env["SPECTRAL_OUTPUT"] ?? "/tmp/MetalPT-validation", isDirectory: true)
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
            if env["SPECTRAL_TRANSMISSION_VALIDATE"] != nil {
                try await TransmissionValidation.run(renderer, output: output, folder: folder)
                NSApplication.shared.terminate(nil)
                return
            }
            if let path = env["SPECTRAL_GLTF"] {
                try await GLTFValidation.run(
                    renderer, url: URL(fileURLWithPath: path), output: output,
                    samples: samples, folder: folder)
                NSApplication.shared.terminate(nil)
                return
            }
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
            for kind in DemoScene.allCases {
                renderer.model.scene = kind
                var gpuTimes: [Double] = []
                for i in 0..<samples {
                    if i == 2 && kind == .cornell && env["SPECTRAL_CAPTURE"] != nil {
                        let desc = MTLCaptureDescriptor()
                        desc.captureObject = d

                        desc.destination = .gpuTraceDocument
                        desc.outputURL = folder.appendingPathComponent("MetalPT.gputrace")
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
                let counts = renderer.lastCounters!.contents().bindMemory(to: UInt32.self, capacity: 8)
                guard counts[3] == 0 && counts[4] == 0 else {
                    throw RenderFailure("GPU overflow / nonfinite diagnostics")
                }
                let sorted = gpuTimes.sorted()
                report["\(kind)GPUms"] =
                    sorted.isEmpty ? renderer.model.gpuMilliseconds : sorted[sorted.count / 2]
                report["\(kind)GPUmsStatistic"] = "median, excluding first 4 frames"
            }
            let rgb = try await renderer.validateRGB()
            guard simd_length(rgb[0] - SIMD4<Float>(0.2, 0.5, 0.8, 0)) < 0.0001,
                rgb[1].x == 1, abs(rgb[1].y - 0.04) < 0.0001,
                simd_length(rgb[2] - SIMD4<Float>(1, 0.71, 0.29, 0)) < 0.0001,
                abs(rgb[3].x - 1) < 0.002
            else { throw RenderFailure("RGB numerical checks failed: \(rgb)") }
            report["rgbChecks"] = rgb.map { [$0.x, $0.y, $0.z, $0.w] }
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
                renderer.model.camera.look(8, -3)
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
            report["frameResources"] = renderer.lastFrameStats
            if env["SPECTRAL_PROFILE"] == "1" {
                guard !renderer.lastPassTimings.isEmpty,
                    renderer.lastPassTimings.values.allSatisfy({ $0.isFinite && $0 >= 0 })
                else {
                    throw RenderFailure("Missing or invalid pass timestamps")
                }
                report["passGPUms"] = renderer.lastPassTimings
            }
            report["engineChecks"] = try await EngineValidation.run(renderer, output: output)
            report["surfaceAssets"] = try await SurfaceAssetValidation.run(
                renderer, output: output, folder: folder)
            report["analyticLights"] = try await LightValidation.run(renderer, output: output, folder: folder)
            report["spatialDenoise"] = try await DenoiseValidation.run(
                renderer, output: output, folder: folder)
            report["cameraDisplay"] = try await validateCameraDisplay(
                renderer, output: output, folder: folder)
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
    static func validateCameraDisplay(_ renderer: Renderer, output: MTLTexture, folder: URL) async throws
        -> [String: Any]
    {
        let model = renderer.model
        model.scene = .cornell
        model.resetCamera()
        model.paused = false
        model.denoiseEnabled = false
        model.exposure = 0
        model.displayTransform = .aces
        model.whiteBalanceTemperature = 6504
        model.whiteBalanceTint = 0
        for _ in 0..<64 {
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
        }
        try await validateCameraRays(renderer)
        let pinhole = readPixels(output)
        _ = try save(output, to: folder.appendingPathComponent("camera-pinhole.png"))
        model.paused = true
        let samples = model.samples
        for transform in DisplayTransform.allCases {
            model.displayTransform = transform
            model.whiteBalanceTemperature = 9000
            model.whiteBalanceTint = 0.2
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            guard model.samples == samples, readPixels(output) != pinhole else {
                throw RenderFailure(
                    "Display controls must update paused output without resetting accumulation")
            }
            _ = try save(output, to: folder.appendingPathComponent("display-\(transform.rawValue).png"))
        }
        model.displayTransform = .aces
        model.whiteBalanceTemperature = 6504
        model.whiteBalanceTint = 0
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        guard readPixels(output) == pinhole else {
            throw RenderFailure("Display edits changed linear accumulation")
        }
        model.paused = false
        model.camera.depthOfField = true
        model.camera.apertureRadius = 0.15
        model.camera.focusDistance = 4
        model.denoiseEnabled = false
        for index in 0..<64 {
            _ = try renderer.render(to: output)
            await renderer.waitForGPU()
            if index == 0 && model.samples != 1 {
                throw RenderFailure("Lens edits did not reset accumulation")
            }
        }
        guard readPixels(output) != pinhole else { throw RenderFailure("Aperture did not affect image") }
        let counters = renderer.lastCounters!.contents().bindMemory(to: UInt32.self, capacity: 8)
        guard counters[3] == 0 && counters[4] == 0 else { throw RenderFailure("Lens produced invalid paths") }
        _ = try save(output, to: folder.appendingPathComponent("camera-dof.png"))
        model.camera.focusDistance = 8
        _ = try renderer.render(to: output)
        await renderer.waitForGPU()
        guard model.samples == 1 else { throw RenderFailure("Focus edit did not reset accumulation") }
        return [
            "passed": true, "samples": 64, "depth": model.maxDepth,
            "width": output.width, "height": output.height, "apertureRadius": 0.15, "focusDistance": 4,
        ]
    }

    private static func validateCameraRays(_ renderer: Renderer) async throws {
        var camera = FPSCamera()
        camera.yaw = 0.4
        camera.pitch = -0.3
        camera.apertureRadius = 0.15
        for (enabled, focus) in [(false, Float(4)), (true, 4), (true, 8)] {
            camera.depthOfField = enabled
            camera.focusDistance = focus
            var frame = PTFrame()
            camera.fill(&frame, aspect: 4.0 / 3.0)
            frame.size = [128, 96, 0, 0]
            let rays = try await renderer.validateNumerics(
                kernel: "validateCameraRays", count: 8, frameConstants: frame)
            // Pixel (0.3, 0.7) corresponds to projection coordinates (-0.4, -0.4).
            let target =
                camera.position + focus * (camera.forward - 0.4 * frame.right.xyz - 0.4 * frame.up.xyz)
            for i in 0..<4 {
                let origin = rays[2 * i].xyz, direction = rays[2 * i + 1].xyz
                let offset = origin - camera.position
                let radius = enabled ? camera.apertureRadius * (i < 2 ? 0.5 : 0.9) : 0
                let axial = simd_dot(direction, camera.forward)
                let intersection = origin + direction * (focus / axial)
                guard abs(simd_length(offset) - radius) < 0.0001,
                    abs(simd_dot(offset, camera.forward)) < 0.0001,
                    abs(simd_length(direction) - 1) < 0.0001,
                    axial > 0, simd_distance(intersection, target) < 0.0001
                else {
                    throw RenderFailure(
                        "Camera ray violates aperture or focal-plane invariant: lens=\(enabled), focus=\(focus), ray=\(i)"
                    )
                }
            }
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
