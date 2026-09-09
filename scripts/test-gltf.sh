#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcrun swiftc -module-cache-path /tmp/spectral-module-cache -parse-as-library \
  -import-objc-header MetalPT/Renderer/Bridge.h MetalPT/Renderer/RenderFailure.swift \
  MetalPT/Scene/{SceneIdentity,SceneImage,SceneTexture,MeshPrimitive,SceneMesh,SceneMaterial,SceneDescription,SceneGraph}.swift \
  MetalPT/Scene/GLTF/*.swift Tests/GLTFTests.swift -o /tmp/spectral-gltf-tests
/tmp/spectral-gltf-tests
