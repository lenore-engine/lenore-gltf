const std = @import("std");
const zm = @import("zmath");
const resources = @import("lenore-resources");

const document = @import("document.zig");
const dynamic_nodes = @import("dynamic_nodes.zig");
const node_transform = @import("node_transform.zig");

const Document = document.Document;
const DynamicNodes = dynamic_nodes.DynamicNodes;
const Vec3 = resources.Vec3;
const Vec4 = resources.Vec4;

pub const Error = error{IndexOutOfRange};

// One node as the walk reaches it, with both transforms it can be baked
// against.
pub const Node = struct {
    index: u32,
    // The transform from this node's space to the scene's.
    world: zm.Mat,
    // The nearest slotted ancestor or self, and null on a path with none. This
    // is the node whose animator slot moves the geometry at runtime.
    anchor: ?u32,
    // The transform from the anchor's space to this node's, and equal to `world`
    // when there is no anchor. Vertex baking uses this one: baked geometry then
    // composes with the anchor's per-frame world matrix, which is what makes one
    // draw of a merged group follow its animation.
    relative: zm.Mat,
    mesh: ?u32,
    // KHR_node_visibility, inherited: false when this node or any ancestor
    // declares `visible` false. The extension hides everything a node renders,
    // meshes and light sources alike, and leaves cameras alone, so the walk
    // carries the value and each visitor decides what it means for what it
    // collects.
    visible: bool,
};

// Walk one scene depth first, calling `visitor.visit(node)` for each node. The
// visitor returns whether to descend into that node's children, so a caller
// pruning a subtree pays nothing for it.
//
// `dynamic` splits every world transform into a static part that can be baked
// and a runtime part carried by an animator slot. Null is a document with no
// animation, where everything is static and every node's relative transform is
// its world transform.
//
// The visitor is a pointer to any value with a `visit` method rather than a
// function pointer and an opaque context. Each call site monomorphizes, the
// visitor's own error set propagates instead of collapsing to `anyerror`, and
// there is no cast back from an erased pointer to get at the state.
pub fn traverse(
    doc: *const Document,
    scene_index: u32,
    dynamic: ?*const DynamicNodes,
    visitor: anytype,
) !void {
    if (scene_index >= doc.scenes.len) return error.IndexOutOfRange;
    for (doc.scenes[scene_index].nodes) |root| {
        try visit(doc, root, dynamic, zm.identity(), zm.identity(), null, true, visitor);
    }
}

// Recursion is safe because validate.zig bounds the node graph's depth when the
// document is parsed; the comment on its limit carries the measurement.
fn visit(
    doc: *const Document,
    index: u32,
    dynamic: ?*const DynamicNodes,
    parent_world: zm.Mat,
    parent_relative: zm.Mat,
    parent_anchor: ?u32,
    parent_visible: bool,
    visitor: anytype,
) !void {
    const node = doc.nodes[index];

    // A held pose is non-empty only for a node that earned no slot, so this
    // folds the constant part of an animation into the geometry exactly where
    // nothing will play it back.
    const held = if (dynamic) |info| info.held[index] else node_transform.Held{};
    const local = node_transform.nodeLocalMatrix(node, held);
    // Row vector convention: the child's own transform applies first.
    const world = zm.mul(local, parent_world);

    // Entering a slotted node re-anchors the chain. From here down the animator
    // owns everything at and above this node, so the relative transform starts
    // again at identity.
    const slotted = if (dynamic) |info| info.slotted.isSet(index) else false;
    const anchor: ?u32 = if (slotted) index else parent_anchor;
    const relative: zm.Mat = if (slotted)
        zm.identity()
    else if (parent_anchor != null)
        zm.mul(local, parent_relative)
    else
        world;

    // A visible node under a hidden parent stays hidden: the extension makes a
    // false anywhere on the path final for everything below it.
    const visible = parent_visible and node.visible;

    const descend = try visitor.visit(Node{
        .index = index,
        .world = world,
        .anchor = anchor,
        .relative = relative,
        .mesh = node.mesh,
        .visible = visible,
    });
    if (!descend) return;

    for (node.children) |child| {
        try visit(doc, child, dynamic, world, relative, anchor, visible, visitor);
    }
}

// A point carried into another space. The w lane is one, so the matrix's
// translation applies.
pub fn transformPosition(position: Vec3, matrix: zm.Mat) Vec3 {
    const carried = zm.mul(zm.f32x4(position[0], position[1], position[2], 1.0), matrix);
    return .{ carried[0], carried[1], carried[2] };
}

// A direction carried into another space and renormalized. The w lane is zero,
// so the translation does not apply. Correct for an axis, for a light's local
// -Z, and for a tangent, but not for a surface normal under non-uniform scale:
// that one needs the matrix below.
pub fn transformDirection(direction: Vec3, matrix: zm.Mat) Vec3 {
    const carried = zm.mul(zm.f32x4(direction[0], direction[1], direction[2], 0.0), matrix);
    return normalize(.{ carried[0], carried[1], carried[2] });
}

// The matrix that carries surface normals, for use with transformDirection.
//
// A normal is defined by staying perpendicular to the surface, and the plain
// matrix does not preserve that under non-uniform scale: stretching a surface
// along one axis tilts its normal the other way. The matrix that does is the
// inverse transpose, which is the same expression in either vector convention,
// because the inverse of a transpose is the transpose of the inverse.
//
// Compute it once per node. transformDirection runs per vertex.
pub fn normalMatrix(world: zm.Mat) zm.Mat {
    return zm.transpose(zm.inverse(world));
}

// A tangent carried into another space. It follows a surface edge rather than
// standing off the surface, so it transforms with the plain matrix like a
// position rather than with the inverse transpose. The w lane is the handedness
// that reconstructs the bitangent and passes through untouched.
pub fn transformTangent(tangent: Vec4, matrix: zm.Mat) Vec4 {
    const carried = transformDirection(.{ tangent[0], tangent[1], tangent[2] }, matrix);
    return .{ carried[0], carried[1], carried[2], tangent[3] };
}

fn normalize(v: Vec3) Vec3 {
    const length = @sqrt(@reduce(.Add, v * v));
    if (length <= 1e-8) return .{ 1.0, 0.0, 0.0 };
    return v / @as(Vec3, @splat(length));
}
