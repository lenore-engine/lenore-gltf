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

// What sits above a root slot: the part of the chain that never moves, and the
// rigid animation slot carrying the rest.
//
// The walk stops at the nearest ancestor the rigid hierarchy drives, because
// everything from there upward is that node's world transform and is not a
// constant. Below it the chain is static and folds into one matrix, so a root
// costs one multiplication either way.
//
// Identity and no link when `target` is a scene root or is not reachable from
// the default scene.
const Above = struct {
    static: zm.Mat,
    node_slot: ?Slot,
};

// Linear in the graph per call, so building a skeleton whose roots are deep
// costs one walk per root. That is the shape worth keeping only because a
// skeleton has few roots; the rigid hierarchy below accumulates during its
// single walk instead, which is what keeps it linear over hundreds of subtrees.
fn ancestorPrefix(doc: *const Document, node_to_slot: []const ?Slot, target: u32) Above {
    for (defaultSceneRoots(doc)) |root| {
        if (findAncestorPrefix(doc, node_to_slot, root, target)) |above| return above;
    }
    return .{ .static = zm.identity(), .node_slot = null };
}

fn findAncestorPrefix(
    doc: *const Document,
    node_to_slot: []const ?Slot,
    node: u32,
    target: u32,
) ?Above {
    if (node == target) return .{ .static = zm.identity(), .node_slot = null };

    for (doc.nodes[node].children) |child| {
        const below = findAncestorPrefix(doc, node_to_slot, child, target) orelse continue;
        // Already stopped further down: this node is above the one that moves,
        // so its transform is that node's business rather than the prefix's.
        if (below.node_slot != null) return below;
        if (node_to_slot[node]) |slot| return .{ .static = below.static, .node_slot = slot };
        // Row vector convention: the child's local transform comes first, so
        // the chain accumulates on the way back out.
        return .{
            .static = zm.mul(below.static, node_transform.nodeLocalMatrix(doc.nodes[node], .{})),
            .node_slot = null,
        };
    }
    return null;
}

// A root slot whose transform above it moves, and the rigid animation slot it
// follows.
//
// glTF 2.0, 3.7.3.2 takes the skinned mesh node's own transform out of the
// draw, and that is where the reading usually stops. It does not take the
// chain above the *joints* out of anything: a skeleton parented under an
// animated node moves with it, and `BrainStem` is the corpus's proof, hanging
// its eighteen joints below a node carrying 1309 keys.
//
// So the transform above a root is baked only as far as the nearest ancestor
// that the rigid hierarchy drives, and the rest is this link. `Pose.setRootPrefix`
// is what closes it each frame.
pub const PrefixLink = struct {
    slot: Slot,
    node_slot: Slot,
};

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
    // One per root slot whose prefix is not a constant. Empty is the common
    // case: a skeleton under nothing that moves.
    prefix_links: []PrefixLink,

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
        allocator.free(self.prefix_links);
        self.* = undefined;
    }
};

// Numbers the slot set in scene preorder, which is what makes a slot's parent
// precede it. The skeleton pose relies on that ordering for its single forward
// pass, and resources.hierarchy.validate refuses a template without it.
const SkinSlots = struct {
    doc: *const Document,
    member: *const std.DynamicBitSetUnmanaged,
    // The rigid hierarchy's slot per node, for the chain above a root. Not to
    // be confused with `node_to_slot` below, which is this skeleton's own map
    // and is written rather than read.
    rigid_of_node: []const ?Slot,
    links: *std.ArrayList(PrefixLink),
    allocator: Allocator,
    slot_parent: []Slot,
    slot_prefix: []zm.Mat,
    bind_translations: []zm.Vec,
    bind_rotations: []zm.Quat,
    bind_scales: []zm.Vec,
    node_to_slot: []?Slot,
    next: Slot = 0,

    fn visit(self: *SkinSlots, node: u32, ancestor: Slot) Allocator.Error!void {
        var inherited = ancestor;
        if (self.member.isSet(node) and self.node_to_slot[node] == null) {
            const slot = self.next;
            self.next += 1;
            self.node_to_slot[node] = slot;
            self.slot_parent[slot] = ancestor;
            // A root slot folds in the static chain above it, and keeps a link
            // to whatever above that moves. An interior one receives the chain
            // through its parent's world transform, so giving it a prefix as
            // well would apply it twice.
            if (ancestor == no_parent) {
                const above = ancestorPrefix(self.doc, self.rigid_of_node, node);
                self.slot_prefix[slot] = above.static;
                if (above.node_slot) |node_slot|
                    try self.links.append(self.allocator, .{ .slot = slot, .node_slot = node_slot });
            } else {
                self.slot_prefix[slot] = zm.identity();
            }
            const trs = node_transform.nodeTrs(self.doc.nodes[node], .{});
            self.bind_translations[slot] = trs.translation;
            self.bind_rotations[slot] = trs.rotation;
            self.bind_scales[slot] = trs.scale;
            inherited = slot;
        }
        for (self.doc.nodes[node].children) |child| try self.visit(child, inherited);
    }
};

