const std = @import("std");
const Allocator = std.mem.Allocator;

// Decoding of the two forms a glTF `uri` field can take.
//
// A `uri` is a URI reference, never a literal path: glTF 2.0 section 2.8
// requires reserved characters to be percent-encoded, so the path bytes have to
// be recovered before anything is opened. `+` means a space only in HTML form
// encoding, which this is not, and stays literal.
//
// The other form carries the payload inline as a data URI (RFC 2397). Nothing
// here touches the filesystem.
//
// Two questions are asked about an external reference and only the first is
// answered here: whether the string has the shape glTF permits, which needs
// nothing but the string, and whether the path it resolves to stays inside the
// asset directory, which needs the base directory the importer holds.

pub const DecodeError = Allocator.Error || error{
    InvalidPercentEncoding,
    NulByte,
};

// Forms this loader declines to resolve. See validateRelativeReference for why
// declining them is conformant.
pub const ReferenceError = error{
    EmptyReference,
    UnsupportedScheme,
    UnsupportedAuthority,
    AbsolutePath,
    QueryOrFragment,
};

// std.base64.Error is taken whole so the set tracks the decoder this file uses.
pub const DataUriError = Allocator.Error || std.base64.Error || error{
    InvalidDataUri,
    UnsupportedMediaType,
    UnsupportedDataEncoding,
};

// Schemes are case-insensitive (RFC 3986 section 3.1).
pub fn isDataUri(value: []const u8) bool {
    return value.len >= "data:".len and std.ascii.eqlIgnoreCase(value[0.."data:".len], "data:");
}

// The one entry point for an external reference: the form is checked before the
// escapes are decoded, so a caller cannot reach the decoder with a string whose
// shape was never examined.
pub fn decodePathAlloc(
    allocator: Allocator,
    reference: []const u8,
) (ReferenceError || DecodeError)![]u8 {
    try validateRelativeReference(reference);
    return percentDecodeAlloc(allocator, reference);
}

// glTF 2.0 section 2.8 defines an external reference as an RFC 3986
// `path-noscheme` (`ipath-noscheme` of RFC 3987 where the bytes are non-ASCII),
// "without scheme, authority, or parameters". The same section then says a
// client MAY optionally support schemes, authorities, hostnames, absolute paths
// and query or fragment parameters, and that assets using them are less
// portable. Supporting none of them is therefore conformant rather than strict,
// and it is what stops a reference from naming a file outside the asset
// directory before anything tries to resolve it.
//
// This reads the raw reference. A percent-encoded octet is data and never a
// delimiter, so `%3A` and `%2F` are legal inside a segment; decoding first would
// reject valid references and would ask this question of a string that no longer
// has URI syntax.
//
// Dot segments pass. RFC 3986 section 3.3 admits them in a `path-noscheme`, so
// `../textures/x.png` is a conformant reference, and whether it leaves the asset
// directory is a question about the resolved path rather than about this string.
pub fn validateRelativeReference(reference: []const u8) ReferenceError!void {
    if (reference.len == 0) return error.EmptyReference;
    if (std.mem.startsWith(u8, reference, "//")) return error.UnsupportedAuthority;
    if (reference[0] == '/') return error.AbsolutePath;

    var first_segment = true;
    for (reference) |c| switch (c) {
        // Unescaped, these begin the query and the fragment: section 2.8
        // requires a reserved character meant literally to be percent-encoded.
        '?', '#' => return error.QueryOrFragment,
        // `segment-nz-nc` excludes the colon precisely so that a first segment
        // containing one is not mistaken for a scheme name (RFC 3986 section
        // 3.3). A Windows drive letter lands here too, which is correct.
        ':' => if (first_segment) return error.UnsupportedScheme,
        '/' => first_segment = false,
        else => {},
    };
}

