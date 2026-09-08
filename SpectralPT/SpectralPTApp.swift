import SwiftUI

@main
enum SpectralPTEntry {
    static func main() {
        if ProcessInfo.processInfo.environment["SPECTRAL_VALIDATE"] != nil {
            // A single windowless harness, independent of macOS window restoration.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task {
                @MainActor in
                do {
                    await ValidationRunner.run(try Renderer(model: RenderModel()))
                } catch {
                    print("VALIDATION FAILED: \(error)")
                    exit(1)
                }
            }
            app.run()
        } else {
            SpectralPTApp.main()
        }
    }
}

struct SpectralPTApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}
