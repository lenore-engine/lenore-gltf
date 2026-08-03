const std = @import("std");

pub const Error = error{
    InvalidGlb,
    UnsupportedGlbVersion,
};

pub const Chunks = struct {
    json: []const u8,
    bin: ?[]const u8,
};

const header_size = 12;
const chunk_header_size = 8;
const glb_magic: u32 = 0x46546c67;
const json_chunk_type: u32 = 0x4e4f534a;
const bin_chunk_type: u32 = 0x004e4942;

const Chunk = struct {
    kind: u32,
    data: []const u8,
};

// glTF 2.0 section 4.4.3.1 fixes the container: chunks appear in the order of
// its Table 1, one JSON chunk and at most one BIN chunk, and a client ignores
// chunks whose type it does not know. chunkLength is the length of chunkData,
// and the start and end of every chunk are four-byte aligned, so the padding
// each chunk carries is counted inside its own length.
pub fn split(blob: []const u8) Error!Chunks {
    if (blob.len < header_size) return error.InvalidGlb;
    if (readU32(blob, 0) != glb_magic) return error.InvalidGlb;
    if (readU32(blob, 4) != 2) return error.UnsupportedGlbVersion;

    const declared_length: usize = readU32(blob, 8);
    if (declared_length != blob.len) return error.InvalidGlb;

    var offset: usize = header_size;
    const json = try nextChunk(blob, &offset);
    if (json.kind != json_chunk_type or json.data.len == 0)
        return error.InvalidGlb;

    var bin: ?[]const u8 = null;
    var chunk_index: usize = 1;
    while (offset < blob.len) : (chunk_index += 1) {
        const chunk = try nextChunk(blob, &offset);
        switch (chunk.kind) {
            json_chunk_type => return error.InvalidGlb,
            bin_chunk_type => {
                if (chunk_index != 1 or bin != null) return error.InvalidGlb;
                bin = chunk.data;
            },
            else => {},
        }
    }

    return .{ .json = json.data, .bin = bin };
}

fn nextChunk(blob: []const u8, offset: *usize) Error!Chunk {
    const remaining = blob.len - offset.*;
    if (remaining < chunk_header_size) return error.InvalidGlb;

    const length: usize = readU32(blob, offset.*);
    const kind = readU32(blob, offset.* + 4);
    offset.* += chunk_header_size;

    if (length % 4 != 0 or length > blob.len - offset.*)
        return error.InvalidGlb;

    const data = blob[offset.*..][0..length];
    offset.* += length;
    return .{ .kind = kind, .data = data };
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