// Returns owned path bytes with every `%HH` triplet decoded once. RFC 3986
// section 2.1 makes the hexadecimal digits `A`-`F` and `a`-`f` equivalent, so
// both cases are accepted.
//
// A NUL, decoded or literal, is an error rather than a byte passed on. The
// result is destined for a path, and std.posix.toPosixPath only asserts the
// absence of one, which leaves a truncated path in a build without safety.
//
// The output is never longer than the input, so counting first buys an
// exact-size allocation with no growth and no temporary list.
//
// Private: reached through decodePathAlloc, which checks the form first. A
// public percent-decoder would be the door an unexamined reference walks through
// on its way to the filesystem.
fn percentDecodeAlloc(allocator: Allocator, uri: []const u8) DecodeError![]u8 {
    const output = try allocator.alloc(u8, try decodedLength(uri));

    var src: usize = 0;
    var dst: usize = 0;
    while (src < uri.len) : (dst += 1) {
        if (uri[src] == '%') {
            // decodedLength walked this string with the same predicate and
            // rejected it unless both digits are hexadecimal.
            output[dst] = (hexNibble(uri[src + 1]).? << 4) | hexNibble(uri[src + 2]).?;
            src += 3;
        } else {
            output[dst] = uri[src];
            src += 1;
        }
    }
    std.debug.assert(dst == output.len);
    return output;
}

// Validates the escapes and returns the decoded byte count. Splitting it out is
// what lets the loop above index without bounds arithmetic.
fn decodedLength(uri: []const u8) error{ InvalidPercentEncoding, NulByte }!usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < uri.len) : (len += 1) {
        if (uri[i] == 0) return error.NulByte;
        if (uri[i] != '%') {
            i += 1;
            continue;
        }
        if (i + 2 >= uri.len) return error.InvalidPercentEncoding;
        const hi = hexNibble(uri[i + 1]) orelse return error.InvalidPercentEncoding;
        const lo = hexNibble(uri[i + 2]) orelse return error.InvalidPercentEncoding;
        if ((hi << 4) | lo == 0) return error.NulByte;
        i += 3;
    }
    return len;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// glTF 2.0 section 3.6.1.1: a buffer data URI must carry `application/octet-stream`
// or `application/gltf-buffer`. Only their base64 form is accepted, so metadata
// can never be mistaken for binary payload.
pub fn decodeBufferDataUriAlloc(allocator: Allocator, value: []const u8) DataUriError![]u8 {
    return decodeDataUriAlloc(allocator, value, &.{
        "application/octet-stream",
        "application/gltf-buffer",
    });
}

// PNG and JPEG are the only image media types glTF 2.0 defines: section 2.6
// lists them, and section 5.18.2 allows `image.mimeType` no other value.
pub fn decodeImageDataUriAlloc(allocator: Allocator, value: []const u8) DataUriError![]u8 {
    return decodeDataUriAlloc(allocator, value, &.{ "image/png", "image/jpeg" });
}

// RFC 2397 section 3 gives the grammar as `data:[<mediatype>][;base64],<data>`,
// where a media type may be followed by parameters. The encoding marker is
// therefore the last `;` group, and a media type carrying parameters fails the
// comparison below: neither type glTF permits takes any.
//
// Both the media type and the marker are compared without regard to case. That
// document writes them lowercase and says nothing about case, so the tolerant
// reading is taken.
fn decodeDataUriAlloc(
    allocator: Allocator,
    value: []const u8,
    allowed_media_types: []const []const u8,
) DataUriError![]u8 {
    if (!isDataUri(value)) return error.InvalidDataUri;

    const comma = std.mem.indexOfScalarPos(u8, value, "data:".len, ',') orelse
        return error.InvalidDataUri;
    const metadata = value["data:".len..comma];
    const base64_separator = std.mem.lastIndexOfScalar(u8, metadata, ';') orelse
        return error.UnsupportedDataEncoding;
    if (!std.ascii.eqlIgnoreCase(metadata[base64_separator + 1 ..], "base64"))
        return error.UnsupportedDataEncoding;

    const media_type = metadata[0..base64_separator];
    const supported = for (allowed_media_types) |allowed| {
        if (std.ascii.eqlIgnoreCase(media_type, allowed)) break true;
    } else false;
    if (!supported) return error.UnsupportedMediaType;

    const encoded = value[comma + 1 ..];
    const decoder = std.base64.standard.Decoder;
    // decode's precondition is that dest is exactly this size; it writes without
    // a bounds check of its own.
    const decoded = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    errdefer allocator.free(decoded);
    try decoder.decode(decoded, encoded);
    return decoded;
}
