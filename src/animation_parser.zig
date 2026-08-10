const std = @import("std");
const zm = @import("zmath");
const resources = @import("lenore-resources");

const document = @import("document.zig");
const dynamic_nodes = @import("dynamic_nodes.zig");
const node_transform = @import("node_transform.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const Slot = resources.Slot;
const no_parent = resources.no_parent;
const Animation = resources.Animation;
const Channel = resources.AnimationChannel;
const Keyframe = resources.Keyframe;
const Track = resources.AnimationTrack;
const NodeTemplate = resources.NodeTemplate;
const SkeletonTemplate = resources.SkeletonTemplate;

pub const Error = document.Error ||
    resources.AnimationInitError ||
    SkeletonTemplate.InitError ||
    NodeTemplate.InitError;

// The scene an asset is animated in. Section 3.5.1 leaves `scene` optional and
// says a client may then delay rendering until one is requested, which is not a
// choice a loader can make; scene zero is what viewers show and what an exporter
// omitting the property means. Of 355 documents in the Khronos sample collection
// and this project's own assets, five omit it and two of those are animated, so
// returning nothing here would silently drop their animation.
fn defaultSceneRoots(doc: *const Document) []const u32 {
    if (doc.scenes.len == 0) return &.{};
    return doc.scenes[doc.default_scene orelse 0].nodes;
}

// The accumulated world transform of everything above `target`, not including
// its own local transform. Identity when `target` is a scene root or is not
// reachable from the default scene.
//
// Linear in the graph per call, so building a skeleton whose roots are deep
// costs one walk per root. That is the shape worth keeping only because a skin
// has few roots; the rigid hierarchy below accumulates during its single walk
// instead, which is what keeps it linear over hundreds of subtrees.
fn ancestorPrefix(doc: *const Document, target: u32) zm.Mat {
    for (defaultSceneRoots(doc)) |root| {
        if (findAncestorPrefix(doc, root, zm.identity(), target)) |prefix| return prefix;
    }
    return zm.identity();
}

fn findAncestorPrefix(doc: *const Document, node: u32, accumulated: zm.Mat, target: u32) ?zm.Mat {
    if (node == target) return accumulated;

    // Row vector convention: the child's local transform comes first.
    const world = zm.mul(node_transform.nodeLocalMatrix(doc.nodes[node], .{}), accumulated);
    for (doc.nodes[node].children) |child| {
        if (findAncestorPrefix(doc, child, world, target)) |prefix| return prefix;
    }
    return null;
}

// The slot space of one skin, plus the map that rebases channels into it. The
// caller keeps both alive together: the template copies what it needs, and the
// clips are parsed against `node_to_slot` afterwards.
pub const JointHierarchy = struct {
    slot_parent: []Slot,
    slot_prefix: []zm.Mat,
    bind_translations: []zm.Vec,
    bind_rotations: []zm.Quat,
    bind_scales: []zm.Vec,
    inverse_bind: []zm.Mat,
    joint_slot: []u16,
    // Dense over the document's nodes, null for a node with no slot.
    node_to_slot: []?Slot,

    pub fn templateInit(self: *const JointHierarchy) SkeletonTemplate.Init {
        return .{
            .slot_parent = self.slot_parent,
            .slot_prefix = self.slot_prefix,
            .bind_translations = self.bind_translations,
            .bind_rotations = self.bind_rotations,
            .bind_scales = self.bind_scales,
            .inverse_bind = self.inverse_bind,
            .joint_slot = self.joint_slot,
        };
    }

    pub fn deinit(self: *JointHierarchy, allocator: Allocator) void {
        allocator.free(self.slot_parent);
        allocator.free(self.slot_prefix);
        allocator.free(self.bind_translations);
        allocator.free(self.bind_rotations);
        allocator.free(self.bind_scales);
        allocator.free(self.inverse_bind);
        allocator.free(self.joint_slot);
        allocator.free(self.node_to_slot);
        self.* = undefined;
    }
};

// Numbers the slot set in scene preorder, which is what makes a slot's parent
// precede it. The skeleton pose relies on that ordering for its single forward
// pass, and resources.hierarchy.validate refuses a template without it.
const SkinSlots = struct {
    doc: *const Document,
    member: *const std.DynamicBitSetUnmanaged,
    slot_parent: []Slot,
    slot_prefix: []zm.Mat,
    bind_translations: []zm.Vec,
    bind_rotations: []zm.Quat,
    bind_scales: []zm.Vec,
    node_to_slot: []?Slot,
    next: Slot = 0,

    fn visit(self: *SkinSlots, node: u32, ancestor: Slot) void {
        var inherited = ancestor;
        if (self.member.isSet(node) and self.node_to_slot[node] == null) {
            const slot = self.next;
            self.next += 1;
            self.node_to_slot[node] = slot;
            self.slot_parent[slot] = ancestor;
            // A root slot folds in the static chain above it. An interior one
            // receives that chain through its parent's world transform, so
            // giving it a prefix as well would apply the chain twice.
            self.slot_prefix[slot] = if (ancestor == no_parent)
                ancestorPrefix(self.doc, node)
            else
                zm.identity();
            const trs = node_transform.nodeTrs(self.doc.nodes[node], .{});
            self.bind_translations[slot] = trs.translation;
            self.bind_rotations[slot] = trs.rotation;
            self.bind_scales[slot] = trs.scale;
            inherited = slot;
        }
        for (self.doc.nodes[node].children) |child| self.visit(child, inherited);
    }
};

// The slot hierarchy of one skin, or null when the index names no skin.
//
// The slot set is the skin's joints plus every node lying strictly between a
// joint and its nearest joint ancestor. Exporters routinely interpose helper
// nodes there, for scale compensation or for orientation, and dropping them
// freezes every joint reachable only through one.
pub fn buildJointHierarchy(
    allocator: Allocator,
    doc: *const Document,
    skin_index: u32,
) Error!?JointHierarchy {
    if (skin_index >= doc.skins.len) return null;
    const skin = doc.skins[skin_index];

    // Direct parent per node. validate.zig proved the graph is a forest, so one
    // pass over the children arrays is the whole relation.
    const parent_of = try allocator.alloc(?u32, doc.nodes.len);
    defer allocator.free(parent_of);
    @memset(parent_of, null);
    for (doc.nodes, 0..) |node, index| {
        for (node.children) |child| parent_of[child] = @intCast(index);
    }

    var is_joint: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, doc.nodes.len);
    defer is_joint.deinit(allocator);
    var member: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, doc.nodes.len);
    defer member.deinit(allocator);
    for (skin.joints) |joint| {
        is_joint.set(joint);
        member.set(joint);
    }

    for (skin.joints) |joint| {
        // Intermediates count only where a joint ancestor exists. Without one
        // the chain above is the static prefix, not slot data.
        var above = parent_of[joint];
        while (above) |index| : (above = parent_of[index]) {
            if (is_joint.isSet(index)) break;
        } else continue;
        above = parent_of[joint];
        while (!is_joint.isSet(above.?)) : (above = parent_of[above.?]) member.set(above.?);
    }

    const slot_count = member.count();
    if (slot_count > resources.max_slots) return error.TooManySlots;

    const slot_parent = try allocator.alloc(Slot, slot_count);
    errdefer allocator.free(slot_parent);
    const slot_prefix = try allocator.alloc(zm.Mat, slot_count);
    errdefer allocator.free(slot_prefix);
    const bind_translations = try allocator.alloc(zm.Vec, slot_count);
    errdefer allocator.free(bind_translations);
    const bind_rotations = try allocator.alloc(zm.Quat, slot_count);
    errdefer allocator.free(bind_rotations);
    const bind_scales = try allocator.alloc(zm.Vec, slot_count);
    errdefer allocator.free(bind_scales);
    const node_to_slot = try allocator.alloc(?Slot, doc.nodes.len);
    errdefer allocator.free(node_to_slot);
    @memset(node_to_slot, null);

    var slots: SkinSlots = .{
        .doc = doc,
        .member = &member,
        .slot_parent = slot_parent,
        .slot_prefix = slot_prefix,
        .bind_translations = bind_translations,
        .bind_rotations = bind_rotations,
        .bind_scales = bind_scales,
        .node_to_slot = node_to_slot,
    };
    for (defaultSceneRoots(doc)) |root| slots.visit(root, no_parent);

    // A joint outside the default scene is never visited above, and a slot left
    // unassigned would be an uninitialized bind pose that a vertex still indexes
    // through joint_slot. Appending them as roots keeps the arrays whole; the
    // asset is degenerate either way.
    for (0..doc.nodes.len) |node| {
        if (!member.isSet(node) or node_to_slot[node] != null) continue;
        const slot = slots.next;
        slots.next += 1;
        node_to_slot[node] = slot;
        slot_parent[slot] = no_parent;
        slot_prefix[slot] = zm.identity();
        const trs = node_transform.nodeTrs(doc.nodes[node], .{});
        bind_translations[slot] = trs.translation;
        bind_rotations[slot] = trs.rotation;
        bind_scales[slot] = trs.scale;
    }
    std.debug.assert(slots.next == slot_count);

    // Section 5.28.2: inverseBindMatrices is one MAT4 per joint, and validate.zig
    // has already checked the component type, the shape and the count, so the
    // read below cannot be short.
    const inverse_bind = try allocator.alloc(zm.Mat, skin.joints.len);
    errdefer allocator.free(inverse_bind);
    if (skin.inverse_bind_matrices) |accessor| {
        const raw = try allocator.alloc([16]f32, skin.joints.len);
        defer allocator.free(raw);
        try doc.read([16]f32, accessor, raw);
        // Section 5.25.4's storage again: column-major, which is the transpose
        // of zmath's rows, so the sixteen floats read straight through.
        for (inverse_bind, raw) |*matrix, m| matrix.* = .{
            zm.f32x4(m[0], m[1], m[2], m[3]),
            zm.f32x4(m[4], m[5], m[6], m[7]),
            zm.f32x4(m[8], m[9], m[10], m[11]),
            zm.f32x4(m[12], m[13], m[14], m[15]),
        };
    } else {
        @memset(inverse_bind, zm.identity());
    }

    // Every joint is a member of the slot set, so every one of these is assigned.
    const joint_slot = try allocator.alloc(u16, skin.joints.len);
    errdefer allocator.free(joint_slot);
    for (skin.joints, joint_slot) |joint, *slot| slot.* = node_to_slot[joint].?;

    return .{
        .slot_parent = slot_parent,
        .slot_prefix = slot_prefix,
        .bind_translations = bind_translations,
        .bind_rotations = bind_rotations,
        .bind_scales = bind_scales,
        .inverse_bind = inverse_bind,
        .joint_slot = joint_slot,
        .node_to_slot = node_to_slot,
    };
}

