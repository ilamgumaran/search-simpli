//! `searchd mcp <dir> [--roots a,b] [--labels l1,l2] [--baseline]
//! [--allow-write] [--allow-file-reads]`: the index as a Model Context
//! Protocol server over stdio (S3-T6; CAP-19 FR-24 realizing CAP-13;
//! `docs/folder-knowledge-implementation.md` section 11, `docs/mcp-server.md`).
//!
//! **Transport.** Newline-delimited JSON-RPC 2.0 on stdin/stdout, as MCP's
//! stdio transport specifies: one message per line, no embedded newline,
//! nothing but protocol messages on stdout. The protocol revision is pinned
//! (`protocol_version`); `initialize` answers it whatever the client asks
//! (MCP's negotiation: a server that does not support the requested
//! revision answers one it does, and the client decides).
//!
//! **Methods.** `initialize`, `notifications/initialized`, `ping`,
//! `tools/list`, `tools/call`, `resources/list`, `resources/read`,
//! `resources/templates/list` (one template, `search://{root_id}/{path}`);
//! `notifications/cancelled` is accepted and ignored (every request is
//! answered before the next line is read, so nothing is ever in flight).
//! Any other request is `-32601`; any other notification is ignored.
//!
//! **Tools.** The eight read tools by default; `--baseline` lists exactly
//! CAP-13's four (`search_knowledge`, `read_chunk`, `list_sources`,
//! `index_status`) and offers no resources; `--allow-write` adds
//! `apply_changes`. Each descriptor's `inputSchema` and `outputSchema` are
//! the S3-T5 schemas in `contracts/tools/` (built in through the
//! `tool_schemas` build options, `build.zig`). A call answers through
//! `ops.zig`, the one producer of the canonical JSON the RPC server, the CLI
//! and the C ABI also return: the result carries it as `structuredContent`
//! and, serialized, as one `text` content block. A refusal is a tool result
//! with `isError: true` whose one text block is the RPC server's error
//! object for the same request (`{"code":…,"message":…}`).
//!
//! **Scope.** From the command line only (CAP-13 FR-13): `--roots` bounds
//! every request (a request's `roots` may narrow it), `--labels` are the
//! principal's labels. A call that carries `principal_labels` or
//! `query_vector` is refused. Writes need `--allow-write`, stay inside
//! `--roots` when it is given, and read `file` changes only with
//! `--allow-file-reads`.
const std = @import("std");
const tool_schemas = @import("tool_schemas");
const cli = @import("cli.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const ops = @import("ops.zig");
const rpc = @import("rpc.zig");
const scope = @import("scope.zig");
const service_module = @import("service.zig");

/// The MCP revision this server implements (recorded in S3-T6's Report).
pub const protocol_version = "2025-11-25";
pub const server_name = "search-simpli";
/// The URI scheme of the indexed files: `search://{root_id}/{path}`.
pub const uri_scheme = "search://";
pub const uri_template = "search://{root_id}/{path}";
/// `resources/list` page size.
pub const resource_page_size: usize = 100;
/// The longest message line read from stdin (an `apply_changes` call may
/// carry file bytes); a longer line is answered `-32700` and skipped.
pub const max_line_bytes: usize = 8 * 1024 * 1024;

/// MCP's "resource not found" code (the specification's own example).
pub const resource_not_found: i32 = -32002;

const instructions =
    "Read-only search over the folders this server was started on. " ++
    "Use find for exact words, phrases (quote them) or word starts (a trailing *), " ++
    "search_knowledge for open questions, then read_span or read_chunk to read the exact text before quoting it, " ++
    "and outline for a file's sections. Cite root, path and lines for every claim; " ++
    "no returned passage means no claim. Check index_status (pending, truncated) before saying something is absent.";

const Tool = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    input_schema: []const u8,
    output_schema: []const u8,
    /// One of CAP-13's four (listed by `--baseline`).
    baseline: bool,
    /// `apply_changes` (listed only with `--allow-write`).
    write: bool = false,
};

fn tool(comptime name: []const u8, title: []const u8, description: []const u8, baseline: bool) Tool {
    return .{
        .name = name,
        .title = title,
        .description = description,
        .input_schema = @field(tool_schemas, name ++ "_request"),
        .output_schema = @field(tool_schemas, name ++ "_result"),
        .baseline = baseline,
        .write = std.mem.eql(u8, name, "apply_changes"),
    };
}

