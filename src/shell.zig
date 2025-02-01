const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");

const ARG_MAX = 4096;

const ShellError = error{
    ExecChildFailed,
    CommandNotFound,
};

const CliError = error{
    ReadError,
};

var foreground_pid: ?std.posix.pid_t = null;

fn pipeCommand(group: *const parser.Group, command_idx: usize, fd: ?i32, allocator: std.mem.Allocator) !void {
    const cmd = group.commands.items[command_idx];
    const is_last_pipe = command_idx == 0;

    if (fd) |old_fd| {
        try std.posix.dup2(old_fd, std.posix.STDOUT_FILENO);
        std.posix.close(old_fd);
    }

    if (is_last_pipe) {
        if (group.rstdout) |rstdout| {
            const stdout_fd = try std.posix.open(rstdout, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
            try std.posix.dup2(stdout_fd, std.posix.STDOUT_FILENO);
            std.posix.close(stdout_fd);
        }
        if (group.rstderr) |rstderr| {
            const stderr_fd = try std.posix.open(rstderr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
            try std.posix.dup2(stderr_fd, std.posix.STDOUT_FILENO);
            std.posix.close(stderr_fd);
        }
        if (group.rstdin) |rstdin| {
            const stdin_fd = try std.posix.open(rstdin, .{ .ACCMODE = .RDONLY }, 0o644);
            try std.posix.dup2(stdin_fd, std.posix.STDIN_FILENO);
            std.posix.close(stdin_fd);
        }
    } else {
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

fn execute(groups: []const parser.Group) !void {
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
            if (group.is_background) {
                try std.posix.setpgid(0, 0);
                std.debug.print("[{d}]\n", .{std.c.getpid()});
            }

            pipeCommand(&group, start_idx, null, allocator) catch |err| {
                printShellError(err);
                std.process.exit(1);
            };
        }

        if (group.is_background) {
            _ = std.posix.waitpid(pid, std.c.W.NOHANG);
        } else {
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
}

fn handleBackgroundProcess(_: i32) callconv(.c) void {
    if (foreground_pid) |_| {
        return;
    }

    const result = std.posix.waitpid(-1, std.c.W.NOHANG);
    if (result.pid > 0 and foreground_pid != result.pid) {
        std.debug.print("[{d}] Done\n", .{result.pid});
    }

    if (result.pid == foreground_pid) {
        foreground_pid = null;
    }
}

fn readLine(buf: []u8) !?[]const u8 {
    const stdin = std.io.getStdIn().reader();
    const line = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch return CliError.ReadError;

    return line;
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const background_process_action = std.posix.Sigaction{
        .handler = .{ .handler = handleBackgroundProcess },
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            .linux => std.posix.empty_sigset,
            else => @compileError("os not supported"),
        },
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &background_process_action, null);

    var buf: [ARG_MAX]u8 = undefined;
    while (true) {
        const cwd = try std.posix.getcwd(&buf);
        std.debug.print("{s}> ", .{cwd});

        const line = try readLine(&buf);

        // EOF
        if (line == null) std.process.exit(0);

        if (line.?.len == 0) continue;

        const groups = parser.parse(line.?, allocator) catch |err| {
            std.debug.print("zkal: {any}", .{err});
            continue;
        };

        execute(groups) catch |err| {
            std.debug.print("zkal: {any}", .{err});
        };
    }
}
