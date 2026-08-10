const std = @import("std");
const zm = @import("zmath");

const gltf = @import("lenore-gltf");
const resources = @import("lenore-resources");
const animation_parser = gltf.animation_parser;
const document = gltf.document;

const testing = std.testing;
const no_parent = resources.no_parent;

fn floats(comptime values: []const f32) [values.len * 4]u8 {
    var bytes: [values.len * 4]u8 = undefined;
    for (values, 0..) |value, index| {
        const element: f32 = value;
        @memcpy(bytes[index * 4 ..][0..4], std.mem.asBytes(&element));
    }
    return bytes;
}

// Accessors in the order the pieces are concatenated:
//
//   0 two_times    1 one_time      2 two_vec3     3 two_vec4
//   4 spline_vec3  5 two_matrices  6 four_scalars 7 one_vec3
//   8 six_scalars  9 spline_vec4
const two_times = floats(&.{ 0.0, 1.0 });
const one_time = floats(&.{0.0});
const two_vec3 = floats(&.{ 1.0, 0.0, 0.0, 2.0, 0.0, 0.0 });
const two_vec4 = floats(&.{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0 });
const spline_vec3 = floats(&.{ 9.0, 9.0, 9.0, 4.0, 5.0, 6.0, 8.0, 8.0, 8.0 });
// Two MAT4, column-major: identity, then identity with translation (5, 6, 7).
const two_matrices = floats(&.{
    1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
    1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 5.0, 6.0, 7.0, 1.0,
});
const four_scalars = floats(&.{ 0.1, 0.2, 0.3, 0.4 });
const one_vec3 = floats(&.{ 0.0, 0.0, 0.0 });
// One cubic spline key of two morph weights: in-tangent, value, out-tangent.
const six_scalars = floats(&.{ 9.0, 9.0, 0.5, 0.6, 8.0, 8.0 });
// One cubic spline rotation key, the same way. All four components of a
// quaternion tangent are real, so none of these is a placeholder.
const spline_vec4 = floats(&.{
    1.0, 2.0, 3.0, 4.0,
    0.0, 0.0, 0.0, 1.0,
    5.0, 6.0, 7.0, 8.0,
});

const samples = two_times ++ one_time ++ two_vec3 ++ two_vec4 ++
    spline_vec3 ++ two_matrices ++ four_scalars ++ one_vec3 ++ six_scalars ++
    spline_vec4;

const prelude =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"byteLength":332,"uri":"a.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":8},
    \\                {"buffer":0,"byteOffset":8,"byteLength":4},
    \\                {"buffer":0,"byteOffset":12,"byteLength":24},
    \\                {"buffer":0,"byteOffset":36,"byteLength":32},
    \\                {"buffer":0,"byteOffset":68,"byteLength":36},
    \\                {"buffer":0,"byteOffset":104,"byteLength":128},
    \\                {"buffer":0,"byteOffset":232,"byteLength":16},
    \\                {"buffer":0,"byteOffset":248,"byteLength":12},
    \\                {"buffer":0,"byteOffset":260,"byteLength":24},
    \\                {"buffer":0,"byteOffset":284,"byteLength":48}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},
    \\              {"bufferView":1,"componentType":5126,"count":1,"type":"SCALAR"},
    \\              {"bufferView":2,"componentType":5126,"count":2,"type":"VEC3"},
    \\              {"bufferView":3,"componentType":5126,"count":2,"type":"VEC4"},
    \\              {"bufferView":4,"componentType":5126,"count":3,"type":"VEC3"},
    \\              {"bufferView":5,"componentType":5126,"count":2,"type":"MAT4"},
    \\              {"bufferView":6,"componentType":5126,"count":4,"type":"SCALAR"},
    \\              {"bufferView":7,"componentType":5126,"count":1,"type":"VEC3"},
    \\              {"bufferView":8,"componentType":5126,"count":6,"type":"SCALAR"},
    \\              {"bufferView":9,"componentType":5126,"count":3,"type":"VEC4"}],
