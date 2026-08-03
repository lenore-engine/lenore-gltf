const zm = @import("zmath");
const resources = @import("lenore-resources");

const types = @import("types.zig");

// Constant TRS overrides sampled from single-key animation channels. A channel
// with one keyframe holds a value for the whole clip, so it can be folded into
// the node's local transform instead of costing a runtime animator slot. A
// present field replaces the node's own value for that path; an absent one
// falls back to what the node declares.
pub const Held = struct {
    translation: ?zm.Vec = null,
    rotation: ?zm.Quat = null,
    scale: ?zm.Vec = null,
};

// One node's own local transform, in the row vector convention (v * M) that
// zmath and resources.composeTransform use. This is the only place a glTF node
// becomes a matrix: the scene walk, the skeleton bind pose and the animation
// parser all compose from here, and a second implementation that read the
// matrix differently would show up as baked geometry and animation drifting
// apart rather than as anything failing.
//
// glTF 2.0 section 3.5.3 makes matrix and the TRS properties mutually
// exclusive, and validate.zig refuses a node carrying both, so the two branches
// below are the only two cases.
//
// Section 5.25.4 stores matrix column-major, and zmath declares Mat as four
// rows stored consecutively, so the sixteen floats are the transpose of what
// zmath holds and read straight back as four rows. That transpose is the whole
// conversion: no shuffle, no per-element move.
//
// A matrix node ignores the overrides. Section 3.5.3 forbids matrix on a node
// any animation channel targets, so the combination describes no asset the
// specification allows, and there is no meaning to give it: the matrix is
// stated as the entire local transform and a held TRS path has nothing to
// replace in it.
pub fn nodeLocalMatrix(node: types.Node, held: Held) zm.Mat {
    if (node.matrix) |m| return .{
        zm.f32x4(m[0], m[1], m[2], m[3]),
        zm.f32x4(m[4], m[5], m[6], m[7]),
        zm.f32x4(m[8], m[9], m[10], m[11]),
        zm.f32x4(m[12], m[13], m[14], m[15]),
    };

    const trs = nodeTrs(node, held);
    return resources.composeTransform(trs.translation, trs.rotation, trs.scale);
}

pub const Trs = struct {
    translation: zm.Vec,
    rotation: zm.Quat,
    scale: zm.Vec,
};

// A node's translation, rotation and scale, each override or declaration or
// section 3.5.3 default in turn. Separate from the matrix above because the
// skeleton and the rigid animation hierarchy store the three rather than their
// product: an animation channel writes one of them per frame.
//
// A node declaring `matrix` yields the defaults, and nothing is lost by that.
// Section 3.5.3 forbids `matrix` on an animated node and validate.zig refuses
// the pair, so no channel ever samples into the three, and such a node's real
// transform reaches the hierarchy as its bind local matrix instead.
pub fn nodeTrs(node: types.Node, held: Held) Trs {
    // The w lane is unused by composeTransform and carries the value that makes
    // each vector read as what it is, a point and a direction triple.
    return .{
        .translation = held.translation orelse
            if (node.translation) |v| zm.f32x4(v[0], v[1], v[2], 1.0) else zm.f32x4(0.0, 0.0, 0.0, 1.0),
        .rotation = held.rotation orelse
            if (node.rotation) |v| zm.f32x4(v[0], v[1], v[2], v[3]) else zm.qidentity(),
        .scale = held.scale orelse
            if (node.scale) |v| zm.f32x4(v[0], v[1], v[2], 1.0) else zm.f32x4(1.0, 1.0, 1.0, 1.0),
    };
}