// The skeleton alone, for a caller that has no clips to rebase. An importer
// keeps the hierarchy instead, because parsing the clips needs its node map.
pub fn parseSkeletonTemplate(
    allocator: Allocator,
    doc: *const Document,
    skin_index: u32,
) Error!?SkeletonTemplate {
    var hierarchy = (try buildJointHierarchy(allocator, doc, skin_index)) orelse return null;
    defer hierarchy.deinit(allocator);
    return try SkeletonTemplate.init(allocator, hierarchy.templateInit());
}

// One clip, keeping the channels whose target node has a slot and rebasing them
// onto it. What a slot means belongs to the caller: a joint for a skin, a
// dynamic node for rigid animation.
//
// Morph weight channels are not here. They address no slot, they are per object
// rather than per node, and parseMorphWeights returns them as their own clip.
pub fn parseClip(
    allocator: Allocator,
    doc: *const Document,
    animation_index: u32,
    node_to_slot: []const ?Slot,
) Error!Animation {
    if (animation_index >= doc.animations.len) return error.IndexOutOfRange;
    const source = doc.animations[animation_index];

    var channels: std.ArrayList(Channel) = try .initCapacity(allocator, source.channels.len);
    errdefer {
        for (channels.items) |*channel| channel.deinit(allocator);
        channels.deinit(allocator);
    }

    for (source.channels) |channel| {
        if (channel.target_path == .weights) continue;
        const slot = node_to_slot[channel.target_node] orelse continue;
        const sampler = source.samplers[channel.sampler];
        channels.appendAssumeCapacity(.{
            .track = try readTrack(allocator, doc, sampler, channel.target_path),
            .target_slot = slot,
        });
    }

    const owned = try channels.toOwnedSlice(allocator);
    errdefer {
        for (owned) |*channel| channel.deinit(allocator);
        allocator.free(owned);
    }
    return try Animation.init(allocator, owned, source.name orelse "animation");
}

