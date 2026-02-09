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
    // Done separately to the 'Configuration help' section to avoid any breaking changes
    try genConfigMetadata(alloc, writer, ast);
}

/// Used by the configuration code gen to crudely map types
pub const FieldType = enum(c_int) {
    string,
    boolean,
    option,
};

/// Used by the configuration code gen to capture configuration metadata
pub const ConfigMetadataEntry = extern struct {
    name: [*:0]const u8,
    field_type: FieldType,
    description: [*:0]const u8,
    category: [*:0]const u8,
    options: [*]const [*:0]const u8,
    options_count: usize,
};

/// Generates metadata around configuration
fn genConfigMetadata(alloc: std.mem.Allocator, writer: *std.Io.Writer, ast: std.zig.Ast) !void {
    // Types used from the
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
        \\   description: [*:0]const u8,
        \\   category: [*:0]const u8,
        \\   options: [*]const [*:0]const u8, // Pointer to null-terminated array of option strings, empty otherwise
        \\   options_count: usize,
        \\};
        \\
        \\/// Option strings for configuration fields that are enums.
        \\
    );

    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        const base = unwrapOptional(field.type);
        if (@typeInfo(base) == .@"enum") {
            try writer.writeAll("pub const ");
            const sanitised_name = comptime sanitizeFieldName(field.name);
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

    // Generates the config metadata struct for all Config fields
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        // Getting base type metadata
        const field_type = getFieldType(field.type);
        const base = unwrapOptional(field.type);
        const is_enum = @typeInfo(base) == .@"enum";

        // Find the field in the AST to get its doc comment
        const tokens = ast.tokens.items(.tag);
        const parsed = found: for (tokens, 0..) |token, i| {
            if (token != .identifier) continue;
            if (tokens[i - 1] != .doc_comment) continue;

            const name = ast.tokenSlice(@intCast(i));
            const key = if (name[0] == '@') name[2 .. name.len - 1] else name;
            if (!std.mem.eql(u8, key, field.name)) continue;

            break :found try parseDocComment(alloc, ast, @intCast(i - 1), tokens);
        } else ParsedComment{ .category = "", .description = "" };

        // Write name
        try writer.writeAll("    .{ .name = \"");
        try writer.writeAll(field.name);

        // Write type
        try writer.writeAll("\", .field_type = .");
        try writer.writeAll(@tagName(field_type));

        // Write description
        try writer.writeAll(", .description =");
        if (parsed.description.len == 0) {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeAll("\n");
            try writer.writeAll(parsed.description);
        }

        // Write category
        try writer.writeAll(", .category = \"");
        try writer.writeAll(parsed.category);
        try writer.writeAll("\"");

        // Write options
        try writer.writeAll(", .options = ");
        if (is_enum) {
            try writer.writeAll("&");
            const sanitised_name = comptime sanitizeFieldName(field.name);
            try writer.writeAll(&sanitised_name);
            try writer.writeAll("_options");
        } else {
            try writer.writeAll("&.{}");
        }

        // Write options count
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

fn getFieldType(comptime T: type) FieldType {
    const base = unwrapOptional(T);

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

fn genConfigField(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    ast: std.zig.Ast,
    comptime field: []const u8,
) !void {
    const tokens = ast.tokens.items(.tag);
    for (tokens, 0..) |token, i| {
        // We only care about identifiers that are preceded by doc comments.
        // NOTE: Ensure this holds true when adding /// @category to fields with no existing docs
        if (token != .identifier) continue;
        if (tokens[i - 1] != .doc_comment) continue;

        // Identifier may have @"" so we strip that.
        const name = ast.tokenSlice(@intCast(i));
        const key = if (name[0] == '@') name[2 .. name.len - 1] else name;
        if (!std.mem.eql(u8, key, field)) continue;

        const comment = try extractDocComments(alloc, ast, @intCast(i - 1), tokens);
        if (std.mem.eql(u8, comment, "")) {
            break;
        }
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

const ParsedComment = struct {
    category: []const u8,
    description: []const u8,
};

/// Parses doc comments pulling out category if available, with the rest of the comment
/// as a multiline string
fn parseDocComment(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    index: std.zig.Ast.TokenIndex,
    tokens: []std.zig.Token.Tag,
) !ParsedComment {
    const start_idx: usize = start_idx: for (0..index) |i| {
        const reverse_i = index - i - 1;
        const token = tokens[reverse_i];
        if (token != .doc_comment) break :start_idx reverse_i + 1;
    } else unreachable;

    var category: []const u8 = "";
    var desc_buffer: std.Io.Writer.Allocating = .init(alloc);
    defer desc_buffer.deinit();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    for (start_idx..index + 1) |i| {
        const token = tokens[i];
        if (token != .doc_comment) break;

        const raw = ast.tokenSlice(@intCast(i))[3..];
        const trimmed = std.mem.trimLeft(u8, raw, " ");
        if (std.mem.startsWith(u8, trimmed, "@category")) {
            // Parse the category line and skip processing as part of description
            category = trimmed["@category ".len..];
            continue;
        }

        try lines.append(alloc, ast.tokenSlice(@intCast(i))[3..]);
    }

    // Convert the lines to a multiline string.
    const prefix = findCommonPrefix(lines);
    for (lines.items) |line| {
        try desc_buffer.writer.writeAll("    \\\\");
        try desc_buffer.writer.writeAll(line[@min(prefix, line.len)..]);
        try desc_buffer.writer.writeAll("\n");
    }

    return .{
        .category = category,
        .description = try desc_buffer.toOwnedSlice(),
    };
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

    // Go through and build up the lines, skipping @category directives.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    for (start_idx..index + 1) |i| {
        const token = tokens[i];
        if (token != .doc_comment) break;

        const raw = ast.tokenSlice(@intCast(i))[3..];
        const trimmed = std.mem.trimLeft(u8, raw, " ");
        if (std.mem.startsWith(u8, trimmed, "@category")) continue;

        try lines.append(alloc, ast.tokenSlice(@intCast(i))[3..]);
    }

    if (lines.items.len == 0) return "";

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

fn sanitizeFieldName(comptime name: []const u8) [name.len]u8 {
    @setEvalBranchQuota(10_000);
    var result: [name.len]u8 = undefined;
    for (name, 0..) |c, i| {
        result[i] = if (c == '-') '_' else c;
    }
    return result;
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
