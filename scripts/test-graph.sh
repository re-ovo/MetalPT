#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcrun swiftc -module-cache-path /tmp/spectral-module-cache -parse-as-library -import-objc-header SpectralPT/Renderer/Bridge.h SpectralPT/Renderer/RenderFailure.swift SpectralPT/Renderer/ResourceDescriptors.swift SpectralPT/Renderer/GraphProfiler.swift SpectralPT/Renderer/RenderGraph.swift SpectralPT/Scene/SceneIdentity.swift SpectralPT/Scene/SceneMesh.swift SpectralPT/Scene/SceneMaterial.swift SpectralPT/Scene/SceneDescription.swift SpectralPT/Scene/SceneGraph.swift Tests/SceneGraphTests.swift Tests/RenderGraphTests.swift -o /tmp/spectral-graph-tests
/tmp/spectral-graph-tests
