const std = @import("std");
const document = @import("lenore-gltf").document;

const testing = std.testing;

fn parse(text: []const u8) document.Error!document.Document {
    return document.Document.initJson(testing.allocator, text);
}

// A document that parses when it should not still owns an arena, so it is freed
// before the failure is reported. Without this the diagnostic is the whole
// Document struct printed by expectError, and the run also leaks.
fn expectRejected(text: []const u8, expected: anyerror) !void {
    if (parse(text)) |*value| {
        var doc = value.*;
        doc.deinit();
        std.debug.print("expected {t}, but the document parsed\n", .{expected});
        return error.TestUnexpectedSuccess;
    } else |err| try testing.expectEqual(expected, err);
}

// One buffer of 32 bytes, one tightly packed VEC3/f32 accessor of two elements
// over the first 24, and a second view of the same buffer with a 16-byte stride.
// Cases that need a malformed document state their own JSON rather than mutating
// this one, so a reader sees the whole input beside the expectation.
const geometry =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"byteLength":32,"uri":"geometry.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":24},
    \\                {"buffer":0,"byteOffset":0,"byteLength":32,"byteStride":16}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"},
    \\              {"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"}]}
;

// Eight consecutive floats, 1.0 through 8.0. The two views read the same bytes
// differently: the packed one takes elements at 0 and 12, the interleaved one at
// 0 and 16, which is what makes a stride mistake visible rather than plausible.
fn geometryBytes() [32]u8 {
    var bytes: [32]u8 = undefined;
    for (0..8) |index| {
        const value: f32 = @floatFromInt(index + 1);
        @memcpy(bytes[index * 4 ..][0..4], std.mem.asBytes(&value));
    }
    return bytes;
}

test "document: a minimal asset parses" {
    var doc = try parse(
        \\{"asset":{"version":"2.0"}}
    );
    defer doc.deinit();

    try testing.expect(doc.default_scene == null);
    try testing.expectEqual(@as(usize, 0), doc.nodes.len);
    // With no buffers to attach, the document is complete on its own.
    try testing.expectEqual(@as(usize, 0), doc.buffer_descs.len);
}

test "document: the glTF major version is the one this parser implements" {
    try expectRejected(
        \\{"asset":{"version":"1.0"}}
    , error.UnsupportedVersion);
    try expectRejected(
        \\{"asset":{"version":"two"}}
    , error.UnsupportedVersion);
    // Section 3.2: minVersion is what a client compares against its own
    // support, and a 2.x minor above ours is not something to guess at.
    try expectRejected(
        \\{"asset":{"version":"2.0","minVersion":"2.9"}}
    , error.UnsupportedVersion);
}

test "document: malformed JSON is one error, not a parser crash" {
    try expectRejected("{", error.InvalidJson);
    try expectRejected("", error.InvalidJson);
    try expectRejected(
        \\{"asset":{"version":2.0}}
    , error.InvalidJson);
    // A negative index cannot inhabit the u32 the schema declares, so it is
    // rejected by the JSON layer rather than by a later cast.
    try expectRejected(
        \\{"asset":{"version":"2.0"},"scene":-1}
    , error.InvalidJson);
}

test "document: an extension this parser does not implement is refused when required" {
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "extensionsUsed":["KHR_draco_mesh_compression"],
        \\ "extensionsRequired":["KHR_draco_mesh_compression"]}
    , error.UnsupportedExtension);

    // Section 3.12: extensionsRequired is a subset of extensionsUsed.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "extensionsRequired":["KHR_texture_transform"]}
    , error.InvalidStructure);

    // Used but not required is a document that renders without the extension.
    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "extensionsUsed":["KHR_draco_mesh_compression"]}
    );
    defer doc.deinit();

    // The other direction of the same rule: an extension this parser does read
    // off an object has to be declared before it is honoured, or the document
    // is asking for behaviour it never announced. KHR_materials_unlit is the
    // case with no properties of its own, so the declaration is the only thing
    // separating it from an object the parser would otherwise ignore.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "materials":[{"extensions":{"KHR_materials_unlit":{}}}]}
    , error.InvalidStructure);
}

