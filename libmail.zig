const std = @import("std");
const C = @cImport({
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("tls.h");
    @cInclude("sys/socket.h");
    @cInclude("netdb.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

extern fn getErrno() c_int;

const fmt = std.fmt;
const mem = std.mem;

pub const INDENT = "  ";
pub const CRLF = "\r\n";
pub const MBOX = "INBOX";
pub const IDLE_TIME_LIMIT: u64 = 25 * 60;
pub const CONNECTION_ALIVE_TIME_LIMIT: u16 = 200;
pub const MAX_READ_SIZE: usize = 1024 * 100;

const L = @import("lib.zig");

pub fn log(a: *const Account, comptime format: []const u8, args: anytype) void {
    L.print((INDENT ** 2) ++ "[{s}] ", .{a.name});
    L.print(format, args);
    L.print("\n", .{});
}

pub const Account = struct {
    name: []const u8,
    username: []const u8,
    password: []const u8,
    server: []const u8,
    port: u16,
};

pub const UnseenSet = std.AutoHashMap(usize, void);

pub fn readAccounts(as: *std.ArrayList(Account), input: []const u8) !void {
    var lines = mem.tokenize(u8, input, "\n");
    while (lines.next()) |line| {
        var values = mem.tokenize(u8, line, " ");

        const name = values.next() orelse return error.EmptyAccountName;
        const user = values.next() orelse return error.EmptyAccountUserName;
        const pass = values.next() orelse return error.EmptyAccountPassword;
        const serv = values.next() orelse return error.EmptyAccountServer;
        const port = values.next() orelse return error.EmptyAccountPort;

        try as.append(.{
            .name = name,
            .username = user,
            .password = pass,
            .server = serv,
            .port = fmt.parseInt(u16, port, 10) catch return error.ParseAccountPortNumber,
        });
    }
}

pub fn formatMailStatus(buf: []u8, clients: anytype) !usize {
    var idx: usize = 0;
    for (clients) |c| {
        const cnt = c.unseens.count();
        if (cnt > 0) {
            const s = try fmt.bufPrint(buf[idx..], "({s}: {d}) ", .{ c.a.name, cnt });
            idx += s.len;
        }
    }
    if (idx > 0) {
        const s = try fmt.bufPrint(buf[idx..], "| ", .{});
        idx += s.len;
    }
    return idx;
}

pub fn printUnseenSet(a: *const Account, unseens: *const UnseenSet) !void {
    try L.stdout.writeAll((INDENT ** 2) ++ "[");
    try L.stdout.writeAll(a.name);
    try L.stdout.writeAll("] {");

    var iter = unseens.keyIterator();
    while (iter.next()) |key| {
        try L.stdout.print("{},", .{key.*});
    }
    try L.stdout.writeAll("}\n");
}

pub const TlsConfig = struct {
    config: ?*C.tls_config,

    pub fn setup() !TlsConfig {
        if (C.tls_init() != 0) {
            L.print("tls_init: error\n", .{});
            return error.TlsInit;
        }

        var cfg = C.tls_config_new() orelse {
            L.print("tls_config_new: error\n", .{});
            return error.TlsConfigNew;
        };
        errdefer C.tls_config_free(cfg);

        if (C.tls_config_set_protocols(cfg, C.TLS_PROTOCOLS_DEFAULT) != 0) {
            return error.TlsSetProtocols;
        }
        if (C.tls_config_set_ca_file(cfg, "/opt/libressl/etc/ssl/cert.pem") != 0) {
            return error.TlsSetCaFile;
        }
        if (C.tls_config_set_ciphers(cfg, "secure") != 0) {
            return error.TlsSetCiphers;
        }

        return TlsConfig{ .config = cfg };
    }

    pub fn free(cfg: *TlsConfig) void {
        C.tls_config_free(cfg.config.?);
        cfg.config = null;
    }
};

pub const TlsSocket = struct {
    const Phase = enum {
        Disconnected,
        Connecting,
        TlsStarted,
    };

    account: *const Account,
    config: *const TlsConfig,

    phase: Phase = .Disconnected,
    addrinfo: *C.struct_addrinfo,
    sock: ?c_int = null,
    tls: ?*C.struct_tls = null,

    pub fn init(cfg: *const TlsConfig, a: *const Account) !TlsSocket {
        var hints = mem.zeroes(C.struct_addrinfo);
        var result: *C.struct_addrinfo = undefined;

        hints.ai_family = C.AF_INET;
        hints.ai_socktype = C.SOCK_STREAM;
        hints.ai_flags = 0;
        hints.ai_protocol = 0;

        var buf: [256]u8 = undefined;
        const server = try fmt.bufPrintZ(buf[0..], "{s}", .{a.server});
        const port = try fmt.bufPrintZ(buf[server.len + 1 ..], "{}", .{a.port});

        var rc = C.getaddrinfo(server.ptr, port.ptr, &hints, @ptrCast([*c][*c]C.struct_addrinfo, &result));
        if (rc != 0) {
            var err = C.gai_strerror(rc);
            log(a, "{s}", .{err});
            return error.GetAddrInfo;
        }

        return TlsSocket{
            .account = a,
            .config = cfg,
            .addrinfo = result,
        };
    }

    pub fn deinit(s: *TlsSocket) void {
        C.freeaddrinfo(s.addrinfo);
    }

    pub fn connect(s: *TlsSocket) !void {
        switch (s.phase) {
            .Disconnected => {},
            .Connecting => return error.TlsAlreadyConnecting,
            .TlsStarted => return error.TlsAlreadyStarted,
        }

        const a = s.account;
        const cfg = s.config.config.?;

        L.print("Connecting {s} -> {s}:{}\n", .{ a.name, a.server, a.port });

        const sock = C.socket(C.AF_INET, C.SOCK_STREAM | C.SOCK_NONBLOCK, 0);
        if (sock < 0) {
            log(a, "socket: error", .{});
            return error.SocketCreation;
        }
        log(a, "socket created: {}", .{sock});

        errdefer {
            const r = C.close(sock);
            log(a, "close: {}", .{r});
        }

        const rc = C.connect(sock, @ptrCast([*c]const C.struct_sockaddr, s.addrinfo.ai_addr), s.addrinfo.ai_addrlen);
        if (rc < 0) {
            const errno = getErrno();
            if (errno == C.EINPROGRESS) {
                log(a, "connect: In Progress", .{});
            } else {
                log(a, "connect: error ({}, {})", .{ rc, errno });
                return error.Connect;
            }
        } else {
            log(a, "connect: success", .{});
        }

        if (s.tls == null) {
            s.tls = C.tls_client() orelse {
                log(a, "tls_client: error", .{});
                return error.TlsClientInit;
            };
        }

        errdefer {
            C.tls_free(s.tls.?);
            log(a, "tls_free", .{});
        }

        if (C.tls_configure(s.tls.?, cfg) != 0) {
            log(a, "tls_configure: error", .{});
            return error.TlsConfigure;
        }
        log(a, "tls_configure: success", .{});

        s.sock = sock;
        s.phase = .Connecting;
    }

    pub fn startTLS(s: *TlsSocket) !void {
        if (s.phase != .Connecting) return error.TlsSocketNotConnecting;

        const a = s.account;

        var buf: [256]u8 = undefined;
        _ = try fmt.bufPrintZ(&buf, "{s}", .{a.server});

        const sock = s.sock.?;
        const tls = s.tls.?;

        if (C.tls_connect_socket(tls, sock, &buf) != 0) {
            log(a, "tls_connect_socket: error", .{});
            return error.TlsConnectSocket;
        }
        log(a, "tls_connect_socket: success", .{});

        errdefer s.disconnect();

        var rc = C.tls_handshake(tls);
        if (rc == -1) {
            log(a, "tls_handshake", .{});
            return error.TlsHandshake;
        }
        log(a, "tls_handshake: success", .{});

        s.phase = .TlsStarted;
    }

    pub fn disconnect(s: *TlsSocket) void {
        switch (s.phase) {
            .Connecting, .TlsStarted => {},
            else => return,
        }

        const a = s.account;
        log(a, "Connection closing", .{});

        const tls = s.tls.?;
        var rc = C.tls_close(tls);
        log(a, "tls_close: {}", .{rc});
        C.tls_reset(tls);
        log(a, "tls_reset", .{});

        const sock = s.sock.?;
        rc = C.shutdown(sock, C.SHUT_RDWR);
        log(a, "shutdown: {}", .{rc});
        rc = C.close(sock);
        log(a, "close: {}", .{rc});

        s.phase = .Disconnected;
        s.sock = null;
    }

    pub fn read(s: *TlsSocket, buf: []u8) !usize {
        if (s.phase != .TlsStarted) return error.TlsNotYetStarted;

        const a = s.account;

        const bytes = C.tls_read(s.tls, buf.ptr, buf.len);
        log(a, "tls_read: {}", .{bytes});

        if (bytes == C.TLS_WANT_POLLIN) {
            log(a, "tls_read: TLS_WANT_POLLIN", .{});
            return error.TlsWantPollIn;
        } else if (bytes == C.TLS_WANT_POLLOUT) {
            log(a, "tls_read: TLS_WANT_POLLOUT", .{});
            return error.TlsWantPollOut;
        } else if (bytes < 0) {
            return error.TlsRead;
        }

        return @intCast(usize, bytes);
    }

    pub fn write(s: *TlsSocket, cmd: []const u8, comptime logging: bool) !void {
        if (s.phase != .TlsStarted) return error.TlsNotYetStarted;

        const a = s.account;

        const bytes = C.tls_write(s.tls, cmd.ptr, cmd.len);
        log(a, "tls_write: {}, {}", .{ bytes, cmd.len });
        if (logging and bytes == cmd.len) {
            log(a, "\"{s}\"", .{cmd[0 .. cmd.len - 2]});
        }

        if (bytes == C.TLS_WANT_POLLIN) {
            log(a, "tls_read: TLS_WANT_POLLIN", .{});
            return error.TlsWantPollIn;
        } else if (bytes == C.TLS_WANT_POLLOUT) {
            log(a, "tls_read: TLS_WANT_POLLOUT", .{});
            return error.TlsWantPollOut;
        } else if (bytes < 0) {
            return error.TlsWrite;
        } else if (bytes != cmd.len) {
            return error.TlsWriteBytesMismatch;
        }
    }
};
