const std = @import("std");
const zm = @import("zmath");

const gltf = @import("lenore-gltf");
const document = gltf.document;
const dynamic_nodes = gltf.dynamic_nodes;

const testing = std.testing;

fn floats(comptime values: []const f32) [values.len * 4]u8 {
    var bytes: [values.len * 4]u8 = undefined;
    for (values, 0..) |value, index| {
        const element: f32 = value;
        @memcpy(bytes[index * 4 ..][0..4], std.mem.asBytes(&element));
    }
    return bytes;
}

// One buffer serving every case below, as six accessors in the order the pieces
// are concatenated, so a document only names the two it needs per channel:
//
//   0  two_keys           1  one_key            2  two_translations
//   3  one_translation    4  one_rotation       5  one_spline_key
const two_keys = floats(&.{ 0.0, 1.0 });
const one_key = floats(&.{0.0});
const two_translations = floats(&.{ 1.0, 0.0, 0.0, 2.0, 0.0, 0.0 });
const one_translation = floats(&.{ 1.0, 2.0, 3.0 });
const one_rotation = floats(&.{ 0.0, 0.0, 0.0, 1.0 });
const one_spline_key = floats(&.{ 9.0, 9.0, 9.0, 4.0, 5.0, 6.0, 8.0, 8.0, 8.0 });

const samples = two_keys ++ one_key ++ two_translations ++
    one_translation ++ one_rotation ++ one_spline_key;

const prelude =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"byteLength":100,"uri":"a.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":8},
    \\                {"buffer":0,"byteOffset":8,"byteLength":4},
    \\                {"buffer":0,"byteOffset":12,"byteLength":24},
    \\                {"buffer":0,"byteOffset":36,"byteLength":12},
    \\                {"buffer":0,"byteOffset":48,"byteLength":16},
    \\                {"buffer":0,"byteOffset":64,"byteLength":36}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},
    \\              {"bufferView":1,"componentType":5126,"count":1,"type":"SCALAR"},
    \\              {"bufferView":2,"componentType":5126,"count":2,"type":"VEC3"},
    \\              {"bufferView":3,"componentType":5126,"count":1,"type":"VEC3"},
    \\              {"bufferView":4,"componentType":5126,"count":1,"type":"VEC4"},
    \\              {"bufferView":5,"componentType":5126,"count":3,"type":"VEC3"}],
;

fn collect(comptime body: []const u8) !struct {
    doc: document.Document,
    info: dynamic_nodes.DynamicNodes,

    fn deinit(self: *@This()) void {
        self.info.deinit(testing.allocator);
        self.doc.deinit();
    }
} {
    var doc = try document.Document.initJson(testing.allocator, prelude ++ body);
    errdefer doc.deinit();
    try doc.attachBuffers(&.{&samples});
    return .{ .doc = doc, .info = try dynamic_nodes.collect(testing.allocator, &doc) };
}

fn expectSlotted(info: dynamic_nodes.DynamicNodes, expected: []const bool) !void {
    for (expected, 0..) |slotted, node|
        try testing.expectEqual(slotted, info.slotted.isSet(node));
}

test "dynamic nodes: a document with no animations slots nothing" {
    var loaded = try collect(
        \\ "nodes":[{"children":[1]},{}],
        \\ "scenes":[{"nodes":[0]}]}
    );
    defer loaded.deinit();

    try expectSlotted(loaded.info, &.{ false, false });
    for (loaded.info.held) |held| {
        try testing.expectEqual(@as(?zm.Vec, null), held.translation);
        try testing.expectEqual(@as(?zm.Quat, null), held.rotation);
        try testing.expectEqual(@as(?zm.Vec, null), held.scale);
    }
}