test "document: accessor shapes this parser refuses are named individually" {
    // Section 3.6.2.3: a base array of zeros is only a document when something
    // says which elements differ from them.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "accessors":[{"componentType":5126,"count":1,"type":"SCALAR"}]}
    , error.InvalidStructure);

    // Section 3.6.2.4: a MAT3 of single-byte components needs each column
    // padded to four bytes, which this reader does not unpack.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":16,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":16}],
        \\ "accessors":[{"bufferView":0,"componentType":5121,"count":1,"type":"MAT3"}]}
    , error.UnsupportedMatrixPadding);

    // Section 5.1.4: normalized has no meaning for float or 32-bit integer
    // components.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":16,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":16}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":1,"type":"SCALAR",
        \\               "normalized":true}]}
    , error.InvalidStructure);
}

test "document: only triangles are drawn, and only two texture coordinate sets exist" {
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":24,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"mode":0}]}]}
    , error.UnsupportedPrimitiveMode);

    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "images":[{"uri":"t.png"}],
        \\ "textures":[{"source":0}],
        \\ "materials":[{"pbrMetallicRoughness":
        \\   {"baseColorTexture":{"index":0,"texCoord":2}}}]}
    , error.UnsupportedTexCoord);
}

test "document: an image declares one source and a media type this loader knows" {
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":8,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":8}],
        \\ "images":[{"bufferView":0,"mimeType":"image/webp"}]}
    , error.InvalidImageMimeType);

    // Section 5.18.1: uri and bufferView are mutually exclusive, and one of
    // them has to be there.
    try expectRejected(
        \\{"asset":{"version":"2.0"},"images":[{}]}
    , error.InvalidStructure);
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":8,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":8}],
        \\ "images":[{"uri":"t.png","bufferView":0}]}
    , error.InvalidStructure);
}

test "document: an index naming something that is not there is out of range" {
    try expectRejected(
        \\{"asset":{"version":"2.0"},"scene":0}
    , error.IndexOutOfRange);
    try expectRejected(
        \\{"asset":{"version":"2.0"},"scenes":[{"nodes":[0]}]}
    , error.IndexOutOfRange);
    try expectRejected(
        \\{"asset":{"version":"2.0"},"nodes":[{"children":[1]}]}
    , error.IndexOutOfRange);
}

test "document: the node graph is a forest, checked over every node" {
    // Two parents for one node.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "nodes":[{"children":[2]},{"children":[2]},{}]}
    , error.InvalidStructure);

    // A cycle among nodes that no scene mentions: unreachable from any root, so
    // a walk that started from the scenes would not see it.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "scenes":[{"nodes":[0]}],"scene":0,
        \\ "nodes":[{},{"children":[2]},{"children":[1]}]}
    , error.InvalidStructure);

    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "scenes":[{"nodes":[0]}],"scene":0,
        \\ "nodes":[{"children":[1,2]},{},{}]}
    );
    defer doc.deinit();
    try testing.expectEqual(@as(?u32, 0), doc.default_scene);
    try testing.expectEqual(@as(usize, 3), doc.nodes.len);
}

test "document: attachBuffers is atomic and refuses a table that does not match" {
    var doc = try parse(geometry);
    defer doc.deinit();

    const bytes = geometryBytes();
    try testing.expectError(error.BufferCountMismatch, doc.attachBuffers(&.{}));
    try testing.expectError(
        error.BufferSizeMismatch,
        doc.attachBuffers(&.{bytes[0..8]}),
    );
    // A refused attachment leaves the document unattached rather than half-bound.
    try testing.expectError(error.BuffersNotAttached, doc.bufferViewBytes(0));

    try doc.attachBuffers(&.{&bytes});
    try testing.expectError(error.BuffersAlreadyAttached, doc.attachBuffers(&.{&bytes}));
}

