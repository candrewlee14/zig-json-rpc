const std = @import("std");
pub const xev = @import("xev");

pub fn TypedRequest(comptime ParamsT: type) type {
    return struct {
        const RealParamsT = if (ParamsT == std.json.Value) std.json.Value else ?ParamsT;
        const Self = @This();

        id: ?u32 = null,
        jsonrpc: []const u8,
        method: []const u8,
        params: RealParamsT = if (ParamsT == std.json.Value) .null else null,

        pub fn getEndpoint(self: *const Self) ?Self {
            return Endpoint.fromString(self.method);
        }
    };
}

test TypedRequest {
    const json_str =
        \\ [{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}]
    ;
    const ReqT = TypedRequest([]const i32);
    const req = try std.json.parseFromSlice([]const ReqT, std.testing.allocator, json_str, .{});
    defer req.deinit();
    const exp_reqs: []const ReqT = &[_]ReqT{ReqT{
        .jsonrpc = "2.0",
        .method = "subtract",
        .params = &.{ 42, 23 },
        .id = 1,
    }};
    try std.testing.expectEqualDeep(exp_reqs, req.value);
}

pub fn TypedResponse(comptime ResultT: type, comptime ErrDataT: type) type {
    return struct {
        const RealResultT = if (ResultT == std.json.Value) std.json.Value else ?ResultT;
        const RealErrDataT = if (ErrDataT == std.json.Value) std.json.Value else ?ErrDataT;
        const Self = @This();

        id: ?u32,
        jsonrpc: []const u8 = "2.0",
        result: RealResultT = if (ResultT == std.json.Value) .null else null,
        @"error": ?Error = null,

        const Error = struct {
            code: i32,
            message: []const u8,
            data: RealErrDataT = if (ErrDataT == std.json.Value) .null else null,
        };
    };
}

const Endpoint = enum {
    const Self = @This();

    subtract,
    add,
    ping,

    pub fn Params(comptime self: Self) type {
        return switch (self) {
            .subtract => []const i32,
            .add => []const i32,
            .ping => void,
        };
    }
    pub fn Response(comptime self: Self) type {
        return switch (self) {
            .subtract => i32,
            .add => i32,
            .ping => []const u8,
        };
    }
    pub fn route(comptime endpoint: Self, params: endpoint.Params()) !endpoint.Response() {
        return switch (endpoint) {
            .subtract => subtract(params),
            .add => add(params),
            .ping => "pong",
        };
    }
    pub fn fromString(str: []const u8) ?Self {
        inline for (@typeInfo(Self).Enum.fields) |field| {
            if (std.mem.eql(u8, field.name, str)) return @field(Self, field.name);
        }
        return null;
    }

    pub fn toString(self: Self) []const u8 {
        inline for (@typeInfo(Self).Enum.fields) |field| {
            if (field.value == @intFromEnum(self)) return field.name;
        }
        unreachable;
    }
};

fn subtract(params: []const i32) i32 {
    return params[0] - params[1];
}

fn add(params: []const i32) i32 {
    return params[0] + params[1];
}

test Endpoint {
    const params: []const i32 = &.{ 15, 7 };
    const res: i32 = try Endpoint.route(.subtract, params);
    const res2: i32 = try Endpoint.route(.add, params);
    try std.testing.expectEqual(@as(i32, 8), res);
    try std.testing.expectEqual(@as(i32, 22), res2);
}

