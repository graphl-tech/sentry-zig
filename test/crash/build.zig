//! Smallest complete consumer of sentry-zig: an executable that links
//! sentry-native, plus the crashpad_handler it needs beside it at runtime.
//!
//! Driven by `.github/scripts/crash-test.sh`, which runs the result and checks
//! that a minidump appeared.

const std = @import("std");
const sentry = @import("sentry_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "crash-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    sentry.linkSentry(b, exe);
    b.installArtifact(exe);

    // Same settings as linkSentry used, so this reuses that CMake run rather
    // than building sentry-native a second time.
    const artifacts = sentry.buildSentryNativeArtifacts(b, .{
        .target = target,
        .optimize = optimize,
    });
    b.getInstallStep().dependOn(
        &sentry.addInstallCrashpadHandler(b, artifacts, .bin).step,
    );
}