test "document: a view or an accessor reaching past its buffer is caught at attach" {
    var view_case = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":32,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":16,"byteLength":24}]}
    );
    defer view_case.deinit();
    const bytes = geometryBytes();
    try testing.expectError(
        error.BufferViewOutOfBounds,
        view_case.attachBuffers(&.{&bytes}),
    );

    var accessor_case = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":32,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"byteOffset":16,"componentType":5126,
        \\               "count":2,"type":"VEC3"}]}
    );
    defer accessor_case.deinit();
    try testing.expectError(
        error.AccessorOutOfBounds,
        accessor_case.attachBuffers(&.{&bytes}),
    );
}

// Section 3.6.1.1: a bufferView lies within buffer.byteLength. The attached
// slice may be longer, because a file on disk carries whatever the exporter
// left after the declared bytes, so the declaration is the bound and the slice
// is not.
test "document: byteLength bounds a view, not the length of the attached slice" {
    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":8,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":32}]}
    );
    defer doc.deinit();

    const bytes = geometryBytes();
    try testing.expectError(error.BufferViewOutOfBounds, doc.attachBuffers(&.{&bytes}));
}

// Section 3.6.2.4: "When two or more vertex attribute accessors use the same
// bufferView, its byteStride MUST be defined." Without it read() takes the
// tightly packed stride and returns interleaved data as though it were packed,
// with no error anywhere.
test "document: a view shared by two vertex attributes declares its stride" {
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":48,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":48}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"},
        \\              {"bufferView":0,"byteOffset":24,"componentType":5126,
        \\               "count":2,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1}}]}]}
    , error.InvalidStructure);
}

// The rule is about vertex attributes, so two accessors sharing a view for
// index data are a layout the same section permits. Section 3.6.1.1 goes
// further: a view that does not hold vertex attributes MUST NOT define a
// stride, so demanding one here would describe an unwritable document.
test "document: two index accessors may share a view with no stride" {
    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":48,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24},
        \\                {"buffer":0,"byteOffset":24,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"},
        \\              {"bufferView":1,"byteOffset":6,"componentType":5123,
        \\               "count":3,"type":"SCALAR"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1},
        \\                          {"attributes":{"POSITION":0},"indices":2}]}]}
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.accessors.len);
}

test "document: byteStride is bounded, aligned, and wide enough for its element" {
    // Section 5.11.4 gives minimum 4 and maximum 252; the schema printed with it
    // adds multipleOf 4.
    for ([_][]const u8{ "0", "1", "3", "255", "256" }) |stride| {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer,
            \\{{"asset":{{"version":"2.0"}},
            \\ "buffers":[{{"byteLength":48,"uri":"b.bin"}}],
            \\ "bufferViews":[{{"buffer":0,"byteLength":48,"byteStride":{s}}}]}}
        , .{stride});
        try expectRejected(text, error.InvalidStructure);
    }

    // Section 3.6.2.4: an element has to fit inside one stride.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":48,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":48,"byteStride":8}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"}]}
    , error.InvalidStructure);

    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":252,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":252,"byteStride":252}]}
    );
    defer doc.deinit();
}

test "document: an accessor may end on the last byte of its view and not past it" {
    // Section 3.6.2.4 states the span as
    // byteOffset + stride * (count - 1) + element size <= bufferView.length.
    const bytes = geometryBytes();

    var exact = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":24,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"}]}
    );
    defer exact.deinit();
    try exact.attachBuffers(&.{bytes[0..24]});

    var one_past = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":24,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"byteOffset":4,"componentType":5126,
        \\               "count":2,"type":"VEC3"}]}
    );
    defer one_past.deinit();
    try testing.expectError(
        error.AccessorOutOfBounds,
        one_past.attachBuffers(&.{bytes[0..24]}),
    );
}