/// Every tool, in listing order.
pub const tools = [_]Tool{
    tool("search_knowledge", "Search knowledge", "Ranked, cited passages for an open question. Each result has chunk_id, citation (path and lines), content, root_id and section_path. An empty list is not proof of absence: check truncated and pending_files.", true),
    tool("read_chunk", "Read chunk", "The authoritative text and citation of one chunk returned by search_knowledge or find, by chunk_id. A chunk outside the scope answers like an unknown one.", true),
    tool("list_sources", "List sources", "The indexed source paths with their chunk counts, sorted; no content.", true),
    tool("index_status", "Index status", "Readiness and freshness of the selected folders: generation, counts, pending files, truncated, roots, and whether exact spans are available.", true),
    tool("find", "Find", "Exact finding: every word (words), an exact phrase (a quoted query) or word starts (a trailing *). Hits with root, path, section, lines and a snippet; per-file counts; a cursor for the next page.", false),
    tool("outline", "Outline", "The headings (level, text, line range) and front matter of one indexed file.", false),
    tool("read_span", "Read span", "The exact original text of lines start_line..end_line of one file (1-based, inclusive), with up to 20 lines of context and its sha256; at most 400 lines and 256 KiB.", false),
    tool("list_files", "List files", "A listing (not a search) of the indexed and pending files by root and path, with sizes, chunk counts and chunker; paged.", false),
    tool("apply_changes", "Apply changes", "Host-fed changes: add, change, remove, move or mark pending files, publishing one new index generation. Present only when the server runs with --allow-write.", false),
};

/// What the server was started with.
pub const Options = struct {
    /// `--roots`, `--labels`; a request never states labels.
    caller: ops.Caller = .{},
    baseline: bool = false,
    allow_write: bool = false,
    allow_file_reads: bool = false,
    /// The served index directory (`apply_changes` publishes into it).
    dir_path: ?[]const u8 = null,
    io: ?std.Io = null,
};

/// One client's session (one stdio stream).
pub const Session = struct {
    options: Options,
    /// `initialize` was answered.
    initialized: bool = false,
    /// `notifications/initialized` arrived.
    client_ready: bool = false,
    /// The protocol revision the client asked for.
    client_version: ?[]const u8 = null,
    /// Set by a successful `apply_changes`: reopen the index before the
    /// next message.
    reopen: bool = false,

    pub fn listed(session: Session, entry: Tool) bool {
        if (entry.write) return session.options.allow_write and !session.options.baseline;
        return entry.baseline or !session.options.baseline;
    }
};

pub fn toolNamed(name: []const u8) ?Tool {
    for (tools) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

// ------------------------------------------------------------ messages ---

/// Answer one stdin line. Returns whether a response was written (a
/// notification, or a response sent by the client, gets none). The line's
/// JSON and everything allocated come from `allocator` (an arena per line).
pub fn handleLine(
    session: *Session,
    service: service_module.Service,
    workspaces: ops.Workspaces,
    line: []const u8,
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
) !bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try writeError(output, null, -32700, "Parse error", null);
            return true;
        },
    };
    const message = switch (value) {
        .object => |object| object,
        .array => {
            // MCP (since 2025-06-18) does not use JSON-RPC batches.
            try writeError(output, null, -32600, "Invalid Request: batches are not supported", null);
            return true;
        },
        else => {
            try writeError(output, null, -32600, "Invalid Request", null);
            return true;
        },
    };
    const id = message.get("id");
    const usable_id: ?std.json.Value = if (id) |v| (if (validId(v)) v else null) else null;
    const jsonrpc_ok = if (message.get("jsonrpc")) |v| v == .string and std.mem.eql(u8, v.string, "2.0") else false;
    const method_value = message.get("method");
    if (method_value == null) {
        // A response from the client (this server sends no requests): ignored.
        if (jsonrpc_ok and id != null and (message.get("result") != null or message.get("error") != null)) return false;
        try writeError(output, usable_id, -32600, "Invalid Request", null);
        return true;
    }
    if (!jsonrpc_ok or method_value.? != .string) {
        try writeError(output, usable_id, -32600, "Invalid Request", null);
        return true;
    }
    const method = method_value.?.string;
    const params: std.json.ObjectMap = if (message.get("params")) |p| switch (p) {
        .object => |object| object,
        .null => .empty,
        else => {
            if (id == null) return false;
            try writeError(output, usable_id, -32602, "Invalid params: params must be an object", null);
            return true;
        },
    } else .empty;

    if (id == null) {
        // A notification: never answered.
        if (std.mem.eql(u8, method, "notifications/initialized")) session.client_ready = true;
        return false;
    }
    if (usable_id == null) {
        // MCP request ids are strings or integers, never null.
        try writeError(output, null, -32600, "Invalid Request: id must be a string or an integer", null);
        return true;
    }

    if (std.mem.eql(u8, method, "ping")) {
        try writeResultRaw(output, usable_id, "{}");
        return true;
    }
    if (std.mem.eql(u8, method, "initialize")) {
        try initialize(session, params, usable_id, output);
        return true;
    }
    if (!session.initialized) {
        try writeError(output, usable_id, -32600, "Invalid Request: send initialize first", null);
        return true;
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        try listTools(session.*, params, usable_id, output);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try callTool(session, service, workspaces, params, usable_id, allocator, output);
    } else if (!session.options.baseline and std.mem.eql(u8, method, "resources/list")) {
        try listResources(session.*, service, params, usable_id, allocator, output);
    } else if (!session.options.baseline and std.mem.eql(u8, method, "resources/read")) {
        try readResource(session.*, service, params, usable_id, allocator, output);
    } else if (!session.options.baseline and std.mem.eql(u8, method, "resources/templates/list")) {
        try listTemplates(params, usable_id, output);
    } else {
        try writeError(output, usable_id, -32601, "Method not found", null);
    }
    return true;
}