// glTF 2.0, animation.sampler.output: a CUBICSPLINE sampler stores three values
// per key, in the order in-tangent, property value, out-tangent, so a key's
// value is at index 3k + 1 and its tangents either side of it.
//
// validate.zig has already required the output count to be the input count times
// the width times three for a cubic spline and times one otherwise, so the key
// count is the input count and the indexing below cannot run off either array.
fn readTrack(
    allocator: Allocator,
    doc: *const Document,
    sampler: types.AnimationSampler,
    path: types.TargetPath,
) Error!Track {
    const key_count = doc.accessors[sampler.input].count;
    const spline = sampler.interpolation == .cubicspline;
    const stride: usize = if (spline) 3 else 1;
    const value: usize = if (spline) 1 else 0;

    const times = try allocator.alloc(f32, key_count);
    defer allocator.free(times);
    try doc.read(f32, sampler.input, times);

    switch (path) {
        .translation, .scale => {
            const values = try allocator.alloc([3]f32, doc.accessors[sampler.output].count);
            defer allocator.free(values);
            try doc.read([3]f32, sampler.output, values);

            const keys = try allocator.alloc(Keyframe(zm.Vec), key_count);
            errdefer allocator.free(keys);
            for (keys, times, 0..) |*key, time, index| {
                const triple = values[index * stride + value];
                key.* = .{ .time = time, .value = zm.f32x4(triple[0], triple[1], triple[2], 1.0) };
            }

            // Exhaustive, so a mode added to either the document's enum or the
            // resource one stops the build here rather than mapping to the
            // wrong arm.
            const blend: resources.Blend(zm.Vec) = switch (sampler.interpolation) {
                .linear => .linear,
                .step => .step,
                .cubicspline => .{
                    .cubicspline = try readVectorTangents(allocator, key_count, values),
                },
            };

            const track: resources.TransformTrack(zm.Vec) = .{ .keys = keys, .blend = blend };
            return if (path == .translation) .{ .translation = track } else .{ .scale = track };
        },
        .rotation => {
            const values = try allocator.alloc([4]f32, doc.accessors[sampler.output].count);
            defer allocator.free(values);
            try doc.read([4]f32, sampler.output, values);

            const keys = try allocator.alloc(Keyframe(zm.Quat), key_count);
            errdefer allocator.free(keys);
            for (keys, times, 0..) |*key, time, index| {
                const quaternion = values[index * stride + value];
                key.* = .{
                    .time = time,
                    .value = zm.f32x4(quaternion[0], quaternion[1], quaternion[2], quaternion[3]),
                };
            }

            const blend: resources.Blend(zm.Quat) = switch (sampler.interpolation) {
                .linear => .linear,
                .step => .step,
                .cubicspline => .{
                    .cubicspline = try readQuatTangents(allocator, key_count, values),
                },
            };

            return .{ .rotation = .{ .keys = keys, .blend = blend } };
        },
        // Handled by parseMorphWeights, and skipped by every caller here.
        .weights => return error.TypeMismatch,
    }
}

