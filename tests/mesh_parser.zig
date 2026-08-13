const std = @import("std");

const gltf = @import("lenore-gltf");
const document = gltf.document;
const mesh_parser = gltf.mesh_parser;

const testing = std.testing;

// Every case here states its own document and its own bytes, so a reader sees
// the whole input beside the expectation rather than a shared fixture mutated
// per test. The helpers below only turn values into little endian bytes.
fn floats(comptime values: []const f32) [values.len * 4]u8 {
    var bytes: [values.len * 4]u8 = undefined;
    for (values, 0..) |value, index| {
        const element: f32 = value;
        @memcpy(bytes[index * 4 ..][0..4], std.mem.asBytes(&element));
    }
    return bytes;
}

fn shorts(comptime values: []const u16) [values.len * 2]u8 {
    var bytes: [values.len * 2]u8 = undefined;
    for (values, 0..) |value, index| {
        const element: u16 = value;
        @memcpy(bytes[index * 2 ..][0..2], std.mem.asBytes(&element));
    }
    return bytes;
}

fn load(text: []const u8, bytes: []const u8) !document.Document {
    var doc = try document.Document.initJson(testing.allocator, text);
    errdefer doc.deinit();
    try doc.attachBuffers(&.{bytes});
    return doc;
}

fn expectVec3(expected: [3]f32, actual: @Vector(3, f32)) !void {
    inline for (0..3) |lane|
        try testing.expectApproxEqAbs(expected[lane], actual[lane], 1e-6);
}

fn expectVec4(expected: [4]f32, actual: @Vector(4, f32)) !void {
    inline for (0..4) |lane|
        try testing.expectApproxEqAbs(expected[lane], actual[lane], 1e-6);
}

// Three vertices at (1,2,3), (4,5,6), (7,8,9) and nothing else.
const positions_only =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"byteLength":36,"uri":"b.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteLength":36}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
    \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}]}
;

test "mesh parser: a primitive with only positions gets the interchange defaults" {
    const bytes = floats(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    var doc = try load(positions_only, &bytes);
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), primitive.vertices.len);
    try expectVec3(.{ 1, 2, 3 }, primitive.vertices[0].position);
    try expectVec3(.{ 7, 8, 9 }, primitive.vertices[2].position);

    // No NORMAL, TEXCOORD_0 or TANGENT, and no basis is generated without both
    // of the first two, so every vertex keeps what Vertex3D declares.
    try expectVec3(.{ 0, 1, 0 }, primitive.vertices[0].normal);
    try expectVec4(.{ 1, 0, 0, 1 }, primitive.vertices[0].tangent);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, primitive.vertices[0].colour);

    // Non-indexed geometry gets the sequence, so nothing downstream carries the
    // case.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, primitive.indices);
    try testing.expectEqual(@as(?u32, null), primitive.material);
    try testing.expectEqual(@as(u3, 0), primitive.streams.index());
    try testing.expectEqual(@as(?mesh_parser.MorphDeltas, null), primitive.morph);
}

test "mesh parser: a primitive with no POSITION is refused" {
    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":12,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":12}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":1,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"NORMAL":0}}]}]}
    , &floats(&.{ 0, 1, 0 }));
    defer doc.deinit();

    try testing.expectError(
        error.EmptyPrimitive,
        mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]),
    );
}

// TEXCOORD_0 as normalized unsigned bytes and COLOR_0 as normalized unsigned
// shorts, the two quantized spellings section 3.7.2 allows and the reference
// read as floats, which fails rather than decodes.
test "mesh parser: normalized integer attributes decode to floats" {
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0 });
    const uvs = [_]u8{ 0, 255, 255, 0 };
    const colours = shorts(&.{ 0, 32768, 65535, 65535, 0, 32768 });
    const bytes = positions ++ uvs ++ colours;

    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":40,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24},
        \\                {"buffer":0,"byteOffset":24,"byteLength":4},
        \\                {"buffer":0,"byteOffset":28,"byteLength":12}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5121,"normalized":true,"count":2,"type":"VEC2"},
        \\              {"bufferView":2,"componentType":5123,"normalized":true,"count":2,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1,"COLOR_0":2}}]}]}
    , &bytes);
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    // Section 3.11: f = c / 255 for an unsigned byte, f = c / 65535 for an
    // unsigned short. 32768 / 65535 is 0.50001, which rounds to 128 as unorm8.
    try testing.expectApproxEqAbs(@as(f32, 0.0), primitive.vertices[0].uv[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), primitive.vertices[0].uv[1], 1e-6);
    try testing.expectEqual([4]u8{ 0, 128, 255, 255 }, primitive.vertices[0].colour);
    try testing.expectEqual([4]u8{ 255, 0, 128, 255 }, primitive.vertices[1].colour);

    // A VEC3 colour supplies an opaque alpha, and the stream is declared so an
    // uploader writes it.
    try testing.expect(primitive.streams.colour);
    try testing.expect(!primitive.streams.uv1);
    try testing.expect(!primitive.streams.skinned);
}

