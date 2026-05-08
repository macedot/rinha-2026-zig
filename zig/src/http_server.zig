const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
});
const config = @import("config.zig");
const dataset = @import("dataset.zig");
const ivf_search = @import("ivf_search.zig");
const c_bridge = @import("c_bridge.zig");
const vectorizer = @import("vectorizer.zig");
const http_resp = @import("http_resp.zig");

const REQ_BUF_SIZE = 32768;

extern fn __errno_location() *c_int;
fn getErrno() c_int { return __errno_location().*; }

pub const Server = struct {
    cfg: *const config.Config,
    ds: ?*dataset.Dataset,
    use_zig: bool,
    server_fd: c_int,

    pub fn init(cfg: *const config.Config, ds: ?*dataset.Dataset, use_zig: bool) !Server {
        const server_fd = try createSocket(cfg);
        return Server{ .cfg = cfg, .ds = ds, .use_zig = use_zig, .server_fd = server_fd };
    }

    pub fn run(self: *Server) !void {
        while (true) {
            var client_addr: c.struct_sockaddr = undefined;
            var client_addr_len: c.socklen_t = @sizeOf(c.struct_sockaddr);
            const client_fd = c.accept(self.server_fd, &client_addr, &client_addr_len);
            if (client_fd < 0) {
                const e = getErrno();
                if (e == c.EINTR) continue;
                std.debug.print("accept error: {}\n", .{e});
                return error.AcceptFailed;
            }
            defer _ = c.close(client_fd);
            self.handleConnection(client_fd) catch |err| switch (err) {
                error.ConnectionClosed, error.BrokenPipe => {},
                else => std.debug.print("conn error: {}\n", .{err}),
            };
        }
    }

    fn handleConnection(self: *Server, fd: c_int) !void {
        var req_buf: [REQ_BUF_SIZE]u8 = undefined;
        var req_len: usize = 0;

        while (true) {
            const n = c.read(fd, req_buf[req_len..].ptr, req_buf.len - req_len);
            if (n < 0) {
                const e = getErrno();
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                return error.ReadFailed;
            }
            if (n == 0) return error.ConnectionClosed;
            req_len += @intCast(n);

            if (try self.tryProcess(fd, req_buf[0..req_len])) return;
            if (req_len >= REQ_BUF_SIZE - 1) return;
        }
    }

    fn tryProcess(self: *Server, fd: c_int, buf: []u8) !bool {
        const header_end = std.mem.find(u8, buf, "\r\n\r\n") orelse {
            if (buf.len >= REQ_BUF_SIZE - 1) {
                _ = try writeAll(fd, http_resp.resp_bad_req);
                return true;
            }
            return false;
        };

        const headers = buf[0..header_end];
        const body_start = header_end + 4;

        if (std.mem.startsWith(u8, headers, "GET /ready")) {
            _ = try writeAll(fd, http_resp.resp_ready);
            return true;
        }

        if (std.mem.startsWith(u8, headers, "POST /fraud-score")) {
            const cl = findContentLength(headers) orelse {
                _ = try writeAll(fd, http_resp.resp_bad_req);
                return true;
            };
            if (buf.len < body_start + cl) return false;

            const body = buf[body_start .. body_start + cl];
            const q = vectorizer.build(body) orelse {
                _ = try writeAll(fd, http_resp.resp_bad_req);
                return true;
            };

            const frauds = if (self.use_zig) ivf_search.search(q, self.ds.?) else c_bridge.search(q);
            if (frauds > 5) {
                _ = try writeAll(fd, http_resp.resp_internal_err);
                return true;
            }
            _ = try writeAll(fd, http_resp.scoreFor(frauds));
            return true;
        }

        _ = try writeAll(fd, http_resp.resp_not_found);
        return true;
    }
};

fn writeAll(fd: c_int, data: []const u8) !usize {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = c.write(fd, data.ptr + sent, data.len - sent);
        if (n < 0) {
            const e = getErrno();
            if (e == c.EAGAIN or e == c.EWOULDBLOCK) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.BrokenPipe;
        sent += @intCast(n);
    }
    return sent;
}

fn findContentLength(headers: []const u8) ?usize {
    const key = "Content-Length:";
    const pos = std.ascii.findIgnoreCase(headers, key) orelse return null;
    var p = pos + key.len;
    while (p < headers.len and (headers[p] == ' ' or headers[p] == '\t')) : (p += 1) {}
    var v: usize = 0;
    while (p < headers.len and std.ascii.isDigit(headers[p])) : (p += 1) {
        v = v * 10 + (headers[p] - '0');
    }
    return v;
}

fn createSocket(cfg: *const config.Config) !c_int {
    if (cfg.use_tcp) return createTcpSocket(cfg);
    return createUdsSocket(cfg);
}

fn setNonBlock(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

fn createTcpSocket(cfg: *const config.Config) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var opt: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &opt, @sizeOf(c_int));
    if (cfg.reuse_port) {
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEPORT, &opt, @sizeOf(c_int));
    }
    if (cfg.tcp_nodelay) {
        _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &opt, @sizeOf(c_int));
    }

    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(cfg.port);
    addr.sin_addr.s_addr = if (std.mem.eql(u8, cfg.host, "0.0.0.0")) c.INADDR_ANY else c.inet_addr(cfg.host.ptr);

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) return error.BindFailed;
    if (c.listen(fd, 128) != 0) return error.ListenFailed;

    std.debug.print("listening TCP {s}:{}\n", .{ cfg.host, cfg.port });
    return fd;
}

fn createUdsSocket(cfg: *const config.Config) !c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    if (cfg.unlink_uds) {
        _ = c.unlink(cfg.uds_path.ptr);
    }

    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    const path_len = @min(cfg.uds_path.len, @sizeOf(@TypeOf(addr.sun_path)) - 1);
    @memcpy(addr.sun_path[0..path_len], cfg.uds_path[0..path_len]);
    addr.sun_path[path_len] = 0;

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
    if (c.listen(fd, 128) != 0) return error.ListenFailed;

    const mode = octalFromDecimal(cfg.uds_mode);
    _ = c.chmod(cfg.uds_path.ptr, mode);

    std.debug.print("listening UDS {s} mode={}\n", .{ cfg.uds_path, cfg.uds_mode });
    return fd;
}

fn octalFromDecimal(mode: u32) u32 {
    const aa = mode / 100;
    const bb = (mode / 10) % 10;
    const cc = mode % 10;
    return (aa << 6) | (bb << 3) | cc;
}