// The in-tangent and out-tangent either side of key k's value, with a w of zero.
// They are derivatives rather than points, and section C.5's two value weights
// sum to one, so a zero here is what leaves the w the keys were built with.
fn readVectorTangents(
    allocator: Allocator,
    key_count: usize,
    values: []const [3]f32,
) Error![]resources.Tangents(zm.Vec) {
    const tangents = try allocator.alloc(resources.Tangents(zm.Vec), key_count);
    for (tangents, 0..) |*tangent, index| {
        const in = values[index * 3];
        const out = values[index * 3 + 2];
        tangent.* = .{
            .in = zm.f32x4(in[0], in[1], in[2], 0.0),
            .out = zm.f32x4(out[0], out[1], out[2], 0.0),
        };
    }
    return tangents;
}

// All four components are real for a rotation: the tangent is a derivative in
// quaternion space and section C.5 normalizes the result rather than the
// tangents.
fn readQuatTangents(
    allocator: Allocator,
    key_count: usize,
    values: []const [4]f32,
) Error![]resources.Tangents(zm.Quat) {
    const tangents = try allocator.alloc(resources.Tangents(zm.Quat), key_count);
    for (tangents, 0..) |*tangent, index| {
        const in = values[index * 3];
        const out = values[index * 3 + 2];
        tangent.* = .{
            .in = zm.f32x4(in[0], in[1], in[2], in[3]),
            .out = zm.f32x4(out[0], out[1], out[2], out[3]),
        };
    }
    return tangents;
}

