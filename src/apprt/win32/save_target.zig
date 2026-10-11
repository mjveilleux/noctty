//! Where a Settings save lands, and how the bytes get there.
//!
//! The configured path can be a symbolic link (a config kept in a dotfiles
//! repository) or one of several hard links to the same file. Replacing that
//! name with a new file swaps a symbolic link for a plain file and leaves every
//! other hard link on the old bytes, so the save followed the link only until
//! the first time. `resolve` finds the file the name reaches, `write` puts the
//! bytes there.
const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const c = @import("consts.zig");

extern "kernel32" fn GetFinalPathNameByHandleW(
    handle: windows.HANDLE,
    path: [*]u16,
    size: u32,
    flags: u32,
) callconv(.winapi) u32;

extern "kernel32" fn GetFileInformationByHandle(
    handle: windows.HANDLE,
    info: *windows.BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) windows.BOOL;

pub const Target = struct {
    /// The file the configured name reaches now, as `C:\...` or
    /// `\\server\share\...`, or the name itself while no file exists yet.
    /// Owned.
    path: []u8,
    /// Another name reaches the same file, so only writing into the file keeps
    /// the names together.
    hard_linked: bool = false,

    pub fn deinit(self: Target, alloc: Allocator) void {
        alloc.free(self.path);
    }
};

pub const ResolveError = error{
    /// The name is a link whose target is missing. Writing "to" it would
    /// replace the link, which is what resolving exists to avoid.
    DanglingLink,
    ResolveFailed,
} || Allocator.Error;

pub const WriteError = error{
    TempCreateFailed,
    SerializeFailed,
    ReplaceFailed,
} || Allocator.Error;

/// Follow `path` to the file it names. A name with no file behind it is the
/// first save and resolves to itself.
pub fn resolve(alloc: Allocator, path: []const u8) ResolveError!Target {
    const wide = windows.sliceToPrefixedFileW(null, path) catch return error.ResolveFailed;
    // No access is asked for, so a read-only or busy file still opens; the
    // handle only answers questions about the file.
    const handle = windows.kernel32.CreateFileW(
        wide.span().ptr,
        0,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => {
            // The open follows a link and fails on a missing target, so it
            // cannot tell a first save from a dangling link; the attributes of
            // the name itself can.
            const attributes = windows.kernel32.GetFileAttributesW(wide.span().ptr);
            if (attributes != windows.INVALID_FILE_ATTRIBUTES and
                attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) return error.DanglingLink;
            return .{ .path = try alloc.dupe(u8, path) };
        },
        else => return error.ResolveFailed,
    };
    defer windows.CloseHandle(handle);

    var info: windows.BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(handle, &info) == 0) return error.ResolveFailed;

    var storage = try alloc.alloc(u16, 512);
    defer alloc.free(storage);
    const final = while (true) {
        // Success is the length without the terminator; a buffer that is too
        // small gets the length it needs, terminator included.
        const length = GetFinalPathNameByHandleW(handle, storage.ptr, @intCast(storage.len), 0);
        if (length == 0) return error.ResolveFailed;
        if (length < storage.len) break storage[0..length];
        storage = try alloc.realloc(storage, length);
    };
    const name = std.unicode.utf16LeToUtf8Alloc(alloc, final) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ResolveFailed,
    };
    defer alloc.free(name);
    return .{
        .path = try alloc.dupe(u8, plain(name)),
        .hard_linked = info.nNumberOfLinks > 1,
    };
}

/// The final-path API answers in the `\\?\` namespace; every other path in the
/// program is `C:\...` or `\\server\share\...`. Names that are neither (a
/// volume with no drive letter) stay as they are, which the file APIs accept.
/// Edits `name` in place.
fn plain(name: []u8) []u8 {
    const unc = "\\\\?\\UNC\\";
    const extended = "\\\\?\\";
    if (std.mem.startsWith(u8, name, unc)) {
        // \\?\UNC\server\share is \\server\share: the "C\" of the prefix
        // becomes the second separator.
        name[unc.len - 2] = '\\';
        return name[unc.len - 2 ..];
    }
    if (name.len >= extended.len + 3 and std.mem.startsWith(u8, name, extended) and
        std.ascii.isAlphabetic(name[extended.len]) and
        name[extended.len + 1] == ':' and name[extended.len + 2] == '\\')
    {
        return name[extended.len..];
    }
    return name;
}

