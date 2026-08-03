const std = @import("std");
const zm = @import("zmath");

const gltf = @import("lenore-gltf");
const resources = @import("lenore-resources");
const document = gltf.document;
const dynamic_nodes = gltf.dynamic_nodes;
const scene_graph = gltf.scene_graph;

const testing = std.testing;

// Collects what the walk reports, in visit order, and optionally stops
// descending at one node so the pruning path is exercised.
const Collector = struct {
    nodes: std.ArrayList(scene_graph.Node) = .empty,
    allocator: std.mem.Allocator,
    prune: ?u32 = null,

    pub fn visit(self: *Collector, node: scene_graph.Node) !bool {
        try self.nodes.append(self.allocator, node);
        return node.index != self.prune;
    }

    fn deinit(self: *Collector) void {
        self.nodes.deinit(self.allocator);
    }
};

fn parse(text: []const u8) !document.Document {
    return document.Document.initJson(testing.allocator, text);
}

fn expectVec(expected: [4]f32, actual: zm.Vec) !void {
    inline for (0..4) |lane|
        try testing.expectApproxEqAbs(expected[lane], actual[lane], 1e-5);
}

fn expectVec3(expected: [3]f32, actual: resources.Vec3) !void {
    inline for (0..3) |lane|
        try testing.expectApproxEqAbs(expected[lane], actual[lane], 1e-5);
}

// A quarter turn about +Z, which sends +X to +Y.
const quarter_turn_z = "[0,0,0.70710678,0.70710678]";

// 0 -> 1 -> 2, with a rotation at the top. Translations alone would commute, so
// a chain of them cannot tell the composition order from its reverse, and the
// order is the one thing this walk has to get right.
const chain =
    \\{"asset":{"version":"2.0"},
    \\ "nodes":[{"children":[1],"rotation":
++ quarter_turn_z ++
    \\ },
    \\          {"children":[2],"translation":[10,0,0]},
    \\          {"translation":[0,0,10],"mesh":0}],
    \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
    \\ "buffers":[{"byteLength":12,"uri":"b.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteLength":12}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":1,"type":"VEC3"}],
    \\ "scenes":[{"nodes":[0]}]}
;

test "scene graph: a walk accumulates every ancestor transform" {
    var doc = try parse(chain);
    defer doc.deinit();

    var collector: Collector = .{ .allocator = testing.allocator };
    defer collector.deinit();
    try scene_graph.traverse(&doc, 0, null, &collector);

    // Node 1 sits ten along its own +X, which the parent's quarter turn carries
    // to +Y. Composing the other way round would leave it at (10, 0, 0), which
    // is what the reverse order produces and what a chain of translations alone
    // could not have distinguished.
    try testing.expectEqual(@as(usize, 3), collector.nodes.items.len);
    try expectVec(.{ 0, 0, 0, 1 }, collector.nodes.items[0].world[3]);
    try expectVec(.{ 0, 10, 0, 1 }, collector.nodes.items[1].world[3]);
    try expectVec(.{ 0, 10, 10, 1 }, collector.nodes.items[2].world[3]);

    // With no animation nothing is anchored, so the relative transform is the
    // world transform and baking either gives the same geometry.
    for (collector.nodes.items) |node| {
        try testing.expectEqual(@as(?u32, null), node.anchor);
        try expectVec(node.world[3], node.relative[3]);
    }
    try testing.expectEqual(@as(?u32, 0), collector.nodes.items[2].mesh);
    try testing.expectEqual(@as(?u32, null), collector.nodes.items[0].mesh);
}

test "scene graph: a visitor declining to descend prunes the subtree" {
    var doc = try parse(chain);
    defer doc.deinit();

    var collector: Collector = .{ .allocator = testing.allocator, .prune = 1 };
    defer collector.deinit();
    try scene_graph.traverse(&doc, 0, null, &collector);

    try testing.expectEqual(@as(usize, 2), collector.nodes.items.len);
    try testing.expectEqual(@as(u32, 1), collector.nodes.items[1].index);
}

test "scene graph: a scene index outside the document is an error" {
    var doc = try parse(chain);
    defer doc.deinit();

    var collector: Collector = .{ .allocator = testing.allocator };
    defer collector.deinit();
    try testing.expectError(
        error.IndexOutOfRange,
        scene_graph.traverse(&doc, 1, null, &collector),
    );
}

test "scene graph: an anchor splits the world transform from the baked one" {
    // 0 static -> 1 driven by a two-key channel -> 2 turned -> 3 offset. The
    // rotation at node 2 is what makes the relative chain non-commutative, so
    // composing it in the wrong order is visible at node 3.
    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "nodes":[{"children":[1],"translation":[10,0,0]},
        \\          {"children":[2]},
        \\          {"children":[3],"rotation":
    ++ quarter_turn_z ++
        \\ },
        \\          {"translation":[10,0,0]}],
        \\ "buffers":[{"byteLength":32,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":8},{"buffer":0,"byteOffset":8,"byteLength":24}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},
        \\              {"bufferView":1,"componentType":5126,"count":2,"type":"VEC3"}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":1}],
        \\                "channels":[{"sampler":0,"target":{"node":1,"path":"translation"}}]}]}
    );
    defer doc.deinit();
    const bytes: [32]u8 = @splat(0);
    try doc.attachBuffers(&.{&bytes});

    var info = try dynamic_nodes.collect(testing.allocator, &doc);
    defer info.deinit(testing.allocator);

    var collector: Collector = .{ .allocator = testing.allocator };
    defer collector.deinit();
    try scene_graph.traverse(&doc, 0, &info, &collector);

    const above = collector.nodes.items[0];
    const anchor = collector.nodes.items[1];
    const turned = collector.nodes.items[2];
    const offset = collector.nodes.items[3];

    // Above the anchor nothing changed.
    try testing.expectEqual(@as(?u32, null), above.anchor);
    try expectVec(.{ 10, 0, 0, 1 }, above.relative[3]);

    // The anchor itself bakes to identity: its own transform is what the
    // animator writes every frame, so baking it in would apply it twice.
    try testing.expectEqual(@as(?u32, 1), anchor.anchor);
    try expectVec(.{ 10, 0, 0, 1 }, anchor.world[3]);
    try expectVec(.{ 0, 0, 0, 1 }, anchor.relative[3]);

    // Below it the baked transform is measured from the anchor and the world one
    // still names the whole chain. Node 3 sits ten along its own +X, which node
    // 2's quarter turn carries to +Y, so the relative offset is (0, 10, 0) and
    // the world position adds node 0's ten along +X.
    try testing.expectEqual(@as(?u32, 1), turned.anchor);
    try testing.expectEqual(@as(?u32, 1), offset.anchor);
    try expectVec(.{ 10, 10, 0, 1 }, offset.world[3]);
    try expectVec(.{ 0, 10, 0, 1 }, offset.relative[3]);
}