// A parsed morph weight clip and the number of targets one key carries, so a
// caller can size its weights buffer without taking the track apart.
pub const WeightsClip = struct {
    animation: Animation,
    target_count: u32,
};

// The morph weight channel of one clip that targets one node, as a clip of its
// own. Weights are per object scalars and address no slot, so they bypass the
// hierarchy entirely. Null when the clip does not drive that node's weights.
pub fn parseMorphWeights(
    allocator: Allocator,
    doc: *const Document,
    animation_index: u32,
    node: u32,
) Error!?WeightsClip {
    if (animation_index >= doc.animations.len) return error.IndexOutOfRange;
    const source = doc.animations[animation_index];

    for (source.channels) |channel| {
        if (channel.target_path != .weights or channel.target_node != node) continue;
        const sampler = source.samplers[channel.sampler];

        const key_count = doc.accessors[sampler.input].count;
        const output_count = doc.accessors[sampler.output].count;
        const stride: usize = if (sampler.interpolation == .cubicspline) 3 else 1;
        // Exact, and at least one: validate.zig required the output count to be
        // the key count times the mesh's morph target count times the stride,
        // and refuses an accessor of no elements.
        const width = output_count / (key_count * stride);

        const times = try allocator.alloc(f32, key_count);
        errdefer allocator.free(times);
        try doc.read(f32, sampler.input, times);

        const raw = try allocator.alloc(f32, output_count);
        defer allocator.free(raw);
        try doc.read(f32, sampler.output, raw);

        // The values compacted to one run of weights per key. A spline sampler
        // interleaves in-tangent, value and out-tangent per key, so the values
        // are one run in three and the tangents are the other two.
        const values = try allocator.alloc(f32, key_count * width);
        errdefer allocator.free(values);
        const offset = if (sampler.interpolation == .cubicspline) width else 0;
        for (0..key_count) |key| {
            @memcpy(values[key * width ..][0..width], raw[key * stride * width + offset ..][0..width]);
        }

        // The two tangent runs of each key, kept adjacent in that order, which
        // is the layout WeightBlend.cubicspline documents.
        const blend: resources.WeightBlend = switch (sampler.interpolation) {
            .linear => .linear,
            .step => .step,
            .cubicspline => blk: {
                const tangents = try allocator.alloc(f32, key_count * width * 2);
                errdefer allocator.free(tangents);
                for (0..key_count) |key| {
                    const key_base = key * 3 * width;
                    @memcpy(tangents[2 * key * width ..][0..width], raw[key_base..][0..width]);
                    @memcpy(
                        tangents[(2 * key + 1) * width ..][0..width],
                        raw[key_base + 2 * width ..][0..width],
                    );
                }
                break :blk .{ .cubicspline = tangents };
            },
        };
        errdefer switch (blend) {
            .cubicspline => |tangents| allocator.free(tangents),
            .linear, .step => {},
        };

        var channels = try allocator.alloc(Channel, 1);
        errdefer allocator.free(channels);
        channels[0] = .{
            .track = .{ .weights = .{
                .times = times,
                .values = values,
                .width = @intCast(width),
                .blend = blend,
            } },
            .target_slot = 0,
        };

        return .{
            .animation = try Animation.init(allocator, channels, source.name orelse "morph"),
            .target_count = @intCast(width),
        };
    }
    return null;
}

