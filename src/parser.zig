const std = @import("std");

const ParserError = error{
    InvalidToken,
    InvalidCommand,
    InvalidGroup,
    OutOfMemory,
};

const Command = struct {
    argv: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) Command {
        return Command{
            .argv = std.ArrayList([]const u8).init(allocator),
        };
    }
};

const LogicalOperator = enum {
    None,
    And,
    Or,
};

pub const Group = struct {
    commands: std.ArrayList(Command),

    rstdin: ?[]const u8,
    rstdout: ?[]const u8,
    rstderr: ?[]const u8,

    is_background: bool,
    logical_operator: LogicalOperator,

    fn init(allocator: std.mem.Allocator) Group {
        return Group{
            .commands = std.ArrayList(Command).init(allocator),
            .rstdin = null,
            .rstdout = null,
            .rstderr = null,
            .is_background = false,
            .logical_operator = .None,
        };
    }
};

const ParserState = struct {
    current_command: Command,
    current_group: Group,
    groups: std.ArrayList(Group),
};

fn pipe(state: *ParserState, token_it: *std.mem.SplitIterator(u8, .scalar)) !void {
    if (state.current_command.argv.items.len == 0) {
        return ParserError.InvalidCommand;
    }

    if (token_it.peek() == null) {
        return ParserError.InvalidToken;
    }

    state.current_group.commands.append(state.current_command) catch |err| return err;
    state.current_command = Command.init(state.current_command.argv.allocator);

    return;
}

fn output(state: *ParserState, token_it: *std.mem.SplitIterator(u8, .scalar)) !void {
    if (state.current_command.argv.items.len == 0) {
        return ParserError.InvalidCommand;
    }

    state.current_group.rstdout = token_it.next() orelse return ParserError.InvalidToken;
}

fn input(state: *ParserState, token_it: *std.mem.SplitIterator(u8, .scalar)) !void {
    if (state.current_command.argv.items.len == 0) {
        return ParserError.InvalidCommand;
    }

    state.current_group.rstdin = token_it.next() orelse return ParserError.InvalidToken;
}

fn andChain(state: *ParserState, token_it: *std.mem.SplitIterator(u8, .scalar)) !void {
    if (state.current_command.argv.items.len == 0) {
        return ParserError.InvalidCommand;
    }

    if (token_it.peek() == null) {
        return ParserError.InvalidToken;
    }

    state.current_group.logical_operator = LogicalOperator.And;
    state.current_group.commands.append(state.current_command) catch |err| return err;
    state.groups.append(state.current_group) catch |err| return err;

    state.current_command = Command.init(state.current_command.argv.allocator);
    state.current_group = Group.init(state.current_group.commands.allocator);

    return;
}

fn orChain(state: *ParserState, token_it: *std.mem.SplitIterator(u8, .scalar)) !void {
    if (state.current_command.argv.items.len == 0) {
        return ParserError.InvalidCommand;
    }

    if (token_it.peek() == null) {
        return ParserError.InvalidToken;
    }

    state.current_group.logical_operator = LogicalOperator.Or;
    state.current_group.commands.append(state.current_command) catch |err| return err;
    state.groups.append(state.current_group) catch |err| return err;

    state.current_command = Command.init(state.current_command.argv.allocator);
    state.current_group = Group.init(state.current_group.commands.allocator);

    return;
}

fn outputError(state: *ParserState, token_it: *std.mem.SplitIterator(u8, .scalar)) !void {
    if (state.current_command.argv.items.len == 0) {
        return ParserError.InvalidCommand;
    }

    state.current_group.rstderr = token_it.next() orelse return ParserError.InvalidToken;
}

const TokenFn = *const fn (*ParserState, *std.mem.SplitIterator(u8, .scalar)) ParserError!void;

const TokenToFunctionMap = std.StaticStringMap(TokenFn).initComptime(.{
    .{ "|", pipe },
    .{ ">", output },
    .{ "<", input },
    .{ "2>", outputError },
    .{ "&&", andChain },
    .{ "||", orChain },
});

pub fn parse(line: []const u8, allocator: std.mem.Allocator) ![]const Group {
    var tokens = std.mem.splitScalar(u8, line, ' ');

    var state = ParserState{
        .current_command = Command.init(allocator),
        .current_group = Group.init(allocator),
        .groups = std.ArrayList(Group).init(allocator),
    };

    while (tokens.next()) |token| {
        if (std.mem.trim(u8, token, " ").len == 0) continue;

        if (TokenToFunctionMap.get(token)) |token_fn| {
            token_fn(&state, &tokens) catch |err| return err;
        } else {
            state.current_command.argv.append(token) catch |err| return err;
        }
    }

    if (state.current_command.argv.items.len > 0) {
        state.current_group.commands.append(state.current_command) catch |err| return err;
        state.groups.append(state.current_group) catch |err| return err;
    } else {
        return ParserError.InvalidCommand;
    }

    return state.groups.items;
}