// Both offsets are inside u32 on their own and their sum is not. The widening
// to u64 is what makes these rejections happen; computed in u32 the first wraps
// to 8 and the second to 20, and each would then look like it fits.
test "document: a span that overflows u32 is still out of bounds" {
    var view_case = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":8,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":4294967290,"byteLength":14}]}
    );
    defer view_case.deinit();
    const eight = [_]u8{0} ** 8;
    try testing.expectError(
        error.BufferViewOutOfBounds,
        view_case.attachBuffers(&.{&eight}),
    );

    var accessor_case = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":24,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"byteOffset":4294967292,"componentType":5126,
        \\               "count":2,"type":"VEC3"}]}
    );
    defer accessor_case.deinit();
    const bytes = geometryBytes();
    try testing.expectError(
        error.AccessorOutOfBounds,
        accessor_case.attachBuffers(&.{bytes[0..24]}),
    );
}

test "document: the accessor offset is aligned within the buffer, not only the view" {
    // Section 3.6.2.4 constrains accessor.byteOffset and the sum
    // accessor.byteOffset + bufferView.byteOffset, so a view at an odd offset
    // cannot host an aligned accessor.
    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":32,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":2,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"byteOffset":4,"componentType":5126,
        \\               "count":1,"type":"VEC3"}]}
    , error.InvalidStructure);

    try expectRejected(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":32,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"byteOffset":2,"componentType":5126,
        \\               "count":1,"type":"VEC3"}]}
    , error.InvalidStructure);
}

test "document: a rejected attachment binds no buffer at all" {
    // One valid buffer and one that is short: the failure has to leave the
    // document unattached rather than half-bound, which a single-buffer case
    // cannot demonstrate.
    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":8,"uri":"a.bin"},{"byteLength":16,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":8},{"buffer":1,"byteLength":16}]}
    );
    defer doc.deinit();

    const first = [_]u8{1} ** 8;
    const short_second = [_]u8{2} ** 4;
    try testing.expectError(
        error.BufferSizeMismatch,
        doc.attachBuffers(&.{ &first, &short_second }),
    );
    try testing.expectError(error.BuffersNotAttached, doc.bufferViewBytes(0));

    const second = [_]u8{2} ** 16;
    try doc.attachBuffers(&.{ &first, &second });
    try testing.expectEqual(@as(usize, 8), (try doc.bufferViewBytes(0)).len);
}

// std.json.ParseOptions.duplicate_field_behavior defaults to reporting an error
// and this parser does not override it, so a repeated key is a malformed
// document rather than a last-one-wins merge. Pinned here because the policy
// lives in a default rather than in this code.
test "document: a duplicated JSON key is refused" {
    try expectRejected(
        \\{"asset":{"version":"2.0"},"scene":0,"scene":0}
    , error.InvalidJson);
}

test "document: every index into another array is checked at its own site" {
    const cases = [_][]const u8{
        // mesh primitive to material
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":24,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}]}
        ,
        // mesh primitive to accessor
        \\{"asset":{"version":"2.0"},
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}]}
        ,
        // texture to image
        \\{"asset":{"version":"2.0"},"textures":[{"source":0}]}
        ,
        // texture to sampler
        \\{"asset":{"version":"2.0"},
        \\ "images":[{"uri":"t.png"}],"textures":[{"source":0,"sampler":0}]}
        ,
        // skin to joint node
        \\{"asset":{"version":"2.0"},"skins":[{"joints":[0]}]}
        ,
        // animation channel to sampler: the animation carries one, the channel
        // names the second.
        \\{"asset":{"version":"2.0"},
        \\ "nodes":[{}],
        \\ "buffers":[{"byteLength":32,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":8},{"buffer":0,"byteOffset":8,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},
        \\              {"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"}],
        \\ "animations":[{"samplers":[{"input":0,"output":1}],
        \\                "channels":[{"sampler":1,"target":{"node":0,"path":"translation"}}]}]}
        ,
        // node to camera
        \\{"asset":{"version":"2.0"},"nodes":[{"camera":0}]}
        ,
    };
    for (cases) |text| try expectRejected(text, error.IndexOutOfRange);
}

