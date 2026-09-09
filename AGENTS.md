# Repository Guidelines

## Project Structure & Module Organization

- `MetalPT/ContentView.swift` contains controls; `Views/MetalViewport.swift` bridges MetalKit and mouse input.
- `Renderer/` separates orchestration (`Renderer`), pass ordering (`PathTracingPasses`), individual pass declarations (`Passes/`), frame resources, camera/state, Render Graph, and GPU scene upload (`BindlessScene`). Paths are relative to `MetalPT/`.
- `Scene/` contains a stable-ID scene graph, mesh-local material slots, typed materials, compiled instance/light descriptions, CPU geometry, image/texture/sampler assets, demos, and glTF import. `Renderer/Shared.h` defines the CPU/GPU ABI.
- `Shaders/` separates sampling and RGB BSDF headers from per-stage `.metal` files (camera, intersection, shading, shadows, queues, accumulation, display, validation). Shared shader helpers must be inline to avoid duplicate definitions.
- `Resources/` holds historical data attribution/licenses; `Assets.xcassets` holds app assets. `Tests/`, `scripts/`, and `docs/validation/` contain tests, workflows, and outputs at repository root.

## Build, Test, and Development Commands

Use macOS 26.5+, an M3-or-newer Mac, and Xcode 26 with Metal Toolchain. Open `MetalPT.xcodeproj` and run **MetalPT / My Mac** for interactive development.

```sh
xcodebuild -project MetalPT.xcodeproj -scheme MetalPT \
  -configuration Debug -derivedDataPath /tmp/MetalPT-build \
  CODE_SIGNING_ALLOWED=NO build
scripts/test-graph.sh
scripts/validate-gpu.sh validation
scripts/validate-gpu.sh capture
SPECTRAL_SPP=512 scripts/validate-gpu.sh release
```

These commands build, test graph/ABI, validate GPU execution, capture frames, and measure Release rendering. Set `SPECTRAL_OUTPUT` to choose the report directory. Run capture and Shader Validation separately.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` functions and properties. Shared C structures use the `PT` prefix. Keep blocks expanded. Run `scripts/format.sh` using Xcode's `swift-format` and `clang-format` (override with `CLANG_FORMAT`). Repository configurations set a 110-column limit for Swift, MSL, and C headers.

Declare every pass resource access and GPU stage through its typed inputs in Render Graph. Register indirect scene resources in `ResourceRegistry`; materialize transients after graph compilation. Preserve residency for indirect references and retain resources until GPU completion. Update ABI assertions whenever shared layouts change. Document linear RGB conventions, PDFs, and weighting assumptions.

## Testing Guidelines

Graph tests are standalone Swift assertions, not XCTest. Keep graph/ABI checks in `Tests/RenderGraphTests.swift`, hierarchy/material-binding checks in `Tests/SceneGraphTests.swift`, and primitive/image/binding checks in `Tests/SurfaceAssetTests.swift`, with descriptive failure messages. GPU integration checks live in `ValidationRunner.swift` and execute production shaders.

Cover changed behavior with graph/ABI checks or deterministic GPU scenarios. For rendering changes, inspect images and record resolution, spp, depth, hardware, and validation status. There is no percentage coverage target. Simple changes do not require permanent unit-test code.

## Commit & Pull Request Guidelines

Use Conventional Commit types with concise Chinese subjects, such as `refactor(renderer): 拆分资源管理模块`. Preserve unrelated working-tree changes.

PRs should explain the problem, resulting behavior, validation commands, and limitations. Link relevant issues and include before/after images for visual changes. Keep build products and large `.gputrace` bundles outside the repository. Preserve data attribution in `Resources/NOTICE.md`.
