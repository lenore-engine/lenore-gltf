const std = @import("std");

const gltf = @import("lenore-gltf");
const loader = gltf.loader;

const testing = std.testing;
const io = std.testing.io;

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

// Three floats, so one VEC3 accessor over a twelve byte buffer.
const buffer_bytes = [_]u8{
    0x00, 0x00, 0x80, 0x3f,
    0x00, 0x00, 0x00, 0x40,
    0x00, 0x00, 0x40, 0x40,
};

fn documentText(comptime buffer_uri: []const u8) []const u8 {
    return "{\"asset\":{\"version\":\"2.0\"}," ++
        "\"buffers\":[{\"byteLength\":12,\"uri\":\"" ++ buffer_uri ++ "\"}]," ++
        "\"bufferViews\":[{\"buffer\":0,\"byteLength\":12}]," ++
        "\"accessors\":[{\"bufferView\":0,\"componentType\":5126,\"count\":1,\"type\":\"VEC3\"}]}";
}

test "loader: a document and the file beside it come back together" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(tmp.dir, "models/model.gltf", documentText("geometry.bin"));
    try write(tmp.dir, "models/geometry.bin", &buffer_bytes);

    var loaded = try loader.open(testing.allocator, io, tmp.dir, "models/model.gltf");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("models", loaded.directory);
    var values: [1][3]f32 = undefined;
    try loaded.document.read([3]f32, 0, &values);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, values[0]);
}

test "loader: a buffer reference reaching outside the root is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The document sits one directory down, so a single step up is inside the
    // root and two are not. Both spellings of the escape are tried: the plain
    // one, and the one that only becomes an escape after percent-decoding.
    try write(tmp.dir, "models/model.gltf", documentText("../secret.bin"));
    try write(tmp.dir, "secret.bin", &buffer_bytes);
    var inside = try loader.open(testing.allocator, io, tmp.dir, "models/model.gltf");
    inside.deinit(testing.allocator);

    try write(tmp.dir, "models/escape.gltf", documentText("../../secret.bin"));
    try testing.expectError(
        error.PathEscapesRoot,
        loader.open(testing.allocator, io, tmp.dir, "models/escape.gltf"),
    );

    // RFC 3986 section 2.2: an encoded delimiter is data, so this passes every
    // check on the reference as written and is an escape only once decoded.
    try write(tmp.dir, "models/encoded.gltf", documentText("%2e%2e%2f%2e%2e%2fsecret.bin"));
    try testing.expectError(
        error.PathEscapesRoot,
        loader.open(testing.allocator, io, tmp.dir, "models/encoded.gltf"),
    );
}

test "loader: a symlink is never traversed, at any component" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The secret sits outside anything the document may name, and the escape is
    // a link rather than a `..`, which no check on the string can see.
    try write(tmp.dir, "outside/secret.bin", &buffer_bytes);
    try tmp.dir.createDirPath(io, "root/models");

    // The link is the last component: the buffer itself.
    try write(tmp.dir, "root/models/direct.gltf", documentText("link.bin"));
    try tmp.dir.symLink(io, "../../outside/secret.bin", "root/models/link.bin", .{});
    var root = try tmp.dir.openDir(io, "root", .{});
    defer root.close(io);

    try testing.expectError(
        error.SymlinkRefused,
        loader.open(testing.allocator, io, root, "models/direct.gltf"),
    );

    // And the link is a directory on the way: the name resolves entirely inside
    // the root, and only the traversal leaves it.
    try write(tmp.dir, "root/models/indirect.gltf", documentText("elsewhere/secret.bin"));
    try tmp.dir.symLink(io, "../../outside", "root/models/elsewhere", .{});

    // Linux answers a link met by O_NOFOLLOW with ELOOP for the file above and
    // with ENOTDIR here, and both arrive as one refusal.
    try testing.expectError(
        error.SymlinkRefused,
        loader.open(testing.allocator, io, root, "models/indirect.gltf"),
    );

    // The same shape with a real file loads, so the refusals above are the links
    // and not the arrangement of the test.
    try write(tmp.dir, "root/models/plain.gltf", documentText("real.bin"));
    try write(tmp.dir, "root/models/real.bin", &buffer_bytes);
    var loaded = try loader.open(testing.allocator, io, root, "models/plain.gltf");
    loaded.deinit(testing.allocator);
}

