//! This program is used to generate the help strings from the configuration
//! file and CLI actions for Ghostty. These can then be used to generate
//! help, docs, website, etc.

const std = @import("std");
const Config = @import("config/Config.zig");
const Action = @import("cli/ghostty.zig").Action;
const KeybindAction = @import("input/Binding.zig").Action;
const help_strings = @import("help_strings");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\// THIS FILE IS AUTO GENERATED
        \\
        \\
    );

    try genConfig(alloc, writer);
    try genActions(alloc, writer);
    try genKeybindActions(alloc, writer);
    try stdout.end();
}

fn genConfig(alloc: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("config/Config.zig"), .zig);
    defer ast.deinit(alloc);

    try writer.writeAll(
        \\/// Configuration help
        \\pub const Config = struct {
        \\
        \\
    );

    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        try genConfigField(alloc, writer, ast, field.name);
    }

    try writer.writeAll("};\n");

    // Generate metadata entry struct and runtime array
    try genConfigMetadata(alloc, writer, ast);
}

/// Generates metadata around configuration
fn genConfigMetadata(_: std.mem.Allocator, writer: *std.Io.Writer, _: std.zig.Ast) !void {
    // Types used by the code gen
    try writer.writeAll(
        \\pub const FieldType = enum(c_int) {
        \\   string,
        \\   boolean,
        \\   option,
        \\};
        \\
        \\/// Configuration Metadata for rendering GUI Settings pages.
        \\pub const ConfigMetadataEntry = extern struct {
        \\   name: [*:0]const u8,
        \\   field_type: FieldType,
        \\   options: [*]const [*:0]const u8, // Pointer to null-terminated array of option strings, empty otherwise
        \\   options_count: usize,
        \\};
        \\
        \\/// Option strings for configuration fields that are enums.
        \\
    );

    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        // Generates enum options array for exposing a configs options via C api
        const base = unwrapOptional(field.type);
        if (@typeInfo(base) == .@"enum") {
            try writer.writeAll("pub const ");
            // TODO: We duplicate this... not the best
            var sanitised_name: [field.name.len]u8 = undefined;
            for (field.name, 0..) |c, i| {
                sanitised_name[i] = if (c == '-') '_' else c;
            }
            try writer.writeAll(&sanitised_name);
            try writer.writeAll("_options = [_][*:0]const u8{ ");
            try genEnumOptions(base, writer);
            try writer.writeAll("};\n");
        }
    }

    try writer.writeAll(
        \\
        \\/// Runtime array of all config metadata entries
        \\pub const config_metadata_entries = [_]ConfigMetadataEntry{
        \\
    );

    // Generates the config metadata list for all fields
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        const field_type = getFieldType(field.type);
        const base = unwrapOptional(field.type);
        const is_enum = @typeInfo(base) == .@"enum";

        try writer.writeAll("    .{ .name = \"");
        try writer.writeAll(field.name);
        try writer.writeAll("\", .field_type = .");
        try writer.writeAll(@tagName(field_type));
        try writer.writeAll(", .options = ");

        if (is_enum) {
            try writer.writeAll("&");
            // TODO: Fix the duplication
            var sanitised_name: [field.name.len]u8 = undefined;
            for (field.name, 0..) |c, i| {
                sanitised_name[i] = if (c == '-') '_' else c;
            }
            try writer.writeAll(&sanitised_name);
            try writer.writeAll("_options");
        } else {
            try writer.writeAll("&.{}");
        }

        try writer.writeAll(", .options_count = ");
        if (is_enum) {
            const enum_info = @typeInfo(base).@"enum";
            try writer.print("{}", .{enum_info.fields.len});
        } else {
            try writer.writeAll("0");
        }

        try writer.writeAll(" },\n");
    }

    try writer.writeAll("};\n");
}

fn genEnumOptions(comptime T: type, wrtier: *std.Io.Writer) !void {
    const info = @typeInfo(T).@"enum";

    inline for (info.fields) |field| {
        try wrtier.writeAll("\"");
        try wrtier.writeAll(field.name);
        try wrtier.writeAll("\", ");
    }
}

pub const FieldType = enum(c_int) {
    string,
    boolean,
    option,
};

pub const ConfigMetadataEntry = extern struct {
    name: [*:0]const u8,
    field_type: FieldType,
    options: [*]const [*:0]const u8,
    options_count: usize,
};

fn getFieldType(comptime T: type) FieldType {
    const base = unwrapOptional(T);
    // TODO:  @"cursor-style-blink": ?bool = null,
    // Probably need to be smarter about this when null actually means something....

    if (base == bool) return .boolean;

    if (@typeInfo(base) == .@"enum") return .option;

    return .string;
}

fn unwrapOptional(comptime T: type) type {
    switch (@typeInfo(T)) {
        .optional => |opt| return opt.child,
        else => return T,
    }
}