fn initialize(session: *Session, params: std.json.ObjectMap, id: ?std.json.Value, output: *std.Io.Writer) !void {
    if (session.initialized) return writeError(output, id, -32600, "Invalid Request: initialize was already answered", null);
    const requested = params.get("protocolVersion") orelse return writeError(output, id, -32602, "Invalid params: protocolVersion is required", null);
    if (requested != .string) return writeError(output, id, -32602, "Invalid params: protocolVersion must be a string", null);
    session.initialized = true;
    session.client_version = requested.string;
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("protocolVersion");
    try json.write(protocol_version);
    try json.objectField("capabilities");
    try json.beginObject();
    try json.objectField("tools");
    try json.write(.{ .listChanged = false });
    if (!session.options.baseline) {
        try json.objectField("resources");
        try json.write(.{ .subscribe = false, .listChanged = false });
    }
    try json.endObject();
    try json.objectField("serverInfo");
    try json.write(.{ .name = server_name, .title = "Search Simpli", .version = tool_schemas.contracts_version });
    try json.objectField("instructions");
    try json.write(instructions);
    try json.endObject();
    try json.endObject();
}

/// MCP's opaque pagination: every listed tool fits one page, so any cursor
/// is unknown.
fn listTools(session: Session, params: std.json.ObjectMap, id: ?std.json.Value, output: *std.Io.Writer) !void {
    if (params.get("cursor")) |cursor| if (cursor != .null)
        return writeError(output, id, -32602, "Invalid params: unknown cursor", null);
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("tools");
    try json.beginArray();
    for (tools) |entry| {
        if (!session.listed(entry)) continue;
        try json.beginObject();
        try json.objectField("name");
        try json.write(entry.name);
        try json.objectField("title");
        try json.write(entry.title);
        try json.objectField("description");
        try json.write(entry.description);
        try json.objectField("inputSchema");
        try writeRaw(&json, entry.input_schema);
        try json.objectField("outputSchema");
        try writeRaw(&json, entry.output_schema);
        try json.objectField("annotations");
        if (entry.write) {
            try json.write(.{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = false, .openWorldHint = false });
        } else {
            try json.write(.{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true, .openWorldHint = false });
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try json.endObject();
}

// ----------------------------------------------------------- tools/call ---

/// The outcome of one tool call: the canonical JSON, or the RPC server's
/// error object for the same request.
const Outcome = union(enum) {
    ok: []const u8,
    refused: struct { code: i32, message: []const u8 },
};

fn callTool(
    session: *Session,
    service: service_module.Service,
    workspaces: ops.Workspaces,
    params: std.json.ObjectMap,
    id: ?std.json.Value,
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
) !void {
    const name_value = params.get("name") orelse return writeError(output, id, -32602, "Invalid params: name is required", null);
    if (name_value != .string) return writeError(output, id, -32602, "Invalid params: name must be a string", null);
    const name = name_value.string;
    const entry = toolNamed(name) orelse return unknownTool(output, id, name, allocator);
    if (!session.listed(entry)) return unknownTool(output, id, name, allocator);
    const arguments_value: ?std.json.Value = params.get("arguments");
    const arguments: std.json.ObjectMap = if (arguments_value) |v| switch (v) {
        .object => |object| object,
        .null => .empty,
        else => return writeError(output, id, -32602, "Invalid params: arguments must be an object", null),
    } else .empty;
    const outcome = try runTool(session, service, workspaces, entry, arguments, allocator);
    try writeToolResult(output, id, outcome, allocator);
}

fn unknownTool(output: *std.Io.Writer, id: ?std.json.Value, name: []const u8, allocator: std.mem.Allocator) !void {
    try writeError(output, id, -32602, try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{name}), null);
}

/// Run `entry` on `arguments` (exactly what the RPC server would run for
/// the method of the same name, with the server's scope).
pub fn runTool(
    session: *Session,
    service: service_module.Service,
    workspaces: ops.Workspaces,
    entry: Tool,
    arguments: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !Outcome {
    // CAP-13 FR-13: the principal and the query vector are never the caller's.
    if (arguments.get("principal_labels") != null)
        return refusal(-32602, "Invalid params: principal_labels comes from the server's command line (--labels), never from a request");
    if (arguments.get("query_vector") != null)
        return refusal(-32602, "Invalid params: query_vector is not accepted over MCP (CAP-13: no caller-supplied vectors)");
    const caller = session.options.caller;
    const name = entry.name;
    const result: ops.Result = if (std.mem.eql(u8, name, "search_knowledge"))
        ops.searchKnowledge(allocator, service, arguments, caller, workspaces) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.OperationFailed => return refusal(-32603, "Internal error"),
        }
    else if (std.mem.eql(u8, name, "read_chunk"))
        try ops.readChunk(allocator, service, arguments, caller)
    else if (std.mem.eql(u8, name, "list_sources"))
        ops.listSources(allocator, service, arguments, caller, workspaces) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.OperationFailed => return refusal(-32603, "Internal error"),
        }
    else if (std.mem.eql(u8, name, "index_status"))
        try ops.indexStatus(allocator, service, arguments, caller)
    else if (std.mem.eql(u8, name, "find"))
        try ops.find(allocator, service, arguments, caller)
    else if (std.mem.eql(u8, name, "outline"))
        try ops.outline(allocator, service, arguments, caller)
    else if (std.mem.eql(u8, name, "read_span"))
        try ops.readSpan(allocator, service, arguments, caller)
    else if (std.mem.eql(u8, name, "list_files"))
        try ops.listFiles(allocator, service, arguments, caller)
    else if (std.mem.eql(u8, name, "apply_changes"))
        return applyChanges(session, arguments, allocator)
    else
        unreachable;
    return outcomeOf(result, allocator);
}