// Section 3.5.3: "When a node is targeted for animation (referenced by an
// animation.channel.target), only TRS properties MAY be present; matrix MUST
// NOT be present." The two documents below differ in one property, so the
// rejection is that property and not the rest of the animation.
fn animatedNodeDocument(comptime node: []const u8) []const u8 {
    return
    \\{"asset":{"version":"2.0"},
    \\ "nodes":[
    ++ node ++
        \\],
        \\ "buffers":[{"byteLength":32,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":8},{"buffer":0,"byteOffset":8,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},
        \\              {"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"}],
        \\ "animations":[{"samplers":[{"input":0,"output":1}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    ;
}

test "document: an animated node declaring a matrix is refused" {
    var doc = try parse(animatedNodeDocument(
        \\{"translation":[1,2,3]}
    ));
    doc.deinit();

    try expectRejected(animatedNodeDocument(
        \\{"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}
    ), error.InvalidStructure);
}

// A chain of `depth` nodes, each the only child of the one before it.
fn nodeChain(depth: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator,
        \\{"asset":{"version":"2.0"},"nodes":[
    );
    for (0..depth) |index| {
        if (index > 0) try text.append(testing.allocator, ',');
        if (index + 1 < depth)
            try text.print(testing.allocator, "{{\"children\":[{d}]}}", .{index + 1})
        else
            try text.appendSlice(testing.allocator, "{}");
    }
    try text.appendSlice(testing.allocator, "]}");
    return text.toOwnedSlice(testing.allocator);
}

// Depth is the one property of a document that turns into stack consumption, and
// every tree walk in this module recurses on the strength of this limit.
test "document: node nesting is bounded" {
    const accepted = try nodeChain(1024);
    defer testing.allocator.free(accepted);
    var doc = try parse(accepted);
    doc.deinit();

    const refused = try nodeChain(1025);
    defer testing.allocator.free(refused);
    try expectRejected(refused, error.NodeGraphTooDeep);
}

test "document: read copies packed and interleaved accessors alike" {
    var doc = try parse(geometry);
    defer doc.deinit();
    const bytes = geometryBytes();
    try doc.attachBuffers(&.{&bytes});

    var packed_values: [2][3]f32 = undefined;
    try doc.read([3]f32, 0, &packed_values);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, packed_values[0]);
    try testing.expectEqual([3]f32{ 4.0, 5.0, 6.0 }, packed_values[1]);

    // The 16-byte stride skips the fourth float, which the packed read returned.
    var strided: [2][3]f32 = undefined;
    try doc.read([3]f32, 1, &strided);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, strided[0]);
    try testing.expectEqual([3]f32{ 5.0, 6.0, 7.0 }, strided[1]);
}

test "document: read refuses every mismatch it can name" {
    var doc = try parse(geometry);
    defer doc.deinit();
    const bytes = geometryBytes();

    var destination: [2][3]f32 = undefined;
    try testing.expectError(error.BuffersNotAttached, doc.read([3]f32, 0, &destination));

    try doc.attachBuffers(&.{&bytes});
    try testing.expectError(error.IndexOutOfRange, doc.read([3]f32, 7, &destination));

    var wrong_component: [2][3]u16 = undefined;
    try testing.expectError(error.TypeMismatch, doc.read([3]u16, 0, &wrong_component));

    var wrong_arity: [2][2]f32 = undefined;
    try testing.expectError(error.TypeMismatch, doc.read([2]f32, 0, &wrong_arity));

    var wrong_count: [3][3]f32 = undefined;
    try testing.expectError(error.CountMismatch, doc.read([3]f32, 0, &wrong_count));
}

// Base data in the first 36 bytes as nine floats 1.0 through 9.0, one u16 index
// at 36, and one VEC3 of replacement values at 40.
//
// 0   base, three VEC3 elements   36
// 36  sparse indices, one u16      2
// 38  padding to the value offset  2
// 40  sparse values, one VEC3     12
// 52  end
fn sparseBytes() [52]u8 {
    var bytes: [52]u8 = @splat(0);
    for (0..9) |index| {
        const value: f32 = @floatFromInt(index + 1);
        @memcpy(bytes[index * 4 ..][0..4], std.mem.asBytes(&value));
    }
    std.mem.writeInt(u16, bytes[36..38], 1, .little);
    for ([_]f32{ 100.0, 200.0, 300.0 }, 0..) |value, index| {
        @memcpy(bytes[40 + index * 4 ..][0..4], std.mem.asBytes(&value));
    }
    return bytes;
}

const sparse_document =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"byteLength":52,"uri":"b.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteLength":36},
    \\                {"buffer":0,"byteOffset":36,"byteLength":2},
    \\                {"buffer":0,"byteOffset":40,"byteLength":12}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3",
    \\               "sparse":{"count":1,
    \\                         "indices":{"bufferView":1,"componentType":5123},
    \\                         "values":{"bufferView":2}}}]}
;

test "document: a sparse overlay replaces the elements it names" {
    var doc = try parse(sparse_document);
    defer doc.deinit();
    const bytes = sparseBytes();
    try doc.attachBuffers(&.{&bytes});

    var values: [3][3]f32 = undefined;
    try doc.read([3]f32, 0, &values);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, values[0]);
    try testing.expectEqual([3]f32{ 100.0, 200.0, 300.0 }, values[1]);
    try testing.expectEqual([3]f32{ 7.0, 8.0, 9.0 }, values[2]);
}