test "mesh parser: joints widen to u16 and weights are renormalized" {
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0 });
    const joints = [_]u8{ 3, 0, 0, 0, 1, 2, 0, 0 };
    // The first vertex sums to 2.0 and the second to 0.0, the two cases the
    // renormalization has to tell apart.
    const weights = floats(&.{ 1, 1, 0, 0, 0, 0, 0, 0 });
    const bytes = positions ++ joints ++ weights;

    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":64,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24},
        \\                {"buffer":0,"byteOffset":24,"byteLength":8},
        \\                {"buffer":0,"byteOffset":32,"byteLength":32}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5121,"count":2,"type":"VEC4"},
        \\              {"bufferView":2,"componentType":5126,"count":2,"type":"VEC4"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2}}]}]}
    , &bytes);
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    try testing.expectEqual(@Vector(4, u16){ 3, 0, 0, 0 }, primitive.vertices[0].joints);
    try testing.expectEqual(@Vector(4, u16){ 1, 2, 0, 0 }, primitive.vertices[1].joints);
    try expectVec4(.{ 0.5, 0.5, 0, 0 }, primitive.vertices[0].weights);
    // No influence at all is left alone rather than handed to joint zero.
    try expectVec4(.{ 0, 0, 0, 0 }, primitive.vertices[1].weights);
    try testing.expect(primitive.streams.skinned);
}

test "mesh parser: narrow indices widen and an out of range one is refused" {
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 });
    const good = shorts(&.{ 0, 1, 2 });
    const bad = shorts(&.{ 0, 1, 3 });

    const text =
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":44,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":36},
        \\                {"buffer":0,"byteOffset":36,"byteLength":6}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}]}
    ;

    {
        var doc = try load(text, &(positions ++ good ++ [_]u8{ 0, 0 }));
        defer doc.deinit();
        var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
        defer primitive.deinit(testing.allocator);
        try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, primitive.indices);
    }

    // Index 3 is inside the accessor and outside the vertex array. The document
    // parser cannot see it: its checks are about where bytes are, not what they
    // address.
    var doc = try load(text, &(positions ++ bad ++ [_]u8{ 0, 0 }));
    defer doc.deinit();
    try testing.expectError(
        error.VertexIndexOutOfRange,
        mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]),
    );
}

test "mesh parser: morph deltas interleave with the target index varying fastest" {
    // Two vertices, two targets. Target 0 carries positions and normals, target
    // 1 carries positions only, so the zero fill is what the second target's
    // normals must be.
    //
    // The base primitive declares NORMAL, and that is load-bearing rather than
    // decoration: section 3.7.2.1 makes a base without normals a primitive
    // whose targets are given calculated flat normals, so a supplied delta
    // would not survive to be read here. Accessor 2 serves as both.
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0 });
    const target0_positions = floats(&.{ 1, 0, 0, 2, 0, 0 });
    const target0_normals = floats(&.{ 0, 1, 0, 0, 2, 0 });
    const target1_positions = floats(&.{ 0, 0, 3, 0, 0, 4 });
    const bytes = positions ++ target0_positions ++ target0_normals ++ target1_positions;

    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":96,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":24},
        \\                {"buffer":0,"byteOffset":24,"byteLength":24},
        \\                {"buffer":0,"byteOffset":48,"byteLength":24},
        \\                {"buffer":0,"byteOffset":72,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"},
        \\              {"bufferView":2,"componentType":5126,"count":2,"type":"VEC3"},
        \\              {"bufferView":3,"componentType":5126,"count":2,"type":"VEC3"}],
        \\ "meshes":[{"weights":[0.5,0.25],
        \\            "primitives":[{"attributes":{"POSITION":0,"NORMAL":2},
        \\                           "targets":[{"POSITION":1,"NORMAL":2},{"POSITION":3}]}]}]}
    , &bytes);
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    const morph = primitive.morph orelse return error.TestExpectedMorph;
    try testing.expectEqual(@as(u32, 2), morph.target_count);
    // Element v * target_count + t, three floats each: vertex 0 target 0, then
    // vertex 0 target 1, then vertex 1 target 0, then vertex 1 target 1.
    try testing.expectEqualSlices(f32, &.{
        1, 0, 0, 0, 0, 3,
        2, 0, 0, 0, 0, 4,
    }, morph.positions);
    try testing.expectEqualSlices(f32, &.{
        0, 1, 0, 0, 0, 0,
        0, 2, 0, 0, 0, 0,
    }, morph.normals);

    // The mesh declares weights and they are not folded in: the rest pose is
    // what the accessor holds, and whoever poses the mesh applies the weights.
    try expectVec3(.{ 0, 0, 0 }, primitive.vertices[0].position);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, doc.meshes[0].weights);
}

