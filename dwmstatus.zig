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

    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    try L.printArgs(args);

    if (args.len < 2) {
        return error.StatusFileNotSpecified;
    }

    const status = try std.fs.createFileAbsolute(args[1], .{ .read = true });
    defer status.close();

    var buffer: [512]u8 = undefined;
    while (true) {
        try status.seekTo(0);
        var idx = try status.readAll(buffer[0..256]);
        //L.print("{}: {s}\n", .{ idx, buffer[0..idx] });

        idx += try L.formatTime(buffer[idx..]);
        buffer[idx] = '\x00';

        setRootName(dpy, win, &buffer);

        std.time.sleep(1_000_000_000);
    }
}
