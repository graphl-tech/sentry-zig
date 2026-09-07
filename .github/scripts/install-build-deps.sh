#!/usr/bin/env bash
#
# Install what sentry-zig needs to drive sentry-native's CMake build.
#
# Zig supplies the compiler, archiver and linker, so this is only CMake and a
# generator. Runner images already ship CMake; Ninja is the one thing that is
# not reliably present.
#
# Invoked from .github/workflows/crash-test.yml with `shell: bash`, which is
# Git Bash on the Windows runner.

set -euo pipefail

case "${RUNNER_OS:-$(uname -s)}" in
    Linux)
        sudo apt-get update -qq
        sudo apt-get install -y --no-install-recommends cmake ninja-build
        ;;
    macOS | Darwin)
        # CMake is preinstalled on the macOS images; Ninja usually is too, so
        # only reach for Homebrew when it is genuinely missing.
        command -v ninja >/dev/null 2>&1 || brew install ninja
        command -v cmake >/dev/null 2>&1 || brew install cmake
        ;;
    Windows* | MINGW* | MSYS*)
        # The windows-* images ship both, and the Unix Makefiles fallback would
        # not work here anyway (no make), so fail loudly rather than later.
        for tool in cmake ninja; do
            command -v "$tool" >/dev/null 2>&1 || {
                echo "install-build-deps: '$tool' not found on the Windows runner" >&2
                exit 1
            }
        done
        ;;
    *)
        echo "install-build-deps: unrecognised runner '${RUNNER_OS:-$(uname -s)}'" >&2
        exit 1
        ;;
esac

echo "cmake: $(cmake --version | head -1)"
if command -v ninja >/dev/null 2>&1; then
    echo "ninja: $(ninja --version)"
else
    echo "ninja: not present, CMake will fall back to Unix Makefiles"
fi
