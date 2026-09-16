#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/tests
swiftc -swift-version 5 Sources/Segmenter.swift Sources/CaptionHistory.swift Tests/main.swift -framework NaturalLanguage -o .build/tests/segmentation
.build/tests/segmentation