;

fn load(comptime body: []const u8) !document.Document {
    var doc = try document.Document.initJson(testing.allocator, prelude ++ body);
    errdefer doc.deinit();
    try doc.attachBuffers(&.{&samples});
    return doc;
}

fn expectVec(expected: [4]f32, actual: zm.Vec) !void {
    inline for (0..4) |lane|
        try testing.expectApproxEqAbs(expected[lane], actual[lane], 1e-6);
}

// Two joints, one the child of the other, with inverse bind matrices.
const chain_skin =
    \\ "nodes":[{"children":[1],"translation":[10,0,0]},{"translation":[0,1,0]}],
    \\ "scenes":[{"nodes":[0]}],
    \\ "skins":[{"joints":[0,1],"inverseBindMatrices":5}]}
;

test "animation parser: a skin becomes slots in topological order" {
    var doc = try load(chain_skin);
    defer doc.deinit();

    var hierarchy = (try animation_parser.buildJointHierarchy(testing.allocator, &doc, 0)).?;
    defer hierarchy.deinit(testing.allocator);

    try testing.expectEqualSlices(resources.Slot, &.{ no_parent, 0 }, hierarchy.slot_parent);
    try testing.expectEqualSlices(u16, &.{ 0, 1 }, hierarchy.joint_slot);
    try expectVec(.{ 10, 0, 0, 1 }, hierarchy.bind_translations[0]);
    try expectVec(.{ 0, 1, 0, 1 }, hierarchy.bind_translations[1]);

    // Section 5.28.2 stores each matrix column-major, so the translation of the
    // second one lands in the last row once read as zmath holds it.
    try expectVec(.{ 0, 0, 0, 1 }, hierarchy.inverse_bind[0][3]);
    try expectVec(.{ 5, 6, 7, 1 }, hierarchy.inverse_bind[1][3]);

    // A root slot folds in the chain above it, and there is none here.
    try expectVec(.{ 0, 0, 0, 1 }, hierarchy.slot_prefix[0][3]);
    // An interior slot receives that chain through its parent instead.
    try expectVec(.{ 0, 0, 0, 1 }, hierarchy.slot_prefix[1][3]);
}

test "animation parser: an index naming no skin is not a skeleton" {
    var doc = try load(chain_skin);
    defer doc.deinit();
    try testing.expectEqual(
        @as(?animation_parser.JointHierarchy, null),
        try animation_parser.buildJointHierarchy(testing.allocator, &doc, 1),
    );
}

test "animation parser: a helper node between two joints keeps its slot" {
    // 0 and 2 are joints, 1 is not. Dropping node 1 would freeze node 2, because
    // an exporter puts its scale compensation or orientation there.
    var doc = try load(
        \\ "nodes":[{"children":[1]},{"children":[2],"translation":[0,2,0]},{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "skins":[{"joints":[0,2]}]}
    );
    defer doc.deinit();

    var hierarchy = (try animation_parser.buildJointHierarchy(testing.allocator, &doc, 0)).?;
    defer hierarchy.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), hierarchy.slot_parent.len);
    try testing.expectEqualSlices(resources.Slot, &.{ no_parent, 0, 1 }, hierarchy.slot_parent);
    try testing.expectEqualSlices(u16, &.{ 0, 2 }, hierarchy.joint_slot);
    try expectVec(.{ 0, 2, 0, 1 }, hierarchy.bind_translations[1]);
    // Without inverseBindMatrices every joint binds at identity.
    try expectVec(.{ 0, 0, 0, 1 }, hierarchy.inverse_bind[0][3]);
}

test "animation parser: a joint above the joint set is a static prefix" {
    // Node 0 is not a joint and has no joint ancestor, so it is not a slot. Its
    // transform reaches the skeleton as the root slot's prefix.
    var doc = try load(
        \\ "nodes":[{"children":[1],"translation":[10,0,0]},{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "skins":[{"joints":[1]}]}
    );
    defer doc.deinit();

    var hierarchy = (try animation_parser.buildJointHierarchy(testing.allocator, &doc, 0)).?;
    defer hierarchy.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), hierarchy.slot_parent.len);
    try expectVec(.{ 10, 0, 0, 1 }, hierarchy.slot_prefix[0][3]);
}

