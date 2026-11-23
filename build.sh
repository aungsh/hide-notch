#!/bin/zsh
# Builds hide-notch and installs it to ~/.local/bin.
set -euo pipefail
cd "${0:A:h}"
mkdir -p bin "$HOME/.local/bin"
swiftc -O -swift-version 5 hide-notch.swift -o bin/hide-notch
strip -x bin/hide-notch
codesign --force --sign - bin/hide-notch
cp bin/hide-notch "$HOME/.local/bin/hide-notch"
echo "installed: $HOME/.local/bin/hide-notch ($(stat -f%z bin/hide-notch) bytes)"