test "document: a sparse accessor with no base view starts from zeros" {
    // Section 3.6.2.3: "When accessor.bufferView is undefined, the sparse
    // accessor is initialized as an array of zeros."
    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":52,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":36,"byteLength":2},
        \\                {"buffer":0,"byteOffset":40,"byteLength":12}],
        \\ "accessors":[{"componentType":5126,"count":3,"type":"VEC3",
        \\               "sparse":{"count":1,
        \\                         "indices":{"bufferView":0,"componentType":5123},
        \\                         "values":{"bufferView":1}}}]}
    );
    defer doc.deinit();
    const bytes = sparseBytes();
    try doc.attachBuffers(&.{&bytes});

    var values: [3][3]f32 = undefined;
    try doc.read([3]f32, 0, &values);
    try testing.expectEqual([3]f32{ 0.0, 0.0, 0.0 }, values[0]);
    try testing.expectEqual([3]f32{ 100.0, 200.0, 300.0 }, values[1]);
    try testing.expectEqual([3]f32{ 0.0, 0.0, 0.0 }, values[2]);
}

test "document: the sparse object is checked without the bytes where it can be" {
    const cases = [_]struct { sparse: []const u8, expected: anyerror }{
        // Section 5.2.1: count minimum 1.
        .{
            .sparse =
            \\"count":0,"indices":{"bufferView":1,"componentType":5123},"values":{"bufferView":2}
            ,
            .expected = error.InvalidStructure,
        },
        // Section 3.6.2.3: no more deviating elements than the base has.
        .{
            .sparse =
            \\"count":4,"indices":{"bufferView":1,"componentType":5123},"values":{"bufferView":2}
            ,
            .expected = error.InvalidStructure,
        },
        // Section 5.3.3: the index type is unsigned byte, short or int.
        .{
            .sparse =
            \\"count":1,"indices":{"bufferView":1,"componentType":5126},"values":{"bufferView":2}
            ,
            .expected = error.InvalidStructure,
        },
        // Sections 5.3.1 and 5.4.1: neither overlay view defines a stride.
        .{
            .sparse =
            \\"count":1,"indices":{"bufferView":3,"componentType":5123},"values":{"bufferView":2}
            ,
            .expected = error.InvalidStructure,
        },
        // Section 5.3.1: the index offset is aligned to the index component.
        .{
            .sparse =
            \\"count":1,"indices":{"bufferView":1,"byteOffset":1,"componentType":5123},"values":{"bufferView":2}
            ,
            .expected = error.InvalidStructure,
        },
        .{
            .sparse =
            \\"count":1,"indices":{"bufferView":9,"componentType":5123},"values":{"bufferView":2}
            ,
            .expected = error.IndexOutOfRange,
        },
    };

    for (cases) |case| {
        var buffer: [640]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer,
            \\{{"asset":{{"version":"2.0"}},
            \\ "buffers":[{{"byteLength":64,"uri":"b.bin"}}],
            \\ "bufferViews":[{{"buffer":0,"byteLength":36}},
            \\                {{"buffer":0,"byteOffset":36,"byteLength":4}},
            \\                {{"buffer":0,"byteOffset":40,"byteLength":12}},
            \\                {{"buffer":0,"byteOffset":52,"byteLength":8,"byteStride":4}}],
            \\ "accessors":[{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3",
            \\               "sparse":{{{s}}}}}]}}
        , .{case.sparse});
        try expectRejected(text, case.expected);
    }
}

