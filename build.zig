//! sentry-zig — sentry-native build integration for Zig projects.
//!
//! Public API (call from a consumer's build.zig):
//!
//!   const sentry = @import("sentry_zig");
//!
//!   // Build sentry-native (+ crashpad_handler) for a target.
//!   const artifacts = sentry.buildSentryNativeArtifacts(b, .{
//!       .target = target,
//!       .optimize = optimize,
//!   });
//!
//!   // Wire headers + static archives + system libs into a compile.
//!   sentry.linkSentry(b, exe);
//!
//!   // Crashpad spawns this binary at runtime; it has to sit next to the exe.
//!   _ = sentry.addInstallCrashpadHandler(b, artifacts, .bin);
//!
//! `buildSentryNativeArtifacts` is memoized per (builder, target, optimize,
//! backend, transport, build type), so `linkSentry` and an explicit
//! `buildSentryNativeArtifacts` call with the same settings share one CMake
//! run rather than building sentry-native twice.
//!
//! sentry-native is compiled by **`zig cc` / `zig c++`** driven through CMake
//! rather than by the host's cc/c++. That is what keeps the integration free
//! of the usual static-C++ grief:
//!
//!   * The archives are built against the same bundled libc++ the consumer
//!     links with, so `link_libcpp = true` is the whole C++ story — no
//!     hunting for `libstdc++.so.6` via `gcc -print-file-name`, and no
//!     `linkSystemLibrary("stdc++")` silently aliasing to libc++ (wrong ABI).
//!   * `-target` is forwarded, so cross-compiling produces sentry archives for
//!     the target instead of silently for the host.
//!   * The consumer keeps its own `use_llvm` / `use_lld` choice; nothing here
//!     forces a particular codegen or linker backend.
//!
//! Nothing else is taken from the host either: crashpad's vendored zlib is
//! built rather than the system one, and the libcurl it links on Linux comes
//! from this package's own `curl` dependency, built for the target. See `Curl`.
//!
//! sentry-native and curl are declared as this package's own zon dependencies,
//! so consumers don't declare them themselves.
//!
//! Targets **Zig 0.17.0**.

const std = @import("std");

/// No-op `pub fn build` — sentry-zig produces no install artifacts of its own.
/// The helpers below are invoked from the consumer's build.zig.
pub fn build(b: *std.Build) void {
    _ = b;
}

/// Our own builder, so we resolve *our* zon dependencies and source files
/// regardless of which consumer is calling.
fn ownBuilder(b: *std.Build) *std.Build {
    return b.dependencyFromBuildZig(@This(), .{}).builder;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// `SENTRY_BACKEND`. Only `crashpad` is exercised by this package's own
/// wiring; the others build, but their extra-archive lists are untested.
pub const Backend = enum {
    /// Out-of-process handler. Writes minidumps and can spawn on any signal,
    /// including ones that leave the process unable to run its own handler.
    crashpad,
    /// In-process handler. No separate `crashpad_handler` binary.
    inproc,
    /// No crash handling; the `sentry_*` API still works for messages/events.
    none,
};

/// `SENTRY_TRANSPORT`. `none` means events are written to the local database
/// but never uploaded, which is what you want for offline minidump collection.
pub const Transport = enum { none, curl };

/// `CMAKE_BUILD_TYPE`.
pub const BuildType = enum {
    debug,
    release,
    rel_with_deb_info,
    min_size_rel,

    fn cmakeName(self: BuildType) []const u8 {
        return switch (self) {
            .debug => "Debug",
            .release => "Release",
            .rel_with_deb_info => "RelWithDebInfo",
            .min_size_rel => "MinSizeRel",
        };
    }
};

pub const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    backend: Backend = .crashpad,
    transport: Transport = .none,
    /// Overrides the `optimize`-derived default. sentry-native is
    /// crash-reporting infrastructure: you want its debug info for
    /// symbolication and you never want to step into it, so `.debug`
    /// deliberately maps to `RelWithDebInfo` rather than `Debug`.
    build_type: ?BuildType = null,
    /// Where crashpad's libcurl comes from. Ignored for non-Linux targets,
    /// which don't use libcurl at all.
    curl: Curl = .bundled,
};

