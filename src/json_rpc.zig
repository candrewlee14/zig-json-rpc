const std = @import("std");
pub const xev = @import("xev");
pub const http = @import("./http.zig");
pub const ExampleMethodMapping = @import("./example_endpoint.zig").MethodMapping;

const BUF_SIZE = 4096;

pub const RpcErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    pub fn toString(self: RpcErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
        };
    }
};

pub fn Request(comptime ParamsT: type) type {
    return struct {
        const RealParamsT = if (ParamsT == std.json.Value) std.json.Value else ?ParamsT;
        const Self = @This();

        id: ?u32 = null,
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: RealParamsT = if (ParamsT == std.json.Value) .null else null,
    };
}

test Request {
    const json_str =
        \\ [{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}]
    ;
    const ReqT = Request([]const i32);
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

pub fn Response(comptime ResultT: type, comptime ErrDataT: type) type {
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

            pub fn fromRpcErrorCode(rpc_err_code: RpcErrorCode, data: RealErrDataT) Error {
                return Error{
                    .code = @intFromEnum(rpc_err_code),
                    .message = rpc_err_code.toString(),
                    .data = data,
                };
            }
        };
    };
}

const StringsResponse = Response([]const u8, []const u8);

const State = enum(u8) {
    active,
    shutting_down,
    inactive,
};