// Where one document skin's joints sit inside the skeleton that carries them.
//
// The joint index space is the skin's own, because that is what the vertex
// attribute addresses, and a skeleton holds the joints of every skin in it laid
// end to end. So a mesh reads the run `[joint_offset, joint_offset + joint_count)`
// of its skeleton's joint transforms, and needs no rebase of its own.
pub const SkinPlacement = struct {
    skeleton: u32,
    joint_offset: u32,
    joint_count: u32,
};

// One hierarchy per connected component of the document's joint forest, and
// where each skin landed in it.
pub const Skeletons = struct {
    hierarchies: []JointHierarchy,
    // Dense over the document's skins. Null for a skin with no joints at all,
    // which has nothing to place.
    placements: []?SkinPlacement,

    pub fn deinit(self: *Skeletons, allocator: Allocator) void {
        for (self.hierarchies) |*hierarchy| hierarchy.deinit(allocator);
        allocator.free(self.hierarchies);
        allocator.free(self.placements);
        self.* = undefined;
    }
};

// Every skeleton the document needs, one per component of the joint forest.
//
// **A skeleton is not a skin.** Two skins whose joints share a tree are one
// hierarchy here, because the transform of a joint in one of them may be what
// carries a joint of the other: `RecursiveSkeletons` nests 84 skins that way,
// 80 of them rooted under a joint belonging to another skin, twenty deep. Built
// per skin, each one would end at its own topmost joint and fold everything
// above into a constant, which freezes the parent's motion out of the child.
//
// Godot resolves the same ambiguity the same way and says so where it does it:
// `modules/gltf/skin_tool.cpp:314`, "combine all skins that are actually
// branches of a main skeleton", reached through a disjoint set over the nodes
// and a pass that unions groups whose highest member is parented into another
// group. The specification does not settle it, which that comment also says.
//
// Sharing is what makes it cheaper as well as correct: a joint carried by
// several skins is evaluated once for all of them rather than once per skin, and
// the clips are rebased into one slot space rather than into 84.
//
// The slot set of a component is its joints plus every node lying strictly
// between a joint and its nearest joint ancestor. Exporters routinely interpose
// helper nodes there, for scale compensation or for orientation, and dropping
// them freezes every joint reachable only through one.
pub fn buildSkeletons(
    allocator: Allocator,
    doc: *const Document,
    rigid_of_node: []const ?Slot,
) Error!Skeletons {
    // Direct parent per node. validate.zig proved the graph is a forest, so one
    // pass over the children arrays is the whole relation.
    const parent_of = try allocator.alloc(?u32, doc.nodes.len);
    defer allocator.free(parent_of);
    @memset(parent_of, null);
    for (doc.nodes, 0..) |node, index| {
        for (node.children) |child| parent_of[child] = @intCast(index);
    }

    // Every joint of every skin, and one skin that claims each. The claim is
    // arbitrary among the skins sharing a joint and is only used to name the
    // set a node belongs to.
    var is_joint: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, doc.nodes.len);
    defer is_joint.deinit(allocator);
    const claimed_by = try allocator.alloc(u32, doc.nodes.len);
    defer allocator.free(claimed_by);
    for (doc.skins, 0..) |skin, index| {
        for (skin.joints) |joint| {
            if (!is_joint.isSet(joint)) claimed_by[joint] = @intCast(index);
            is_joint.set(joint);
        }
    }

    // Union skins that touch. A skin joins another when it shares a joint with
    // it, and when the chain above one of its joints reaches a joint of the
    // other: the second case is the nested skeleton, and it is the one a
    // per-skin build gets wrong.
    const component_of = try allocator.alloc(u32, doc.skins.len);
    defer allocator.free(component_of);
    for (component_of, 0..) |*owner, index| owner.* = @intCast(index);
    for (doc.skins, 0..) |skin, index| {
        for (skin.joints) |joint| {
            if (claimed_by[joint] != index) union2(component_of, @intCast(index), claimed_by[joint]);
            var above = parent_of[joint];
            while (above) |node| : (above = parent_of[node]) {
                if (!is_joint.isSet(node)) continue;
                union2(component_of, @intCast(index), claimed_by[node]);
                break;
            }
        }
    }

    // Dense component numbers, in ascending order of the first skin in each, so
    // a document whose skins do not touch keeps them in its own order.
    const number = try allocator.alloc(?u32, doc.skins.len);
    defer allocator.free(number);
    @memset(number, null);
    var components: u32 = 0;
    for (0..doc.skins.len) |index| {
        const root = find(component_of, @intCast(index));
        if (number[root] == null) {
            number[root] = components;
            components += 1;
        }
    }

    const placements = try allocator.alloc(?SkinPlacement, doc.skins.len);
    errdefer allocator.free(placements);
    @memset(placements, null);

    var hierarchies: std.ArrayList(JointHierarchy) = .empty;
    errdefer {
        for (hierarchies.items) |*hierarchy| hierarchy.deinit(allocator);
        hierarchies.deinit(allocator);
    }

    var component: u32 = 0;
    while (component < components) : (component += 1) {
        var built = try buildComponent(
            allocator,
            doc,
            rigid_of_node,
            parent_of,
            component_of,
            number,
            component,
            placements,
            @intCast(hierarchies.items.len),
        );
        errdefer built.deinit(allocator);
        try hierarchies.append(allocator, built);
    }

    return .{
        .hierarchies = try hierarchies.toOwnedSlice(allocator),
        .placements = placements,
    };
}