/// Make the file at `target` hold exactly `bytes`.
///
/// The bytes go to a synced temporary file beside it first. A name with one
/// link is then replaced atomically, so a crash never leaves a half-written
/// config; a hard-linked file is rewritten in place, because a replacement
/// would leave the other names on the old bytes. That rewrite is not atomic:
/// the temporary file stays if it fails, as the only complete copy.
pub fn write(alloc: Allocator, target: Target, bytes: []const u8) WriteError!void {
    const tmp_path = try std.fmt.allocPrint(
        alloc,
        "{s}.tmp-{x}-{x}",
        .{ target.path, sys.GetCurrentProcessId(), @as(u64, @intCast(@max(std.time.milliTimestamp(), 0))) },
    );
    defer alloc.free(tmp_path);

    // Closed before the replace: Windows blocks it while the temp handle is open.
    var temp_pending = false;
    defer if (temp_pending) std.fs.cwd().deleteFile(tmp_path) catch {}; // Best-effort temp cleanup.
    {
        const tmp = std.fs.cwd().createFile(tmp_path, .{}) catch return error.TempCreateFailed;
        temp_pending = true;
        defer tmp.close();
        var write_buf: [4096]u8 = undefined;
        var fw = tmp.writer(&write_buf);
        fw.interface.writeAll(bytes) catch return error.SerializeFailed;
        fw.interface.flush() catch return error.SerializeFailed;
        tmp.sync() catch return error.SerializeFailed;
    }

    if (target.hard_linked) {
        temp_pending = false;
        const file = std.fs.cwd().createFile(target.path, .{}) catch return error.ReplaceFailed;
        defer file.close();
        file.writeAll(bytes) catch return error.SerializeFailed;
        file.sync() catch return error.SerializeFailed;
        std.fs.cwd().deleteFile(tmp_path) catch {}; // The rewrite finished: the copy is no longer needed.
        return;
    }

    const target_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, target.path) catch return error.OutOfMemory;
    defer alloc.free(target_w);
    const tmp_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, tmp_path) catch return error.OutOfMemory;
    defer alloc.free(tmp_w);
    if (sys.ReplaceFileW(target_w, tmp_w, null, 0, null, null) == 0) {
        // Likely ERROR_FILE_NOT_FOUND if the user didn't have a
        // config file yet. Fall back to MoveFileExW.
        if (sys.MoveFileExW(tmp_w, target_w, c.MOVEFILE_REPLACE_EXISTING) == 0) {
            return error.ReplaceFailed;
        }
    }
    temp_pending = false;
}

const testing = std.testing;

extern "kernel32" fn CreateSymbolicLinkW(link: [*:0]const u16, target: [*:0]const u16, flags: u32) callconv(.winapi) windows.BOOLEAN;
extern "kernel32" fn CreateHardLinkW(link: [*:0]const u16, existing: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;

/// A scratch directory and the absolute path of a name in it. Public for the
/// tests of the code that saves through it.
pub const Scratch = struct {
    tmp: testing.TmpDir,
    /// The directory's absolute path.
    root: []u8,

    pub fn init() !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realpathAlloc(testing.allocator, ".") };
    }

    pub fn deinit(self: *Scratch) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn path(self: *const Scratch, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.root, name });
    }

    pub fn symlink(self: *const Scratch, link: []const u8, target: []const u8) !void {
        const link_path = try self.path(link);
        defer testing.allocator.free(link_path);
        const link_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, link_path);
        defer testing.allocator.free(link_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, target);
        defer testing.allocator.free(target_w);
        // ALLOW_UNPRIVILEGED_CREATE: works with Developer Mode, no elevation.
        if (CreateSymbolicLinkW(link_w, target_w, 0x2) == 0) {
            if (windows.GetLastError() == .PRIVILEGE_NOT_HELD) return error.SkipZigTest;
            return error.SymlinkFailed;
        }
    }

    pub fn hardlink(self: *const Scratch, link: []const u8, existing: []const u8) !void {
        const link_path = try self.path(link);
        defer testing.allocator.free(link_path);
        const existing_path = try self.path(existing);
        defer testing.allocator.free(existing_path);
        const link_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, link_path);
        defer testing.allocator.free(link_w);
        const existing_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, existing_path);
        defer testing.allocator.free(existing_w);
        if (CreateHardLinkW(link_w, existing_w, null) == 0) return error.HardLinkFailed;
    }

    /// Whether the name itself, not what it reaches, is a reparse point.
    pub fn isLink(self: *const Scratch, name: []const u8) !bool {
        const p = try self.path(name);
        defer testing.allocator.free(p);
        const w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, p);
        defer testing.allocator.free(w);
        const attributes = windows.kernel32.GetFileAttributesW(w);
        return attributes != windows.INVALID_FILE_ATTRIBUTES and attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }

    pub fn expectContent(self: *const Scratch, name: []const u8, expected: []const u8) !void {
        const content = try self.tmp.dir.readFileAlloc(testing.allocator, name, 1 << 20);
        defer testing.allocator.free(content);
        try testing.expectEqualStrings(expected, content);
    }

    /// The entries of the scratch directory, to show a save left nothing else.
    pub fn expectNames(self: *const Scratch, expected: []const []const u8) !void {
        var names: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (names.items) |name| testing.allocator.free(name);
            names.deinit(testing.allocator);
        }
        var dir = try self.tmp.dir.openDir(".", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| try names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
        std.mem.sort([]u8, names.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        try testing.expectEqual(expected.len, names.items.len);
        for (expected, names.items) |want, got| try testing.expectEqualStrings(want, got);
    }
};

