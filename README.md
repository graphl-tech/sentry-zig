# sentry-zig

Shared [sentry-native](https://github.com/getsentry/sentry-native) build glue
for Zig projects: builds sentry-native and Crashpad and provides
helpers to use from the zig build system.

Requires CMake be in PATH. We plan to supplant the CMake usage with the zig build system eventually.

Targets **Zig 0.15.2**.

## Usage

Add the dependency:

```sh
zig fetch --save git+https://github.com/graphl-tech/sentry-zig
```

Then, in `build.zig`:

```zig
const sentry = @import("sentry_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ .name = "app", .root_module = ... });

    // Headers, archives and the system libs/frameworks the backend needs.
    sentry.linkSentry(b, exe);

    // Crashpad spawns crashpad_handler at runtime, so it has to be installed
    // next to the executable.
    const artifacts = sentry.buildSentryNativeArtifacts(b, .{
        .target = target,
        .optimize = optimize,
    });
    b.getInstallStep().dependOn(
        &sentry.addInstallCrashpadHandler(b, artifacts, .bin).step,
    );
}
```

At runtime, point sentry at the handler you installed:

```zig
const options = c.sentry_options_new();
c.sentry_options_set_handler_path(options, ".../crashpad_handler");
c.sentry_options_set_database_path(options, ".../sentry-db");
_ = c.sentry_init(options);
```

With `.transport = .none` (the default) nothing is ever uploaded; crashes just
land as `.dmp` minidumps under the database path for offline analysis.

## Requirements

`cmake` on `PATH`, plus a Zig toolchain. Ninja is used when present and
`Unix Makefiles` otherwise. Zig C++ is used instead of the local compiler.

Nothing else is taken from the host. Crashpad's vendored zlib is built rather
than the system one, and on Linux — where crashpad links libcurl
unconditionally, with no CMake option to opt out — libcurl is built for the
target from a lazy `curl` dependency. Override with `.curl = .system` to search
the host instead, or `.curl = .explicit` to point at your own:

```zig
sentry.buildSentryNativeArtifacts(b, .{
    .target = target,
    .optimize = optimize,
    .curl = .{ .explicit = .{ .include_dir = ..., .library = ... } },
});
```

The bundled libcurl is built without TLS, since crashpad only reaches it to
upload a report and `.transport = .none` never does. Use `.system` or
`.explicit` if you set `.transport = .curl`.

## Platform support

Linux and macOS, including cross-compiling between architectures. Windows is
not wired up yet: crashpad needs the Windows SDK, which `zig cc` does not
bundle, so Windows targets fail early with an explanation rather than deep
inside CMake

## License

MIT. sentry-native itself is MIT; Crashpad and mini_chromium are Apache-2.0.