// Numbers the dynamic nodes in scene preorder and accumulates the static chain
// above each subtree as it goes, which is what keeps the whole build linear.
// Calling ancestorPrefix per subtree root instead would be quadratic on an asset
// with hundreds of them.
const NodeSlots = struct {
    doc: *const Document,
    slotted: *const std.DynamicBitSetUnmanaged,
    held: []const node_transform.Held,
    node_to_slot: []?Slot,
    parent: []Slot,
    prefix: []zm.Mat,
    bind_translations: []zm.Vec,
    bind_rotations: []zm.Quat,
    bind_scales: []zm.Vec,
    bind_local: []zm.Mat,
    next: Slot = 0,

    fn walk(self: *NodeSlots, node: u32, static_world: zm.Mat, ancestor: Slot) void {
        const source = self.doc.nodes[node];

        if (!self.slotted.isSet(node)) {
            // Still static: fold this node's local transform, with any held pose
            // in it, into the chain a slot found deeper will carry as its prefix.
            const world = zm.mul(node_transform.nodeLocalMatrix(source, self.held[node]), static_world);
            for (source.children) |child| self.walk(child, world, no_parent);
            return;
        }

        const slot = self.next;
        self.next += 1;
        self.node_to_slot[node] = slot;
        self.parent[slot] = ancestor;
        // Only a subtree root carries a prefix. Every ancestor of an interior
        // slot is itself slotted, so the chain reaches it through the parent.
        self.prefix[slot] = if (ancestor == no_parent) static_world else zm.identity();

        // The node's own values, not the held ones. dynamic_nodes leaves `held`
        // empty for a slotted node because its hold channels stay in the clip,
        // and taking them here as well would apply them twice if that ever
        // stopped being true.
        const trs = node_transform.nodeTrs(source, .{});
        self.bind_translations[slot] = trs.translation;
        self.bind_rotations[slot] = trs.rotation;
        self.bind_scales[slot] = trs.scale;
        self.bind_local[slot] = node_transform.nodeLocalMatrix(source, .{});

        // A slotted node's subtree can hold more slots, but nothing above them
        // is static any more, so the accumulated chain ends here.
        for (source.children) |child| self.walk(child, zm.identity(), slot);
    }
};

// Every dynamic node of a document as one hierarchy plus every clip rebased onto
// it. Null for a document with no clips or nothing dynamic to drive, which costs
// a purely static asset nothing.
//
// `node_to_slot` is dense over the document's nodes and is the caller's only way
// back from a node index to the slot whose world transform moves it. The slot
// space is not derived from the node space by any rule a caller could reproduce,
// since it counts only the slotted nodes the default scene reaches.
//
// It is cleared here rather than by the caller, so a document with nothing to
// drive leaves it all null instead of leaving whatever was in it.
//
// The returned template owns its arrays. resources.NodeTemplate.init takes them
// over from the call, including on failure, so there is no half-owned state to
// unwind here.
pub fn parseNodeAnimation(
    allocator: Allocator,
    doc: *const Document,
    node_to_slot: []?Slot,
) Error!?NodeTemplate {
    std.debug.assert(node_to_slot.len == doc.nodes.len);
    @memset(node_to_slot, null);

    const assembled = (try assembleNodeAnimation(allocator, doc, node_to_slot)) orelse return null;
    return try NodeTemplate.init(allocator, assembled);
}