test "save target of a missing file is the name itself, and the first save creates it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expectEqualStrings(path, target.path);
    try testing.expect(!target.hard_linked);

    try write(testing.allocator, target, "font-size = 14\n");
    try scratch.expectContent("config.ghostty", "font-size = 14\n");
    try scratch.expectNames(&.{"config.ghostty"});
}

test "save target of a plain file is replaced atomically and leaves no temporary file" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "old\n" });
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expect(std.ascii.eqlIgnoreCase(path, target.path));
    try testing.expect(!target.hard_linked);
    try write(testing.allocator, target, "new\n");
    try scratch.expectContent("config.ghostty", "new\n");
    try scratch.expectNames(&.{"config.ghostty"});
}

test "save target follows a symbolic link and keeps it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.makeDir("dotfiles");
    try scratch.tmp.dir.writeFile(.{ .sub_path = "dotfiles/config.ghostty", .data = "old\n" });
    // A relative link, as a dotfiles manager makes it.
    try scratch.symlink("config.ghostty", "dotfiles\\config.ghostty");
    try testing.expect(try scratch.isLink("config.ghostty"));
    const link = try scratch.path("config.ghostty");
    defer testing.allocator.free(link);
    const real = try scratch.path("dotfiles\\config.ghostty");
    defer testing.allocator.free(real);

    const target = try resolve(testing.allocator, link);
    defer target.deinit(testing.allocator);
    try testing.expect(std.ascii.eqlIgnoreCase(real, target.path));
    try testing.expect(!target.hard_linked);

    try write(testing.allocator, target, "new\n");
    // The link is still a link, both names read the new bytes, and the
    // temporary file was made beside the real file, not beside the link.
    try testing.expect(try scratch.isLink("config.ghostty"));
    try scratch.expectContent("config.ghostty", "new\n");
    try scratch.expectContent("dotfiles/config.ghostty", "new\n");
    try scratch.expectNames(&.{ "config.ghostty", "dotfiles" });
    var dotfiles = try scratch.tmp.dir.openDir("dotfiles", .{ .iterate = true });
    defer dotfiles.close();
    var it = dotfiles.iterate();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "save target follows a chain of links" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "real.conf", .data = "old\n" });
    try scratch.symlink("middle.conf", "real.conf");
    try scratch.symlink("config.ghostty", "middle.conf");
    const link = try scratch.path("config.ghostty");
    defer testing.allocator.free(link);
    const real = try scratch.path("real.conf");
    defer testing.allocator.free(real);

    const target = try resolve(testing.allocator, link);
    defer target.deinit(testing.allocator);
    try testing.expect(std.ascii.eqlIgnoreCase(real, target.path));
    try write(testing.allocator, target, "new\n");
    try testing.expect(try scratch.isLink("config.ghostty"));
    try testing.expect(try scratch.isLink("middle.conf"));
    try scratch.expectContent("real.conf", "new\n");
}

test "save target refuses a dangling link instead of replacing it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.symlink("config.ghostty", "missing\\config.ghostty");
    const link = try scratch.path("config.ghostty");
    defer testing.allocator.free(link);

    try testing.expectError(error.DanglingLink, resolve(testing.allocator, link));
    try testing.expect(try scratch.isLink("config.ghostty"));
}

test "save target writes through hard links so every name sees the bytes" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "old\n" });
    try scratch.hardlink("dotfile", "config.ghostty");
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expect(target.hard_linked);

    try write(testing.allocator, target, "new, and longer than before\n");
    try scratch.expectContent("config.ghostty", "new, and longer than before\n");
    try scratch.expectContent("dotfile", "new, and longer than before\n");
    // A shorter rewrite truncates: nothing of the old bytes is left behind.
    try write(testing.allocator, target, "x\n");
    try scratch.expectContent("dotfile", "x\n");
    try scratch.expectNames(&.{ "config.ghostty", "dotfile" });
}

test "save target of a name in a missing directory is the name itself" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const path = try scratch.path("new-dir\\custom.conf");
    defer testing.allocator.free(path);
    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expectEqualStrings(path, target.path);
}

test "final path names lose the extended-length prefix and keep other shapes" {
    const cases = [_]struct { name: []const u8, plain: []const u8 }{
        .{ .name = "\\\\?\\C:\\Users\\a\\config.ghostty", .plain = "C:\\Users\\a\\config.ghostty" },
        .{ .name = "\\\\?\\UNC\\server\\share\\dir\\config.ghostty", .plain = "\\\\server\\share\\dir\\config.ghostty" },
        // A volume without a drive letter has no shorter spelling.
        .{ .name = "\\\\?\\Volume{01234567-89ab-cdef-0123-456789abcdef}\\a.conf", .plain = "\\\\?\\Volume{01234567-89ab-cdef-0123-456789abcdef}\\a.conf" },
        .{ .name = "C:\\already\\plain.conf", .plain = "C:\\already\\plain.conf" },
        .{ .name = "\\\\?\\C:", .plain = "\\\\?\\C:" },
    };
    for (cases) |case| {
        const buffer = try testing.allocator.dupe(u8, case.name);
        defer testing.allocator.free(buffer);
        try testing.expectEqualStrings(case.plain, plain(buffer));
    }
}