pub fn Server(comptime LocalMethodMapping: type) type {
    return struct {
        const http_version = "HTTP/1.1";
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
        buffer_pool: std.heap.MemoryPool([BUF_SIZE]u8),

        state: std.atomic.Atomic(State) = std.atomic.Atomic(State).init(.inactive),

        pub fn init(alloc: std.mem.Allocator, addr: std.net.Address) !Self {
            return Self{
                .alloc = alloc,
                .tp = xev.ThreadPool.init(.{}),
                .loop = try xev.Loop.init(.{}),
                .addr = addr,

                .completion_pool = std.heap.MemoryPool(xev.Completion).init(alloc),
                .socket_pool = std.heap.MemoryPool(xev.TCP).init(alloc),
                .buffer_pool = std.heap.MemoryPool([BUF_SIZE]u8).init(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            self.loop.stop();
            self.loop.deinit();
            self.completion_pool.deinit();
            self.socket_pool.deinit();
            self.buffer_pool.deinit();
        }

        fn mainLoop(self: *Self) !void {
            self.state.store(.active, .Release);
            self.socket_ = try xev.TCP.init(self.addr);
            const socket = &self.socket_.?;
            try socket.bind(self.addr);
            try socket.listen(256);
            while (self.state.load(.Acquire) == .active) {
                const c = try self.completion_pool.create();
                socket.accept(&self.loop, c, Self, self, acceptCallback);
                std.log.debug("accepting connections!", .{});
                try self.loop.run(.until_done);
                std.log.debug("", .{});
            }
        }

        pub fn start(self: *Self) !void {
            self.server_thread_ = try std.Thread.spawn(.{}, Self.mainLoop, .{self});
        }

        pub fn shutdown(self: *Self) !void {
            std.log.debug("shutting down!", .{});
            self.state.store(.shutting_down, .Release);
            std.log.debug("joining server thread (may be waiting on accept)", .{});
            // ignore error, we just want to end the accept loop
            if (std.net.tcpConnectToAddress(self.addr) catch null) |stream| {
                stream.close();
            }
            self.server_thread_.?.join();
        }

        fn destroyBuf(self: *Self, buf: []const u8) void {
            self.buffer_pool.destroy(
                @alignCast(
                    @as(*[BUF_SIZE]u8, @ptrFromInt(@intFromPtr(buf.ptr))),
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

        fn writeErrorResponse(
            self: *Self,
            writer: anytype,
            response_buf: []u8,
            res_fb: anytype,
            res_writer: anytype,
            rpc_error_code: RpcErrorCode,
        ) !void {
            _ = self;
            const response = StringsResponse{ .id = null, .@"error" = StringsResponse.Error.fromRpcErrorCode(rpc_error_code, "") };
            // write to response writer
            try std.json.stringify(response, .{}, res_writer);
            // use that writer's position to have a correct content-length in the output writer
            try writer.print("{s} {} {s}\r\n{s}\r\nContent-Length: {}\r\n\r\n{s}", .{
                Self.http_version,
                @intFromEnum(http.Status.ok),
                http.Status.ok.toString(),
                Self.http_response_header,
                res_fb.pos,
                response_buf[0..res_fb.pos],
            });
        }

        fn readCallbackHelper(
            self: *Self,
            read_buf: xev.ReadBuffer,
            r: xev.TCP.ReadError!usize,
            writer: anytype,
            res_buf: []u8,
            res_fb: anytype,
            res_writer: anytype,
        ) anyerror!xev.CallbackAction {
            const n = try r;
            const crs = "\r\n\r\n";

            const header_end = if (std.mem.indexOfPos(u8, read_buf.slice, 0, crs)) |idx| idx + crs.len else return error.BadHttpHeader;
            std.log.debug("read {} bytes", .{n});

            const body = read_buf.slice[header_end..n];

            const parsed_req = std.json.parseFromSlice(Request(std.json.Value), self.alloc, body, .{}) catch return error.InvalidRequest;
            defer parsed_req.deinit();

            const endpoint = LocalMethodMapping.fromString(parsed_req.value.method) orelse return error.MethodNotFound;

            var status = http.Status.ok;
            switch (endpoint) {
                inline else => |m| {
                    const result = try blk: {
                        if (LocalMethodMapping.Params(m) != void) {
                            const parsed_params = std.json.parseFromValue(
                                LocalMethodMapping.Params(m),
                                self.alloc,
                                parsed_req.value.params,
                                .{},
                            ) catch return error.InvalidParams;
                            defer parsed_params.deinit();
                            break :blk LocalMethodMapping.route(m, parsed_params.value);
                        } else {
                            break :blk LocalMethodMapping.route(m, {});
                        }
                    };
                    // TODO: improve error_data here
                    const response = Response(LocalMethodMapping.Result(m), []const u8){
                        .id = parsed_req.value.id,
                        .result = result,
                    };
                    if (parsed_req.value.id == null) {
                        // This is a Notification, so no need to serialize the result, but we'll still write the HTTP response below
                        status = http.Status.accepted;
                    } else {
                        try std.json.stringify(response, .{}, res_writer);
                    }
                    try writer.print("{s} {} {s}\r\n{s}\r\nContent-Length: {}\r\n\r\n{s}", .{
                        Self.http_version,
                        @intFromEnum(status),
                        status.toString(),
                        Self.http_response_header,
                        res_fb.pos,
                        res_buf[0..res_fb.pos],
                    });
                },
            }
            // Read again
            return .rearm;
        }

        fn readCallback(
            self_: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            socket: xev.TCP,
            read_buf: xev.ReadBuffer,
            r: xev.TCP.ReadError!usize,
        ) xev.CallbackAction {
            std.log.debug("read callback", .{});
            const self = self_.?;

            if (self.state.load(.Acquire) != .active) {
                socket.shutdown(&self.loop, c, Self, self, shutdownCallback);
                self.destroyBuf(read_buf.slice);
                return .disarm;
            }

            const c_write = self.completion_pool.create() catch unreachable;

            const buf_write = self.buffer_pool.create() catch unreachable;
            var fb = std.io.fixedBufferStream(buf_write);
            var writer = fb.writer();

            var response_buf: [BUF_SIZE]u8 = undefined;
            var res_fb = std.io.fixedBufferStream(response_buf[0..]);
            var res_writer = res_fb.writer();

            if (self.readCallbackHelper(read_buf, r, writer, &response_buf, res_fb, res_writer)) |action| {
                socket.write(loop, c_write, .{ .slice = buf_write[0..fb.pos] }, Self, self, writeCallback);
                return action;
            } else |err| {
                defer self.completion_pool.destroy(c);
                defer self.destroyBuf(read_buf.slice);
                const rpc_err_code = switch (err) {
                    error.InvalidParams => RpcErrorCode.invalid_params,
                    error.InvalidRequest => RpcErrorCode.invalid_request,
                    error.BadHttpHeader => RpcErrorCode.parse_error,
                    error.MethodNotFound => RpcErrorCode.method_not_found,
                    else => RpcErrorCode.internal_error,
                };
                self.writeErrorResponse(writer, &response_buf, res_fb, res_writer, rpc_err_code) catch |w_err| {
                    std.log.warn("failed to write error response, err={}", .{w_err});
                    return .disarm;
                };
                socket.write(loop, c_write, .{ .slice = buf_write[0..fb.pos] }, Self, self, writeCallback);
                return .disarm;
            }
        }

        fn writeCallback(
            self_: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            s: xev.TCP,
            buf: xev.WriteBuffer,
            r: xev.TCP.WriteError!usize,
        ) xev.CallbackAction {
            _ = s;
            _ = l;
            const self = self_.?;
            if (self.state.load(.Acquire) != .active) {
                self.destroyBuf(buf.slice);
                return .disarm;
            }
            std.log.debug("write callback", .{});
            _ = r catch |err| {
                std.log.warn("write error, err={}", .{err});
            };

            // We do nothing for write, just put back objects into the pool.
            self.completion_pool.destroy(c);
            self.destroyBuf(buf.slice);
            std.log.debug("destroyed buf", .{});
            return .disarm;
        }

        fn shutdownCallback(
            self_: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            s: xev.TCP,
            r: xev.TCP.ShutdownError!void,
        ) xev.CallbackAction {
            const self = self_.?;
            const state_ = self.state.compareAndSwap(.shutting_down, .inactive, .AcqRel, .Acquire);
            if (state_) |state| {
                if (state == .inactive) {
                    self.completion_pool.destroy(c);
                    return .disarm;
                }
            }
            std.log.debug("shutdown callback", .{});
            _ = r catch |err| {
                std.log.warn("shutdown failed, err={}", .{err});
                unreachable;
            };
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
            self.state.store(.inactive, .Release);
            return .disarm;
        }
    };
}

pub fn RpcService(comptime LocalMethodMapping: type, comptime ServerMethodMapping: type) type {
    return struct {
        const Self = @This();

        addr: std.net.Address,
        prng: std.rand.DefaultPrng = std.rand.DefaultPrng.init(123),
        server: Server(LocalMethodMapping),
        started: bool = false,

        pub fn init(alloc: std.mem.Allocator, addr: std.net.Address) !Self {
            const prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.os.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            return Self{
                .addr = addr,
                .server = try Server(LocalMethodMapping).init(alloc, addr),
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
        pub fn call(self: *Self, comptime endpoint: ServerMethodMapping, params: endpoint.Params()) !endpoint.Result() {
            const ParamsT = endpoint.Params();
            // Caller
            // - Build Request
            const rand = self.prng.random();
            const req = Request(ParamsT){
                .id = rand.int(u32),
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
            return ServerMethodMapping.route(endpoint, params);
            // return error.Unimplemented;
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    std.log.debug("hello!", .{});
    const addr = try std.net.Address.parseIp("0.0.0.0", 1234);
    var rpc_service = try RpcService(ExampleMethodMapping, ExampleMethodMapping).init(alloc, addr);
    defer rpc_service.deinit();

    try rpc_service.start(alloc);
    std.log.debug("started rpc service!", .{});
    defer rpc_service.shutdown();

    const out = try rpc_service.call(.subtract, &.{ 10, 5 });
    std.log.debug("called rpc service: {any}!", .{out});

    std.time.sleep(3 * std.time.ns_per_s);
}

test RpcService {
    const addr = try std.net.Address.parseIp("0.0.0.0", 0);
    var rpc_service = try RpcService(ExampleMethodMapping, ExampleMethodMapping).init(std.testing.allocator, addr);
    defer rpc_service.deinit();
    try rpc_service.start(std.testing.allocator);
    defer rpc_service.shutdown();
    const out = try rpc_service.call(.subtract, &.{ 10, 5 });
    _ = out;
}
