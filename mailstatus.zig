const std = @import("std");
const C = @cImport({
    @cInclude("sys/poll.h");
});

const L = @import("lib.zig");
const M = @import("libmail.zig");

const fmt = std.fmt;
const mem = std.mem;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    try L.printArgs(args);

    if (args.len < 2) {
        return error.StatusFileNotSpecified;
    }

    const stdin = std.io.getStdIn().reader();
    const input = try stdin.readAllAlloc(allocator, 10000);
    defer allocator.free(input);

    var cfg = try M.TlsConfig.setup();
    defer cfg.free();

    const accounts = blk: {
        var as = std.ArrayList(M.Account).init(allocator);
        try M.readAccounts(&as, input);
        break :blk try as.toOwnedSlice();
    };
    defer allocator.free(accounts);

    if (accounts.len == 0) {
        return error.AccountsNotSpecified;
    }

    const clients = blk: {
        var cs = std.ArrayList(Client).init(allocator);
        for (accounts) |*a| {
            try cs.append(.{
                .a = a,
                .socket = try M.TlsSocket.init(&cfg, a),
                .timer1 = try std.time.Timer.start(),
                .timer2 = try std.time.Timer.start(),
                .unseens = M.UnseenSet.init(allocator),
                .buffer = std.ArrayList(u8).init(allocator),
            });
        }
        break :blk try cs.toOwnedSlice();
    };
    defer {
        for (clients) |*c| {
            c.socket.deinit();
            c.unseens.deinit();
        }
        allocator.free(clients);
    }

    const pfds = try allocator.alloc(C.struct_pollfd, accounts.len);
    defer allocator.free(pfds);
    buildPfds(pfds, clients);

    var pfds_changed = true;
    const poll_timeout: c_int = 1000;
    while (true) {
        const poll = C.poll(@ptrCast([*c]C.struct_pollfd, pfds), clients.len, poll_timeout);
        if (poll < 0) {
            L.print(M.INDENT ++ "poll() failed: {}\n", .{poll});
            return error.PollError1;
        }

        var status_changed = false;
        if (poll > 0) {
            var buf: [30]u8 = undefined;
            const len = L.formatLogTimestamp(&buf);
            L.print("{s} | poll() => {}\n", .{ buf[0..len], poll });

            try processPfds(pfds, clients, &status_changed, &pfds_changed);
        } else {
            checkConnections(clients, &pfds_changed);
        }

        if (pfds_changed) {
            buildPfds(pfds, clients);
            pfds_changed = false;
            status_changed = true;
        }

        if (poll != 0) {
            printPfds(pfds, clients);
        }

        if (status_changed) {
            var buffer: [256]u8 = undefined;
            var idx = try M.formatMailStatus(&buffer, clients);

            const output = try std.fs.createFileAbsolute(args[1], .{ .truncate = true });
            defer output.close();

            try output.writeAll(buffer[0..idx]);
        }
    }
}

fn checkConnections(clients: []Client, pfds_changed: *bool) void {
    for (clients) |*c| {
        switch (c.socket.phase) {
            .Disconnected => {
                if (c.connect()) pfds_changed.* = true;
            },
            .TlsStarted => {
                c.checkInactivity() catch |e| {
                    M.log(c.a, "checkInactivity: {}", .{e});
                    c.disconnect();
                    pfds_changed.* = true;
                };
            },
            else => {},
        }
    }
}

fn buildPfds(pfds: []C.struct_pollfd, clients: []Client) void {
    var buf: [30]u8 = undefined;
    const len = L.formatLogTimestamp(&buf);

    L.print("{s} | Preparing for poll()...\n", .{buf[0..len]});

    for (clients) |*c, i| {
        var events: c_short = 0;
        switch (c.socket.phase) {
            .Connecting => events = C.POLLOUT,
            .TlsStarted => events = C.POLLIN,
            else => {},
        }

        pfds[i].fd = if (events == 0) -1 else c.socket.sock.?;
        pfds[i].events = events | @intCast(c_short, C.POLLHUP);
    }
}

fn printPfds(pfds: []C.struct_pollfd, clients: []Client) void {
    for (pfds) |*p, i| {
        if (p.fd < 0) continue;
        const c = &clients[i];
        const args = .{ i, p.fd, p.events, c.a.name, c.connectCount, c.socket.phase };
        L.print(M.INDENT ++ "pollfd: [{}] ({}, {}) {s} #{} @{}\n", args);
    }
}