fn refusal(code: i32, message: []const u8) Outcome {
    return .{ .refused = .{ .code = code, .message = message } };
}

/// The RPC server's mapping (`rpc.errorCodeOf`, "Invalid params: <reason>").
fn outcomeOf(result: ops.Result, allocator: std.mem.Allocator) !Outcome {
    return switch (result) {
        .ok => |text| .{ .ok = text },
        .failed => |failure| .{ .refused = .{
            .code = rpc.errorCodeOf(failure.code),
            .message = if (failure.code == .invalid_argument) try std.fmt.allocPrint(allocator, "Invalid params: {s}", .{failure.message}) else failure.message,
        } },
    };
}

/// `apply_changes` (only with `--allow-write`): the arguments are the change
/// request itself (section 6). Every root it names, declared or changed,
/// must be inside `--roots` when that is given (FR-24: host-authorized
/// roots); `file` changes are read only with `--allow-file-reads`.
fn applyChanges(session: *Session, arguments: std.json.ObjectMap, allocator: std.mem.Allocator) !Outcome {
    if (session.options.caller.roots) |bound| {
        for ([_][]const u8{ "roots", "changes" }) |field| {
            const list = arguments.get(field) orelse continue;
            if (list != .array) continue;
            for (list.array.items) |item| {
                if (item != .object) continue;
                const root_value = item.object.get("root_id") orelse continue;
                if (root_value != .string) continue;
                for (bound) |allowed| {
                    if (std.mem.eql(u8, allowed, root_value.string)) break;
                } else return refusal(-32602, try std.fmt.allocPrint(allocator, "Invalid params: root \"{s}\" is outside the server's --roots", .{root_value.string}));
            }
        }
    }
    const io = session.options.io orelse return refusal(-32603, "Internal error");
    const request_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = arguments }, .{});
    var dir = std.Io.Dir.cwd().openDir(io, session.options.dir_path orelse ".", .{ .iterate = true }) catch return refusal(-32603, "Internal error");
    defer dir.close(io);
    const result = ops.applyChanges(allocator, io, dir, request_json, .{ .allow_file_reads = session.options.allow_file_reads, .write_roots = session.options.caller.roots, .write_labels = if (session.options.caller.roots != null or session.options.caller.labels.len != 0) session.options.caller.labels else null }) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err == error.WriterBusy) return refusal(-32006, "Writer busy: another writer holds WRITER.LOCK");
        return refusal(-32603, try std.fmt.allocPrint(allocator, "Internal error: {s}", .{@errorName(err)}));
    };
    if (result == .ok) session.reopen = true;
    return outcomeOf(result, allocator);
}

fn writeToolResult(output: *std.Io.Writer, id: ?std.json.Value, outcome: Outcome, allocator: std.mem.Allocator) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    switch (outcome) {
        .ok => |text| try json.write(text),
        .refused => |refused| try json.write(try std.json.Stringify.valueAlloc(allocator, .{ .code = refused.code, .message = refused.message }, .{})),
    }
    try json.endObject();
    try json.endArray();
    switch (outcome) {
        .ok => |text| {
            try json.objectField("structuredContent");
            try writeRaw(&json, text);
            try json.objectField("isError");
            try json.write(false);
        },
        .refused => {
            try json.objectField("isError");
            try json.write(true);
        },
    }
    try json.endObject();
    try json.endObject();
}

// ------------------------------------------------------------ resources ---

fn serverScope(session: Session) scope.Request {
    return .{ .roots = session.options.caller.roots, .principal_labels = session.options.caller.labels };
}