test "animation parser: a skeleton template validates its own topology" {
    var doc = try load(chain_skin);
    defer doc.deinit();

    var template = (try animation_parser.parseSkeletonTemplate(testing.allocator, &doc, 0)).?;
    defer template.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), template.slotCount());
    try testing.expectEqual(@as(usize, 2), template.jointCount());
}

test "animation parser: a clip is rebased onto slots and unmapped channels drop" {
    var doc = try load(
        \\ "nodes":[{"children":[1]},{},{}],
        \\ "scenes":[{"nodes":[0,2]}],
        \\ "animations":[{"samplers":[{"input":0,"output":2},{"input":0,"output":3}],
        \\                "channels":[{"sampler":0,"target":{"node":1,"path":"translation"}},
        \\                            {"sampler":1,"target":{"node":1,"path":"rotation"}},
        \\                            {"sampler":0,"target":{"node":2,"path":"scale"}}]}]}
    );
    defer doc.deinit();

    // Node 1 is slot 3, node 0 and node 2 have none.
    const node_to_slot = [_]?resources.Slot{ null, 3, null };
    var clip = try animation_parser.parseClip(testing.allocator, &doc, 0, &node_to_slot);
    defer clip.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), clip.channels.len);
    try testing.expectEqual(@as(u32, 3), clip.channels[0].target_slot);
    try testing.expectEqual(@as(u64, 4), clip.slot_count);
    try testing.expectEqual(@as(f32, 0.0), clip.start_time);
    try testing.expectEqual(@as(f32, 1.0), clip.duration);

    // The track's tag is the path, and it carries that path's keys and no other.
    const translation = clip.channels[0].track.translation;
    try testing.expectEqual(@as(usize, 2), translation.keys.len);
    try expectVec(.{ 1, 0, 0, 1 }, translation.keys[0].value);
    try expectVec(.{ 2, 0, 0, 1 }, translation.keys[1].value);
    try testing.expectEqual(@as(f32, 1.0), translation.keys[1].time);
    try expectVec(.{ 0, 0, 0, 1 }, clip.channels[1].track.rotation.keys[0].value);

    // A sampler that declared no interpolation is LINEAR, and a linear track
    // carries no tangents to be read.
    try testing.expectEqual(resources.Interpolation.linear, translation.blend);
}