/// Crashpad's Linux HTTP transport links libcurl unconditionally — there is no
/// CMake option to opt out — so a Linux build has to get one from somewhere.
pub const Curl = union(enum) {
    /// Build a minimal libcurl (no TLS, no zlib, no system libs) from
    /// sentry-zig's own lazy `curl` dependency, for the same target. Nothing
    /// is searched for on the host, so cross-compiling works.
    ///
    /// crashpad only reaches libcurl when it uploads a crash report, which it
    /// never does under `.transport = .none`; this build exists to satisfy the
    /// link. Pair `.transport = .curl` with `.system` or `.explicit` instead —
    /// a TLS-less libcurl cannot talk to sentry.io.
    bundled,
    /// Let CMake find a libcurl on the host. Fine natively; the wrong
    /// architecture as soon as you cross-compile.
    system,
    /// An existing libcurl built for the target, forwarded as CMake's
    /// `CURL_INCLUDE_DIR` / `CURL_LIBRARY`.
    explicit: struct {
        /// Directory containing `curl/curl.h`.
        include_dir: std.Build.LazyPath,
        library: std.Build.LazyPath,
    },
};

fn defaultBuildType(optimize: std.builtin.Optimize) BuildType {
    return switch (optimize) {
        .debug, .safe, .fast => .rel_with_deb_info,
        .small => .min_size_rel,
    };
}

// ---------------------------------------------------------------------------
// Artifacts
// ---------------------------------------------------------------------------

pub const Artifacts = struct {
    /// Install prefix's `include/` — contains `sentry.h`.
    include_dir: std.Build.LazyPath,
    /// `libsentry.a` followed by the backend's static dependencies, already in
    /// the order some linkers need: client → util → snapshot → minidump →
    /// compat → mpack → zlib → mini_chromium → unwind.
    libs: []const std.Build.LazyPath,
    /// `bin/crashpad_handler[.exe]`. Null for backends without an
    /// out-of-process handler.
    crashpad_handler: ?std.Build.LazyPath,
    /// Basename `crashpad_handler` must be installed under for
    /// `sentry_options_set_handler_path` to find it next to the exe.
    crashpad_handler_name: []const u8,
    target: std.Build.ResolvedTarget,
    backend: Backend,

    /// Add headers, archives and the system libraries/frameworks the backend
    /// needs to `compile`.
    pub fn link(self: Artifacts, compile: *std.Build.Step.Compile) void {
        linkArtifacts(compile, self);
    }
};

/// Basename of the crashpad handler binary on `os_tag`.
pub fn crashpadHandlerName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "crashpad_handler.exe",
        else => "crashpad_handler",
    };
}

// ---------------------------------------------------------------------------
// buildSentryNativeArtifacts
// ---------------------------------------------------------------------------

/// Memoized on a key covering the consumer builder and every setting that
/// changes the output, so repeat calls reuse the same CMake run.
var artifacts_cache: std.StringHashMapUnmanaged(Artifacts) = .empty;

