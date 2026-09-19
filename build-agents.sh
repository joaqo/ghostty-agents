#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
zig_bin="${ZIG:-zig}"
stable_tag="$(git describe --tags --match 'v[0-9]*' --abbrev=0)"
version="${stable_tag#v}+ghostty-agents.$(git rev-parse --short=9 HEAD)"
"$zig_bin" build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native \
  -Dversion-string="$version"
macos/build.nu --configuration ReleaseLocal --arch "$(uname -m)"
printf '\nBuilt Ghostty Agents: %s/macos/build/ReleaseLocal/Ghostty Agents.app\n' "$PWD"
