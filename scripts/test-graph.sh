#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcrun swiftc -module-cache-path /tmp/spectral-module-cache -parse-as-library -import-objc-header SpectralPT/Renderer/Bridge.h SpectralPT/Renderer/RenderGraph.swift Tests/RenderGraphTests.swift -o /tmp/spectral-graph-tests
/tmp/spectral-graph-tests
