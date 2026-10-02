//! Brings up sentry-native and then deliberately faults, so CI can assert that
//! crashpad caught it and wrote a minidump.
//!
//!   crash-test <database-dir>
//!
//! No DSN is configured, so nothing is uploaded — crashpad just writes the
//! `.dmp` into the local database, which is what we check for.

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sentry.h");
});

/// Zig installs a SIGSEGV handler of its own before main, and crashpad chains
/// to it after writing the dump — at which point it tries to symbolize a stack
/// trace through every crashpad and libunwind frame in a 20MB binary and spins
/// there for minutes. Crashpad owns the crash in a real deployment, so hand it
/// over cleanly and let the process die.
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <database-dir>\n", .{args[0]});
        return error.MissingDatabaseDir;
    }
    const database_path = try arena.dupeZ(u8, args[1]);

    // crashpad_handler is installed next to the executable, which is where
    // `addInstallCrashpadHandler` puts it and where a shipped app would keep it.
    const exe_dir = try std.process.executableDirPathAlloc(init.io, arena);
    const handler_path = try std.fs.path.joinZ(arena, &.{
        exe_dir,
        switch (builtin.os.tag) {
            .windows => "crashpad_handler.exe",
            else => "crashpad_handler",
        },
    });

    const options = c.sentry_options_new() orelse return error.SentryOptionsNew;
    c.sentry_options_set_handler_path(options, handler_path.ptr);
    c.sentry_options_set_database_path(options, database_path.ptr);
    c.sentry_options_set_release(options, "sentry-zig-crash-test@0.0.0");

    const rc = c.sentry_init(options);
    if (rc != 0) {
        std.debug.print("sentry_init failed: {d}\n", .{rc});
        return error.SentryInit;
    }
    std.debug.print("sentry up; handler={s} database={s}\n", .{ handler_path, database_path });

    crash();
}

/// A null-ish dereference the optimizer cannot elide.
fn crash() noreturn {
    const p: *volatile u8 = @ptrFromInt(0x1);
    p.* = 0;
    unreachable;
}
