#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Override this path if clang-format is installed outside PATH.
formatter="${CLANG_FORMAT:-clang-format}"
if ! command -v "$formatter" >/dev/null 2>&1; then
    print -u2 "clang-format is required. Install it or set CLANG_FORMAT to its executable path."
    exit 1
fi

xcrun swift-format format --configuration .swift-format --in-place --recursive MetalPT Tests
find MetalPT -type f \( -name '*.metal' -o -name '*.h' \) -print0 |
    xargs -0 "$formatter" --style=file -i