pub fn Server(comptime LocalEndpoint: type) type {
    return struct {
        const http_version = "HTTP/1.1";
        const status_ok = "200 OK";
        const status_bad_request = "400 Bad Request";
        const http_response_header = "Content-Type: application/json; charset=utf-8\r\n" ++
            "Server: zig-json-rpc";
        const Self = @This();

        alloc: std.mem.Allocator,
        server_thread_: ?std.Thread = null,

        socket_: ?xev.TCP = null,
        tp: xev.ThreadPool,
        loop: xev.Loop,
        addr: std.net.Address,

        completion_pool: std.heap.MemoryPool(xev.Completion),
        socket_pool: std.heap.MemoryPool(xev.TCP),
        buffer_pool: std.heap.MemoryPool([4096]u8),

        active: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),

        pub fn init(alloc: std.mem.Allocator, addr: std.net.Address) !Self {
            return Self{
                .alloc = alloc,
                .tp = xev.ThreadPool.init(.{}),
                .loop = try xev.Loop.init(.{}),
                .addr = addr,

                .completion_pool = std.heap.MemoryPool(xev.Completion).init(alloc),
                .socket_pool = std.heap.MemoryPool(xev.TCP).init(alloc),
                .buffer_pool = std.heap.MemoryPool([4096]u8).init(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            self.active.store(false, .Release);
            self.loop.stop();
            if (self.server_thread_) |thr| {
                thr.detach();
            }
            self.loop.deinit();
            self.completion_pool.deinit();
            self.socket_pool.deinit();
            self.buffer_pool.deinit();
        }

        fn mainLoop(self: *Self) !void {
            self.active.store(true, .Release);
            self.socket_ = try xev.TCP.init(self.addr);
            const socket = &self.socket_.?;
            try socket.bind(self.addr);
            try socket.listen(256);
            while (self.active.load(.Acquire)) {
                const c = try self.completion_pool.create();
                socket.accept(&self.loop, c, Self, self, acceptCallback);
                std.log.debug("accepting connections!", .{});
                try self.loop.run(.until_done);
                std.log.debug("ran through at least once", .{});
            }
        }

        pub fn start(self: *Self) !void {
            self.server_thread_ = try std.Thread.spawn(.{}, Self.mainLoop, .{self});
        }

        fn destroyBuf(self: *Self, buf: []const u8) void {
            self.buffer_pool.destroy(
                @alignCast(
                    @as(*[4096]u8, @ptrFromInt(@intFromPtr(buf.ptr))),
                ),
            );
        }

        fn acceptCallback(
            self_: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            r: xev.TCP.AcceptError!xev.TCP,
        ) xev.CallbackAction {
            std.log.debug("accept callback", .{});
            const self = self_.?;
            // Create our socket
            const socket = self.socket_pool.create() catch unreachable;
            socket.* = r catch unreachable;

            // Start reading -- we can reuse c here because its done.
            const buf = self.buffer_pool.create() catch unreachable;
            socket.read(l, c, .{ .slice = buf }, Self, self, readCallback);
            return .disarm;
        }

        fn readCallback(
            self_: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            socket: xev.TCP,
            buf: xev.ReadBuffer,
            r: xev.TCP.ReadError!usize,
        ) xev.CallbackAction {
            std.log.debug("read callback", .{});
            const self = self_.?;
            const n = r catch |err| switch (err) {
                error.EOF => {
                    // socket.shutdown(loop, c, Self, self, shutdownCallback);
                    self.completion_pool.destroy(c);
                    self.destroyBuf(buf.slice);
                    return .disarm;
                },

                else => {
                    self.destroyBuf(buf.slice);
                    self.completion_pool.destroy(c);
                    std.log.warn("server read unexpected err={}", .{err});
                    return .disarm;
                },
            };

            const header_ = blk: {
                var i: usize = 0;
                while (i < buf.slice.len - 3) {
                    if (std.mem.eql(u8, buf.slice[i .. i + 4], "\r\n\r\n")) break :blk i + 4;
                    i += 1;
                }
                break :blk null;
            };
            std.log.debug("read {} bytes", .{n});
            if (header_ == null) {
                self.destroyBuf(buf.slice);
                self.completion_pool.destroy(c);
                std.log.warn("bad HTTP header format", .{});
                return .disarm;
            }
            const header = buf.slice[0..header_.?];
            _ = header;
            const body = buf.slice[header_.?..n];
            const status = if (body.len == 0) Self.status_bad_request else Self.status_ok;

            const c_echo = self.completion_pool.create() catch unreachable;
            const buf_write = self.buffer_pool.create() catch unreachable;
            var fb = std.io.fixedBufferStream(buf_write);
            var writer = fb.writer();

            const parsed_req = std.json.parseFromSlice(TypedRequest(std.json.Value), self.alloc, body, .{}) catch |err| {
                // TODO: write bad request
                self.destroyBuf(buf.slice);
                self.completion_pool.destroy(c);
                std.log.warn("bad request, err={}", .{err});
                return .disarm;
            };
            defer parsed_req.deinit();
            const endpoint_ = LocalEndpoint.fromString(parsed_req.value.method);
            if (endpoint_ == null) {
                // TODO: write bad request, no such method
                self.destroyBuf(buf.slice);
                self.completion_pool.destroy(c);
                std.log.warn("no such method \"{s}\"", .{parsed_req.value.method});
                return .disarm;
            }

            var response_buf: [4096]u8 = undefined;
            var res_fb = std.io.fixedBufferStream(response_buf[0..]);
            var res_writer = res_fb.writer();

            switch (endpoint_.?) {
                inline else => |m| {
                    const result = blk: {
                        if (LocalEndpoint.Params(m) != void) {
                            const parsed_params = std.json.parseFromValue(LocalEndpoint.Params(m), self.alloc, parsed_req.value.params, .{}) catch |err| {
                                // TODO: write bad request, params
                                std.log.warn("bad request, failed to parse params, err={}", .{err});
                                return .disarm;
                            };
                            break :blk LocalEndpoint.route(m, parsed_params.value) catch |err| {
                                // TODO: write internal server error
                                std.log.warn("internal error, err={}", .{err});
                                return .disarm;
                            };
                        } else {
                            break :blk LocalEndpoint.route(m, {}) catch |err| {
                                // TODO: write internal server error
                                std.log.warn("internal error, err={}", .{err});
                                return .disarm;
                            };
                        }
                    };
                    // TODO: improve error_data here
                    const response = TypedResponse(LocalEndpoint.Response(m), []const u8){
                        .id = parsed_req.value.id,
                        .result = result,
                    };
                    std.json.stringify(response, .{}, res_writer) catch |err| {
                        self.destroyBuf(buf.slice);
                        self.completion_pool.destroy(c);
                        std.log.warn("failed to write to response buffer err={}", .{err});
                        return .disarm;
                    };
                    writer.print("{s} {s}\r\n{s}\r\nContent-Length: {}\r\n\r\n{s}\r\n\r\n", .{
                        Self.http_version,
                        status,
                        Self.http_response_header,
                        res_fb.pos,
                        response_buf[0..res_fb.pos],
                    }) catch |err| {
                        self.destroyBuf(buf.slice);
                        self.completion_pool.destroy(c);
                        std.log.warn("failed to write to output buffer err={}", .{err});
                        return .disarm;
                    };
                    socket.write(loop, c_echo, .{ .slice = buf_write[0..fb.pos] }, Self, self, writeCallback);
                },
            }

            // Read again
            return .rearm;
        }

        fn writeCallback(
            self_: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            s: xev.TCP,
            buf: xev.WriteBuffer,
            r: xev.TCP.WriteError!usize,
        ) xev.CallbackAction {
            _ = r catch unreachable;

            // We do nothing for write, just put back objects into the pool.
            std.log.debug("write callback", .{});
            const self = self_.?;
            self.completion_pool.destroy(c);
            self.destroyBuf(buf.slice);
            std.log.debug("destroyed buf", .{});
            s.shutdown(l, c, Self, self, shutdownCallback);
            // std.log.debug("queued shutdown", .{});
            return .disarm;
        }

        pub fn shutdown(self: *Self) !void {
            self.active.store(false, .Release);
            var c = try self.completion_pool.create();
            if (self.socket_) |s| {
                std.log.debug("queueing socket writer shutdown!", .{});
                s.close(&self.loop, c, Self, self, closeCallback);
                s.shutdown(&self.loop, c, Self, self, shutdownCallback);
            } else {
                std.log.debug("no socket", .{});
            }
        }

        fn shutdownCallback(
            self_: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            s: xev.TCP,
            r: xev.TCP.ShutdownError!void,
        ) xev.CallbackAction {
            const self = self_.?;
            std.log.debug("shutdown callback", .{});
            _ = r catch unreachable;
            s.close(l, c, Self, self, closeCallback);
            return .disarm;
        }

        fn closeCallback(
            self_: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            socket: xev.TCP,
            r: xev.TCP.CloseError!void,
        ) xev.CallbackAction {
            std.log.debug("close callback", .{});
            _ = l;
            _ = r catch unreachable;
            _ = socket;

            const self = self_.?;
            self.completion_pool.destroy(c);
            return .disarm;
        }
    };
}

pub fn RpcService(comptime LocalEndpoint: type, comptime ServerEndpoint: type) type {
    return struct {
        const Self = @This();

        addr: std.net.Address,
        prng: std.rand.DefaultPrng = std.rand.DefaultPrng.init(123),
        server: Server(LocalEndpoint),
        started: bool = false,

        pub fn init(alloc: std.mem.Allocator, addr: std.net.Address) !Self {
            const prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.os.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            return Self{
                .addr = addr,
                .server = try Server(LocalEndpoint).init(alloc, addr),
                .prng = prng,
            };
        }

        pub fn deinit(self: *Self) void {
            self.server.deinit();
        }

        pub fn start(
            self: *Self,
            alloc: std.mem.Allocator,
            // addr: std.net.Address,
        ) !void {
            _ = alloc;
            try self.server.start();
        }
        pub fn shutdown(self: *Self) void {
            self.server.shutdown() catch unreachable;
        }
        pub fn connect() void {}
        pub fn listen() void {}
        pub fn call(self: *Self, comptime endpoint: ServerEndpoint, params: endpoint.Params()) !endpoint.Response() {
            const ParamsT = endpoint.Params();
            const ResponseT = endpoint.Response();
            _ = ResponseT;
            // Caller
            // - Build Request
            const rand = self.prng.random();
            const req = TypedRequest(ParamsT){
                .id = rand.int(u32),
                .jsonrpc = "2.0",
                .method = endpoint.toString(),
                .params = params,
            };
            _ = req;
            // - Serialize Request
            // - Send over stream
            // Callee
            // - Read from stream
            // - Deserialize Request
            // - Route to proper method
            // - Serialize Response
            // - Send back over stream
            // Caller
            // - Read from stream
            // - Deserialize Response
            //
            // Profit!
            //
            return Endpoint.route(endpoint, params);
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    std.log.debug("hello!", .{});
    const addr = try std.net.Address.parseIp("0.0.0.0", 1234);
    var rpc_service = try RpcService(Endpoint, Endpoint).init(alloc, addr);
    defer rpc_service.deinit();

    try rpc_service.start(alloc);
    std.log.debug("started rpc service!", .{});
    defer rpc_service.shutdown();

    const out = try rpc_service.call(.subtract, &.{ 10, 5 });
    std.log.debug("called rpc service: {any}!", .{out});

    if (rpc_service.server.server_thread_) |thr| thr.join();
}

test RpcService {
    const addr = try std.net.Address.parseIp("0.0.0.0", 0);
    var rpc_service = try RpcService(Endpoint, Endpoint).init(std.testing.allocator, addr);
    defer rpc_service.deinit();
    try rpc_service.start(std.testing.allocator);
    defer rpc_service.shutdown();
    const out = try rpc_service.call(.subtract, &.{ 10, 5 });
    _ = out;
}
