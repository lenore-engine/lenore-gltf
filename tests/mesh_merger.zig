const std = @import("std");

const gltf = @import("lenore-gltf");
const resources = @import("lenore-resources");
const mesh_merger = gltf.mesh_merger;

const testing = std.testing;
const Merger = mesh_merger.Merger;

// Vertices are only ever identified by position here: the merger never reads a
// vertex, so the rest of the interchange layout would only make the expectations
// longer.
fn fill(vertices: []resources.Vertex3D, first: f32) void {
    for (vertices, 0..) |*vertex, index| {
        vertex.* = .{
            .position = .{ first + @as(f32, @floatFromInt(index)), 0.0, 0.0 },
            .normal = .{ 0.0, 1.0, 0.0 },
            .uv = .{ 0.0, 0.0 },
            .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
        };
    }
}

fn positions(allocator: std.mem.Allocator, group: mesh_merger.Group) ![]f32 {
    const output = try allocator.alloc(f32, group.vertices.items.len);
    for (group.vertices.items, output) |vertex, *value| value.* = vertex.position[0];
    return output;
}

test "mesh merger: primitives sharing a group concatenate with rebased indices" {
    var merger: Merger = .empty;
    defer merger.deinit(testing.allocator);

    fill(try merger.appendPrimitive(
        testing.allocator,
        null,
        0,
        .{},
        3,
        &.{ 0, 1, 2 },
        .keep,
    ), 1.0);
    fill(try merger.appendPrimitive(
        testing.allocator,
        null,
        0,
        .{},
        2,
        &.{ 1, 0 },
        .keep,
    ), 4.0);

    try testing.expectEqual(@as(usize, 1), merger.groups.count());
    const group = merger.groups.values()[0];

    const merged = try positions(testing.allocator, group);
    defer testing.allocator.free(merged);
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4, 5 }, merged);

    // The second primitive's indices are its own, shifted by the three vertices
    // already in the group.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 4, 3 }, group.indices.items);
}

test "mesh merger: anchor, material and skinning each split a group" {
    var merger: Merger = .empty;
    defer merger.deinit(testing.allocator);

    fill(try merger.appendPrimitive(testing.allocator, null, 0, .{}, 1, &.{0}, .keep), 1.0);
    // A different material renders with a different texture set and cull state.
    fill(try merger.appendPrimitive(testing.allocator, null, 1, .{}, 1, &.{0}, .keep), 2.0);
    // A different anchor moves under a different instance matrix.
    fill(try merger.appendPrimitive(testing.allocator, 7, 0, .{}, 1, &.{0}, .keep), 3.0);
    // No material at all is the default material, not material zero.
    fill(try merger.appendPrimitive(testing.allocator, null, null, .{}, 1, &.{0}, .keep), 4.0);
    // Skinning has no neutral default: merging these two would leave the first
    // primitive's vertices with zero weights, collapsing them onto the origin.
    fill(try merger.appendPrimitive(testing.allocator, null, 0, .{ .skinned = true }, 1, &.{0}, .keep), 5.0);

    try testing.expectEqual(@as(usize, 5), merger.groups.count());
    // Insertion order is iteration order, so the submesh list is the same on
    // every run.
    for (merger.groups.values(), 1..) |group, expected| {
        const merged = try positions(testing.allocator, group);
        defer testing.allocator.free(merged);
        try testing.expectEqualSlices(f32, &.{@floatFromInt(expected)}, merged);
    }

    try testing.expectEqual(mesh_merger.GroupKey{
        .anchor = null,
        .material = 0,
        .skinned = true,
    }, merger.groups.keys()[4]);
}