/// `resources/list`: the visible indexed files whose bytes the index
/// retained (the ones `resources/read` can answer), by root then path,
/// `resource_page_size` per page; the cursor is `"<generation>:<offset>"`.
fn listResources(session: Session, service: service_module.Service, params: std.json.ObjectMap, id: ?std.json.Value, allocator: std.mem.Allocator, output: *std.Io.Writer) !void {
    const generation = service.engine.generation;
    var offset: usize = 0;
    if (params.get("cursor")) |cursor| switch (cursor) {
        .null => {},
        .string => |text| offset = parseCursor(text, generation) orelse
            return writeError(output, id, -32602, "Invalid params: unknown or stale cursor", null),
        else => return writeError(output, id, -32602, "Invalid params: cursor must be a string", null),
    };
    const folder = service.folder orelse return writeError(output, id, -32603, "Internal error", null);
    const files = try (service_module.ScopedService{ .service = service }).listFiles(allocator, serverScope(session), null, null);
    var readable = std.ArrayList(Readable).empty;
    if (try folder.sourceSection()) |section| {
        for (files) |file| {
            if (!std.mem.eql(u8, file.status, "indexed")) continue;
            const record = try scope.recordPath(allocator, file.root_id, file.path);
            const entry = section.find(record) orelse continue;
            try readable.append(allocator, .{ .root_id = file.root_id, .path = file.path, .size = entry.text_length });
        }
    }
    const start = @min(offset, readable.items.len);
    const end = @min(start + resource_page_size, readable.items.len);
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("resources");
    try json.beginArray();
    for (readable.items[start..end]) |file| {
        try json.beginObject();
        try json.objectField("uri");
        try json.write(try uriOf(allocator, file.root_id, file.path));
        try json.objectField("name");
        try json.write(file.path);
        try json.objectField("title");
        try json.write(try std.fmt.allocPrint(allocator, "{s}/{s}", .{ file.root_id, file.path }));
        try json.objectField("mimeType");
        try json.write(mimeTypeOf(file.path));
        try json.objectField("size");
        try json.write(file.size);
        try json.endObject();
    }
    try json.endArray();
    if (end < readable.items.len) {
        try json.objectField("nextCursor");
        try json.write(try std.fmt.allocPrint(allocator, "{d}:{d}", .{ generation, end }));
    }
    try json.endObject();
    try json.endObject();
}

const Readable = struct { root_id: []const u8, path: []const u8, size: usize };

fn parseCursor(text: []const u8, generation: u64) ?usize {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const cursor_generation = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;
    if (cursor_generation != generation) return null;
    return std.fmt.parseInt(usize, text[colon + 1 ..], 10) catch null;
}

fn listTemplates(params: std.json.ObjectMap, id: ?std.json.Value, output: *std.Io.Writer) !void {
    if (params.get("cursor")) |cursor| if (cursor != .null)
        return writeError(output, id, -32602, "Invalid params: unknown cursor", null);
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("resourceTemplates");
    try json.beginArray();
    try json.write(.{
        .uriTemplate = uri_template,
        .name = "indexed-file",
        .title = "An indexed file",
        .description = "The retained bytes of one indexed file, whole: at most 400 lines and 256 KiB (read_span's limits); longer files are read with read_span. root_id and path are percent-encoded; path keeps its slashes.",
    });
    try json.endArray();
    try json.endObject();
    try json.endObject();
}

/// `resources/read`: the whole file through `read_span`'s limits (one span
/// from line 1 to the last line, no context): a file over 400 lines or
/// 256 KiB is `-32005` naming the limits; a hidden, unknown or not retained
/// file is `-32002` "Resource not found" alike.
fn readResource(session: Session, service: service_module.Service, params: std.json.ObjectMap, id: ?std.json.Value, allocator: std.mem.Allocator, output: *std.Io.Writer) !void {
    const uri_value = params.get("uri") orelse return writeError(output, id, -32602, "Invalid params: uri is required", null);
    if (uri_value != .string) return writeError(output, id, -32602, "Invalid params: uri must be a string", null);
    const uri = uri_value.string;
    const parsed = (try parseUri(allocator, uri)) orelse
        return writeError(output, id, -32602, "Invalid params: expected search://{root_id}/{path}", null);
    const scoped = service_module.ScopedService{ .service = service };
    const span = try scoped.readSpan(allocator, serverScope(session), parsed.root_id, parsed.path, 1, std.math.maxInt(u32), 0);
    const text: []const u8 = switch (span) {
        .ok => |found| found.text,
        .failed => |failure| switch (failure.code) {
            .not_found => return writeError(output, id, resource_not_found, "Resource not found", uri),
            .capacity => return writeError(output, id, rpc.errorCodeOf(.capacity), failure.message, uri),
            // Line 1 of a visible file is past its end only when it is empty.
            .invalid_argument => "",
        },
    };
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("contents");
    try json.beginArray();
    try json.write(.{ .uri = uri, .mimeType = mimeTypeOf(parsed.path), .text = text });
    try json.endArray();
    try json.endObject();
    try json.endObject();
}

const ParsedUri = struct { root_id: []const u8, path: []const u8 };

/// `search://{root_id}/{path}`, both percent-decoded; null when malformed.
pub fn parseUri(allocator: std.mem.Allocator, uri: []const u8) !?ParsedUri {
    if (!std.mem.startsWith(u8, uri, uri_scheme)) return null;
    const rest = uri[uri_scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const root_id = (try percentDecode(allocator, rest[0..slash])) orelse return null;
    const path = (try percentDecode(allocator, rest[slash + 1 ..])) orelse return null;
    if (root_id.len == 0 or path.len == 0 or std.mem.indexOfScalar(u8, root_id, '/') != null) return null;
    return .{ .root_id = root_id, .path = path };
}

fn percentDecode(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out = try std.ArrayList(u8).initCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '%') {
            try out.append(allocator, text[i]);
            continue;
        }
        if (i + 2 >= text.len) return null;
        const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
        try out.append(allocator, byte);
        i += 2;
    }
    return out.items;
}

