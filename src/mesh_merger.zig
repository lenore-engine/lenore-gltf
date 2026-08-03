const std = @import("std");
const resources = @import("lenore-resources");

const Allocator = std.mem.Allocator;
const Vertex3D = resources.Vertex3D;
const VertexStreams = resources.VertexStreams;

pub const Error = error{
    TooManyVertices,
    VertexIndexOutOfRange,
} || Allocator.Error;

// What makes two primitives one draw. Geometry baked relative to the same
// animator anchor moves under one instance matrix, the same material means the
// same texture set, alpha mode and cull state, and a skinned primitive reads
// its position from joints the unskinned one does not have. Primitives that
// agree on all three render identically, so concatenating them is lossless and
// turns a draw call per primitive into a draw call per group.
//
// `anchor` is the nearest slotted ancestor the scene walk found, and null is
// fully static geometry. `material` is null for a primitive that declares none,
// which section 3.7.2.1 makes the default material rather than material zero.
pub const GroupKey = struct {
    anchor: ?u32,
    material: ?u32,
    skinned: bool,
};

pub const Group = struct {
    vertices: std.ArrayList(Vertex3D) = .empty,
    indices: std.ArrayList(u32) = .empty,
    // The union of what the merged primitives declared. Colour and texture set
    // one carry neutral defaults, white and (0, 0), so a primitive without them
    // renders correctly inside a group that has them. Skinning has no such
    // default, which is why it is part of the key instead: zero weights collapse
    // a vertex onto the origin rather than leaving it where it was.
    streams: VertexStreams = .{},
};

// Load-time merging of primitives into one vertex and index stream per group.
// Pure accumulation: no device, no buffers, and the caller writes the vertices
// itself.
pub const Merger = struct {
    // An array hash map, so iteration order is insertion order and the emitted
    // submesh list is the same on every run.
    groups: std.AutoArrayHashMapUnmanaged(GroupKey, Group) = .empty,

    pub const empty: Merger = .{};

    pub fn deinit(self: *Merger, allocator: Allocator) void {
        for (self.groups.values()) |*group| {
            group.vertices.deinit(allocator);
            group.indices.deinit(allocator);
        }
        self.groups.deinit(allocator);
        self.* = undefined;
    }

    // Reserve room for one primitive in its group and return the uninitialized
    // vertex tail for the caller to fill. Handing back the destination is what
    // lets the caller bake the node transform straight into place instead of
    // transforming a scratch copy and copying it in.
    //
    // Indices are rebased against the group's current vertex count as they are
    // appended, so the caller passes them in the primitive's own index space.
    //
    // Either the whole primitive is reserved or nothing changes. Both arrays are
    // grown before either is written, and a group created by a call that then
    // fails is removed again, so a failed merge cannot leave an empty group
    // behind to be emitted as a draw of nothing.
    pub fn appendPrimitive(
        self: *Merger,
        allocator: Allocator,
        anchor: ?u32,
        material: ?u32,
        streams: VertexStreams,
        vertex_count: u32,
        indices: []const u32,
    ) Error![]Vertex3D {
        const entry = try self.groups.getOrPut(allocator, .{
            .anchor = anchor,
            .material = material,
            .skinned = streams.skinned,
        });
        if (!entry.found_existing) entry.value_ptr.* = .{};
        // A group this call created is destroyed with it, arrays first: the
        // reservations below may have grown one of them before another failed,
        // and popping the entry alone would drop that memory rather than free
        // it. A group that was already here keeps whatever it had.
        errdefer if (!entry.found_existing) {
            var abandoned = self.groups.pop().?;
            abandoned.value.vertices.deinit(allocator);
            abandoned.value.indices.deinit(allocator);
        };

        const group = entry.value_ptr;
        const base = group.vertices.items.len;
        // The merged index stream is u32 and the rebasing below adds to `base`,
        // so the group has to stay inside that width. A single primitive cannot
        // reach it, a group of them can, and the cast is only safe because this
        // ran first.
        if (base + vertex_count > std.math.maxInt(u32)) return error.TooManyVertices;

        // An index outside the primitive would rebase into another primitive's
        // vertices, or past the group entirely. parsePrimitive already refuses
        // it, and checking again here is what makes the addition below safe by
        // construction rather than by that.
        for (indices) |index| {
            if (index >= vertex_count) return error.VertexIndexOutOfRange;
        }

        try group.vertices.ensureUnusedCapacity(allocator, vertex_count);
        try group.indices.ensureUnusedCapacity(allocator, indices.len);

        group.streams.colour = group.streams.colour or streams.colour;
        group.streams.uv1 = group.streams.uv1 or streams.uv1;
        group.streams.skinned = streams.skinned;

        const rebase: u32 = @intCast(base);
        for (indices) |index| group.indices.appendAssumeCapacity(rebase + index);
        return group.vertices.addManyAsSliceAssumeCapacity(vertex_count);
    }
};
