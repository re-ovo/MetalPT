#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcrun swiftc -module-cache-path /tmp/spectral-module-cache -parse-as-library -import-objc-header MetalPT/Renderer/Bridge.h MetalPT/Renderer/RenderFailure.swift MetalPT/Renderer/ResourceDescriptors.swift MetalPT/Renderer/GraphProfiler.swift MetalPT/Renderer/RenderGraph.swift MetalPT/Scene/SceneIdentity.swift MetalPT/Scene/SceneImage.swift MetalPT/Scene/SceneTexture.swift MetalPT/Scene/MeshPrimitive.swift MetalPT/Scene/SceneMesh.swift MetalPT/Scene/SceneMaterial.swift MetalPT/Scene/SceneDescription.swift MetalPT/Scene/SceneGraph.swift MetalPT/Renderer/FPSCamera.swift Tests/FPSCameraTests.swift Tests/SurfaceAssetTests.swift Tests/SceneGraphTests.swift Tests/RenderGraphTests.swift -o /tmp/spectral-graph-tests
/tmp/spectral-graph-tests
