const std = @import("std");
const zm = @import("zmath");

const gltf = @import("lenore-gltf");
const nodeLocalMatrix = gltf.node_transform.nodeLocalMatrix;
const Held = gltf.node_transform.Held;
const Node = gltf.document.Node;

// A node carrying nothing but the transform under test. The parser fills every
// field, so a test document cannot use `.{}` and each case would otherwise
// repeat nine defaults.
const Transform = struct {
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    matrix: ?[16]f32 = null,
};

fn node(transform: Transform) Node {
    return .{
        .name = null,
        .children = &.{},
        .mesh = null,
        .skin = null,
        .camera = null,
        .light = null,
        .translation = transform.translation,
        .rotation = transform.rotation,
        .scale = transform.scale,
        .matrix = transform.matrix,
        .weights = &.{},
    };
}

// A vector lane is a comptime index, so both loops are unrolled.
fn expectMatrix(expected: zm.Mat, actual: zm.Mat) !void {
    for (expected, actual) |expected_row, actual_row| {
        inline for (0..4) |lane|
            try std.testing.expectApproxEqAbs(expected_row[lane], actual_row[lane], 1e-6);
    }
}

fn expectPoint(expected: [3]f32, point: [3]f32, matrix: zm.Mat) !void {
    const transformed = zm.mul(zm.f32x4(point[0], point[1], point[2], 1.0), matrix);
    inline for (0..3) |lane|
        try std.testing.expectApproxEqAbs(expected[lane], transformed[lane], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), transformed[3], 1e-6);
}

// A quarter turn about +Z, which sends +X to +Y. Section 3.5.3 stores rotation
// as a unit quaternion XYZW with W the scalar.
const quarter_turn_z: [4]f32 = .{ 0.0, 0.0, @sqrt(2.0) / 2.0, @sqrt(2.0) / 2.0 };

test "glTF node transform: a node declaring nothing is the identity" {
    try expectMatrix(zm.identity(), nodeLocalMatrix(node(.{}), .{}));
}

test "glTF node transform: TRS composes scale, then rotation, then translation" {
    // Section 3.5.3: "TRS properties MUST be converted to matrices and
    // postmultiplied in the T * R * S order; first the scale is applied to the
    // vertices, then the rotation, and then the translation."
    //
    // +X scales to (2, 0, 0), turns to (0, 2, 0), lands at (10, 22, 30).
    // +Y scales to (0, 3, 0), turns to (-3, 0, 0), lands at (7, 20, 30).
    // Applying the same factors in any other order moves both points, so this
    // pair pins the order rather than merely agreeing with it.
    const matrix = nodeLocalMatrix(node(.{
        .translation = .{ 10.0, 20.0, 30.0 },
        .rotation = quarter_turn_z,
        .scale = .{ 2.0, 3.0, 4.0 },
    }), .{});

    try expectPoint(.{ 10.0, 22.0, 30.0 }, .{ 1.0, 0.0, 0.0 }, matrix);
    try expectPoint(.{ 7.0, 20.0, 30.0 }, .{ 0.0, 1.0, 0.0 }, matrix);
    try expectPoint(.{ 10.0, 20.0, 34.0 }, .{ 0.0, 0.0, 1.0 }, matrix);
}

test "glTF node transform: an omitted TRS property takes its default" {
    // Section 3.5.3 defaults: zero translation, identity rotation, unit scale.
    // Each pair below writes one property and omits the other two, against the
    // same transform spelled out in full.
    try expectMatrix(
        nodeLocalMatrix(node(.{
            .translation = .{ 10.0, 20.0, 30.0 },
            .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
            .scale = .{ 1.0, 1.0, 1.0 },
        }), .{}),
        nodeLocalMatrix(node(.{ .translation = .{ 10.0, 20.0, 30.0 } }), .{}),
    );
    try expectMatrix(
        nodeLocalMatrix(node(.{
            .translation = .{ 0.0, 0.0, 0.0 },
            .rotation = quarter_turn_z,
            .scale = .{ 1.0, 1.0, 1.0 },
        }), .{}),
        nodeLocalMatrix(node(.{ .rotation = quarter_turn_z }), .{}),
    );
    try expectMatrix(
        nodeLocalMatrix(node(.{
            .translation = .{ 0.0, 0.0, 0.0 },
            .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
            .scale = .{ 2.0, 3.0, 4.0 },
        }), .{}),
        nodeLocalMatrix(node(.{ .scale = .{ 2.0, 3.0, 4.0 } }), .{}),
    );
}