test "scene graph: a held pose is folded into a static node's transform" {
    // One clip, one single-key channel on node 0. dynamic_nodes folds it rather
    // than slotting the node, and the walk has to apply it: the node's own
    // translation is (10, 0, 0) and the held one replaces it.
    var doc = try parse(
        \\{"asset":{"version":"2.0"},
        \\ "nodes":[{"translation":[10,0,0]}],
        \\ "buffers":[{"byteLength":16,"uri":"b.bin"}],
        \\ "bufferViews":[{"buffer":0,"byteLength":4},{"buffer":0,"byteOffset":4,"byteLength":12}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":1,"type":"SCALAR"},
        \\              {"bufferView":1,"componentType":5126,"count":1,"type":"VEC3"}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":0,"output":1}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer doc.deinit();

    var bytes: [16]u8 = @splat(0);
    inline for (.{ 1.0, 2.0, 3.0 }, 0..) |value, index| {
        const element: f32 = value;
        @memcpy(bytes[4 + index * 4 ..][0..4], std.mem.asBytes(&element));
    }
    try doc.attachBuffers(&.{&bytes});

    var info = try dynamic_nodes.collect(testing.allocator, &doc);
    defer info.deinit(testing.allocator);

    var collector: Collector = .{ .allocator = testing.allocator };
    defer collector.deinit();
    try scene_graph.traverse(&doc, 0, &info, &collector);

    try testing.expectEqual(@as(?u32, null), collector.nodes.items[0].anchor);
    try expectVec(.{ 1, 2, 3, 1 }, collector.nodes.items[0].world[3]);
}

test "scene graph: a normal keeps its surface under non-uniform scale" {
    const matrix = zm.scaling(2.0, 1.0, 1.0);

    // A surface through the origin whose normal is (1, 1, 0) has (1, -1, 0)
    // lying in it. Stretching x doubles both, and only one of the two ways to
    // carry the normal keeps them perpendicular.
    const along = scene_graph.transformDirection(.{ 1, -1, 0 }, matrix);
    const plain = scene_graph.transformDirection(.{ 1, 1, 0 }, matrix);
    const correct = scene_graph.transformDirection(.{ 1, 1, 0 }, scene_graph.normalMatrix(matrix));

    try testing.expectApproxEqAbs(@as(f32, 0.0), @reduce(.Add, correct * along), 1e-5);
    try testing.expect(@abs(@reduce(.Add, plain * along)) > 0.5);

    // The inverse transpose of a diagonal scale is the reciprocal scale, so the
    // normal leans the other way from the surface.
    try expectVec3(.{ 0.44721, 0.89443, 0.0 }, correct);
    try expectVec3(.{ 0.89443, 0.44721, 0.0 }, plain);

    // A diagonal matrix is its own transpose, so the case above cannot tell the
    // inverse transpose from the plain inverse. A scale composed with a rotation
    // can, and it is the ordinary case in a scene graph.
    const turned = zm.mul(matrix, zm.rotationZ(0.7));
    const turned_along = scene_graph.transformDirection(.{ 1, -1, 0 }, turned);
    const turned_normal = scene_graph.transformDirection(.{ 1, 1, 0 }, scene_graph.normalMatrix(turned));
    const without_transpose = scene_graph.transformDirection(.{ 1, 1, 0 }, zm.inverse(turned));

    try testing.expectApproxEqAbs(@as(f32, 0.0), @reduce(.Add, turned_normal * turned_along), 1e-5);
    try testing.expect(@abs(@reduce(.Add, without_transpose * turned_along)) > 0.1);
}

test "scene graph: a position takes the translation and a direction does not" {
    const matrix = zm.mul(zm.scaling(2.0, 2.0, 2.0), zm.translation(1.0, 2.0, 3.0));

    try expectVec3(.{ 3, 2, 3 }, scene_graph.transformPosition(.{ 1, 0, 0 }, matrix));
    try expectVec3(.{ 1, 0, 0 }, scene_graph.transformDirection(.{ 1, 0, 0 }, matrix));
}

test "scene graph: a tangent carries its handedness through untouched" {
    const matrix = zm.mul(zm.scaling(2.0, 1.0, 1.0), zm.translation(5.0, 0.0, 0.0));
    const carried = scene_graph.transformTangent(.{ 0, 1, 0, -1 }, matrix);

    try testing.expectApproxEqAbs(@as(f32, 0.0), carried[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), carried[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1.0), carried[3], 1e-5);
}
