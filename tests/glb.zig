const std = @import("std");
const document = @import("lenore-gltf").document;

const testing = std.testing;

// A GLB carrying one embedded buffer, laid out by hand so a test can corrupt one
// field and see which check catches it. Offsets are stated rather than computed,
// so a mistake in the builder shows up as a failing valid-file test instead of
// hiding inside every other case.
//
// 0    magic "glTF"                     4
// 4    version, 2                       4
// 8    total length                     4
// 12   JSON chunk length                4
// 16   JSON chunk type "JSON"           4
// 20   JSON text, space-padded to 60   60
// 80   BIN chunk length                 4
// 84   BIN chunk type "BIN\0"           4
// 88   BIN payload                     12
// 100  end of file
const file_size = 100;
const json_length_offset = 12;
const json_type_offset = 16;
const json_offset = 20;
const json_length = 60;
const bin_length_offset = 80;
const bin_type_offset = 84;
const bin_offset = 88;
const bin_length = 12;

// The declared buffer is 12 bytes, exactly the BIN payload, so a test that needs
// the specification's 0-3 padding bytes changes the declaration rather than the
// chunk.
const json_text = "{\"asset\":{\"version\":\"2.0\"},\"buffers\":[{\"byteLength\":12}]}";

const magic: u32 = 0x46546c67;
const json_chunk_type: u32 = 0x4e4f534a;
const bin_chunk_type: u32 = 0x004e4942;

const File = [file_size]u8;

comptime {
    // The JSON chunk is padded with trailing spaces to a four-byte boundary
    // (glTF 2.0 section 4.4.3.2), which is what makes the stated offsets hold.
    std.debug.assert(json_text.len == 57);
    std.debug.assert(json_length == json_text.len + 3);
    std.debug.assert(file_size == bin_offset + bin_length);
}

fn validFile() File {
    var bytes: File = @splat(0);

    put32(&bytes, 0, magic);
    put32(&bytes, 4, 2);
    put32(&bytes, 8, file_size);

    put32(&bytes, json_length_offset, json_length);
    put32(&bytes, json_type_offset, json_chunk_type);
    @memcpy(bytes[json_offset..][0..json_text.len], json_text);
    @memset(bytes[json_offset + json_text.len ..][0 .. json_length - json_text.len], ' ');

    put32(&bytes, bin_length_offset, bin_length);
    put32(&bytes, bin_type_offset, bin_chunk_type);
    for (bytes[bin_offset..][0..bin_length], 0..) |*byte, index| byte.* = @intCast(index);

    return bytes;
}

fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn expectRejected(bytes: []const u8, expected: anyerror) !void {
    try testing.expectError(expected, document.Document.initGlb(testing.allocator, bytes));
}

test "GLB: a well-formed file parses and attaches its BIN chunk zero-copy" {
    const bytes = validFile();
    var doc = try document.Document.initGlb(testing.allocator, &bytes);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.buffer_descs.len);
    try testing.expectEqual(@as(u32, bin_length), doc.buffer_descs[0].byte_length);
    try testing.expect(doc.buffer_descs[0].uri == null);

    // Zero-copy: the attached buffer is a slice of the caller's blob, not a copy.
    try testing.expectEqual(@as(usize, 1), doc.buffers.len);
    try testing.expectEqual(@intFromPtr(&bytes[bin_offset]), @intFromPtr(doc.buffers[0].ptr));
    try testing.expectEqual(@as(usize, bin_length), doc.buffers[0].len);
}

test "GLB: the header is checked before anything is read from it" {
    var truncated = validFile();
    try expectRejected(truncated[0..11], error.InvalidGlb);

    var wrong_magic = validFile();
    put32(&wrong_magic, 0, 0x46546c68);
    try expectRejected(&wrong_magic, error.InvalidGlb);

    var wrong_version = validFile();
    put32(&wrong_version, 4, 1);
    try expectRejected(&wrong_version, error.UnsupportedGlbVersion);

    // Section 4.4.2: the header length is the total length of the asset, so a
    // declaration that disagrees with the blob is not a file this loader guesses
    // about.
    var short_declaration = validFile();
    put32(&short_declaration, 8, file_size - 4);
    try expectRejected(&short_declaration, error.InvalidGlb);

    var long_declaration = validFile();
    put32(&long_declaration, 8, file_size + 4);
    try expectRejected(&long_declaration, error.InvalidGlb);
    _ = &truncated;
}

