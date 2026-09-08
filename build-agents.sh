#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
zig_bin="${ZIG:-zig}"
"$zig_bin" build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native
macos/build.nu --configuration ReleaseLocal --arch "$(uname -m)"
printf '\nBuilt Ghostty Agents: %s/macos/build/ReleaseLocal/Ghostty Agents.app\n' "$PWD"