test "animation parser: a cubic spline track keeps the value and both tangents" {
    var doc = try load(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":4,"interpolation":"CUBICSPLINE"}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer doc.deinit();

    const node_to_slot = [_]?resources.Slot{0};
    var clip = try animation_parser.parseClip(testing.allocator, &doc, 0, &node_to_slot);
    defer clip.deinit(testing.allocator);

    // The output holds in-tangent, value, out-tangent per key. Taking element
    // zero would give (9, 9, 9).
    const track = clip.channels[0].track.translation;
    try testing.expectEqual(@as(usize, 1), track.keys.len);
    try expectVec(.{ 4, 5, 6, 1 }, track.keys[0].value);

    // The tangents are the elements either side of it, and they are read into
    // the mode rather than beside it: a track sampled as a spline cannot be
    // missing them. Their w is zero because they are derivatives and not points.
    const tangents = track.blend.cubicspline;
    try testing.expectEqual(@as(usize, 1), tangents.len);
    try expectVec(.{ 9, 9, 9, 0 }, tangents[0].in);
    try expectVec(.{ 8, 8, 8, 0 }, tangents[0].out);
    try testing.expectEqual(resources.Interpolation.cubicspline, clip.channels[0].track.interpolation());
}

const morph_document =
    \\ "nodes":[{"mesh":0}],
    \\ "scenes":[{"nodes":[0]}],
    \\ "meshes":[{"primitives":[{"attributes":{"POSITION":7},
    \\                           "targets":[{"POSITION":7},{"POSITION":7}]}]}],
    \\ "animations":[{"samplers":[{"input":0,"output":6}],
    \\                "channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}]}
;

test "animation parser: morph weights come back one vector per key" {
    var doc = try load(morph_document);
    defer doc.deinit();

    var parsed = (try animation_parser.parseMorphWeights(testing.allocator, &doc, 0, 0)).?;
    defer parsed.animation.deinit(testing.allocator);

    // Two keys of two targets each, the target index varying fastest.
    try testing.expectEqual(@as(u32, 2), parsed.target_count);
    const track = parsed.animation.channels[0].track.weights;
    try testing.expectEqual(@as(u32, 2), track.width);
    try testing.expectEqualSlices(f32, &.{ 0.0, 1.0 }, track.times);
    try testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0.4 }, track.values);
}

test "animation parser: a cubic spline weight key keeps the value and both tangents" {
    var doc = try load(
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":7},
        \\                           "targets":[{"POSITION":7},{"POSITION":7}]}]}],
        \\ "animations":[{"samplers":[{"input":1,"output":8,"interpolation":"CUBICSPLINE"}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}]}
    );
    defer doc.deinit();

    var parsed = (try animation_parser.parseMorphWeights(testing.allocator, &doc, 0, 0)).?;
    defer parsed.animation.deinit(testing.allocator);

    // One key of two targets. The file interleaves in-tangent, value and
    // out-tangent per key, so taking the first run of the three would give
    // (9, 9) for the values.
    const track = parsed.animation.channels[0].track.weights;
    try testing.expectEqual(@as(u32, 2), track.width);
    try testing.expectEqualSlices(f32, &.{0.0}, track.times);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.6 }, track.values);

    // The tangents are compacted into their own array, in-run then out-run per
    // key, which is the layout the sampler indexes them by.
    try testing.expectEqualSlices(
        f32,
        &.{ 9.0, 9.0, 8.0, 8.0 },
        track.blend.cubicspline,
    );
}

test "animation parser: a weights channel for another node is not this node's" {
    var doc = try load(morph_document);
    defer doc.deinit();
    try testing.expectEqual(
        @as(?animation_parser.WeightsClip, null),
        try animation_parser.parseMorphWeights(testing.allocator, &doc, 0, 1),
    );
}

test "animation parser: a weights channel is not a transform channel" {
    var doc = try load(morph_document);
    defer doc.deinit();

    const node_to_slot = [_]?resources.Slot{0};
    var clip = try animation_parser.parseClip(testing.allocator, &doc, 0, &node_to_slot);
    defer clip.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), clip.channels.len);
}

test "animation parser: rigid animation slots only the dynamic nodes" {
    // Node 0 is static and node 1 changes, so there is one slot and node 0's
    // transform reaches it as the prefix rather than as a slot of its own.
    var doc = try load(
        \\ "nodes":[{"children":[1],"translation":[10,0,0]},{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":2},{"input":0,"output":3}],
        \\                "channels":[{"sampler":0,"target":{"node":1,"path":"translation"}},
        \\                            {"sampler":1,"target":{"node":1,"path":"rotation"}}]}]}
    );
    defer doc.deinit();

    var node_to_slot: [2]?resources.Slot = undefined;
    var template = (try animation_parser.parseNodeAnimation(
        testing.allocator,
        &doc,
        &node_to_slot,
    )).?;
    defer template.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), template.slotCount());
    try testing.expectEqualSlices(resources.Slot, &.{no_parent}, template.parent);
    try expectVec(.{ 10, 0, 0, 1 }, template.prefix[0][3]);
    try testing.expectEqual(@as(usize, 1), template.clips.len);
    try testing.expectEqual(@as(usize, 2), template.clips[0].channels.len);

    // Two channels of one node share its slot, and the list holds it once.
    try testing.expectEqualSlices(u16, &.{0}, template.animated_slots[0]);

    // The map is what an importer resolves a mesh's anchor through, and it is
    // the only place the node space and the slot space meet. Node 0 is static
    // and reaches the slot as a prefix, so it earns none of its own.
    try testing.expectEqualSlices(?resources.Slot, &.{ null, 0 }, &node_to_slot);
}

