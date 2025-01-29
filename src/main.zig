const std = @import("std");
const builtin = @import("builtin");

const parser = @import("parser.zig");
const shell = @import("shell.zig");

const ARG_MAX = 4096;

const CliError = error{
    ReadError,
};

fn readLine(buf: []u8) !?[]const u8 {
    const stdin = std.io.getStdIn().reader();
    const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch return CliError.ReadError;

    return line;
}

pub fn main() !void {
    switch (builtin.os.tag) {
        .linux => {},
        .macos => {},
        else => {
            std.debug.print("zkal: Unsupported OS\n", .{});
            return;
        },
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [ARG_MAX]u8 = undefined;
    while (true) {
        const cwd = std.posix.getcwd(&buf);
        std.debug.print("{s}> ", .{cwd});

        const line = try readLine(&buf);

        // EOF
        if (line == null) std.process.exit(0);

        if (line.?.len == 0) continue;

        const groups = parser.parse(line.?, allocator) catch |err| {
            std.debug.print("zkal: {any}", .{err});
            continue;
        };

        shell.run(groups) catch |err| {
            std.debug.print("zkal: {any}", .{err});
        };
    }
}
