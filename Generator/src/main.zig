const std = @import("std");

// Zig 负责读取构建输入、调用 Rust crypto CLI，并以原子替换方式输出 Blob。

const max_manifest_size = 64 * 1024 * 1024;
const max_blob_size = 64 * 1024 * 1024;
const max_string_size = 1024 * 1024;

const ManifestString = struct {
    text: []const u8,
    source: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

const Manifest = struct {
    version: u32,
    app_namespace: []const u8,
    strings: []ManifestString,
};

const Arguments = struct {
    manifest_path: []const u8 = "-",
    output_path: []const u8 = "-",
    crypto_cli_path: []const u8 = "zdstring-crypto",
    profile: []const u8 = "debug",
    nonce_mode: ?[]const u8 = null,
    build_salt_b64: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "scan")) {
        try run_scan(allocator, init.io, argv[2..]);
        return;
    }
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "merge-manifests")) {
        try run_merge_manifests(allocator, init.io, argv[2..]);
        return;
    }
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "catalog-manifest")) {
        try run_catalog_manifest(allocator, init.io, argv[2..]);
        return;
    }
    const arguments = try parse_arguments(argv);
    const manifest = try read_manifest(allocator, init.io, arguments.manifest_path);
    try validate_manifest(allocator, manifest);
    const blob = try run_crypto_cli(allocator, init.io, arguments, manifest);
    if (blob.len == 0 or blob.len > max_blob_size) return error.InvalidBlobOutput;
    try write_output_atomically(allocator, init.io, arguments.output_path, blob);
}

const ScanArguments = struct {
    input_path: []const u8 = "-",
    output_path: []const u8 = "-",
    manifest_path: []const u8 = "-",
    language: []const u8 = "swift",
    namespace: []const u8 = "",
};

const ScanEntry = struct {
    text: []const u8,
    source: []const u8,
    id: ?[]const u8 = null,
};

const CatalogArguments = struct {
    input_path: []const u8 = "-",
    output_path: []const u8 = "-",
    namespace: []const u8 = "",
};

fn parse_catalog_arguments(args: []const []const u8) !CatalogArguments {
    var result = CatalogArguments{};
    var index: usize = 0;
    while (index < args.len) {
        if (index + 1 >= args.len) return error.MissingArgumentValue;
        const option = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, option, "--input")) {
            result.input_path = value;
        } else if (std.mem.eql(u8, option, "--output")) {
            result.output_path = value;
        } else if (std.mem.eql(u8, option, "--namespace")) {
            result.namespace = value;
        } else {
            return error.UnknownArgument;
        }
        index += 2;
    }
    if (result.namespace.len == 0 or result.namespace.len > 256) return error.InvalidCatalogArguments;
    return result;
}

fn run_catalog_manifest(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    // 目录映射只在构建机上读取明文，输出的访问器和 Blob 均只依赖稳定 ID。
    const arguments = try parse_catalog_arguments(args);
    const source = try read_manifest(allocator, io, arguments.input_path);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCatalogMapping,
    };
    var entries: std.ArrayList(ScanEntry) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |item| {
        const text = switch (item.value_ptr.*) {
            .string => |value| value,
            else => return error.InvalidCatalogMapping,
        };
        if (text.len == 0 or text.len > max_string_size) return error.InvalidCatalogMapping;
        const id = try std.fmt.allocPrint(allocator, "0x{x:0>16}", .{catalog_string_id(text)});
        try entries.append(allocator, .{
            .text = text,
            .source = arguments.input_path,
            .id = id,
        });
    }
    if (entries.items.len == 0) return error.InvalidCatalogMapping;
    const manifest = try build_manifest_json(allocator, arguments.namespace, entries.items);
    try write_output_atomically(allocator, io, arguments.output_path, manifest);
}

fn parse_scan_arguments(args: []const []const u8) !ScanArguments {
    var result = ScanArguments{};
    var index: usize = 0;
    while (index < args.len) {
        if (index + 1 >= args.len) return error.MissingArgumentValue;
        const option = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, option, "--input")) {
            result.input_path = value;
        } else if (std.mem.eql(u8, option, "--output")) {
            result.output_path = value;
        } else if (std.mem.eql(u8, option, "--manifest")) {
            result.manifest_path = value;
        } else if (std.mem.eql(u8, option, "--language")) {
            result.language = value;
        } else if (std.mem.eql(u8, option, "--namespace")) {
            result.namespace = value;
        } else {
            return error.UnknownArgument;
        }
        index += 2;
    }
    if (result.namespace.len == 0 or
        !(std.mem.eql(u8, result.language, "swift") or std.mem.eql(u8, result.language, "objc")))
    {
        return error.InvalidScanArguments;
    }
    return result;
}

