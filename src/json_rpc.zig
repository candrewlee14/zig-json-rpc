const std = @import("std");

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

pub const Response = struct {
    const Self = @This();

    id: ?u32,
    jsonrpc: []const u8,
    result: std.json.Value = .null,
    @"error": ?Error = .null,

    const Error = struct {
        code: i32,
        message: []const u8,
        data: std.json.Value = .null,
    };
};

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

pub fn RpcService(comptime LocalEndpoint: type, comptime ServerEndpoint: type) type {
    _ = LocalEndpoint;
    return struct {
        const Self = @This();

        mu: std.Thread.Mutex = .{},
        prng: std.rand.DefaultPrng,
        client: std.http.Client,
        server: std.http.Server,
        active: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),
        tp: std.Thread.Pool,
        started: bool = false,

        pub fn init(alloc: std.mem.Allocator) !Self {
            const prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.os.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            // var tp: std.Thread.Pool = undefined;
            // try tp.init(.{ .allocator = alloc });
            return Self{
                .prng = prng,
                .client = std.http.Client{ .allocator = alloc },
                .server = std.http.Server.init(alloc, .{ .reuse_address = true }),
                .tp = undefined,
            };
        }
        pub fn start(
            self: *Self,
            alloc: std.mem.Allocator,
            // addr: std.net.Address,
        ) !void {
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
        pub fn deinit(self: *Self) void {
            self.client.deinit();
            self.server.deinit();
            if (self.started) self.tp.deinit();
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

// test Response {
//     {
//         const json_str =
//             \\ {"jsonrpc": "2.0", "result": 19, "id": 1}
//         ;
//         const Res = Response(i32, []const u8);
//         const res = try std.json.parseFromSlice(Res, std.testing.allocator, json_str, .{});
//         defer res.deinit();
//         try std.testing.expectEqualDeep(
//             Res{
//                 .jsonrpc = "2.0",
//                 .result = 19,
//                 .id = 1,
//             },
//             res.value,
//         );
//     }
//     {
//         const json_str =
//             \\ {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": null}
//         ;
//         const Res = Response(i32, []const u8);
//         const res = try std.json.parseFromSlice(Res, std.testing.allocator, json_str, .{});
//         defer res.deinit();
//         try std.testing.expectEqualDeep(
//             Res{
//                 .jsonrpc = "2.0",
//                 .@"error" = .{
//                     .code = -32700,
//                     .message = "Parse error",
//                 },
//                 .id = null,
//             },
//             res.value,
//         );
//     }
//     {
//         const json_str =
//             \\ [
//             \\    {"jsonrpc": "2.0", "result": 7, "id": 1},
//             \\    {"jsonrpc": "2.0", "result": 19, "id": 2},
//             \\    {"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid Request"}, "id": null},
//             \\    {"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": 5},
//             \\    {"jsonrpc": "2.0", "result": 20, "id": 9}
//             \\ ]
//         ;
//         const Res = Response(i32, []const u8);
//         const res = try std.json.parseFromSlice([]const Res, std.testing.allocator, json_str, .{});
//         defer res.deinit();
//         const exp_res_list: []const Res = &.{
//             Res{ .jsonrpc = "2.0", .result = 7, .id = 1 },
//             Res{ .jsonrpc = "2.0", .result = 19, .id = 2 },
//             Res{ .jsonrpc = "2.0", .@"error" = .{ .code = -32600, .message = "Invalid Request" }, .id = null },
//             Res{ .jsonrpc = "2.0", .@"error" = .{ .code = -32601, .message = "Method not found" }, .id = 5 },
//             Res{ .jsonrpc = "2.0", .result = 20, .id = 9 },
//         };
//         try std.testing.expectEqualDeep(
//             exp_res_list,
//             res.value,
//         );
//     }
// }
//
// const TestUnion = union(enum) {
//     str: []const u8,
//     num: i32,
// };
//
// test "Blah" {
//     std.debug.print("\n", .{});
//     var writer = std.io.getStdOut().writer();
//     try std.json.stringify(TestUnion{ .str = "Hey!" }, .{}, writer);
//     std.debug.print("oi\n", .{});
// }
