const std = @import("std");
const uri = @import("lenore-gltf").uri;

const testing = std.testing;

fn expectPath(reference: []const u8, expected: []const u8) !void {
    const decoded = try uri.decodePathAlloc(testing.allocator, reference);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(expected, decoded);
}

test "glTF URI: percent escapes decode to path bytes" {
    try expectPath("Box%20With%20Spaces.bin", "Box With Spaces.bin");
    try expectPath("textures%2fbase%2Ecolor.png", "textures/base.color.png");
    try expectPath("caf%C3%A9.bin", "caf\xc3\xa9.bin");
}

// glTF 2.0 section 2.8 gives these two spellings of one path as an example and
// declares both valid: non-ASCII bytes may be written as they are or escaped.
test "glTF URI: a non-ASCII path is accepted in either spelling" {
    try expectPath("grande_sph\xc3\xa8re.png", "grande_sph\xc3\xa8re.png");
    try expectPath("grande_sph%C3%A8re.png", "grande_sph\xc3\xa8re.png");
}

test "glTF URI: plus and unescaped paths remain literal" {
    try expectPath("textures/a+b.png", "textures/a+b.png");
    try expectPath("plain.bin", "plain.bin");
}

test "glTF URI: malformed escapes and NUL are rejected" {
    const invalid = [_][]const u8{ "%", "%2", "%GG", "bad%0X.bin" };
    for (invalid) |reference|
        try testing.expectError(
            error.InvalidPercentEncoding,
            uri.decodePathAlloc(testing.allocator, reference),
        );

    try testing.expectError(error.NulByte, uri.decodePathAlloc(testing.allocator, "bad%00.bin"));
    try testing.expectError(error.NulByte, uri.decodePathAlloc(testing.allocator, "bad\x00.bin"));
}

test "glTF URI: a relative reference passes the form check" {
    const accepted = [_][]const u8{
        "plain.bin",
        "textures/base.png",
        "../shared/textures/base.png",
        // RFC 3986 section 3.3 names this as the way to write a first segment
        // that contains a colon.
        "./this:that.bin",
        // A colon outside the first segment cannot be read as a scheme.
        "textures/this:that.png",
        "grande_sph\xc3\xa8re.png",
    };
    for (accepted) |reference| try uri.validateRelativeReference(reference);
}

test "glTF URI: optional URI components are declined" {
    const cases = [_]struct { reference: []const u8, expected: anyerror }{
        .{ .reference = "", .expected = error.EmptyReference },
        .{ .reference = "http://example.com/box.bin", .expected = error.UnsupportedScheme },
        .{ .reference = "file:///srv/box.bin", .expected = error.UnsupportedScheme },
        .{ .reference = "C:/assets/box.bin", .expected = error.UnsupportedScheme },
        .{ .reference = "//example.com/box.bin", .expected = error.UnsupportedAuthority },
        .{ .reference = "/etc/shadow", .expected = error.AbsolutePath },
        .{ .reference = "box.bin?revision=2", .expected = error.QueryOrFragment },
        .{ .reference = "box.bin#fragment", .expected = error.QueryOrFragment },
    };
    for (cases) |case| {
        try testing.expectError(case.expected, uri.validateRelativeReference(case.reference));
        try testing.expectError(
            case.expected,
            uri.decodePathAlloc(testing.allocator, case.reference),
        );
    }
}

// The form check reads the raw reference, so an escaped delimiter stays a byte
// of the path instead of being read as one. Decoding first would reject both.
test "glTF URI: an escaped delimiter is data, not syntax" {
    try expectPath("textures/a%3Ab.png", "textures/a:b.png");
    try expectPath("a%2Fb.png", "a/b.png");
    try expectPath("%2Fnot-absolute.bin", "/not-absolute.bin");
}

// Dot segments are a conformant part of a path-noscheme, so this file accepts
// them. Whether the resolved path stays inside the asset directory is decided
// where the base directory is known, and is deliberately not decided here.
test "glTF URI: dot segments are not this file's question" {
    try expectPath("..%2F..%2Fetc%2Fshadow", "../../etc/shadow");
    try expectPath("../../etc/shadow", "../../etc/shadow");
}

test "glTF URI: embedded buffer data URIs decode standard base64" {
    const cases = [_]struct { encoded: []const u8, expected: []const u8 }{
        .{ .encoded = "data:application/octet-stream;base64,AAECA/7/", .expected = "\x00\x01\x02\x03\xfe\xff" },
        .{ .encoded = "DATA:APPLICATION/GLTF-BUFFER;BASE64,dGVzdA==", .expected = "test" },
    };
    for (cases) |case| {
        const decoded = try uri.decodeBufferDataUriAlloc(testing.allocator, case.encoded);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, case.expected, decoded);
    }
}

test "glTF URI: embedded PNG and JPEG data URIs decode standard base64" {
    inline for (.{
        "data:image/png;base64,iVBORw==",
        "DATA:IMAGE/JPEG;BASE64,iVBORw==",
    }) |encoded| {
        const decoded = try uri.decodeImageDataUriAlloc(testing.allocator, encoded);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, "\x89PNG", decoded);
    }
    try testing.expectError(
        error.UnsupportedMediaType,
        uri.decodeImageDataUriAlloc(testing.allocator, "data:image/webp;base64,AAAA"),
    );
}

test "glTF URI: malformed or unsupported buffer data URIs fail explicitly" {
    try testing.expect(!uri.isDataUri("buffer.bin"));
    try testing.expect(uri.isDataUri("DaTa:application/octet-stream;base64,"));

    const cases = [_]struct { encoded: []const u8, expected: anyerror }{
        .{ .encoded = "buffer.bin", .expected = error.InvalidDataUri },
        .{ .encoded = "data:application/octet-stream;base64", .expected = error.InvalidDataUri },
        .{ .encoded = "data:application/octet-stream,AAAA", .expected = error.UnsupportedDataEncoding },
        .{ .encoded = "data:text/plain;base64,AAAA", .expected = error.UnsupportedMediaType },
        // RFC 2397 permits parameters after the media type; neither type glTF
        // allows takes any, so one is read as part of the type and declined.
        .{ .encoded = "data:application/octet-stream;charset=utf-8;base64,AAAA", .expected = error.UnsupportedMediaType },
        .{ .encoded = "data:application/octet-stream;base64,AA*A", .expected = error.InvalidCharacter },
        .{ .encoded = "data:application/octet-stream;base64,AAA", .expected = error.InvalidPadding },
    };
    for (cases) |case|
        try testing.expectError(
            case.expected,
            uri.decodeBufferDataUriAlloc(testing.allocator, case.encoded),
        );
}

// An empty payload is a valid data URI and the decoder must not turn it into an
// error or a null slice: a zero-length buffer is a legal glTF buffer.
test "glTF URI: an empty data URI payload decodes to an empty slice" {
    const decoded = try uri.decodeBufferDataUriAlloc(testing.allocator, "data:application/octet-stream;base64,");
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 0), decoded.len);
}