fn run_scan(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    // 扫描阶段只生成编译器可见的 ID 调用和构建期 Manifest，不在源码旁保存明文副本。
    const arguments = try parse_scan_arguments(args);
    const source = try read_manifest(allocator, io, arguments.input_path);
    var rewritten: std.ArrayList(u8) = .empty;
    var entries: std.ArrayList(ScanEntry) = .empty;
    var cursor: usize = 0;
    while (try find_zd_string(source, cursor, arguments.language)) |token_start| {
        const parsed = try parse_literal(source, token_start, arguments.language, allocator);
        try rewritten.appendSlice(allocator, source[cursor..token_start]);
        const id = string_id(arguments.namespace, parsed.text);
        const replacement = try build_decode_expression(allocator, id, arguments.language);
        try rewritten.appendSlice(allocator, replacement);
        try entries.append(allocator, .{ .text = parsed.text, .source = arguments.input_path });
        cursor = parsed.end;
    }
    try rewritten.appendSlice(allocator, source[cursor..]);
    const sanitized = try strip_comments(allocator, rewritten.items, arguments.language);
    try write_output_atomically(allocator, io, arguments.output_path, sanitized);
    const manifest = try build_manifest_json(allocator, arguments.namespace, entries.items);
    try write_output_atomically(allocator, io, arguments.manifest_path, manifest);
}

fn run_merge_manifests(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    // 多个编译单元各自产生 Manifest，合并时强制校验 namespace 防止 ID 域混用。
    var output_path: ?[]const u8 = null;
    var inputs: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) {
        if (index + 1 >= args.len) return error.MissingArgumentValue;
        const option = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, option, "--output")) {
            output_path = value;
        } else if (std.mem.eql(u8, option, "--input")) {
            try inputs.append(allocator, value);
        } else {
            return error.UnknownArgument;
        }
        index += 2;
    }
    const destination = output_path orelse return error.InvalidMergeArguments;
    if (inputs.items.len == 0) return error.InvalidMergeArguments;

    var namespace: ?[]const u8 = null;
    var entries: std.ArrayList(ScanEntry) = .empty;
    for (inputs.items) |input_path| {
        const input = try read_manifest(allocator, io, input_path);
        var parsed = try std.json.parseFromSlice(Manifest, allocator, input, .{});
        defer parsed.deinit();
        try validate_manifest(allocator, input);
        if (namespace) |existing| {
            if (!std.mem.eql(u8, existing, parsed.value.app_namespace)) return error.NamespaceMismatch;
        } else {
            namespace = try allocator.dupe(u8, parsed.value.app_namespace);
        }
        for (parsed.value.strings) |entry| {
            try entries.append(allocator, .{
                .text = try allocator.dupe(u8, entry.text),
                .source = try allocator.dupe(u8, entry.source orelse input_path),
                .id = if (entry.id) |id| try allocator.dupe(u8, id) else null,
            });
        }
    }
    const merged = try build_manifest_json(allocator, namespace orelse return error.InvalidMergeArguments, entries.items);
    try write_output_atomically(allocator, io, destination, merged);
}

const ParsedLiteral = struct { text: []const u8, end: usize };

fn find_zd_string(source: []const u8, start: usize, language: []const u8) !?usize {
    // 按语言跳过完整词法单元，避免 raw/multiline 文本和嵌套注释中的示例被改写。
    const swift = std.mem.eql(u8, language, "swift");
    var index = start;
    while (index < source.len) {
        if (try skip_noncode(source, index, swift, 0)) |end| {
            index = end;
        } else if (is_protected_string(source, index)) {
            return index;
        } else {
            index += 1;
        }
    }
    return null;
}

fn is_protected_string(source: []const u8, index: usize) bool {
    return std.mem.startsWith(u8, source[index..], "ZDString(") and
        (index == 0 or !is_identifier_byte(source[index - 1]));
}

