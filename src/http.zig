pub const Status = enum(u16) {
    ok = 200,
    accepted = 202,
    method_not_allowed = 405,
    unsupported_media_type = 415,

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .accepted => "Accepted",
            .method_not_allowed => "Method Not Allowed",
            .unsupported_media_type => "Unsupported Media Type",
        };
    }
};
