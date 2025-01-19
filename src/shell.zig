const std = @import("std");
const parser = @import("parser.zig");

const ShellError = error{
    ExecChildFailed,
    CommandNotFound,
};

fn pipeCommand(group: *const parser.Group, command_idx: usize, fd: ?i32, allocator: std.mem.Allocator) !void {
    const cmd = group.commands.items[command_idx];
    const is_last_pipe = command_idx == 0;

    if (fd) |old_fd| {
        try std.posix.dup2(old_fd, std.posix.STDOUT_FILENO);
        std.posix.close(old_fd);
    }

    if (is_last_pipe) {} else {
        const pipe = try std.posix.pipe();

        const pid = try std.posix.fork();
        if (pid == 0) {
            try pipeCommand(group, command_idx - 1, pipe[1], allocator);
        }

        std.posix.close(pipe[1]);
        try std.posix.dup2(pipe[0], std.posix.STDIN_FILENO);
        std.posix.close(pipe[0]);

        _ = std.posix.waitpid(pid, 0);
    }

    const envp = std.c.environ;

    const cmd_name = cmd.argv.items[0];
    const path = try allocator.dupeZ(u8, cmd_name);
    const args = try allocator.allocSentinel(?[*:0]u8, cmd.argv.items.len, null);
    for (cmd.argv.items, 0..) |arg, i| args[i] = (try allocator.dupeZ(u8, arg)).ptr;

    _ = std.posix.execvpeZ(path, args, envp) catch null;
    return ShellError.CommandNotFound;
}

fn printShellError(err: anyerror) void {
    switch (err) {
        ShellError.ExecChildFailed => {
            std.debug.print("zkal: Failed to execute\n", .{});
        },
        ShellError.CommandNotFound => {
            std.debug.print("zkal: Command not found\n", .{});
        },
        else => {
            std.debug.print("zkal: Error occured.\n", .{});
        },
    }
}

pub fn run(groups: []const parser.Group) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    for (groups) |group| {
        const start_idx = group.commands.items.len - 1;
        const start_command = group.commands.items[start_idx];
        const start_cmd_name = start_command.argv.items[0];

        if (std.mem.eql(u8, start_cmd_name, "cd")) {
            try std.posix.chdir("HOME");
        } else if (std.mem.eql(u8, start_cmd_name, "exit")) {
            try std.process.exit(0);
        }

        const pid = try std.posix.fork();

        if (pid == 0) {
            pipeCommand(&group, start_idx, null, allocator) catch |err| printShellError(err);
        }

        const result = std.posix.waitpid(pid, 0);
        const pipe_errored = if (std.posix.W.IFEXITED(result.status))
            std.posix.W.EXITSTATUS(result.status) != 0
        else
            false;

        switch (group.logical_operator) {
            .None, .And => {
                if (pipe_errored) break;
            },
            .Or => {
                if (!pipe_errored) break;
            },
        }
    }
}