fn processPfds(pfds: []C.struct_pollfd, clients: []Client, status_changed: *bool, pfds_changed: *bool) !void {
    for (pfds) |*p, i| {
        if (p.revents & (C.POLLERR | C.POLLNVAL) != 0) {
            return error.PollError;
        }

        const c = &clients[i];
        const a = c.a;

        if (p.revents & C.POLLHUP != 0) {
            M.log(a, "revents = POLLHUP", .{});
            c.disconnect();
            pfds_changed.* = true;
            continue;
        }

        switch (c.socket.phase) {
            .Connecting => {
                if (p.revents & C.POLLOUT == 0) continue;

                c.connectReady() catch |e| {
                    M.log(a, "connectReady error: {}", .{e});
                    c.disconnect();
                };
                pfds_changed.* = true;
            },
            .TlsStarted => {
                if (p.revents & C.POLLIN == 0) continue;

                const args = .{ i, p.fd, p.events, p.revents, a.name };
                L.print(M.INDENT ++ "pollfd: [{}] ({}, {}, {}) {s}\n", args);

                c.unseensChanged = false;
                c.readReady() catch |e| {
                    M.log(a, "readReady error: {}", .{e});
                    c.disconnect();
                    pfds_changed.* = true;
                };
                if (c.unseensChanged) status_changed.* = true;
            },
            else => {},
        }
    }
}