fn skip_noncode(source: []const u8, start: usize, swift: bool, depth: usize) anyerror!?usize {
    // Swift 块注释允许嵌套，ObjC 则在第一个结束标记处关闭。
    if (std.mem.startsWith(u8, source[start..], "//")) {
        var index = start + 2;
        while (index < source.len) {
            if (!swift and source[index] == '\\') {
                if (index + 1 < source.len and source[index + 1] == '\n') {
                    index += 2;
                    continue;
                }
                if (index + 2 < source.len and source[index + 1] == '\r' and source[index + 2] == '\n') {
                    index += 3;
                    continue;
                }
            }
            if (source[index] == '\n' or source[index] == '\r') break;
            index += 1;
        }
        return index;
    }
    if (std.mem.startsWith(u8, source[start..], "/*")) {
        var index = start + 2;
        var nesting: usize = 1;
        while (index < source.len) {
            if (std.mem.startsWith(u8, source[index..], "*/")) {
                nesting -= 1;
                index += 2;
                if (nesting == 0) return index;
            } else if (swift and std.mem.startsWith(u8, source[index..], "/*")) {
                nesting += 1;
                index += 2;
            } else {
                index += 1;
            }
        }
        return error.UnsupportedLiteral;
    }
    if (!swift) {
        if (try skip_cpp_raw_string(source, start)) |end| return end;
    } else {
        if (try skip_swift_regex(source, start)) |end| return end;
        if (is_ambiguous_bare_regex(source, start)) return error.UnsupportedLiteral;
    }
    return skip_source_string(source, start, swift, depth);
}

fn skip_cpp_raw_string(source: []const u8, start: usize) !?usize {
    // ObjC++ 允许多个编码前缀和最多 16 字节定界符，定界符内部的引号不结束字面量。
    const prefixes = [_][]const u8{ "R\"", "u8R\"", "uR\"", "UR\"", "LR\"" };
    var prefix: ?[]const u8 = null;
    for (prefixes) |candidate| {
        if (std.mem.startsWith(u8, source[start..], candidate)) {
            prefix = candidate;
            break;
        }
    }
    const matched = prefix orelse return null;
    const delimiter_start = start + matched.len;
    var opening = delimiter_start;
    while (opening < source.len and source[opening] != '(') : (opening += 1) {
        if (opening - delimiter_start > 16 or source[opening] == '\\' or source[opening] == ')' or
            source[opening] == ' ' or source[opening] == '\t' or source[opening] == '\r' or source[opening] == '\n')
        {
            return null;
        }
    }
    if (opening >= source.len) return error.UnsupportedLiteral;
    const delimiter = source[delimiter_start..opening];
    var index = opening + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] != ')') continue;
        const closing = index + 1;
        if (closing + delimiter.len < source.len and
            std.mem.eql(u8, source[closing .. closing + delimiter.len], delimiter) and
            source[closing + delimiter.len] == '"')
        {
            return closing + delimiter.len + 1;
        }
    }
    return error.UnsupportedLiteral;
}

fn skip_swift_regex(source: []const u8, start: usize) !?usize {
    // Swift 正则使用与 raw 字符串相同的 # 定界符；只在字符类外识别结束斜杠。
    var slash = start;
    while (slash < source.len and source[slash] == '#') : (slash += 1) {}
    if (slash == start or slash >= source.len or source[slash] != '/') return null;
    const hashes = slash - start;
    var index = slash + 1;
    var in_character_class = false;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            if (index < source.len and source[index] == '\r') index += 1;
            continue;
        }
        if (source[index] == '[') {
            in_character_class = true;
            continue;
        }
        if (source[index] == ']') {
            in_character_class = false;
            continue;
        }
        if (!in_character_class and source[index] == '/' and matches_hashes(source, index + 1, hashes)) {
            return index + 1 + hashes;
        }
    }
    return error.UnsupportedLiteral;
}

fn is_ambiguous_bare_regex(source: []const u8, start: usize) bool {
    // 无 # 定界符的正则与除法无法可靠区分；仅在其中出现保护调用时拒绝，避免静默改写。
    if (source[start] != '/' or start + 1 >= source.len or source[start + 1] == '/' or source[start + 1] == '*') return false;
    var index = start + 1;
    var escaped = false;
    while (index < source.len and source[index] != '\n' and source[index] != '\r') : (index += 1) {
        if (escaped) {
            escaped = false;
        } else if (source[index] == '\\') {
            escaped = true;
        } else if (source[index] == '/' and std.mem.indexOf(u8, source[start..index], "ZDString(") != null) {
            return true;
        }
    }
    return false;
}