test "loader: a percent-encoded name resolves to the file it names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(tmp.dir, "model.gltf", documentText("a%20b.bin"));
    try write(tmp.dir, "a b.bin", &buffer_bytes);

    var loaded = try loader.open(testing.allocator, io, tmp.dir, "model.gltf");
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("", loaded.directory);
}

test "loader: an embedded buffer needs no file at all" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The same three floats, base64 encoded, as a data URI.
    try write(tmp.dir, "model.gltf", documentText(
        "data:application/octet-stream;base64,AACAPwAAAEAAAEBA",
    ));

    var loaded = try loader.open(testing.allocator, io, tmp.dir, "model.gltf");
    defer loaded.deinit(testing.allocator);

    var values: [1][3]f32 = undefined;
    try loaded.document.read([3]f32, 0, &values);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, values[0]);
}

// A GLB of one JSON chunk and one BIN chunk, built byte by byte so the offsets
// are stated rather than produced by the writer this test exists to check.
fn glbBytes(comptime json: []const u8) [12 + 8 + json.len + 8 + buffer_bytes.len]u8 {
    comptime std.debug.assert(json.len % 4 == 0);
    var bytes: [12 + 8 + json.len + 8 + buffer_bytes.len]u8 = undefined;
    @memcpy(bytes[0..4], "glTF");
    std.mem.writeInt(u32, bytes[4..8], 2, .little);
    std.mem.writeInt(u32, bytes[8..12], bytes.len, .little);
    std.mem.writeInt(u32, bytes[12..16], json.len, .little);
    std.mem.writeInt(u32, bytes[16..20], 0x4E4F534A, .little);
    @memcpy(bytes[20..][0..json.len], json);
    std.mem.writeInt(u32, bytes[20 + json.len ..][0..4], buffer_bytes.len, .little);
    std.mem.writeInt(u32, bytes[24 + json.len ..][0..4], 0x004E4942, .little);
    @memcpy(bytes[28 + json.len ..][0..buffer_bytes.len], &buffer_bytes);
    return bytes;
}

test "loader: a container is chosen by its magic, not its name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Padded to four bytes with a space, which section 4.4.3 requires of the
    // JSON chunk and which JSON itself ignores.
    const blob = comptime glbBytes(
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":12}],
        \\"bufferViews":[{"buffer":0,"byteLength":12}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"count":1,"type":"VEC3"}]}
    );
    // The name says glTF and the magic says GLB, and the magic wins.
    try write(tmp.dir, "model.gltf", &blob);

    var loaded = try loader.open(testing.allocator, io, tmp.dir, "model.gltf");
    defer loaded.deinit(testing.allocator);

    var values: [1][3]f32 = undefined;
    try loaded.document.read([3]f32, 0, &values);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, values[0]);
}

test "loader: a buffer with no URI outside a GLB is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Section 4.4.2 gives only a GLB a buffer with no URI, and the document
    // layer already refuses one in a .gltf. The loader's job here is to let that
    // refusal through rather than to try the filesystem with an empty name.
    try write(tmp.dir, "model.gltf",
        \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":12}]}
    );
    try testing.expectError(
        error.InvalidStructure,
        loader.open(testing.allocator, io, tmp.dir, "model.gltf"),
    );
}

test "loader: a reference resolves against the document, not the root" {
    // The reference is relative to the document's own directory, so the same
    // spelling names a different file depending on where the document sits.
    const nested = try loader.resolveConfined(testing.allocator, "models/character", "textures/skin.png");
    defer testing.allocator.free(nested);
    try testing.expectEqualStrings("models/character/textures/skin.png", nested);

    const stepped = try loader.resolveConfined(testing.allocator, "models/character", "../shared/skin.png");
    defer testing.allocator.free(stepped);
    try testing.expectEqualStrings("models/shared/skin.png", stepped);

    const dotted = try loader.resolveConfined(testing.allocator, "models", "./a/./b.png");
    defer testing.allocator.free(dotted);
    try testing.expectEqualStrings("models/a/b.png", dotted);

    try testing.expectError(
        error.PathEscapesRoot,
        loader.resolveConfined(testing.allocator, "models", "../../etc/passwd"),
    );
    // An absolute reference never had a root to be inside of, and uri.zig
    // refuses it before this file sees it.
    try testing.expectError(
        error.AbsolutePath,
        loader.resolveConfined(testing.allocator, "models", "/etc/passwd"),
    );
}