test "GLB: the JSON chunk must come first, exist once, and be non-empty" {
    var wrong_first_type = validFile();
    put32(&wrong_first_type, json_type_offset, bin_chunk_type);
    try expectRejected(&wrong_first_type, error.InvalidGlb);

    // A second JSON chunk anywhere is a malformed container rather than an
    // unknown chunk to ignore.
    var duplicate_json = validFile();
    put32(&duplicate_json, bin_type_offset, json_chunk_type);
    try expectRejected(&duplicate_json, error.InvalidGlb);

    // An empty JSON chunk: length zero, with the text left in place as trailing
    // bytes the walk must then reject.
    var empty_json = validFile();
    put32(&empty_json, json_length_offset, 0);
    try expectRejected(&empty_json, error.InvalidGlb);
}

test "GLB: chunk lengths are bounded and four-byte aligned" {
    // Section 4.4.3.1: chunkLength is the length of chunkData, and the start and
    // end of every chunk are aligned to four bytes. A length that is not a
    // multiple of four cannot satisfy both.
    var unaligned = validFile();
    put32(&unaligned, json_length_offset, json_length + 1);
    try expectRejected(&unaligned, error.InvalidGlb);

    var overrunning = validFile();
    put32(&overrunning, bin_length_offset, bin_length + 4);
    try expectRejected(&overrunning, error.InvalidGlb);

    // A chunk header that does not fit in what remains of the blob.
    var trailing_header = validFile();
    put32(&trailing_header, bin_length_offset, bin_length + 4);
    put32(&trailing_header, 8, file_size);
    try expectRejected(&trailing_header, error.InvalidGlb);
}

test "GLB: unknown chunk types are ignored" {
    // Section 4.4.3.1 requires clients to ignore chunks with unknown types, so
    // an extension chunk in the BIN position leaves a document with no buffer
    // bytes rather than an error.
    var unknown = validFile();
    put32(&unknown, bin_type_offset, 0x4f4f464f);
    try expectRejected(&unknown, error.BufferCountMismatch);
}

test "GLB: the BIN chunk may exceed the declared buffer by its padding only" {
    // Section 4.4.3.3 pads the BIN chunk with trailing zeros, so the chunk is up
    // to three bytes longer than the buffer it carries.
    for ([_]u32{ 9, 10, 11, 12 }) |declared| {
        var bytes = validFile();
        writeDeclaredLength(&bytes, declared);
        var doc = try document.Document.initGlb(testing.allocator, &bytes);
        defer doc.deinit();
        try testing.expectEqual(declared, doc.buffer_descs[0].byte_length);
    }

    // Four bytes of slack is a chunk that does not describe this buffer.
    var slack = validFile();
    writeDeclaredLength(&slack, 8);
    try expectRejected(&slack, error.BufferSizeMismatch);

    var overlong = validFile();
    writeDeclaredLength(&overlong, 13);
    try expectRejected(&overlong, error.BufferSizeMismatch);
}

// Rewrites the byteLength in the JSON text in place, keeping the field two
// characters wide so the chunk length never moves. A single digit is followed by
// a space rather than a leading zero, which JSON does not permit in a number.
fn writeDeclaredLength(bytes: *File, value: u32) void {
    std.debug.assert(value < 100);
    const needle = "\"byteLength\":";
    const start = std.mem.indexOf(u8, bytes[json_offset..][0..json_length], needle).? +
        json_offset + needle.len;
    if (value < 10) {
        bytes[start] = '0' + @as(u8, @intCast(value));
        bytes[start + 1] = ' ';
    } else {
        bytes[start] = '0' + @as(u8, @intCast(value / 10));
        bytes[start + 1] = '0' + @as(u8, @intCast(value % 10));
    }
}

test "GLB: a buffer without a URI outside the BIN chunk is rejected" {
    // Section 3.6.1.2: the GLB-stored buffer is buffer 0 and it is the only one
    // that may omit its URI.
    const two_buffers =
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":4,"uri":"a.bin"},{"byteLength":4}]}
    ;
    try testing.expectError(
        error.InvalidStructure,
        document.Document.initJson(testing.allocator, two_buffers),
    );
}