/// Build sentry-native for `opts.target` via its bundled CMake, compiled with
/// `zig cc` / `zig c++`.
pub fn buildSentryNativeArtifacts(b: *std.Build, opts: BuildOptions) Artifacts {
    const target = opts.target;
    const os_tag = target.result.os.tag;
    const build_type = opts.build_type orelse defaultBuildType(opts.optimize);

    const triple = target.result.zigTriple(b.allocator) catch @panic("OOM");

    // `.explicit` carries LazyPaths that have no cheap stable identity, so it
    // opts out of memoization rather than risk two different libcurls sharing
    // one entry. Callers passing it already hold the Artifacts to reuse.
    const memoize = std.meta.activeTag(opts.curl) != .explicit;
    const key = b.fmt("{x}|{s}|{t}|{t}|{s}|{s}", .{
        @intFromPtr(b),
        triple,
        opts.backend,
        opts.transport,
        build_type.cmakeName(),
        @tagName(opts.curl),
    });
    const gop = artifacts_cache.getOrPut(b.allocator, key) catch @panic("OOM");
    if (memoize and gop.found_existing) return gop.value_ptr.*;

    if (os_tag == .windows) std.debug.panic(
        "sentry-zig: Windows targets are not wired up yet (crashpad needs the Windows SDK, " ++
            "which `zig cc` does not bundle). Target: {s}",
        .{triple},
    );
    switch (os_tag) {
        .linux, .macos => {},
        else => std.debug.panic("sentry-zig: unsupported target OS '{t}'", .{os_tag}),
    }

    const own = ownBuilder(b);
    const sentry_src = own.dependency("sentry_native", .{}).path("");

    // Names the driver script checks for after `cmake --install`, so a lib
    // list that drifts from what sentry-native actually installs fails with a
    // readable message instead of a missing-file link error.
    const lib_names = expectedLibNames(os_tag, opts.backend);

    // CMake only needs to be told it is cross-compiling when the target really
    // is a different machine. An explicit `-Dtarget=` that happens to name the
    // host stays in native mode, where CMake's platform detection is happiest.
    const host = b.graph.host.result;
    const is_cross = os_tag != host.os.tag or target.result.cpu.arch != host.cpu.arch;

    // Only Linux drags in libcurl; on macOS crashpad uses its own transport,
    // so resolving one there would build a dependency nothing links.
    const curl = if (os_tag == .linux) resolveCurl(own, opts) else null;

    const cmake_run = b.addSystemCommand(&.{"sh"});
    // As a file arg rather than a path string, so editing the driver
    // invalidates the cached build instead of silently reusing it.
    cmake_run.addFileArg(own.path("tools/build-sentry-native.sh"));
    cmake_run.addDirectoryArg(sentry_src); // $1 src
    const out_dir = cmake_run.addOutputDirectoryArg("sentry-native"); // $2 out
    cmake_run.addArg(b.graph.zig_exe); // $3 zig
    cmake_run.addArg(triple); // $4 target triple
    cmake_run.addArg(build_type.cmakeName()); // $5 CMAKE_BUILD_TYPE
    cmake_run.addArg(@tagName(opts.backend)); // $6 SENTRY_BACKEND
    cmake_run.addArg(@tagName(opts.transport)); // $7 SENTRY_TRANSPORT
    cmake_run.addArg(if (is_cross) cmakeSystemName(os_tag) else ""); // $8
    cmake_run.addArg(if (is_cross) cmakeSystemProcessor(target.result.cpu.arch) else ""); // $9
    cmake_run.addArg(joinNames(b, lib_names)); // $10 expected libs
    // $11/$12 — as path args rather than strings so the curl build becomes a
    // dependency of this run and its output is hashed into the cache key.
    if (curl) |c| {
        cmake_run.addDirectoryArg(c.include_dir); // $11 CURL_INCLUDE_DIR
        cmake_run.addFileArg(c.library); // $12 CURL_LIBRARY
    } else {
        cmake_run.addArg("");
        cmake_run.addArg("");
    }

    cmake_run.setName(b.fmt("cmake sentry-native ({s})", .{triple}));

    const install_root = out_dir.path(b, "install");

    const libs = b.allocator.alloc(std.Build.LazyPath, lib_names.len) catch @panic("OOM");
    for (lib_names, libs) |name, *lib| {
        lib.* = install_root.path(b, b.fmt("lib/{s}", .{name}));
    }

    const artifacts: Artifacts = .{
        .include_dir = install_root.path(b, "include"),
        .libs = libs,
        .crashpad_handler = if (opts.backend == .crashpad)
            install_root.path(b, b.fmt("bin/{s}", .{crashpadHandlerName(os_tag)}))
        else
            null,
        .crashpad_handler_name = crashpadHandlerName(os_tag),
        .target = target,
        .backend = opts.backend,
    };
    gop.value_ptr.* = artifacts;
    return artifacts;
}