/// The URI of a file: every byte outside RFC 3986's unreserved set is
/// percent-encoded, except the path's slashes.
pub fn uriOf(allocator: std.mem.Allocator, root_id: []const u8, path: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, uri_scheme);
    try percentEncode(allocator, &out, root_id, false);
    try out.append(allocator, '/');
    try percentEncode(allocator, &out, path, true);
    return out.items;
}

fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, keep_slash: bool) !void {
    for (text) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~' or (keep_slash and byte == '/');
        if (plain) {
            try out.append(allocator, byte);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0F] });
        }
    }
}

fn mimeTypeOf(path: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".md") or std.ascii.endsWithIgnoreCase(path, ".markdown")) return "text/markdown";
    return "text/plain";
}

// --------------------------------------------------------------- writing ---

fn validId(value: std.json.Value) bool {
    return switch (value) {
        .integer, .string => true,
        else => false,
    };
}

fn responseStart(json: *std.json.Stringify, id: ?std.json.Value) !void {
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    if (id) |value| try json.write(value) else try json.write(null);
}

fn writeRaw(json: *std.json.Stringify, text: []const u8) !void {
    try json.beginWriteRaw();
    try json.writer.writeAll(text);
    json.endWriteRaw();
}

fn writeResultRaw(output: *std.Io.Writer, id: ?std.json.Value, result: []const u8) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try writeRaw(&json, result);
    try json.endObject();
}

/// A JSON-RPC error; `uri` adds `data: {uri}` (resources).
fn writeError(output: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8, uri: ?[]const u8) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("error");
    if (uri) |text| {
        try json.write(.{ .code = code, .message = message, .data = .{ .uri = text } });
    } else {
        try json.write(.{ .code = code, .message = message });
    }
    try json.endObject();
}

// ----------------------------------------------------------------- stdio ---

const Context = struct {
    service: service_module.Service,
    workspaces: ops.Workspaces,
};

fn splitList(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var items = std.ArrayList([]const u8).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| try items.append(allocator, part);
    return items.items;
}

/// The options `searchd mcp` was started with.
pub fn optionsOf(allocator: std.mem.Allocator, io: std.Io, args: cli.McpArgs) !Options {
    var options = Options{
        .baseline = args.baseline,
        .allow_write = args.allow_write,
        .allow_file_reads = args.allow_file_reads,
        .dir_path = args.path,
        .io = io,
    };
    if (args.roots) |text| options.caller.roots = try splitList(allocator, text);
    if (args.labels) |text| options.caller.labels = try splitList(allocator, text);
    return options;
}

/// `searchd mcp`: serve one client on stdin/stdout until stdin closes.
/// Returns the process exit status (1 when the index cannot be opened).
pub fn run(io: std.Io, gpa: std.mem.Allocator, args: cli.McpArgs) !u8 {
    var options_arena = std.heap.ArenaAllocator.init(gpa);
    defer options_arena.deinit();
    var session = Session{ .options = try optionsOf(options_arena.allocator(), io, args) };

    // S4-T6: the served generation owns its arena (`rpc.Generation`), which
    // the lazy loads allocate through; a reload closes the old one.
    var context = rpc.Generation.open(gpa, io, args.path) catch |err| {
        var buffer: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
        try stderr.interface.print("searchd: cannot open the index at {s}: {s}\n", .{ args.path, @errorName(err) });
        try stderr.flush();
        return 1;
    };
    defer context.close(gpa);

    const line_buffer = try gpa.alloc(u8, max_line_bytes);
    defer gpa.free(line_buffer);
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, line_buffer);
    const reader = &stdin_reader.interface;
    const output_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(output_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, output_buffer);
    const output = &stdout_writer.interface;

    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch {};
                try writeError(output, null, -32700, "Parse error: the message is longer than 8 MiB", null);
                try output.writeByte('\n');
                try output.flush();
                continue;
            },
            else => return err,
        } orelse break;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var request_arena = std.heap.ArenaAllocator.init(gpa);
        defer request_arena.deinit();
        session.reopen = false;
        if (try handleLine(&session, context.service, context.workspaces, line, request_arena.allocator(), output)) {
            try output.writeByte('\n');
            try output.flush();
        }
        if (session.reopen) {
            // The old generation stays served until the new one is open.
            const next = try rpc.Generation.open(gpa, io, args.path);
            context.close(gpa);
            context = next;
        }
    }
    return 0;
}

// ----------------------------------------------------------------- tests ---

const apply = @import("apply.zig");
const snapshot_open = @import("snapshot_open.zig");