// One triangle in the XY plane with the UV axes swapped relative to the
// position axes, so the generated tangent is neither the placeholder nor the
// position edge and the handedness is negative.
const tangent_source =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"byteLength":96,"uri":"b.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteLength":36},
    \\                {"buffer":0,"byteOffset":36,"byteLength":36},
    \\                {"buffer":0,"byteOffset":72,"byteLength":24}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
    \\              {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
    \\              {"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"}],
    \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2}}]}]}
;

test "mesh parser: a missing tangent basis is generated from the UV gradient" {
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 });
    const normals = floats(&.{ 0, 0, 1, 0, 0, 1, 0, 0, 1 });
    // u runs along +Y and v along +X, the transpose of the position edges.
    const uvs = floats(&.{ 0, 0, 0, 1, 1, 0 });
    var doc = try load(tangent_source, &(positions ++ normals ++ uvs));
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    for (primitive.vertices) |vertex|
        try expectVec4(.{ 0, 1, 0, -1 }, vertex.tangent);
}

// A supplied tangent pointing along its own normal. The projection that makes
// the basis orthogonal takes it to exactly zero, which has no direction left in
// it, so the substitute is used and the file's handedness is kept. The Khronos
// Sponza carries vertices shaped exactly like this; copied through, the shader
// normalizes that zero into a NaN and the frame carries it.
test "mesh parser: a supplied tangent parallel to its normal is replaced" {
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 });
    const normals = floats(&.{ 0, 0, 1, 0, 0, 1, 0, 0, 1 });
    const uvs = floats(&.{ 0, 0, 0, 1, 1, 0 });
    const tangents = floats(&.{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1 });

    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":144,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":36},
        \\                {"buffer":0,"byteOffset":36,"byteLength":36},
        \\                {"buffer":0,"byteOffset":72,"byteLength":24},
        \\                {"buffer":0,"byteOffset":96,"byteLength":48}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
        \\              {"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"},
        \\              {"bufferView":3,"componentType":5126,"count":3,"type":"VEC4"}],
        \\ "meshes":[{"primitives":[{"attributes":
        \\   {"POSITION":0,"NORMAL":1,"TEXCOORD_0":2,"TANGENT":3}}]}]}
    , &(positions ++ normals ++ uvs ++ tangents));
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    for (primitive.vertices) |vertex| {
        try expectVec4(.{ 1, 0, 0, 1 }, vertex.tangent);
        // The property the picture depends on, stated rather than implied by
        // the value above: finite, unit length, and orthogonal to the normal.
        const t: @Vector(3, f32) = .{ vertex.tangent[0], vertex.tangent[1], vertex.tangent[2] };
        try testing.expect(std.math.isFinite(t[0]) and std.math.isFinite(t[1]) and std.math.isFinite(t[2]));
        try testing.expectApproxEqAbs(1.0, @sqrt(@reduce(.Add, t * t)), 1e-6);
        try testing.expectApproxEqAbs(0.0, @reduce(.Add, t * vertex.normal), 1e-6);
    }
}

test "mesh parser: a usable declared tangent is kept as it stands" {
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 });
    const normals = floats(&.{ 0, 0, 1, 0, 0, 1, 0, 0, 1 });
    const uvs = floats(&.{ 0, 0, 0, 1, 1, 0 });
    const tangents = floats(&.{ 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1 });

    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":144,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":36},
        \\                {"buffer":0,"byteOffset":36,"byteLength":36},
        \\                {"buffer":0,"byteOffset":72,"byteLength":24},
        \\                {"buffer":0,"byteOffset":96,"byteLength":48}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
        \\              {"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"},
        \\              {"bufferView":3,"componentType":5126,"count":3,"type":"VEC4"}],
        \\ "meshes":[{"primitives":[{"attributes":
        \\   {"POSITION":0,"NORMAL":1,"TEXCOORD_0":2,"TANGENT":3}}]}]}
    , &(positions ++ normals ++ uvs ++ tangents));
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    // The UV gradient above would have produced (0, 1, 0, -1), so this also
    // shows the generator did not run.
    for (primitive.vertices) |vertex|
        try expectVec4(.{ 1, 0, 0, 1 }, vertex.tangent);
}

