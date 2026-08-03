const std = @import("std");
const zm = @import("zmath");

const document = @import("document.zig");
const node_transform = @import("node_transform.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const Held = node_transform.Held;

pub const Error = document.Error;

// The split of the node graph into what an animator drives at runtime and what
// can be folded into geometry at load time. Both halves are derived from the
// same two facts, so they are produced together: a node baked into vertices by
// one subsystem and given an animator slot by another would be transformed
// twice, and nothing would report it.
//
// A node is slotted when a channel gives it a pose that changes over time, or
// when it sits between two such nodes. The second case is not an optimization
// detail: a constant link in a chain of animated nodes cannot be folded away,
// because its child's sampled local transform composes against it every frame.
//
// Everything else a channel targets is held, meaning its channel has a single
// key. glTF sampling of a one-key channel yields that key for every t, so the
// held value is the node's pose for the whole clip and folding it in is exact
// rather than an approximation.
pub const DynamicNodes = struct {
    // Dense over the document's nodes. The animation parser assigns a slot to
    // exactly this set, intersected with what the rendered scene reaches.
    slotted: std.DynamicBitSetUnmanaged,
    // Dense over the document's nodes, and empty for every slotted one: a
    // slotted node's hold channels stay in the clip and pin its pose during
    // playback, so folding them in as well would apply them twice.
    held: []Held,

    pub fn deinit(self: *DynamicNodes, allocator: Allocator) void {
        self.slotted.deinit(allocator);
        allocator.free(self.held);
        self.* = undefined;
    }
};

// Requires the document's buffers, because a held value is read out of the
// channel's output accessor.
pub fn collect(allocator: Allocator, doc: *const Document) Error!DynamicNodes {
    const bake = holdsAreBakeable(doc);

    // Targeted by a channel whose pose changes over time. With baking off,
    // every channel target counts, which is the same set the engine would carry
    // if nothing were ever folded in.
    var changing: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, doc.nodes.len);
    defer changing.deinit(allocator);
    for (doc.animations) |clip| {
        for (clip.channels) |channel| {
            if (channel.target_path == .weights) continue;
            const keys = doc.accessors[clip.samplers[channel.sampler].input].count;
            if (!bake or keys > 1) changing.set(channel.target_node);
        }
    }

    var slotted: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, doc.nodes.len);
    errdefer slotted.deinit(allocator);
    for (doc.scenes) |scene| {
        for (scene.nodes) |root| _ = markSlotted(doc, &changing, &slotted, root, false);
    }

    const held = try allocator.alloc(Held, doc.nodes.len);
    errdefer allocator.free(held);
    @memset(held, .{});

    if (bake) {
        for (doc.animations) |clip| {
            for (clip.channels) |channel| {
                if (channel.target_path == .weights) continue;
                if (slotted.isSet(channel.target_node)) continue;
                try readHeld(
                    allocator,
                    doc,
                    clip.samplers[channel.sampler],
                    channel.target_path,
                    &held[channel.target_node],
                );
            }
        }
    }

    return .{ .slotted = slotted, .held = held };
}

// Folding is decided per document, not per node and path.
//
// What a fold needs is that no clip can ever show the node a different pose. One
// clip gives that outright. It is sufficient rather than necessary: with several
// clips the condition still holds for a node every clip targets with the same
// single key, and a sharper rule could test exactly that.
//
// The coarse rule was chosen against a measurement rather than for simplicity.
// Across the Khronos glTF-Sample-Assets collection and this project's own level
// and object files, 355 documents, six carry more than one clip, and between
// them they contain no single-key translation, rotation or scale channel at all.
// The sharper rule would fold nothing in any of them. In the single-clip
// documents 898 of 4978 such channels hold a single key, which is what the
// coarse rule already folds and why folding is here at all.
//
// That corpus is thin on multi-clip assets, so the measurement says the sharper
// rule buys nothing yet, not that it never will. Character assets with a clip
// per action are the case that would change the answer.
fn holdsAreBakeable(doc: *const Document) bool {
    return doc.animations.len == 1;
}

// Recursion is safe here because validate.zig bounds the node graph's depth when
// the document is parsed, and its comment on that limit carries the measurement.
//
// Returns whether this node or anything below it changes over time, which is
// what the caller needs to decide the node above.
fn markSlotted(
    doc: *const Document,
    changing: *const std.DynamicBitSetUnmanaged,
    slotted: *std.DynamicBitSetUnmanaged,
    node: u32,
    ancestor_changes: bool,
) bool {
    const self_changes = changing.isSet(node);
    var below_changes = false;
    for (doc.nodes[node].children) |child| {
        if (markSlotted(doc, changing, slotted, child, ancestor_changes or self_changes))
            below_changes = true;
    }
    if (self_changes or (ancestor_changes and below_changes)) slotted.set(node);
    return self_changes or below_changes;
}

// The constant value of a single-key channel.
//
// A cubic spline sampler stores each key as an in-tangent, the value and an
// out-tangent, so the value of the first key is element one; the other two
// interpolations store plain values and it is element zero. Section 3.6.2.2
// gives accessor.count a minimum of one and validate.zig refuses zero, and a
// cubic spline output holds three elements per key, so both indices are always
// inside the accessor.
fn readHeld(
    allocator: Allocator,
    doc: *const Document,
    sampler: types.AnimationSampler,
    path: types.TargetPath,
    held: *Held,
) Error!void {
    const value = if (sampler.interpolation == .cubicspline) @as(usize, 1) else 0;

    switch (path) {
        .translation, .scale => {
            const values = try allocator.alloc([3]f32, doc.accessors[sampler.output].count);
            defer allocator.free(values);
            try doc.read([3]f32, sampler.output, values);
            const triple = values[value];
            const vector = zm.f32x4(triple[0], triple[1], triple[2], 1.0);
            if (path == .translation) held.translation = vector else held.scale = vector;
        },
        .rotation => {
            const values = try allocator.alloc([4]f32, doc.accessors[sampler.output].count);
            defer allocator.free(values);
            try doc.read([4]f32, sampler.output, values);
            const quaternion = values[value];
            held.rotation = zm.f32x4(quaternion[0], quaternion[1], quaternion[2], quaternion[3]);
        },
        // Morph weights are not a node transform, and the callers above skip
        // them before reaching this.
        .weights => return,
    }
}