fn skip_source_string(source: []const u8, start: usize, swift: bool, depth: usize) anyerror!?usize {
    // raw 字符串的引号和转义必须匹配相同数量的 #；三引号内的普通引号不结束字符串。
    var quote_start = start;
    if (swift) {
        while (quote_start < source.len and source[quote_start] == '#') : (quote_start += 1) {}
    }
    if (quote_start >= source.len) return null;
    const quote = source[quote_start];
    if (quote != '"' and !(quote == '\'' and !swift)) return null;
    if (depth >= 128) return error.UnsupportedLiteral;
    const hashes = quote_start - start;
    const quotes: usize = if (swift and std.mem.startsWith(u8, source[quote_start..], "\"\"\"")) 3 else 1;
    var index = quote_start + quotes;
    while (index < source.len) {
        if (source[index] == quote) {
            var end = index;
            while (end < source.len and end - index < quotes and source[end] == quote) : (end += 1) {}
            if (end - index == quotes and matches_hashes(source, end, hashes)) return end + hashes;
        }
        if (source[index] == '\\' and matches_hashes(source, index + 1, hashes)) {
            index += 1 + hashes;
            if (index >= source.len) return error.UnsupportedLiteral;
            if (swift and source[index] == '(') {
                index = try skip_interpolation(source, index + 1, depth + 1);
            } else {
                index += 1;
            }
        } else {
            index += 1;
        }
    }
    return error.UnsupportedLiteral;
}

fn matches_hashes(source: []const u8, start: usize, count: usize) bool {
    if (count > source.len - start) return false;
    for (source[start .. start + count]) |byte| {
        if (byte != '#') return false;
    }
    return true;
}

fn skip_interpolation(source: []const u8, start: usize, depth: usize) anyerror!usize {
    // 插值表达式可能包含字符串和括号；其中的保护调用暂不支持，必须显式失败而非遗漏明文。
    var nesting: usize = 1;
    var index = start;
    while (index < source.len) {
        if (try skip_noncode(source, index, true, depth)) |end| {
            index = end;
            continue;
        }
        if (is_protected_string(source, index)) return error.UnsupportedLiteral;
        if (source[index] == '(') nesting += 1;
        if (source[index] == ')') {
            nesting -= 1;
            if (nesting == 0) return index + 1;
        }
        index += 1;
    }
    return error.UnsupportedLiteral;
}

fn is_identifier_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

fn parse_literal(source: []const u8, token_start: usize, language: []const u8, allocator: std.mem.Allocator) !ParsedLiteral {
    // 首期刻意仅接受单行单字面量；复杂表达式失败后中断构建，避免把明文留给编译器。
    var index = token_start + 9;
    if (std.mem.eql(u8, language, "objc") and index < source.len and source[index] == '@') index += 1;
    if (index >= source.len or source[index] != '"') return error.UnsupportedLiteral;
    index += 1;
    var value: std.ArrayList(u8) = .empty;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (byte == '"') {
            if (index + 1 >= source.len or source[index + 1] != ')') return error.UnsupportedLiteral;
            return .{ .text = try value.toOwnedSlice(allocator), .end = index + 2 };
        }
        if (byte == '\n' or byte == '\r') return error.UnsupportedLiteral;
        if (byte != '\\') {
            try value.append(allocator, byte);
            continue;
        }
        index += 1;
        if (index >= source.len) return error.UnsupportedLiteral;
        switch (source[index]) {
            'n' => try value.append(allocator, '\n'),
            'r' => try value.append(allocator, '\r'),
            't' => try value.append(allocator, '\t'),
            '0' => {
                // ObjC 的连续八进制数字不是 Swift 的 NUL 转义，未实现时拒绝以免静默改值。
                if (std.mem.eql(u8, language, "objc") and index + 1 < source.len and
                    source[index + 1] >= '0' and source[index + 1] <= '7') return error.UnsupportedLiteral;
                try value.append(allocator, 0);
            },
            '\\' => try value.append(allocator, '\\'),
            '"' => try value.append(allocator, '"'),
            '(' => return error.UnsupportedLiteral,
            else => return error.UnsupportedLiteral,
        }
    }
    return error.UnsupportedLiteral;
}