test "mesh merger: optional streams are the union of the merged primitives" {
    var merger: Merger = .empty;
    defer merger.deinit(testing.allocator);

    fill(try merger.appendPrimitive(testing.allocator, null, 0, .{ .colour = true }, 1, &.{0}, .keep), 1.0);
    fill(try merger.appendPrimitive(testing.allocator, null, 0, .{ .uv1 = true }, 1, &.{0}, .keep), 2.0);
    // Neither stream, and the group keeps both: this primitive contributes the
    // interchange defaults, which are white and (0, 0).
    fill(try merger.appendPrimitive(testing.allocator, null, 0, .{}, 1, &.{0}, .keep), 3.0);

    try testing.expectEqual(@as(usize, 1), merger.groups.count());
    const streams = merger.groups.values()[0].streams;
    try testing.expect(streams.colour);
    try testing.expect(streams.uv1);
    try testing.expect(!streams.skinned);
}

test "mesh merger: an index outside its own primitive is refused" {
    var merger: Merger = .empty;
    defer merger.deinit(testing.allocator);

    fill(try merger.appendPrimitive(testing.allocator, null, 0, .{}, 2, &.{ 0, 1 }, .keep), 1.0);
    try testing.expectError(
        error.VertexIndexOutOfRange,
        merger.appendPrimitive(testing.allocator, null, 0, .{}, 2, &.{ 0, 2 }, .keep),
    );

    // The rejected primitive left nothing behind.
    const group = merger.groups.values()[0];
    try testing.expectEqual(@as(usize, 2), group.vertices.items.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, group.indices.items);
}

test "mesh merger: a failed reservation leaves no group behind and nothing allocated" {
    // Two calls under one failing allocator, with different keys, so the sweep
    // reaches a failure in the second group's reservations after the first
    // group's have already succeeded. A single call is too shallow: it has too
    // few allocations to fail one array's reservation after the other's
    // succeeded, which is exactly the state that can leak.
    //
    // Until the call succeeds the map must stay empty of anything the failed
    // call created, and the leak check on the testing allocator is the other
    // half: a group popped from the map without its arrays being freed passes
    // the count below and still loses memory.
    var index: usize = 0;
    while (true) : (index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = index });
        const allocator = failing.allocator();

        var merger: Merger = .empty;
        defer merger.deinit(allocator);

        if (merger.appendPrimitive(allocator, null, 0, .{}, 3, &.{ 0, 1, 2 }, .keep)) |vertices| {
            fill(vertices, 1.0);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), merger.groups.count());
            continue;
        }

        if (merger.appendPrimitive(allocator, null, 1, .{}, 3, &.{ 0, 1, 2 }, .keep)) |vertices| {
            fill(vertices, 4.0);
            try testing.expectEqual(@as(usize, 2), merger.groups.count());
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // The first group survives, the second never existed.
            try testing.expectEqual(@as(usize, 1), merger.groups.count());
        }
    }
    try testing.expect(index > 2);
}

test "mesh merger: a mirrored primitive is appended with its triangles reversed" {
    var merger: Merger = .empty;
    defer merger.deinit(testing.allocator);

    fill(try merger.appendPrimitive(
        testing.allocator,
        null,
        0,
        .{},
        6,
        &.{ 0, 1, 2, 3, 4, 5 },
        .reverse,
    ), 1.0);
    // A primitive the same group already holds, wound the other way. Both are
    // in one group, so the reversal has to be per primitive rather than per
    // group, and the rebase still applies to the corners it moved.
    fill(try merger.appendPrimitive(
        testing.allocator,
        null,
        0,
        .{},
        3,
        &.{ 0, 1, 2 },
        .keep,
    ), 7.0);

    const group = merger.groups.values()[0];
    try testing.expectEqualSlices(
        u32,
        &.{ 0, 2, 1, 3, 5, 4, 6, 7, 8 },
        group.indices.items,
    );
}

test "mesh merger: a reversed stream that is not whole triangles keeps its tail" {
    var merger: Merger = .empty;
    defer merger.deinit(testing.allocator);

    // Four corners is one triangle and a corner left over. The remainder names
    // no triangle to turn round, and reading a third corner for it would be a
    // read past the end.
    fill(try merger.appendPrimitive(
        testing.allocator,
        null,
        0,
        .{},
        4,
        &.{ 0, 1, 2, 3 },
        .reverse,
    ), 1.0);

    try testing.expectEqualSlices(u32, &.{ 0, 2, 1, 3 }, merger.groups.values()[0].indices.items);
}
