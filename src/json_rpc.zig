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
        jsonrpc: []const u8,
        result: RealResultT = if (ResultT == std.json.Value) .null else null,
        @"error": ?Error = .null,

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
            .ping => []const u8,
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
    _ = LocalEndpoint;
    return struct {
        const Self = @This();

        server_thread_: ?std.Thread = null,

        tp: xev.ThreadPool,
        loop: xev.Loop,
        addr: std.net.Address,

        completion_pool: std.heap.MemoryPool(xev.Completion),
        socket_pool: std.heap.MemoryPool(xev.TCP),
        buffer_pool: std.heap.MemoryPool([4096]u8),

        active: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),

        pub fn init(alloc: std.mem.Allocator, addr: std.net.Address) !Server {
            return Server{
                .tp = xev.ThreadPool.init(.{}),
                .loop = try xev.Loop.init(alloc),
                .addr = addr,

                .completion_pool = std.heap.MemoryPool(xev.Completion).init(alloc),
                .socket_pool = std.heap.MemoryPool(xev.TCP).init(alloc),
                .buffer_pool = std.heap.MemoryPool([4096]u8).init(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            self.active.store(.Release);
            if (self.server_thread_) |thr| {
                thr.join();
            }
            self.completion_pool.deinit();
            self.socket_pool.deinit();
            self.buffer_pool.deinit();
        }

        pub fn mainLoop(self: *Self) !void {
            const socket = try xev.TCP.init(self.addr);
            try socket.bind(self.addr);
            try socket.listen(256);
            while (self.active.load(.Acquire)) {
                const c = try self.completion_pool.create();
                socket.accept(self.loop, c, self.addr, Self, self, acceptCallback);
                try self.loop.run(.until_done);
            }
        }

        pub fn start(self: *Self) !void {
            self.server_thr = try std.Thread.spawn(.{}, Self.mainLoop, .{self});
        }

        fn destroyBuf(self: *Server, buf: []const u8) void {
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
            const self = self_.?;
            const n = r catch |err| switch (err) {
                error.EOF => {
                    // TODO: do we want to close the listener here? I don't think so
                    // socket.shutdown(loop, c, Self, self, shutdownCallback);
                    std.log.debug("buf: {s}", .{buf.slice});
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

            std.log.debug("read {} bytes", .{n});
            const c_echo = self.completion_pool.create() catch unreachable;
            const buf_write = self.buffer_pool.create() catch unreachable;
            std.mem.copy(u8, buf_write, buf.slice[0..n]);
            socket.write(loop, c_echo, .{ .slice = buf_write[0..n] }, Server, self, writeCallback);

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
            _ = l;
            _ = s;
            _ = r catch unreachable;

            // We do nothing for write, just put back objects into the pool.
            const self = self_.?;
            self.completion_pool.destroy(c);
            self.buffer_pool.destroy(
                @alignCast(
                    @as(*[4096]u8, @ptrFromInt(@intFromPtr(buf.slice.ptr))),
                ),
            );
            return .disarm;
        }

        fn shutdownCallback(
            self_: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            s: xev.TCP,
            r: xev.TCP.ShutdownError!void,
        ) xev.CallbackAction {
            _ = r catch unreachable;
            const self = self_.?;
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
            _ = l;
            _ = r catch unreachable;
            _ = socket;

            const self = self_.?;
            self.stop = true;
            self.completion_pool.destroy(c);
            return .disarm;
        }
    };
}

pub fn RpcService(comptime LocalEndpoint: type, comptime ServerEndpoint: type) type {
    _ = LocalEndpoint;
    return struct {
        const Self = @This();

        prng: std.rand.DefaultPrng = std.rand.DefaultPrng.init(123),

        started: bool = false,

        pub fn init(alloc: std.mem.Allocator) !Self {
            _ = alloc;
            const prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.os.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            // var tp: std.Thread.Pool = undefined;
            // try tp.init(.{ .allocator = alloc });
            return Self{
                .prng = prng,
            };
        }

        pub fn deinit(self: *Self) void {
            self.loop.deinit();
            self.client.deinit();
            self.server.deinit();
            if (self.started) self.tp.deinit();

            self.completion_pool.deinit();
            self.socket_pool.deinit();
            self.buffer_pool.deinit();
        }

        pub fn start(
            self: *Self,
            alloc: std.mem.Allocator,
            loop: *xev.Loop,
            // addr: std.net.Address,
        ) !void {
            const address = std.net.Address.parseIp("0.0.0.0", 4321);
            const server = xev.TCP.init(address);
            const address2 = std.net.Address.parseIp("0.0.0.0", 1234);
            const client = xev.TCP.init(address2);
            _ = client;

            try server.bind(address);
            try server.listen(1);

            const c_accept = try self.completion_pool.create();
            // This returns rearm, so notice this will continue to accept connections
            server.accept(&loop, c_accept, Self, self, (struct {
                fn callback(
                    ud: ?*?xev.TCP,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.AcceptError!xev.TCP,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .rearm;
                }
            }).callback);

            try self.tp.init(.{ .allocator = alloc });
            self.active.store(true, .Release);
            // try self.server.listen(addr);
            _ = try self.tp.spawn((struct {
                fn run(s: *Self) void {
                    while (s.active.load(.Acquire)) {
                        // const res = try self.server.accept(.{});
                    }
                }
            }).run, .{self});
            self.started = true;
        }
        pub fn shutdown(self: *Self) void {
            self.active.store(false, .Release);
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

test RpcService {
    var rpc_service = try RpcService(Endpoint, Endpoint).init(std.testing.allocator);
    defer rpc_service.deinit();
    try rpc_service.start(std.testing.allocator);
    defer rpc_service.shutdown();
    const out = try rpc_service.call(.subtract, &.{ 10, 5 });
    _ = out;
}