const TestServer = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    context: Context = undefined,

    fn init() !*TestServer {
        const self = try std.testing.allocator.create(TestServer);
        self.* = .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator), .tmp = std.testing.tmpDir(.{ .iterate = true }) };
        const a = self.arena_state.allocator();
        const io = std.testing.io;
        // "# Week 7\n\n## Dates\nBand concert: count me in.\n", "# Plan\n\ntide secret\n", ""
        const request =
            \\{"roots":[{"root_id":"school","kind":"host"},{"root_id":"vault","kind":"host","required_labels":["adults"]}],
            \\"changes":[{"op":"add","root_id":"school","path":"week 7.md","content_base64":"IyBXZWVrIDcKCiMjIERhdGVzCkJhbmQgY29uY2VydDogY291bnQgbWUgaW4uCg=="},
            \\{"op":"add","root_id":"school","path":"empty.txt","content_base64":""},
            \\{"op":"pending","root_id":"school","path":"later.md","size":7},
            \\{"op":"add","root_id":"vault","path":"plan.md","content_base64":"IyBQbGFuCgp0aWRlIHNlY3JldAo="}]}
        ;
        switch (try apply.applyChanges(a, io, self.tmp.dir, request, .{})) {
            .ok => {},
            .failed => |failure| {
                std.debug.print("{s}\n", .{failure.message});
                return error.TestUnexpectedResult;
            },
        }
        const opened = try snapshot_open.openScoped(a, io, self.tmp.dir);
        const service = service_module.Service{ .engine = opened.engine, .folder = opened.folder };
        const count = service.engine.documents.len;
        self.context = .{ .service = service, .workspaces = .{
            .query_vector = &.{},
            .results = try a.alloc(hybrid.Result, count),
            .evidence = try a.alloc(engine_module.Evidence, count),
            .sources = try a.alloc(service_module.Source, count),
        } };
        return self;
    }

    fn deinit(self: *TestServer) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
        std.testing.allocator.destroy(self);
    }

    /// The response line, or null when none was written.
    fn send(self: *TestServer, session: *Session, line: []const u8) !?[]const u8 {
        const a = self.arena_state.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        if (!try handleLine(session, self.context.service, self.context.workspaces, line, a, &out.writer)) return null;
        const text = out.written();
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
        return text;
    }

    fn ready(self: *TestServer, options: Options) !Session {
        var session = Session{ .options = options };
        _ = (try self.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")).?;
        try std.testing.expect((try self.send(&session, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == null);
        return session;
    }
};

fn contains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing {s}\nin {s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

test "S3-T6: the handshake, ping, the pinned revision and the lifecycle errors" {
    const server = try TestServer.init();
    defer server.deinit();
    var session = Session{ .options = .{} };
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")).?, "send initialize first");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"result\":{}}", (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"method\":\"ping\"}")).?);
    const answer = (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\",\"capabilities\":{}}}")).?;
    try std.testing.expect(std.mem.startsWith(u8, answer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{\"listChanged\":false},\"resources\":{\"subscribe\":false,\"listChanged\":false}},\"serverInfo\":{\"name\":\"search-simpli\""));
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}")).?, "already answered");
    try std.testing.expect((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}")) == null);
    try std.testing.expect((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}")) == null);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", (try server.send(&session, "{\"jsonrpc\":")).?);
    try contains((try server.send(&session, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]")).?, "-32600");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}")).?, "-32600");
    try contains((try server.send(&session, "{\"jsonrpc\":\"1.0\",\"id\":4,\"method\":\"ping\"}")).?, "\"id\":4,\"error\":{\"code\":-32600");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"prompts/list\"}")).?, "\"id\":5,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\",\"params\":[]}")).?, "-32602");
}

test "S3-T6: tools/list per mode carries the S3-T5 schemas" {
    const server = try TestServer.init();
    defer server.deinit();
    const a = server.arena_state.allocator();
    const Case = struct { options: Options, count: usize };
    for ([_]Case{ .{ .options = .{ .baseline = true }, .count = 4 }, .{ .options = .{}, .count = 8 }, .{ .options = .{ .allow_write = true }, .count = 9 } }) |case| {
        var session = try server.ready(case.options);
        const text = (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")).?;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const listed = parsed.object.get("result").?.object.get("tools").?.array.items;
        try std.testing.expectEqual(case.count, listed.len);
        for (listed) |item| {
            const entry = toolNamed(item.object.get("name").?.string).?;
            const schema = try std.json.Stringify.valueAlloc(a, item.object.get("inputSchema").?, .{});
            try std.testing.expectEqualStrings(entry.input_schema, schema);
        }
    }
    var session = try server.ready(.{});
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"cursor\":\"x\"}}")).?, "unknown cursor");
}