test "glTF node transform: a column-major matrix reads back as four rows" {
    // Section 5.25.4 stores `matrix` column-major, so element col * 4 + row is
    // M[row][col] under the specification's column-vector semantics. zmath is
    // the transpose of that, four rows stored consecutively, so the sixteen
    // floats are its rows in order. The equality below is the check: the array
    // is the transform of the previous test, and both spellings must produce
    // the one matrix.
    const trs = nodeLocalMatrix(node(.{
        .translation = .{ 10.0, 20.0, 30.0 },
        .rotation = quarter_turn_z,
        .scale = .{ 2.0, 3.0, 4.0 },
    }), .{});

    const matrix = nodeLocalMatrix(node(.{ .matrix = .{
        0.0,  2.0,  0.0,  0.0,
        -3.0, 0.0,  0.0,  0.0,
        0.0,  0.0,  4.0,  0.0,
        10.0, 20.0, 30.0, 1.0,
    } }), .{});

    try expectMatrix(trs, matrix);
}

test "glTF node transform: a matrix keeps translation in elements 12 to 14" {
    // The property the specification's own example shows, and the one that goes
    // wrong first if the sixteen floats are read as columns: a pure translation
    // has its vector in the last four elements.
    const matrix = nodeLocalMatrix(node(.{ .matrix = .{
        1.0,  0.0,  0.0,  0.0,
        0.0,  1.0,  0.0,  0.0,
        0.0,  0.0,  1.0,  0.0,
        10.0, 20.0, 30.0, 1.0,
    } }), .{});

    try expectPoint(.{ 11.0, 20.0, 30.0 }, .{ 1.0, 0.0, 0.0 }, matrix);
}

test "glTF node transform: a held value replaces one path and leaves the rest" {
    const declared: Transform = .{
        .translation = .{ 10.0, 20.0, 30.0 },
        .rotation = quarter_turn_z,
        .scale = .{ 2.0, 3.0, 4.0 },
    };

    try expectMatrix(
        nodeLocalMatrix(node(.{
            .translation = .{ 1.0, 2.0, 3.0 },
            .rotation = quarter_turn_z,
            .scale = .{ 2.0, 3.0, 4.0 },
        }), .{}),
        nodeLocalMatrix(node(declared), .{ .translation = zm.f32x4(1.0, 2.0, 3.0, 1.0) }),
    );

    try expectMatrix(
        nodeLocalMatrix(node(.{
            .translation = .{ 10.0, 20.0, 30.0 },
            .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
            .scale = .{ 2.0, 3.0, 4.0 },
        }), .{}),
        nodeLocalMatrix(node(declared), .{ .rotation = zm.qidentity() }),
    );

    try expectMatrix(
        nodeLocalMatrix(node(.{
            .translation = .{ 10.0, 20.0, 30.0 },
            .rotation = quarter_turn_z,
            .scale = .{ 5.0, 5.0, 5.0 },
        }), .{}),
        nodeLocalMatrix(node(declared), .{ .scale = zm.f32x4(5.0, 5.0, 5.0, 1.0) }),
    );
}

test "glTF node transform: a held value overrides a node that declares nothing" {
    // The held path replaces the default, not only a declared value: a channel
    // holding a translation on a node with no TRS still moves it.
    try expectMatrix(
        nodeLocalMatrix(node(.{ .translation = .{ 1.0, 2.0, 3.0 } }), .{}),
        nodeLocalMatrix(node(.{}), .{ .translation = zm.f32x4(1.0, 2.0, 3.0, 1.0) }),
    );
}

test "glTF node transform: a matrix node ignores held values" {
    // Section 3.5.3 forbids `matrix` on a node an animation channel targets, so
    // the combination describes no legal asset and the matrix is taken as the
    // whole local transform.
    const matrix: [16]f32 = .{
        1.0,  0.0,  0.0,  0.0,
        0.0,  1.0,  0.0,  0.0,
        0.0,  0.0,  1.0,  0.0,
        10.0, 20.0, 30.0, 1.0,
    };
    const held: Held = .{
        .translation = zm.f32x4(-1.0, -2.0, -3.0, 1.0),
        .rotation = zm.f32x4(quarter_turn_z[0], quarter_turn_z[1], quarter_turn_z[2], quarter_turn_z[3]),
        .scale = zm.f32x4(9.0, 9.0, 9.0, 1.0),
    };

    try expectMatrix(
        nodeLocalMatrix(node(.{ .matrix = matrix }), .{}),
        nodeLocalMatrix(node(.{ .matrix = matrix }), held),
    );
}
