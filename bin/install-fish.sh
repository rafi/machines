#!/usr/bin/env bash
# Install Fish shell without root access at $HOME/.local
# Dependencies: https://github.com/fish-shell/fish-shell#dependencies-1
# 1. a C++11 compiler (g++ 4.8 or later, or clang 3.3 or later)
# 2. CMake (version 3.5 or later)
set -euo pipefail

FISH_SHELL_VERSION=3.7.1

# Create our directories
BUILD_TEMP_DIR="$(mktemp -d)"
LOCAL_DIR="$HOME"/.local
mkdir -p "$LOCAL_DIR" "$BUILD_TEMP_DIR"
cd "$BUILD_TEMP_DIR"
# shellcheck disable=SC2064
trap 'exit 1' HUP INT PIPE QUIT TERM
trap 'rm -rf "$BUILD_TEMP_DIR"' EXIT

# Download source files for Fish Shell
wget https://github.com/fish-shell/fish-shell/releases/download/${FISH_SHELL_VERSION}/fish-${FISH_SHELL_VERSION}.tar.xz

# Extract files, configure, and compile
tar xvJf fish-${FISH_SHELL_VERSION}.tar.xz
cd fish-${FISH_SHELL_VERSION}
cmake -DCMAKE_INSTALL_PREFIX:PATH="$HOME"/.local -DBUILD_SHARED_LIBS=OFF -DBUILD_DOCS=OFF .
make
make install