test "mesh parser: a vanishing UV gradient still leaves an orthogonal tangent" {
    const positions = floats(&.{ 0, 0, 0, 0, 1, 0, 0, 0, 1 });
    const normals = floats(&.{ 1, 0, 0, 1, 0, 0, 1, 0, 0 });
    // Every UV equal collapses the gradient, so the basis falls back to an axis
    // orthogonal to the normal rather than to a zero tangent a shader would
    // normalize into NaN.
    const uvs = floats(&.{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 });
    var doc = try load(tangent_source, &(positions ++ normals ++ uvs));
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    for (primitive.vertices) |vertex|
        try expectVec4(.{ 0, 1, 0, 1 }, vertex.tangent);
}

test "mesh parser: every allocation failure is propagated and nothing leaks" {
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 });
    const normals = floats(&.{ 0, 0, 1, 0, 0, 1, 0, 0, 1 });
    const uvs = floats(&.{ 0, 0, 0, 1, 1, 0 });
    const bytes = positions ++ normals ++ uvs;

    var doc = try load(tangent_source, &bytes);
    defer doc.deinit();

    var index: usize = 0;
    while (true) : (index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = index });
        if (mesh_parser.parsePrimitive(failing.allocator(), &doc, doc.meshes[0].primitives[0])) |value| {
            var primitive = value;
            primitive.deinit(failing.allocator());
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(index > 0);
}

test "mesh parser: a primitive with no normals is split per face and given flat ones" {
    // Two triangles sharing an edge and lying in different planes: 0,1,2 in the
    // xy plane and 0,2,3 in the yz plane. Vertices 0 and 2 belong to both, and
    // no single normal is right for them, which is the whole reason the
    // geometry is expanded rather than annotated.
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 });
    const indices = shorts(&.{ 0, 1, 2, 0, 2, 3 });

    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":60,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":48},
        \\                {"buffer":0,"byteOffset":48,"byteLength":12}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}]}
    , &(positions ++ indices));
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    // One vertex per corner, and the index list is the identity that leaves.
    try testing.expectEqual(@as(usize, 6), primitive.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, primitive.indices);

    // The first face is wound counter-clockwise seen from +z and the second
    // from +x, which is what the two cross products give.
    for (primitive.vertices[0..3]) |vertex| try expectVec3(.{ 0, 0, 1 }, vertex.normal);
    for (primitive.vertices[3..6]) |vertex| try expectVec3(.{ 1, 0, 0 }, vertex.normal);

    // Corners 0 and 3 are the same source vertex carrying two different
    // normals, which an unsplit list could not express.
    try expectVec3(.{ 0, 0, 0 }, primitive.vertices[0].position);
    try expectVec3(.{ 0, 0, 0 }, primitive.vertices[3].position);
}

test "mesh parser: a morph target of a primitive with no normals gets flat ones" {
    // Section 3.7.2.1: where the base primitive specifies no normals, flat
    // normals are calculated for each morph target too, from that target's
    // displaced geometry. One triangle in the xy plane whose target swings its
    // third corner from +y round to +z, so the displaced face lies in another
    // plane and its normal is not the base's.
    const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 });
    // Only the third corner moves, from (0, 1, 0) to (0, 0, 1).
    const target = floats(&.{ 0, 0, 0, 0, 0, 0, 0, -1, 1 });

    var doc = try load(
        \\{"asset":{"version":"2.0"},
        \\ "buffers":[{"byteLength":72,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":36},
        \\                {"buffer":0,"byteOffset":36,"byteLength":36}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\              {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},
        \\                           "targets":[{"POSITION":1}]}]}]}
    , &(positions ++ target));
    defer doc.deinit();

    var primitive = try mesh_parser.parsePrimitive(testing.allocator, &doc, doc.meshes[0].primitives[0]);
    defer primitive.deinit(testing.allocator);

    const morph = primitive.morph orelse return error.TestExpectedMorph;
    try testing.expectEqual(@as(usize, 9), morph.normals.len);

    // The corner moves from (0, 1, 0) to (0, 0, 1), which lays the triangle in
    // the xz plane: the base face points along +z and the displaced one along
    // -y, so the delta the prepass adds is their difference.
    for (primitive.vertices) |vertex| try expectVec3(.{ 0, 0, 1 }, vertex.normal);
    for (0..3) |corner| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), morph.normals[corner * 3 + 0], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, -1.0), morph.normals[corner * 3 + 1], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, -1.0), morph.normals[corner * 3 + 2], 1e-5);
    }
}
