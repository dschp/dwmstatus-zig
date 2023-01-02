const std = @import("std");
const C = @cImport({
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

const fmt = std.fmt;
const mem = std.mem;

pub const stdout = std.io.getStdOut().writer();

pub fn print(comptime format: []const u8, args: anytype) void {
    stdout.print(format, args) catch unreachable;
}

pub fn printArgs(args: [][:0]u8) !void {
    try stdout.print("Args Len: {}\n", .{args.len});
    for (args) |arg, n| {
        try stdout.print("{}: {s}\n", .{ n, arg });
    }
}

pub fn formatTime(buf: []u8) !usize {
    const now = C.time(null);

    _ = C.setenv("TZ", ":Asia/Bangkok", 1);
    C.tzset();
    const tm_local = C.localtime(&now);
    var fmt_local: [30]u8 = undefined;
    const len_local = C.strftime(&fmt_local, fmt_local.len, "%F (%a) \x06%T\x01", tm_local);

    const tm_gmt = C.gmtime(&now);
    var fmt_gmt: [10]u8 = undefined;
    const len_gmt = C.strftime(&fmt_gmt, fmt_gmt.len, "\x04%R\x01", tm_gmt);

    _ = C.setenv("TZ", ":Asia/Tokyo", 1);
    C.tzset();
    const tm_jst = C.localtime(&now);
    var fmt_jst: [10]u8 = undefined;
    const len_jst = C.strftime(&fmt_jst, fmt_jst.len, "\x05%R\x01", tm_jst);

    _ = C.setenv("TZ", ":EST", 1);
    C.tzset();
    const tm_est = C.localtime(&now);
    var fmt_est: [10]u8 = undefined;
    const len_est = C.strftime(&fmt_est, fmt_est.len, "\x03%R\x01", tm_est);

    const args = .{
        fmt_est[0..len_est],
        fmt_gmt[0..len_gmt],
        fmt_jst[0..len_jst],
        fmt_local[0..len_local],
        tm_local.*.tm_year + 1900 + 543,
    };

    const s = try fmt.bufPrint(buf, " EST:{s} GMT:{s} JST:{s} {s} [{d}]", args);
    return s.len;
}

pub fn formatLogTimestamp(buf: []u8) usize {
    const now = C.time(null);
    _ = C.setenv("TZ", ":Asia/Bangkok", 1);
    C.tzset();
    const tm = C.localtime(&now);
    return C.strftime(buf.ptr, buf.len, "%F %T", tm);
}