fn build_decode_expression(allocator: std.mem.Allocator, id: u64, language: []const u8) ![]u8 {
    var id_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &id_bytes, id, .little);
    var output: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, language, "swift")) {
        try output.appendSlice(allocator, "ZDStringDecodeBytes(["[0..]);
    } else {
        try output.appendSlice(allocator, "ZDStringDecodeBytes((const unsigned char[]){"[0..]);
    }
    for (id_bytes, 0..) |byte, index| {
        if (index != 0) try output.appendSlice(allocator, ", "[0..]);
        const encoded = try std.fmt.allocPrint(allocator, "0x{x:0>2}", .{byte});
        try output.appendSlice(allocator, encoded);
    }
    if (std.mem.eql(u8, language, "swift")) {
        try output.appendSlice(allocator, "])"[0..]);
    } else {
        try output.appendSlice(allocator, "}, 8)"[0..]);
    }
    return try output.toOwnedSlice(allocator);
}

fn strip_comments(allocator: std.mem.Allocator, source: []const u8, language: []const u8) ![]u8 {
    const swift = std.mem.eql(u8, language, "swift");
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < source.len) {
        if (std.mem.startsWith(u8, source[index..], "//")) {
            const end = (try skip_noncode(source, index, swift, 0)) orelse return error.UnsupportedLiteral;
            for (source[index..end]) |byte| {
                if (byte == '\n' or byte == '\r') try output.append(allocator, byte);
            }
            index = end;
            continue;
        }
        if (std.mem.startsWith(u8, source[index..], "/*")) {
            const end = (try skip_noncode(source, index, swift, 0)) orelse return error.UnsupportedLiteral;
            for (source[index..end]) |byte| {
                if (byte == '\n' or byte == '\r') try output.append(allocator, byte);
            }
            index = end;
            continue;
        }
        if (try skip_noncode(source, index, swift, 0)) |end| {
            try output.appendSlice(allocator, source[index..end]);
            index = end;
        } else {
            try output.append(allocator, source[index]);
            index += 1;
        }
    }
    return try output.toOwnedSlice(allocator);
}

fn string_id(namespace: []const u8, bytes: []const u8) u64 {
    // 与 Rust crypto-core 完全复用 ID domain、长度编码和 little-endian 截断规则。
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("LMStringProtection/id/v1");
    var length_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &length_bytes, @intCast(namespace.len), .little);
    hash.update(&length_bytes);
    hash.update(namespace);
    hash.update(bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn catalog_string_id(bytes: []const u8) u64 {
    // 与 Rust crypto-core 复用独立目录 ID 域，避免 App namespace 影响查询 ID。
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("LMStringProtection/catalog-id/v1");
    var digest: [32]u8 = undefined;
    hash.update(bytes);
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn append_json_string(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try output.append(allocator, '"');
    for (value) |byte| switch (byte) {
        '"' => try output.appendSlice(allocator, "\\\""),
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '\n' => try output.appendSlice(allocator, "\\n"),
        '\r' => try output.appendSlice(allocator, "\\r"),
        '\t' => try output.appendSlice(allocator, "\\t"),
        else => if (byte < 0x20) {
            const escaped = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{byte});
            try output.appendSlice(allocator, escaped);
        } else try output.append(allocator, byte),
    };
    try output.append(allocator, '"');
}

fn build_manifest_json(allocator: std.mem.Allocator, namespace: []const u8, entries: []const ScanEntry) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(allocator, "{\"version\":1,\"app_namespace\":");
    try append_json_string(&output, allocator, namespace);
    try output.appendSlice(allocator, ",\"strings\":[");
    for (entries, 0..) |entry, index| {
        if (index != 0) try output.append(allocator, ',');
        try output.appendSlice(allocator, "{\"text\":");
        try append_json_string(&output, allocator, entry.text);
        try output.appendSlice(allocator, ",\"source\":");
        try append_json_string(&output, allocator, entry.source);
        if (entry.id) |id| {
            try output.appendSlice(allocator, ",\"id\":");
            try append_json_string(&output, allocator, id);
        }
        try output.append(allocator, '}');
    }
    try output.appendSlice(allocator, "]}");
    return output.toOwnedSlice(allocator);
}

fn parse_arguments(args: []const []const u8) !Arguments {
    var result = Arguments{};
    var index: usize = 1;
    while (index < args.len) {
        const option = args[index];
        if (index + 1 >= args.len) return error.MissingArgumentValue;
        if (std.mem.eql(u8, option, "--manifest")) {
            result.manifest_path = args[index + 1];
        } else if (std.mem.eql(u8, option, "--output")) {
            result.output_path = args[index + 1];
        } else if (std.mem.eql(u8, option, "--crypto-cli")) {
            result.crypto_cli_path = args[index + 1];
        } else if (std.mem.eql(u8, option, "--profile")) {
            result.profile = args[index + 1];
        } else if (std.mem.eql(u8, option, "--nonce-mode")) {
            result.nonce_mode = args[index + 1];
        } else if (std.mem.eql(u8, option, "--build-salt-b64")) {
            result.build_salt_b64 = args[index + 1];
        } else {
            return error.UnknownArgument;
        }
        index += 2;
    }
    return result;
}