test "document: sparse indices are ordered, in range, and inside their view" {
    var bytes = sparseBytes();

    // Section 3.6.2.3: an index at or above the base element count.
    std.mem.writeInt(u16, bytes[36..38], 3, .little);
    var out_of_range = try parse(sparse_document);
    defer out_of_range.deinit();
    try testing.expectError(
        error.AccessorOutOfBounds,
        out_of_range.attachBuffers(&.{&bytes}),
    );

    // Section 5.2.2: "Indices MUST strictly increase", so a repeat is malformed
    // even though both values are in range.
    const two_indices =
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":64,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":36},
        \\                {"buffer":0,"byteOffset":36,"byteLength":4},
        \\                {"buffer":0,"byteOffset":40,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3",
        \\               "sparse":{"count":2,
        \\                         "indices":{"bufferView":1,"componentType":5123},
        \\                         "values":{"bufferView":2}}}]}
    ;
    var wide: [64]u8 = @splat(0);
    @memcpy(wide[0..52], &sparseBytes());
    std.mem.writeInt(u16, wide[36..38], 1, .little);
    std.mem.writeInt(u16, wide[38..40], 1, .little);

    var repeated = try parse(two_indices);
    defer repeated.deinit();
    try testing.expectError(error.InvalidStructure, repeated.attachBuffers(&.{&wide}));

    // The overlay reaching past the view that holds it.
    var overrunning = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":52,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":36},
        \\                {"buffer":0,"byteOffset":36,"byteLength":2},
        \\                {"buffer":0,"byteOffset":40,"byteLength":12}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3",
        \\               "sparse":{"count":2,
        \\                         "indices":{"bufferView":1,"componentType":5123},
        \\                         "values":{"bufferView":2}}}]}
    );
    defer overrunning.deinit();
    try testing.expectError(
        error.AccessorOutOfBounds,
        overrunning.attachBuffers(&.{&sparseBytes()}),
    );
}

test "document: a failing allocator surfaces as OutOfMemory, not as a leak" {
    // Every prefix of the allocation sequence is exercised, so each allocation
    // site is the failing one in some run and its errdefer path is taken.
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = index,
        });
        const result = document.Document.initJson(failing.allocator(), geometry);
        if (result) |*value| {
            var doc = value.*;
            doc.deinit();
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    } else return error.NeverSucceeded;
}
