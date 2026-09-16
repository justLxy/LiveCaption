#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
testbin=$(mktemp -d)
trap 'rm -rf "$testbin"' EXIT
swiftc -swift-version 5 Sources/Segmenter.swift Sources/CaptionHistory.swift Tests/SegmenterTests.swift -o "$testbin/segmenter-tests"
"$testbin/segmenter-tests"