test "S3-T6: tools/call answers the canonical JSON of ops and refuses forged scope" {
    const server = try TestServer.init();
    defer server.deinit();
    const a = server.arena_state.allocator();
    var session = try server.ready(.{});
    const text = (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"find\",\"arguments\":{\"query\":\"count me in\",\"mode\":\"phrase\"}}}")).?;
    const direct = (try ops.find(a, server.context.service, (try ops.parseObject(a, "{\"query\":\"count me in\",\"mode\":\"phrase\"}")).ok, .{})).ok;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const result = parsed.object.get("result").?.object;
    try std.testing.expectEqualStrings(direct, result.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings(direct, try std.json.Stringify.valueAlloc(a, result.get("structuredContent").?, .{}));
    try std.testing.expect(!result.get("isError").?.bool);
    try contains(direct, "\"root_id\":\"school\",\"path\":\"week 7.md\"");
    // search_knowledge carries the S3-T6 fields.
    const knowledge = (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"search_knowledge\",\"arguments\":{\"query\":\"concert\",\"retrieval_mode\":\"lexical\"}}}")).?;
    try contains(knowledge, "\\\"root_id\\\":\\\"school\\\",\\\"section_path\\\":[\\\"Week 7\\\",\\\"Dates\\\"]");
    try contains(knowledge, "\\\"truncated\\\":false,\\\"pending_files\\\":1");
    // Forged principal and vector, unknown tools, a write without the flag.
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"find\",\"arguments\":{\"query\":\"tide\",\"principal_labels\":[\"adults\"]}}}")).?, "\"isError\":true");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"search_knowledge\",\"arguments\":{\"query\":\"tide\",\"query_vector\":[1]}}}")).?, "query_vector is not accepted");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"apply_changes\",\"arguments\":{\"changes\":[]}}}")).?, "{\"code\":-32602,\"message\":\"Unknown tool: apply_changes\"}");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\"}}")).?, "Unknown tool: read_file");
    // A core refusal is the RPC error object inside an isError result.
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"outline\",\"arguments\":{\"root_id\":\"vault\",\"path\":\"plan.md\"}}}")).?, "\"text\":\"{\\\"code\\\":-32004,\\\"message\\\":\\\"not indexed or not retained: vault/plan.md\\\"}\"}],\"isError\":true}");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"find\",\"arguments\":{\"query\":\"tide\",\"bogus\":1}}}")).?, "Invalid params: unknown field");
    // The command line's labels open the vault; a baseline server has no find.
    var labelled = try server.ready(.{ .caller = .{ .labels = &.{"adults"} } });
    try contains((try server.send(&labelled, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"find\",\"arguments\":{\"query\":\"tide\"}}}")).?, "vault");
    var baseline = try server.ready(.{ .baseline = true });
    try contains((try server.send(&baseline, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"find\",\"arguments\":{\"query\":\"tide\"}}}")).?, "Unknown tool: find");
    try contains((try server.send(&baseline, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"resources/list\"}")).?, "-32601");
}

test "S3-T6: resources list, read and refuse through read_span's limits" {
    const server = try TestServer.init();
    defer server.deinit();
    var session = try server.ready(.{});
    const listed = (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/list\"}")).?;
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resources\":[" ++
        "{\"uri\":\"search://school/empty.txt\",\"name\":\"empty.txt\",\"title\":\"school/empty.txt\",\"mimeType\":\"text/plain\",\"size\":0}," ++
        "{\"uri\":\"search://school/week%207.md\",\"name\":\"week 7.md\",\"title\":\"school/week 7.md\",\"mimeType\":\"text/markdown\",\"size\":46}]}}", listed);
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"search://school/week%207.md\"}}")).?, "\"text\":\"# Week 7\\n\\n## Dates\\nBand concert: count me in.\\n\"");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{\"uri\":\"search://school/empty.txt\"}}")).?, "\"text\":\"\"");
    const hidden = (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/read\",\"params\":{\"uri\":\"search://vault/plan.md\"}}")).?;
    const absent = (try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/read\",\"params\":{\"uri\":\"search://vault/nope.md\"}}")).?;
    try contains(hidden, "{\"code\":-32002,\"message\":\"Resource not found\"");
    try std.testing.expectEqualStrings(hidden[0..std.mem.indexOf(u8, hidden, "\"data\"").?], absent[0..std.mem.indexOf(u8, absent, "\"data\"").?]);
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///etc/hosts\"}}")).?, "-32602");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/read\",\"params\":{\"uri\":\"search://school/week%2\"}}")).?, "-32602");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/templates/list\"}")).?, "\"uriTemplate\":\"search://{root_id}/{path}\"");
    try contains((try server.send(&session, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/list\",\"params\":{\"cursor\":\"9:0\"}}")).?, "stale cursor");
    // The command line's scope: only the vault, with its label.
    var labelled = try server.ready(.{ .caller = .{ .labels = &.{"adults"}, .roots = &.{"vault"} } });
    const vault = (try server.send(&labelled, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"resources/list\"}")).?;
    try contains(vault, "\"uri\":\"search://vault/plan.md\"");
    try std.testing.expect(std.mem.indexOf(u8, vault, "school") == null);
    try contains((try server.send(&labelled, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"resources/read\",\"params\":{\"uri\":\"search://vault/plan.md\"}}")).?, "tide secret");
}

test "S3-T6: URIs round-trip through percent-encoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const uri = try uriOf(a, "home", "trips/தமிழ் notes#1.md");
    try std.testing.expect(std.mem.indexOfAny(u8, uri[uri_scheme.len..], " #") == null);
    const back = (try parseUri(a, uri)).?;
    try std.testing.expectEqualStrings("home", back.root_id);
    try std.testing.expectEqualStrings("trips/தமிழ் notes#1.md", back.path);
    try std.testing.expect((try parseUri(a, "search://home")) == null);
    try std.testing.expect((try parseUri(a, "search:///x.md")) == null);
    try std.testing.expect((try parseUri(a, "search://home/%zz")) == null);
    try std.testing.expect((try parseUri(a, "search://home/a%2")) == null);
}