const ResolvedCurl = struct {
    include_dir: std.Build.LazyPath,
    library: std.Build.LazyPath,
};

/// Locate the libcurl crashpad will link on Linux. Null means "say nothing to
/// CMake and let `find_package(CURL)` search the host".
fn resolveCurl(own: *std.Build, opts: BuildOptions) ?ResolvedCurl {
    switch (opts.curl) {
        .system => return null,
        .explicit => |e| return .{ .include_dir = e.include_dir, .library = e.library },
        .bundled => {},
    }

    if (opts.transport == .curl) std.debug.panic(
        "sentry-zig: .transport = .curl needs a libcurl with TLS, but .curl = .bundled builds " ++
            "one without it (crashpad only needs the symbols, never the connection). Use " ++
            ".curl = .system or .curl = .explicit for an uploading build.",
        .{},
    );

    // Null on the first build, before the lazy dependency has been fetched.
    // The build runner exits before running any step in that pass, so the
    // CMake run we return here is never executed with curl missing.
    const dep = own.lazyDependency("curl", .{
        .target = opts.target,
        // Never called into — this only has to satisfy crashpad's link, so
        // build the smallest thing that does.
        .optimize = .small,
        // Position-independent to match CMAKE_POSITION_INDEPENDENT_CODE, so
        // the archive works in a PIE executable or a shared library.
        .pie = true,
        // Everything below defaults on and would `linkSystemLibrary` a host
        // library into the archive, which is exactly what bundling avoids.
        .@"enable-ssl" = false,
        .zlib = false,
        .libpsl = false,
        .libssh2 = false,
        .nghttp2 = false,
        .libidn2 = false,
        // Pulls in libldap/liblber, which a host happens to have and a
        // cross-compile does not.
        .@"disable-ldap" = true,
    }) orelse return null;

    // Not `dep.artifact("curl")`: the port installs both a library and a
    // command-line tool under that name, which `artifact` rejects as
    // ambiguous. We want the library.
    const lib = findInstalledLib(dep, "curl");
    return .{
        .include_dir = lib.getEmittedIncludeTree(),
        .library = lib.getEmittedBin(),
    };
}

/// `Dependency.artifact` narrowed to libraries, for dependencies that install a
/// library and an executable of the same name.
fn findInstalledLib(dep: *std.Build.Dependency, name: []const u8) *std.Build.Step.Compile {
    for (dep.builder.install_tls.step.dependencies.items) |dep_step| {
        const inst = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
        const art = inst.artifact;
        if (art.kind == .lib and std.mem.eql(u8, art.name, name)) return art;
    }
    std.debug.panic("sentry-zig: no installed library named '{s}' in dependency", .{name});
}

/// Static archives sentry-native installs, in link order.
///
/// The crashpad install layout is OS-specific: on Linux `compat` is a real
/// archive and sentry-native vendors libunwind, while on macOS `compat` is an
/// INTERFACE target (headers only) and unwinding goes through the system
/// libunwind that libsentry already pulls in.
fn expectedLibNames(os_tag: std.Target.Os.Tag, backend: Backend) []const []const u8 {
    return switch (backend) {
        .crashpad => switch (os_tag) {
            .linux => &.{
                "libsentry.a",
                "libcrashpad_client.a",
                "libcrashpad_util.a",
                "libcrashpad_snapshot.a",
                "libcrashpad_minidump.a",
                "libcrashpad_compat.a",
                "libcrashpad_mpack.a",
                "libcrashpad_zlib.a",
                "libmini_chromium.a",
                "libunwind.a",
            },
            .macos => &.{
                "libsentry.a",
                "libcrashpad_client.a",
                "libcrashpad_util.a",
                "libcrashpad_snapshot.a",
                "libcrashpad_minidump.a",
                "libcrashpad_mpack.a",
                "libcrashpad_zlib.a",
                "libmini_chromium.a",
            },
            else => unreachable,
        },
        .inproc, .none => switch (os_tag) {
            .linux => &.{ "libsentry.a", "libunwind.a" },
            else => &.{"libsentry.a"},
        },
    };
}

