//! omawin's timing marks (noctty fork; see github.com/mjveilleux/omawin, `omawin profile
//! terminal`). While `%LOCALAPPDATA%\launcher\trace-on` exists, `mark` appends
//! `noctty <label>\t<QueryPerformanceCounter>` to `%LOCALAPPDATA%\launcher\trace.log`, the
//! file omawin.exe and the PowerShell profile write their marks to. QueryPerformanceCounter is
//! the one clock all processes share, so the marks line up across them. Otherwise inert: a
//! mark costs one file-existence check, and there are a handful per window.

const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn QueryPerformanceCounter(value: *i64) callconv(.winapi) std.os.windows.BOOL;

pub fn mark(label: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    var qpc: i64 = 0;
    _ = QueryPerformanceCounter(&qpc);

    var buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();
    const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    const flag = std.fs.path.join(alloc, &.{ local, "launcher", "trace-on" }) catch return;
    std.fs.accessAbsolute(flag, .{}) catch return;
    const log_path = std.fs.path.join(alloc, &.{ local, "launcher", "trace.log" }) catch return;

    var line_buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "noctty {s}\t{d}\n", .{ label, qpc }) catch return;
    const file = std.fs.createFileAbsolute(log_path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch {};
}