test "dynamic nodes: a channel with more than one key slots its target" {
    var loaded = try collect(
        \\ "nodes":[{"children":[1]},{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer loaded.deinit();

    // The child is untargeted and below nothing that changes, so it stays
    // static and gets baked against its parent's slot.
    try expectSlotted(loaded.info, &.{ true, false });
    try testing.expectEqual(@as(?zm.Vec, null), loaded.info.held[0].translation);
}

test "dynamic nodes: a single key channel is held rather than slotted" {
    var loaded = try collect(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":3}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer loaded.deinit();

    try expectSlotted(loaded.info, &.{false});
    const translation = loaded.info.held[0].translation orelse return error.TestExpectedHeld;
    try testing.expectEqual(@as(f32, 1.0), translation[0]);
    try testing.expectEqual(@as(f32, 2.0), translation[1]);
    try testing.expectEqual(@as(f32, 3.0), translation[2]);
    try testing.expectEqual(@as(?zm.Quat, null), loaded.info.held[0].rotation);
}

test "dynamic nodes: a cubic spline key holds its value, not its tangent" {
    var loaded = try collect(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":5,"interpolation":"CUBICSPLINE"}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer loaded.deinit();

    // The output holds in-tangent, value, out-tangent. Reading element zero
    // would give (9, 9, 9).
    const translation = loaded.info.held[0].translation orelse return error.TestExpectedHeld;
    try testing.expectEqual(@as(f32, 4.0), translation[0]);
    try testing.expectEqual(@as(f32, 5.0), translation[1]);
    try testing.expectEqual(@as(f32, 6.0), translation[2]);
}

test "dynamic nodes: a constant link between two changing nodes is slotted" {
    // 0 -> 1 -> {2, 3}. Nodes 0 and 2 change; node 1 is targeted by nothing.
    // It is slotted anyway, because node 2's sampled local transform composes
    // against it every frame, so folding it into geometry would freeze that
    // composition. Node 3 is below nothing that changes and stays static.
    var loaded = try collect(
        \\ "nodes":[{"children":[1]},{"children":[2,3]},{},{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}},
        \\                            {"sampler":0,"target":{"node":2,"path":"translation"}}]}]}
    );
    defer loaded.deinit();

    try expectSlotted(loaded.info, &.{ true, true, true, false });
}

test "dynamic nodes: a changing node above a static subtree does not slot it" {
    // 0 -> 1 -> 2, with only node 0 changing. Neither descendant has anything
    // below it that changes, so both are folded into node 0's slot.
    var loaded = try collect(
        \\ "nodes":[{"children":[1]},{"children":[2]},{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer loaded.deinit();

    try expectSlotted(loaded.info, &.{ true, false, false });
}

test "dynamic nodes: more than one clip turns folding off entirely" {
    // Both channels hold a single key, so with one clip neither node would be
    // slotted. Two clips may hold different poses for the same node, and
    // switching between them has to keep working, so nothing is folded.
    var loaded = try collect(
        \\ "nodes":[{},{}],
        \\ "scenes":[{"nodes":[0,1]}],
        \\ "animations":[{"samplers":[{"input":1,"output":3}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]},
        \\               {"samplers":[{"input":1,"output":4}],
        \\                "channels":[{"sampler":0,"target":{"node":1,"path":"rotation"}}]}]}
    );
    defer loaded.deinit();

    try expectSlotted(loaded.info, &.{ true, true });
    try testing.expectEqual(@as(?zm.Vec, null), loaded.info.held[0].translation);
    try testing.expectEqual(@as(?zm.Quat, null), loaded.info.held[1].rotation);
}

test "dynamic nodes: a slotted node keeps its hold channels in the clip" {
    // Node 0 has a changing translation and a held rotation in the same clip.
    // The rotation must not also be folded in: the clip still applies it, and a
    // folded copy would be applied twice.
    var loaded = try collect(
        \\ "nodes":[{}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":2},{"input":1,"output":4}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}},
        \\                            {"sampler":1,"target":{"node":0,"path":"rotation"}}]}]}
    );
    defer loaded.deinit();

    try expectSlotted(loaded.info, &.{true});
    try testing.expectEqual(@as(?zm.Quat, null), loaded.info.held[0].rotation);
}

test "dynamic nodes: a morph weight channel is not a node transform" {
    // A weights channel deforms the mesh, not the node, so it neither slots the
    // node nor contributes a held pose.
    var loaded = try collect(
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":3},
        \\                           "targets":[{"POSITION":3}]}]}],
        \\ "animations":[{"samplers":[{"input":1,"output":1}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}]}
    );
    defer loaded.deinit();

    try expectSlotted(loaded.info, &.{false});
    try testing.expectEqual(@as(?zm.Vec, null), loaded.info.held[0].translation);

    // The same with two keys, which is what a single key case cannot show: a
    // weights channel that does change over time still leaves the node static.
    var changing = try collect(
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":3},
        \\                           "targets":[{"POSITION":3}]}]}],
        \\ "animations":[{"samplers":[{"input":0,"output":0}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}]}
    );
    defer changing.deinit();

    try expectSlotted(changing.info, &.{false});
}