fn joinNames(b: *std.Build, names: []const []const u8) []const u8 {
    return std.mem.join(b.allocator, " ", names) catch @panic("OOM");
}

fn cmakeSystemName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .linux => "Linux",
        .macos => "Darwin",
        .windows => "Windows",
        else => "Generic",
    };
}

fn cmakeSystemProcessor(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        .x86 => "i386",
        else => @tagName(arch),
    };
}

// ---------------------------------------------------------------------------
// linkSentry
// ---------------------------------------------------------------------------

/// Build sentry-native for `compile`'s own target/optimize and wire it in.
///
/// This is the one-liner form; it uses the default backend (crashpad) and
/// transport (none). For anything else, call `buildSentryNativeArtifacts` with
/// explicit options and then `artifacts.link(compile)`.
///
/// Note that `compile` still needs `crashpad_handler` installed next to it at
/// runtime — see `addInstallCrashpadHandler`.
pub fn linkSentry(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const target = compile.root_module.resolved_target orelse
        @panic("sentry-zig: linkSentry needs a compile whose root module has a resolved target");
    const artifacts = buildSentryNativeArtifacts(b, .{
        .target = target,
        .optimize = compile.root_module.optimize orelse .debug,
    });
    artifacts.link(compile);
}

/// `sentry.h` as a Zig module, through translate-c: Zig 0.17 removed `@cImport`.
/// `Artifacts.link` adds it to the compile's root module as `sentry_c`; add it to any other
/// module that calls the C API (`mod.addImport("sentry_c", sentryCModule(b, artifacts, optimize))`).
pub fn sentryCModule(
    b: *std.Build,
    artifacts: Artifacts,
    optimize: std.builtin.Optimize,
) *std.Build.Module {
    const tc = b.addTranslateC(.{
        .root_source_file = artifacts.include_dir.path(b, "sentry.h"),
        .target = artifacts.target,
        .optimize = optimize,
    });
    return tc.createModule();
}

fn linkArtifacts(compile: *std.Build.Step.Compile, artifacts: Artifacts) void {
    const mod = compile.root_module;
    mod.addIncludePath(artifacts.include_dir);
    mod.addImport("sentry_c", sentryCModule(compile.step.owner, artifacts, mod.optimize orelse .debug));
    for (artifacts.libs) |lib| mod.addObjectFile(lib);

    // sentry-native and crashpad are C++. Because CMake compiled them with
    // `zig c++`, the bundled libc++ this pulls in is the exact one those
    // archives were built against.
    mod.link_libc = true;
    mod.link_libcpp = true;

    switch (artifacts.target.result.os.tag) {
        .linux => {
            // No-ops on glibc >= 2.34 (folded into libc), still needed when
            // targeting an older glibc.
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("rt", .{});
            mod.linkSystemLibrary("pthread", .{});
        },
        .macos => {
            mod.linkFramework("CoreFoundation", .{});
            mod.linkFramework("CoreServices", .{});
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("Security", .{});
            mod.linkFramework("IOKit", .{});
            mod.linkSystemLibrary("bsm", .{});
        },
        else => |os_tag| std.debug.panic("sentry-zig: no link wiring for '{t}'", .{os_tag}),
    }
}

// ---------------------------------------------------------------------------
// Installing crashpad_handler
// ---------------------------------------------------------------------------

/// Install `crashpad_handler` into `dir` under the basename sentry-zig's
/// runtime lookup expects. Crashpad spawns this binary on crash, so it has to
/// ship next to the executable.
pub fn addInstallCrashpadHandler(
    b: *std.Build,
    artifacts: Artifacts,
    dir: std.Build.InstallDir,
) *std.Build.Step.InstallFile {
    const handler = artifacts.crashpad_handler orelse std.debug.panic(
        "sentry-zig: backend '{t}' has no crashpad_handler to install",
        .{artifacts.backend},
    );
    return b.addInstallFileWithDir(handler, dir, artifacts.crashpad_handler_name);
}