// Split from the call above so that ownership changes hands exactly once. Every
// errdefer here has either fired or been discharged by the time this returns, so
// NodeTemplate.init receives arrays nothing else will free, which matters
// because init takes them over on its own failure too.
fn assembleNodeAnimation(
    allocator: Allocator,
    doc: *const Document,
    node_to_slot: []?Slot,
) Error!?NodeTemplate {
    if (doc.animations.len == 0) return null;

    var info = try dynamic_nodes.collect(allocator, doc);
    defer info.deinit(allocator);

    var slot_count: usize = 0;
    for (defaultSceneRoots(doc)) |root| slot_count += countSlotted(doc, &info.slotted, root);
    if (slot_count == 0) return null;
    if (slot_count > resources.max_slots) return error.TooManySlots;

    const parent = try allocator.alloc(Slot, slot_count);
    errdefer allocator.free(parent);
    const prefix = try allocator.alloc(zm.Mat, slot_count);
    errdefer allocator.free(prefix);
    const bind_translations = try allocator.alloc(zm.Vec, slot_count);
    errdefer allocator.free(bind_translations);
    const bind_rotations = try allocator.alloc(zm.Quat, slot_count);
    errdefer allocator.free(bind_rotations);
    const bind_scales = try allocator.alloc(zm.Vec, slot_count);
    errdefer allocator.free(bind_scales);
    const bind_local = try allocator.alloc(zm.Mat, slot_count);
    errdefer allocator.free(bind_local);

    var slots: NodeSlots = .{
        .doc = doc,
        .slotted = &info.slotted,
        .held = info.held,
        .node_to_slot = node_to_slot,
        .parent = parent,
        .prefix = prefix,
        .bind_translations = bind_translations,
        .bind_rotations = bind_rotations,
        .bind_scales = bind_scales,
        .bind_local = bind_local,
    };
    for (defaultSceneRoots(doc)) |root| slots.walk(root, zm.identity(), no_parent);
    std.debug.assert(slots.next == slot_count);

    const clips = try allocator.alloc(Animation, doc.animations.len);
    var parsed: usize = 0;
    errdefer {
        for (clips[0..parsed]) |*clip| clip.deinit(allocator);
        allocator.free(clips);
    }
    for (clips, 0..) |*clip, index| {
        clip.* = try parseClip(allocator, doc, @intCast(index), node_to_slot);
        parsed += 1;
    }

    const animated_slots = try allocator.alloc([]u16, clips.len);
    var collected: usize = 0;
    errdefer {
        for (animated_slots[0..collected]) |list| allocator.free(list);
        allocator.free(animated_slots);
    }
    for (clips, animated_slots) |clip, *list| {
        // A bit set rather than collecting and sorting: it deduplicates the
        // translation, rotation and scale channels that share one slot, and it
        // yields the slots in ascending order, so the per-frame recompose loop
        // walks its arrays forwards.
        var mask: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, slot_count);
        defer mask.deinit(allocator);
        for (clip.channels) |channel| mask.set(channel.target_slot);

        list.* = try allocator.alloc(u16, mask.count());
        collected += 1;
        var iterator = mask.iterator(.{});
        var position: usize = 0;
        while (iterator.next()) |slot| : (position += 1) list.*[position] = @intCast(slot);
    }

    return .{
        .parent = parent,
        .prefix = prefix,
        .bind_translations = bind_translations,
        .bind_rotations = bind_rotations,
        .bind_scales = bind_scales,
        .bind_local = bind_local,
        .clips = clips,
        .animated_slots = animated_slots,
    };
}

fn countSlotted(doc: *const Document, slotted: *const std.DynamicBitSetUnmanaged, node: u32) usize {
    var total: usize = @intFromBool(slotted.isSet(node));
    for (doc.nodes[node].children) |child| total += countSlotted(doc, slotted, child);
    return total;
}
