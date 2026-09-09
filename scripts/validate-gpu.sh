#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mode=${1:-validation}
build_dir=${METALPT_BUILD_DIR:-/tmp/MetalPT-build}
case "$mode" in
  validation) configuration=Debug; export MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ;;
  capture) configuration=Debug; unset MTL_SHADER_VALIDATION; export MTL_DEBUG_LAYER=1 MTL_CAPTURE_ENABLED=1 METALPT_CAPTURE=1 ;;
  release) configuration=Release; unset MTL_SHADER_VALIDATION MTL_DEBUG_LAYER ;;
  *) print -u2 'Usage: scripts/validate-gpu.sh [validation|capture|release]'; exit 2 ;;
esac
export METALPT_VALIDATE=1
export METALPT_OUTPUT=${METALPT_OUTPUT:-/tmp/MetalPT-$mode-$(date +%Y%m%d-%H%M%S)}
export METALPT_SPP=${METALPT_SPP:-64}
xcodebuild -project MetalPT.xcodeproj -scheme MetalPT -configuration "$configuration" -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO build
"$build_dir/Build/Products/$configuration/MetalPT.app/Contents/MacOS/MetalPT"