/// Generate a single metadata entry for the array
fn genConfigMetadataEntry(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    ast: std.zig.Ast,
    comptime field_name: []const u8,
) !void {
    const tokens = ast.tokens.items(.tag);
    var default_value: []const u8 = "";

    // Extract default value from AST
    for (tokens, 0..) |token, i| {
        if (token != .identifier) continue;
        if (i == 0 or tokens[i - 1] != .doc_comment) continue;

        const name = ast.tokenSlice(@intCast(i));
        const key = if (name[0] == '@') name[2 .. name.len - 1] else name;
        if (!std.mem.eql(u8, key, field_name)) continue;

        // Extract default value: find "=" and read until ","
        if (i + 1 < tokens.len and tokens[i + 1] == .colon) {
            var j = i + 2;
            while (j < tokens.len and tokens[j] != .equal) : (j += 1) {}
            if (j < tokens.len) {
                var k = j + 1;
                while (k < tokens.len and tokens[k] != .comma) : (k += 1) {}

                var default_buf: std.ArrayList(u8) = .empty;
                defer default_buf.deinit(alloc);
                for (j + 2..k) |idx| {
                    try default_buf.appendSlice(alloc, ast.tokenSlice(@intCast(idx)));
                }
                default_value = try alloc.dupe(u8, std.mem.trim(u8, default_buf.items, " \t\n\r"));
            }
        }
        break;
    }

    try writer.writeAll("    .{ .name = \"");
    try writer.writeAll(field_name);
    try writer.writeAll("\" },\n");
}

fn genConfigField(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    ast: std.zig.Ast,
    comptime field: []const u8,
) !void {
    const tokens = ast.tokens.items(.tag);
    for (tokens, 0..) |token, i| {
        // We only care about identifiers that are preceded by doc comments.
        if (token != .identifier) continue;
        if (tokens[i - 1] != .doc_comment) continue;

        // Identifier may have @"" so we strip that.
        const name = ast.tokenSlice(@intCast(i));
        const key = if (name[0] == '@') name[2 .. name.len - 1] else name;
        if (!std.mem.eql(u8, key, field)) continue;

        const comment = try extractDocComments(alloc, ast, @intCast(i - 1), tokens);
        try writer.writeAll("pub const ");
        try writer.writeAll(name);
        try writer.writeAll(": [:0]const u8 = \n");
        try writer.writeAll(comment);
        try writer.writeAll("\n");
        break;
    }
}

fn genActions(alloc: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\
        \\/// Actions help
        \\pub const Action = struct {
        \\
        \\
    );

    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action_file = comptime action_file: {
            const action = @field(Action, field.name);
            break :action_file action.file();
        };

        var ast = try std.zig.Ast.parse(alloc, @embedFile(action_file), .zig);
        defer ast.deinit(alloc);
        const tokens: []std.zig.Token.Tag = ast.tokens.items(.tag);

        for (tokens, 0..) |token, i| {
            // We're looking for a function named "run".
            if (token != .keyword_fn) continue;
            if (!std.mem.eql(u8, ast.tokenSlice(@intCast(i + 1)), "run")) continue;

            // The function must be preceded by a doc comment.
            if (tokens[i - 2] != .doc_comment) {
                std.debug.print(
                    "doc comment must be present on run function of the {s} action!",
                    .{field.name},
                );
                std.process.exit(1);
            }

            const comment = try extractDocComments(alloc, ast, @intCast(i - 2), tokens);
            try writer.writeAll("pub const @\"");
            try writer.writeAll(field.name);
            try writer.writeAll("\" = \n");
            try writer.writeAll(comment);
            try writer.writeAll("\n\n");
            break;
        }
    }

    try writer.writeAll("};\n");
}

fn genKeybindActions(alloc: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("input/Binding.zig"), .zig);
    defer ast.deinit(alloc);

    try writer.writeAll(
        \\/// keybind actions help
        \\pub const KeybindAction = struct {
        \\
        \\
    );

    inline for (@typeInfo(KeybindAction).@"union".fields) |field| {
        if (field.name[0] == '_') continue;
        try genConfigField(alloc, writer, ast, field.name);
    }

    try writer.writeAll("};\n");
}

fn extractDocComments(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    index: std.zig.Ast.TokenIndex,
    tokens: []std.zig.Token.Tag,
) ![]const u8 {
    // Find the first index of the doc comments. The doc comments are
    // always stacked on top of each other so we can just go backwards.
    const start_idx: usize = start_idx: for (0..index) |i| {
        const reverse_i = index - i - 1;
        const token = tokens[reverse_i];
        if (token != .doc_comment) break :start_idx reverse_i + 1;
    } else unreachable;

    // Go through and build up the lines.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    for (start_idx..index + 1) |i| {
        const token = tokens[i];
        if (token != .doc_comment) break;
        try lines.append(alloc, ast.tokenSlice(@intCast(i))[3..]);
    }

    // Convert the lines to a multiline string.
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    const prefix = findCommonPrefix(lines);
    for (lines.items) |line| {
        try buffer.writer.writeAll("    \\\\");
        try buffer.writer.writeAll(line[@min(prefix, line.len)..]);
        try buffer.writer.writeAll("\n");
    }
    try buffer.writer.writeAll(";\n");

    return buffer.toOwnedSlice();
}

fn findCommonPrefix(lines: std.ArrayList([]const u8)) usize {
    var m: usize = std.math.maxInt(usize);
    for (lines.items) |line| {
        var n: usize = std.math.maxInt(usize);
        for (line, 0..) |c, i| {
            if (c != ' ') {
                n = i;
                break;
            }
        }
        m = @min(m, n);
    }
    return m;
}