fn find(component_of: []u32, index: u32) u32 {
    var root = index;
    while (component_of[root] != root) root = component_of[root];
    // Path compression, so the walk above stays short on a deep chain of
    // unions. RecursiveSkeletons unions 84 skins one at a time.
    var walk = index;
    while (component_of[walk] != root) {
        const next = component_of[walk];
        component_of[walk] = root;
        walk = next;
    }
    return root;
}

fn union2(component_of: []u32, a: u32, b: u32) void {
    const left = find(component_of, a);
    const right = find(component_of, b);
    if (left == right) return;
    // The lower index wins, which is what keeps the numbering above stable.
    if (left < right) component_of[right] = left else component_of[left] = right;
}

fn buildComponent(
    allocator: Allocator,
    doc: *const Document,
    rigid_of_node: []const ?Slot,
    parent_of: []const ?u32,
    component_of: []u32,
    number: []const ?u32,
    component: u32,
    placements: []?SkinPlacement,
    skeleton_index: u32,
) Error!JointHierarchy {
    var is_joint: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, doc.nodes.len);
    defer is_joint.deinit(allocator);
    var member: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, doc.nodes.len);
    defer member.deinit(allocator);

    var joint_total: u32 = 0;
    for (doc.skins, 0..) |skin, index| {
        if (number[find(component_of, @intCast(index))].? != component) continue;
        for (skin.joints) |joint| {
            is_joint.set(joint);
            member.set(joint);
        }
        joint_total += @intCast(skin.joints.len);
    }

    for (0..doc.nodes.len) |node| {
        if (!is_joint.isSet(node)) continue;
        // Intermediates count only where a joint ancestor exists. Without one
        // the chain above is outside this skeleton.
        var above = parent_of[node];
        while (above) |index| : (above = parent_of[index]) {
            if (is_joint.isSet(index)) break;
        } else continue;
        above = parent_of[node];
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

    var links: std.ArrayList(PrefixLink) = .empty;
    errdefer links.deinit(allocator);

    var slots: SkinSlots = .{
        .doc = doc,
        .member = &member,
        .rigid_of_node = rigid_of_node,
        .links = &links,
        .allocator = allocator,
        .slot_parent = slot_parent,
        .slot_prefix = slot_prefix,
        .bind_translations = bind_translations,
        .bind_rotations = bind_rotations,
        .bind_scales = bind_scales,
        .node_to_slot = node_to_slot,
    };
    for (defaultSceneRoots(doc)) |root| try slots.visit(root, no_parent);

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

    const inverse_bind = try allocator.alloc(zm.Mat, joint_total);
    errdefer allocator.free(inverse_bind);
    const joint_slot = try allocator.alloc(u16, joint_total);
    errdefer allocator.free(joint_slot);

    // The skins of this component, laid end to end in document order. Each one
    // keeps its own joint numbering inside its run, which is what the vertex
    // attribute indexes.
    var written: u32 = 0;
    for (doc.skins, 0..) |skin, index| {
        if (number[find(component_of, @intCast(index))].? != component) continue;
        if (skin.joints.len == 0) continue;

        // Section 5.28.2: inverseBindMatrices is one MAT4 per joint, and
        // validate.zig has already checked the component type, the shape and
        // the count, so the read below cannot be short.
        const run = inverse_bind[written..][0..skin.joints.len];
        if (skin.inverse_bind_matrices) |accessor| {
            const raw = try allocator.alloc([16]f32, skin.joints.len);
            defer allocator.free(raw);
            try doc.read([16]f32, accessor, raw);
            // Section 5.25.4's storage again: column-major, which is the
            // transpose of zmath's rows, so the sixteen floats read straight
            // through.
            for (run, raw) |*matrix, m| matrix.* = .{
                zm.f32x4(m[0], m[1], m[2], m[3]),
                zm.f32x4(m[4], m[5], m[6], m[7]),
                zm.f32x4(m[8], m[9], m[10], m[11]),
                zm.f32x4(m[12], m[13], m[14], m[15]),
            };
        } else {
            @memset(run, zm.identity());
        }

        // Every joint is a member of the slot set, so every one of these is
        // assigned.
        for (skin.joints, joint_slot[written..][0..skin.joints.len]) |joint, *slot|
            slot.* = node_to_slot[joint].?;

        placements[index] = .{
            .skeleton = skeleton_index,
            .joint_offset = written,
            .joint_count = @intCast(skin.joints.len),
        };
        written += @intCast(skin.joints.len);
    }
    std.debug.assert(written == joint_total);

    return .{
        .slot_parent = slot_parent,
        .slot_prefix = slot_prefix,
        .bind_translations = bind_translations,
        .bind_rotations = bind_rotations,
        .bind_scales = bind_scales,
        .inverse_bind = inverse_bind,
        .joint_slot = joint_slot,
        .node_to_slot = node_to_slot,
        .prefix_links = try links.toOwnedSlice(allocator),
    };
}

// The skeleton carrying one skin, for a caller that has no clips to rebase. An
// importer keeps the whole build instead, because parsing the clips needs each
// hierarchy's node map, and because a skeleton may carry several skins.
pub fn parseSkeletonTemplate(
    allocator: Allocator,
    doc: *const Document,
    skin_index: u32,
) Error!?SkeletonTemplate {
    if (skin_index >= doc.skins.len) return null;
    const rigid_of_node = try allocator.alloc(?Slot, doc.nodes.len);
    defer allocator.free(rigid_of_node);
    @memset(rigid_of_node, null);
    var built = try buildSkeletons(allocator, doc, rigid_of_node);
    defer built.deinit(allocator);
    const placement = built.placements[skin_index] orelse return null;
    return try SkeletonTemplate.init(
        allocator,
        built.hierarchies[placement.skeleton].templateInit(),
    );
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