test "animation parser: a document with nothing to drive has no rigid animation" {
    // No clips at all.
    var static_doc = try load(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}]}
    );
    defer static_doc.deinit();
    // Seeded, because a null result still has to leave the map addressable: a
    // caller that kept the previous document's slots would move this document's
    // geometry with them.
    var node_to_slot: [1]?resources.Slot = .{7};
    try testing.expectEqual(
        @as(?resources.NodeTemplate, null),
        try animation_parser.parseNodeAnimation(testing.allocator, &static_doc, &node_to_slot),
    );
    try testing.expectEqual(@as(?resources.Slot, null), node_to_slot[0]);

    // One clip whose only channel holds a single key, so it is folded into the
    // node's transform and earns no slot.
    var held_doc = try load(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":7}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer held_doc.deinit();
    node_to_slot = .{7};
    try testing.expectEqual(
        @as(?resources.NodeTemplate, null),
        try animation_parser.parseNodeAnimation(testing.allocator, &held_doc, &node_to_slot),
    );
    try testing.expectEqual(@as(?resources.Slot, null), node_to_slot[0]);
}

test "animation parser: a scene is chosen when the document names none" {
    // Section 3.5.1 leaves `scene` optional. Five of 355 real documents omit it
    // and two of those are animated, so treating that as nothing to animate
    // would drop their animation.
    var doc = try load(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer doc.deinit();

    var node_to_slot: [1]?resources.Slot = undefined;
    var template = (try animation_parser.parseNodeAnimation(
        testing.allocator,
        &doc,
        &node_to_slot,
    )).?;
    defer template.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), template.slotCount());
}

test "animation parser: every allocation failure is propagated and nothing leaks" {
    var doc = try load(
        \\ "nodes":[{"children":[1],"translation":[10,0,0]},{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "skins":[{"joints":[0,1],"inverseBindMatrices":5}],
        \\ "animations":[{"samplers":[{"input":0,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":1,"path":"translation"}}]}]}
    );
    defer doc.deinit();

    // The map is the caller's storage, so it stays off the failing allocator:
    // the sweep is about what the parser allocates, not about this buffer.
    var node_to_slot: [2]?resources.Slot = undefined;

    var index: usize = 0;
    while (true) : (index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = index });
        if (animation_parser.parseNodeAnimation(failing.allocator(), &doc, &node_to_slot)) |value| {
            var template = value.?;
            template.deinit(failing.allocator());
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(index > 0);

    index = 0;
    while (true) : (index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = index });
        if (animation_parser.parseSkeletonTemplate(failing.allocator(), &doc, 0)) |value| {
            var template = value.?;
            template.deinit(failing.allocator());
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(index > 0);
}

test "animation parser: a rotation spline keeps all four components of its tangents" {
    var doc = try load(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":9,"interpolation":"CUBICSPLINE"}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"rotation"}}]}]}
    );
    defer doc.deinit();

    const node_to_slot = [_]?resources.Slot{0};
    var clip = try animation_parser.parseClip(testing.allocator, &doc, 0, &node_to_slot);
    defer clip.deinit(testing.allocator);

    const track = clip.channels[0].track.rotation;
    try expectVec(.{ 0, 0, 0, 1 }, track.keys[0].value);

    // A quaternion tangent is a derivative in quaternion space and every
    // component of it is real, unlike the vector tangents whose w is zero
    // because they belong to points that carry one.
    const tangents = track.blend.cubicspline;
    try expectVec(.{ 1, 2, 3, 4 }, tangents[0].in);
    try expectVec(.{ 5, 6, 7, 8 }, tangents[0].out);
}
