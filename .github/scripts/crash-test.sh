#!/usr/bin/env bash
#
# End-to-end check that sentry-zig produces a working crash reporter:
#
#   1. build test/crash against sentry-zig
#   2. assert crashpad_handler shipped next to the executable
#   3. run it and let it fault
#   4. assert crashpad wrote a minidump into the database directory
#
# Invoked from .github/workflows/crash-test.yml with `shell: bash`, so the same
# script runs on all three runners (Git Bash on Windows). Runs locally too:
#
#   .github/scripts/crash-test.sh
#
# Optional first argument is a Zig target triple to build for, which is how a
# cross-compilation leg would use this. Without it, the run is native; with it,
# the binary is only built, not executed.

set -euo pipefail

target="${1:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
project="$repo_root/test/crash"

fail() {
    echo "crash-test: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------

build_args=()
if [ -n "$target" ]; then
    build_args+=("-Dtarget=$target")
fi

echo "==> building test/crash ${build_args[*]:-(native)}"
( cd "$project" && zig build "${build_args[@]}" )

# ---------------------------------------------------------------------------
# 2. Check the layout a shipped app depends on
# ---------------------------------------------------------------------------

bin_dir="$project/zig-out/bin"
exe="$bin_dir/crash-test"
handler="$bin_dir/crashpad_handler"
if [ -f "$exe.exe" ]; then
    exe="$exe.exe"
    handler="$handler.exe"
fi

[ -x "$exe" ] || fail "no crash-test executable at $exe"
[ -f "$handler" ] || fail "crashpad_handler was not installed next to the executable ($handler)"
echo "==> built $(basename "$exe") and $(basename "$handler")"

if [ -n "$target" ]; then
    echo "==> cross-compiled for $target; skipping execution"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Run it and let it crash
# ---------------------------------------------------------------------------

work="$(mktemp -d)"
database="$work/sentry-db"
log="$work/crash-test.log"
mkdir -p "$database"

echo "==> running, database=$database"

# The executable is a native Windows program on that runner, so it cannot make
# sense of a Git Bash path like /tmp/tmp.XXXX. Bash keeps using the POSIX form
# for its own globbing below.
if command -v cygpath >/dev/null 2>&1; then
    database_arg="$(cygpath -w "$database")"
else
    database_arg="$database"
fi

# Backgrounded so a wedged client cannot wedge the run. The test program turns
# Zig's SIGSEGV handler off (see main.zig) so that it dies promptly, but a
# client that kept spinning would otherwise block here forever — and the macOS
# and Windows legs have not been verified by hand.
"$exe" "$database_arg" >"$log" 2>&1 &
app_pid=$!

# ---------------------------------------------------------------------------
# 4. Wait for the minidump
# ---------------------------------------------------------------------------

# crashpad writes the dump out-of-process, so it appears some time after the
# child dies rather than synchronously with it. Where it lands depends on the
# transport: with none configured it stays under `pending/`, so search the whole
# database rather than one subdirectory.
shopt -s nullglob globstar

timeout_seconds="${CRASH_TEST_TIMEOUT:-90}"
deadline=$(( $(date +%s) + timeout_seconds ))
dump=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    candidates=("$database"/**/*.dmp)
    if [ "${#candidates[@]}" -gt 0 ] && [ -s "${candidates[0]}" ]; then
        dump="${candidates[0]}"
        break
    fi
    sleep 1
done

# The child is expected to be gone already; make sure neither it nor a stuck
# handler outlives this script.
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true

echo "==> program output:"
sed 's/^/    /' "$log" || true

if [ -z "$dump" ]; then
    echo "crash-test: no minidump under $database after ${timeout_seconds}s" >&2
    echo "crash-test: database contents:" >&2
    # Listed with a glob rather than `find`, which on the Windows runner can
    # resolve to Windows' own find.exe instead of the Git Bash one.
    for entry in "$database"/**/*; do
        echo "    $entry" >&2
    done
    exit 1
fi

# A minidump starts with the ASCII magic "MDMP"; anything else means we found a
# truncated or half-written file rather than a real dump.
magic="$(head -c 4 "$dump")"
[ "$magic" = "MDMP" ] || fail "$dump is not a minidump (magic '$magic')"

echo "==> minidump written: $dump ($(wc -c <"$dump") bytes)"
echo "crash-test: PASS"
