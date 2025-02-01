const std = @import("std");
const builtin = @import("builtin");

const shell = @import("shell.zig");

pub fn main() !void {
    switch (builtin.os.tag) {
        .linux => {},
        .macos => {},
        else => {
            std.debug.print("zkal: Unsupported OS\n", .{});
            return;
        },
    }

    try shell.run();
}
