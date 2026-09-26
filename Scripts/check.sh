#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

swift format lint --strict --configuration .swift-format --recursive Sources Tests
swift test --disable-sandbox
