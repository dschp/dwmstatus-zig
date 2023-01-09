const std = @import("std");
const L = @import("lib.zig");

const Display = opaque {};
const Window = opaque {};

extern fn getDisplay(display: [*c]const u8) ?*Display;
extern fn getRootWindow(dpy: *Display) *Window;
extern fn setRootName(dpy: *Display, win: *Window, [*c]const u8) void;

pub fn main() !void {
    const dpy = getDisplay(":0") orelse {
        return error.CannotGetDisplay;
    };
    const win = getRootWindow(dpy);

    const buf_size = 1000;

    var buffer_args: [buf_size]u8 = undefined;
    var fba_args = std.heap.FixedBufferAllocator.init(&buffer_args);
    const alloc_args = fba_args.allocator();
    const args = try std.process.argsAlloc(alloc_args);
    defer std.process.argsFree(alloc_args, args);

    var buffer_files: [buf_size]u8 = undefined;
    var fba_files = std.heap.FixedBufferAllocator.init(&buffer_files);
    const alloc_files = fba_files.allocator();
    var files = std.ArrayList(std.fs.File).init(alloc_files);
    defer {
        for (files.items) |f| {
            f.close();
        }
        files.deinit();
    }

    if (args.len > 1) {
        for (args[1..]) |a, i| {
            L.print("{}: {s}\n", .{ i, a });
            try files.append(try std.fs.createFileAbsolute(a, .{ .read = true }));
        }
    }

    var buffer: [buf_size]u8 = undefined;
    while (true) {
        var idx: usize = 0;
        for (files.items) |f| {
            try f.seekTo(0);
            idx += try f.readAll(buffer[idx..]);
        }

        idx += try L.formatTime(buffer[idx..]);
        buffer[idx] = '\x00';

        setRootName(dpy, win, &buffer);

        std.time.sleep(1_000_000_000);
    }
}