fn read_manifest(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var output: std.ArrayList(u8) = .empty;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const read_count = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
            if (read_count == 0) break;
            if (output.items.len + read_count > max_manifest_size) return error.ManifestTooLarge;
            try output.appendSlice(allocator, buffer[0..read_count]);
        }
        return try output.toOwnedSlice(allocator);
    }
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_manifest_size));
}

fn validate_manifest(allocator: std.mem.Allocator, bytes: []const u8) !void {
    // Zig 先验证 Manifest schema，Rust CLI 再负责最终解析、ID 和加密。
    var parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.app_namespace.len == 0 or parsed.value.app_namespace.len > 256) {
        return error.InvalidManifest;
    }
    for (parsed.value.strings) |entry| {
        if (entry.text.len > max_string_size) return error.StringTooLarge;
    }
}

fn run_crypto_cli(allocator: std.mem.Allocator, io: std.Io, arguments: Arguments, manifest: []const u8) ![]u8 {
    var child_arguments: [12][]const u8 = undefined;
    var count: usize = 0;
    child_arguments[count] = arguments.crypto_cli_path;
    count += 1;
    child_arguments[count] = "encrypt";
    count += 1;
    child_arguments[count] = "--manifest";
    count += 1;
    child_arguments[count] = "-";
    count += 1;
    child_arguments[count] = "--output";
    count += 1;
    child_arguments[count] = "-";
    count += 1;
    child_arguments[count] = "--profile";
    count += 1;
    child_arguments[count] = arguments.profile;
    count += 1;
    if (arguments.nonce_mode) |mode| {
        child_arguments[count] = "--nonce-mode";
        count += 1;
        child_arguments[count] = mode;
        count += 1;
    }
    if (arguments.build_salt_b64) |salt| {
        child_arguments[count] = "--build-salt-b64";
        count += 1;
        child_arguments[count] = salt;
        count += 1;
    }
    var child = try std.process.spawn(io, .{
        .argv = child_arguments[0..count],
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var input_buffer: [4096]u8 = undefined;
    var input_writer = child.stdin.?.writer(io, &input_buffer);
    try input_writer.interface.writeAll(manifest);
    try input_writer.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    var output_buffer: [4096]u8 = undefined;
    var output_reader = child.stdout.?.reader(io, &output_buffer);
    const output = try output_reader.interface.allocRemaining(allocator, .limited(max_blob_size));
    child.stdout.?.close(io);
    child.stdout = null;
    const termination = try child.wait(io);
    switch (termination) {
        .exited => |code| if (code != 0) return error.CryptoCliFailed,
        else => return error.CryptoCliFailed,
    }
    return output;
}

fn write_output_atomically(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, path, "-")) {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        return;
    }
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.c.getpid() });
    defer allocator.free(temporary);
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    var file = try std.Io.Dir.cwd().createFile(io, temporary, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.sync(io);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

test "argument parser accepts stdin and explicit crypto cli" {
    _ = Arguments{ .manifest_path = "-", .output_path = "out", .crypto_cli_path = "crypto" };
}

test "scanner rewrites only supported Swift literals" {
    const source = "let value = ZDString(\"hello\\nworld\") // ZDString(\"ignored\")";
    const start = try find_zd_string(source, 0, "swift") orelse return error.TestUnexpectedResult;
    const literal = try parse_literal(source, start, "swift", std.testing.allocator);
    defer std.testing.allocator.free(literal.text);
    try std.testing.expectEqualStrings("hello\nworld", literal.text);
    try std.testing.expectEqual(source.len - " // ZDString(\"ignored\")".len, literal.end);
    try std.testing.expectEqual(@as(u64, 0x212179d7f8f84a82), string_id("com.example.test", "https://api.example.com/v1/user"));
}

test "scanner supports Objective-C literals" {
    const source = "NSString *value = ZDString(@\"hello\");";
    const start = try find_zd_string(source, 0, "objc") orelse return error.TestUnexpectedResult;
    const literal = try parse_literal(source, start, "objc", std.testing.allocator);
    defer std.testing.allocator.free(literal.text);
    try std.testing.expectEqualStrings("hello", literal.text);
}
