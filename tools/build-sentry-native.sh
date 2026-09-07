#!/bin/sh
#
# Configure+build+install sentry-native in one shot
#
# Everything is compiled by `zig cc` / `zig c++` through generated shims rather
# than by the host toolchain. That is what lets the resulting archives link
# against the same bundled libc++ the consumer compiles with, and what makes
# `-target` actually reach the sentry-native build.
#
#   $1  sentry-native source directory
#   $2  output directory (build tree, install prefix and shims live here)
#   $3  zig executable
#   $4  target triple, passed to the shims as `-target`
#   $5  CMAKE_BUILD_TYPE
#   $6  SENTRY_BACKEND
#   $7  SENTRY_TRANSPORT
#   $8  CMAKE_SYSTEM_NAME, or empty to leave CMake in native mode
#   $9  CMAKE_SYSTEM_PROCESSOR, only read when $8 is set
#   $10 space-separated archive names to verify after install
#   $11 CURL_INCLUDE_DIR, or empty to let CMake find one
#   $12 CURL_LIBRARY, or empty to let CMake find one

set -eu

src="$1"
out="$2"
zig="$3"
triple="$4"
build_type="$5"
backend="$6"
transport="$7"
system_name="$8"
system_processor="$9"
expected_libs="${10}"
curl_include_dir="${11}"
curl_library="${12}"

# Zig hands us paths relative to the build root (our cwd), but CMake bakes them
# into rules that Ninja later resolves from inside the build directory. Make
# every path absolute up front so it survives that change of directory.
abspath() {
    case "$1" in
        "" | /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "$1" ;;
    esac
}

src="$(abspath "$src")"
out="$(abspath "$out")"
curl_include_dir="$(abspath "$curl_include_dir")"
curl_library="$(abspath "$curl_library")"

toolchain="$out/toolchain"
build_dir="$out/build"
install_dir="$out/install"
log="$out/cmake.log"
mkdir -p "$toolchain" "$build_dir" "$install_dir"
: > "$log"

# Quiet on success, full transcript on failure: CMake and Ninja are far too
# chatty to let loose on a `zig build` that is doing other things.
run() {
    if ! "$@" >>"$log" 2>&1; then
        echo "sentry-zig: command failed: $*" >&2
        echo "sentry-zig: full log follows ($log)" >&2
        cat "$log" >&2
        exit 1
    fi
}

if [ "$(uname -s)" = "Darwin" ]; then
    # Homebrew is not on a non-login shell's PATH.
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    export PATH
    if [ -z "${SDKROOT:-}" ]; then
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
        export SDKROOT
    fi
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "sentry-zig: 'cmake' not found on PATH; it is required to build sentry-native" >&2
    exit 1
fi

if command -v ninja >/dev/null 2>&1; then
    generator="Ninja"
else
    generator="Unix Makefiles"
fi

# Compiler shims. Baking `-target` in here rather than into CMAKE_*_FLAGS keeps
# it applied to CMake's own probe compilations, so configure-time feature
# detection sees the target instead of the host.
write_shim() {
    shim="$toolchain/$1"
    cat > "$shim" <<EOF
#!/bin/sh
exec "$zig" $2 "\$@"
EOF
    chmod +x "$shim"
}

write_shim zig-cc "cc -target $triple"
write_shim zig-c++ "c++ -target $triple"
write_shim zig-ar "ar"
write_shim zig-ranlib "ranlib"

set -- \
    -G "$generator" \
    -S "$src" \
    -B "$build_dir" \
    -DCMAKE_BUILD_TYPE="$build_type" \
    -DCMAKE_C_COMPILER="$toolchain/zig-cc" \
    -DCMAKE_CXX_COMPILER="$toolchain/zig-c++" \
    -DCMAKE_AR="$toolchain/zig-ar" \
    -DCMAKE_RANLIB="$toolchain/zig-ranlib" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DSENTRY_BUILD_SHARED_LIBS=OFF \
    -DSENTRY_BUILD_TESTS=OFF \
    -DSENTRY_BUILD_EXAMPLES=OFF \
    -DSENTRY_BACKEND="$backend" \
    -DSENTRY_TRANSPORT="$transport"

# Left to itself CMake picks up the host assembler, which happens to work while
# host and target share an architecture and then fails on vendored libunwind's
# per-arch `.S` files the moment they don't.
set -- "$@" -DCMAKE_ASM_COMPILER="$toolchain/zig-cc"

# CMake >= 3.27 asks the linker for a dependency file; `zig cc` rejects the flag
# ("unsupported linker arg: --dependency-file=...").
set -- "$@" -DCMAKE_LINK_DEPENDS_USE_LINKER=OFF

# Crashpad defaults to the system zlib, which an explicit `-target` puts out of
# reach: it drops the host's multiarch lib dir from the compiler's search path,
# so CMake finds zlib.h but no libz. The vendored copy is complete, and building
# it also keeps crashpad_handler free of a libz.so.1 runtime dependency — which
# matters for a binary we ship next to the app.
set -- "$@" -DCRASHPAD_ZLIB_SYSTEM=OFF

# Crashpad's Linux HTTP transport links libcurl unconditionally, with no option
# to opt out, so a cross-architecture Linux build has to be pointed at a libcurl
# for the target. sentry-zig refuses that build up front unless these are set.
if [ -n "$curl_include_dir" ]; then
    set -- "$@" -DCURL_INCLUDE_DIR="$curl_include_dir" -DCURL_LIBRARY="$curl_library"
fi

if [ -n "$system_name" ]; then
    set -- "$@" -DCMAKE_SYSTEM_NAME="$system_name"
    if [ -n "$system_processor" ]; then
        set -- "$@" -DCMAKE_SYSTEM_PROCESSOR="$system_processor"
    fi
fi

run cmake "$@"
run cmake --build "$build_dir" --parallel
run cmake --install "$build_dir"

missing=""
for lib in $expected_libs; do
    [ -f "$install_dir/lib/$lib" ] || missing="$missing $lib"
done
if [ -n "$missing" ]; then
    echo "sentry-zig: sentry-native did not install:$missing" >&2
    echo "sentry-zig: what it did install under lib/:" >&2
    ls -1 "$install_dir/lib" >&2 || true
    exit 1
fi

# The object tree is several times the size of what we keep and is never reused:
# any changed input makes `zig build` re-run this script into a fresh output
# directory anyway.
rm -rf "$build_dir"