const Client = struct {
    socket: M.TlsSocket,
    handler: *const fn (c: *Client, line: []const u8) anyerror!void = Client.disconnected,

    a: *const M.Account,
    unseens: M.UnseenSet,
    unseensChanged: bool = false,
    timer1: std.time.Timer,
    timer2: std.time.Timer,

    buffer: std.ArrayList(u8),
    needleBuffer: [100]u8 = undefined,

    connectCount: usize = 0,
    seq: usize = 0,
    exists: usize = 0,
    bufferPos: usize = 0,
    needle: []const u8 = "",

    fn disconnected(_: *Client, _: []const u8) anyerror!void {
        return error.Disconnected;
    }

    fn disconnect(c: *Client) void {
        c.socket.disconnect();

        M.log(c.a, "Connection closed", .{});

        c.handler = Client.disconnected;
        c.buffer.clearAndFree();
        c.unseens.clearAndFree();
        c.timer1.reset();
        c.timer2.reset();
        c.needle = "";
    }

    fn connect(c: *Client) bool {
        if (c.connectCount > 0) {
            const elapsed = @divFloor(c.timer1.read(), 1_000_000_000);
            const logTime = @divFloor(c.timer2.read(), 1_000_000_000);
            if (elapsed < 30) {
                if (logTime >= 10) {
                    M.log(c.a, "Reconnect Timer: {d} sec", .{elapsed});
                    c.timer2.reset();
                }
                return false;
            }
        }

        c.connectCount += 1;
        c.socket.connect() catch |e| {
            M.log(c.a, "connect error: {}", .{e});
            c.timer1.reset();
            c.timer2.reset();
            return false;
        };

        return true;
    }

    fn connectReady(c: *Client) !void {
        try c.socket.startTLS();
        c.handler = Client.sessionStarted;

        c.timer1.reset();
        c.timer2.reset();

        c.seq = 0;
        c.exists = 0;
        c.bufferPos = 0;
        c.needle = "* OK ";
    }

    fn checkInactivity(c: *Client) !void {
        const elapsed = @divFloor(c.timer2.read(), 1_000_000_000);
        if (elapsed > M.CONNECTION_ALIVE_TIME_LIMIT) {
            M.log(c.a, "Connection isn't active for {} sec", .{elapsed});

            if (c.handler == idleSent) {
                try c.sendIdleDone();
            } else if (c.handler != logoutSent) {
                try c.sendLogout();
            } else {
                return error.InactiveConnection;
            }

            c.timer2.reset();
        }
    }

    fn readReady(c: *Client) !void {
        c.timer2.reset();

        var readBuffer: [1000]u8 = undefined;
        while (true) {
            const read = c.socket.read(&readBuffer) catch |e| switch (e) {
                error.TlsWantPollIn => return,
                else => return e,
            };
            if (read == 0) return error.AsyncRead0Byte;

            try c.buffer.appendSlice(readBuffer[0..read]);
            if (c.buffer.items.len > M.MAX_READ_SIZE) {
                M.log(c.a, "Buffer limit over [{}]\n{s}\n", .{ c.buffer.items.len, c.buffer.items });
                return error.AsyncReadBufferLimitOver;
            }

            if (mem.endsWith(u8, c.buffer.items, M.CRLF)) {
                break;
            } else {
                M.log(c.a, "Not end with CRLF [{}]\n{s}", .{ c.buffer.items.len, c.buffer.items });
            }
        }

        var data = c.buffer.items;
        if (mem.lastIndexOf(u8, data, M.CRLF)) |pos| {
            var s = data[0..pos];
            var ls = mem.tokenize(u8, s, M.CRLF);
            M.log(c.a, "\"{s}\"", .{c.needle});
            while (ls.next()) |line| {
                M.log(c.a, "'{s}'", .{line});
                try c.handler(c, line);
            }

            var rest_start = pos + M.CRLF.len;
            var rest = data[rest_start..];
            if (rest.len > 0) {
                mem.copy(u8, data[0..rest.len], rest);
                c.buffer.shrinkRetainingCapacity(rest.len);
            } else {
                c.buffer.clearRetainingCapacity();
            }
        }
    }

    fn sessionStarted(c: *Client, s: []const u8) !void {
        if (mem.startsWith(u8, s, c.needle)) {
            c.seq += 1;

            var buf: [256]u8 = undefined;
            const f = "A{d} LOGIN {s} {s}" ++ M.CRLF;
            const cmd = try fmt.bufPrint(&buf, f, .{ c.seq, c.a.username, c.a.password });
            try c.socket.write(cmd, false);

            c.needle = try std.fmt.bufPrint(&c.needleBuffer, "A{d} OK ", .{c.seq});
            c.handler = Client.loginSent;
            M.log(c.a, ">>> loginSent", .{});
        }
    }

    fn loginSent(c: *Client, s: []const u8) !void {
        if (mem.startsWith(u8, s, c.needle)) {
            c.exists = 0;
            c.seq += 1;

            var buf: [100]u8 = undefined;
            const cmd = try fmt.bufPrint(&buf, "A{d} SELECT " ++ M.MBOX ++ M.CRLF, .{c.seq});
            try c.socket.write(cmd, true);

            c.needle = try fmt.bufPrint(&c.needleBuffer, "A{d} OK ", .{c.seq});
            c.handler = Client.selectSent;
            M.log(c.a, ">>> selectSent", .{});
        }
    }

    fn selectSent(c: *Client, s: []const u8) !void {
        const needle = " EXISTS";
        if (mem.endsWith(u8, s, needle)) {
            const exists_s = s[2 .. s.len - needle.len];
            M.log(c.a, "Parsed String: '{s}'", .{exists_s});
            c.exists = try fmt.parseInt(usize, exists_s, 10);
            M.log(c.a, "Parsed Int: {d}", .{c.exists});
        } else if (mem.startsWith(u8, s, c.needle)) {
            try c.sendSearch();
        }
    }

    fn sendSearch(c: *Client) !void {
        c.unseens.clearAndFree();
        c.seq += 1;

        var buf: [100]u8 = undefined;
        const cmd = try fmt.bufPrint(&buf, "A{d} SEARCH (UNSEEN)" ++ M.CRLF, .{c.seq});
        try c.socket.write(cmd, true);

        c.needle = try fmt.bufPrint(&c.needleBuffer, "A{d} OK ", .{c.seq});
        c.handler = Client.searchSent;
        M.log(c.a, ">>> searchSent", .{});
    }

    fn searchSent(c: *Client, s: []const u8) !void {
        const needle = "* SEARCH";
        if (mem.startsWith(u8, s, needle)) {
            const ids = s[needle.len..];
            M.log(c.a, "UNSEEN IDs: {s}", .{ids});

            var tkn = mem.tokenize(u8, ids, " ");
            while (tkn.next()) |id_s| {
                const id = try fmt.parseInt(usize, id_s, 10);
                try c.unseens.put(id, {});
                c.unseensChanged = true;
            }

            try M.printUnseenSet(c.a, &c.unseens);
        } else if (mem.startsWith(u8, s, c.needle)) {
            c.seq += 1;

            var buf: [100]u8 = undefined;
            const cmd = try fmt.bufPrint(&buf, "A{d} IDLE" ++ M.CRLF, .{c.seq});
            try c.socket.write(cmd, true);

            c.needle = try fmt.bufPrint(&c.needleBuffer, "A{d} OK", .{c.seq});
            c.handler = Client.idleSent;
            c.timer1.reset();
            M.log(c.a, ">>> idleSent", .{});
        }
    }

    fn idleSent(c: *Client, s: []const u8) !void {
        if (mem.startsWith(u8, s, c.needle)) {
            try c.sendSearch();
            return;
        } else if (!mem.startsWith(u8, s, "* ")) {
            return;
        }

        var tkn = mem.tokenize(u8, s[2..], " ");
        const tkn1st = tkn.next() orelse return error.Idle1stTokenMissing;

        if (mem.eql(u8, tkn1st, "OK")) {
            const elapsed = @divFloor(c.timer1.read(), 1_000_000_000);
            M.log(c.a, "IDLE Timer: {d} sec", .{elapsed});
            if (elapsed > M.IDLE_TIME_LIMIT) {
                try c.sendIdleDone();
            }
            return;
        } else if (mem.eql(u8, tkn1st, "BYE")) {
            return error.ServerShutdown;
        }

        const tkn2nd = tkn.next() orelse return error.Idle2ndTokenMissing;
        const msgID = fmt.parseInt(usize, tkn1st, 10) catch return error.IdleParseMessageID;

        var rest: []const u8 = "";
        if (tkn.next()) |t| {
            if (mem.indexOfPos(u8, s, tkn1st.len + tkn2nd.len + 2, t)) |pos| {
                rest = s[pos..];
            }
        }

        M.log(c.a, "Tokens: {s}|{s}|{s}", .{ tkn1st, tkn2nd, rest });

        if (mem.eql(u8, tkn2nd, "FETCH")) {
            try M.printUnseenSet(c.a, &c.unseens);
            if (mem.indexOf(u8, rest, "\\Seen")) |_| {
                M.log(c.a, "Unseen Remove: {d}", .{msgID});
                _ = c.unseens.remove(msgID);
            } else {
                M.log(c.a, "Unseen Add: {d}", .{msgID});
                try c.unseens.put(msgID, {});
            }
            try M.printUnseenSet(c.a, &c.unseens);
            c.unseensChanged = true;
        } else if (mem.eql(u8, tkn2nd, "EXPUNGE")) {
            M.log(c.a, "Unseen Remove: {d}", .{msgID});
            try M.printUnseenSet(c.a, &c.unseens);
            c.unseensChanged = c.unseens.remove(msgID);
            try M.printUnseenSet(c.a, &c.unseens);

            M.log(c.a, "Unseen Decrement", .{});
            try M.printUnseenSet(c.a, &c.unseens);
            var ii = msgID + 1;
            while (ii <= c.exists) : (ii += 1) {
                if (c.unseens.remove(ii))
                    try c.unseens.put(ii - 1, {});
            }

            c.exists -= 1;
            M.log(c.a, "Exists: {d}", .{c.exists});

            try M.printUnseenSet(c.a, &c.unseens);
        } else if (mem.eql(u8, tkn2nd, "EXISTS")) {
            c.exists = msgID;
            try c.sendIdleDone();
        }
    }

    fn sendIdleDone(c: *Client) !void {
        try c.socket.write("DONE" ++ M.CRLF, true);
        c.handler = Client.idleDoneSent;
        M.log(c.a, ">>> idleDoneSent", .{});
    }

    fn idleDoneSent(c: *Client, s: []const u8) !void {
        if (mem.startsWith(u8, s, c.needle)) {
            try c.sendSearch();
        }
    }

    fn sendLogout(c: *Client) !void {
        c.seq += 1;

        var buf: [100]u8 = undefined;
        const cmd = try fmt.bufPrint(&buf, "A{d} LOGOUT" ++ M.CRLF, .{c.seq});
        try c.socket.write(cmd, true);

        c.needle = try fmt.bufPrint(&c.needleBuffer, "A{d} OK", .{c.seq});
        c.handler = Client.logoutSent;
        M.log(c.a, ">>> logoutSent", .{});
    }

    fn logoutSent(c: *Client, s: []const u8) !void {
        if (mem.startsWith(u8, s, c.needle)) {
            M.log(c.a, ">>> logoutCompleted", .{});
            return error.LoginCompleted;
        }
    }
};
