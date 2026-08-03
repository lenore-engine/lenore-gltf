const std = @import("std");
const resources = @import("lenore-resources");

const document = @import("document.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const Vertex3D = resources.Vertex3D;
const Vec3 = resources.Vec3;
const Vec4 = resources.Vec4;

pub const Error = error{
    EmptyPrimitive,
    VertexIndexOutOfRange,
} || document.Error;

// Morph target deltas in the layout lenore-gpu's MorphUpload takes: three floats
// per (vertex, target) pair with the target index varying fastest, so element
// v * target_count + t is target t's delta for vertex v. Flat rather than an
// array of vectors, because std430 pads a vec3 element to sixteen bytes and the
// upload writes its own interleaved element type anyway.
//
// `normals` is empty when no target declares NORMAL. TANGENT deltas are not
// carried: the consumer has no slot for them, and the animated case uses the
// rest pose basis.
pub const MorphDeltas = struct {
    positions: []f32,
    normals: []f32,
    target_count: u32,

    pub fn deinit(self: *MorphDeltas, allocator: Allocator) void {
        allocator.free(self.positions);
        allocator.free(self.normals);
        self.* = undefined;
    }
};

// One primitive as geometry, ready for an uploader and for the merger. The
// fields line up with lenore-gpu's Upload so the engine passes them across
// without a translation pass.
pub const Primitive = struct {
    vertices: []Vertex3D,
    // Always present, and always u32. A primitive can exceed the u16 vertex
    // limit on its own, and generating the sequence for non-indexed geometry
    // here removes that case from everything downstream.
    indices: []u32,
    // Null means the primitive declares no material, which section 3.7.2.1
    // makes the default material rather than material zero. Folding it to zero
    // here would silently give it the file's first material instead.
    material: ?u32,
    streams: resources.VertexStreams,
    morph: ?MorphDeltas,

    pub fn deinit(self: *Primitive, allocator: Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
        if (self.morph) |*morph| morph.deinit(allocator);
        self.* = undefined;
    }
};

// Read one primitive's geometry. Every accessor index, component type, element
// shape and attribute count was checked when the document was parsed, so the
// reads below cannot mismatch and the only failures left are allocation, an
// empty primitive and a vertex index outside its own primitive.
//
// Morph targets are never baked into the rest pose. Section 3.7.2.2 makes
// mesh.weights the default value of the morph weights and an animation channel
// or node.weights overrides them, so the weights belong to whoever poses the
// mesh. The reference baked them here whenever they were non-zero and guessed
// from that whether the deformation was static, which double-applies on a mesh
// that is both authored in a morphed pose and animated.
pub fn parsePrimitive(
    allocator: Allocator,
    doc: *const Document,
    primitive: types.Primitive,
) Error!Primitive {
    const position_accessor = primitive.position orelse return error.EmptyPrimitive;
    const vertex_count = doc.accessors[position_accessor].count;
    if (vertex_count == 0) return error.EmptyPrimitive;

    var result: Primitive = .{
        .vertices = try allocator.alloc(Vertex3D, vertex_count),
        .indices = &.{},
        .material = primitive.material,
        .streams = .{
            // A lone JOINTS_0 would leave every weight at zero and collapse the
            // mesh onto the first joint, so the stream needs both halves.
            .skinned = primitive.joints_0 != null and primitive.weights_0 != null,
            .colour = primitive.color_0 != null,
            .uv1 = primitive.texcoord_1 != null,
        },
        .morph = null,
    };
    errdefer result.deinit(allocator);

    {
        const positions = try readVectors(3, allocator, doc, position_accessor);
        defer allocator.free(positions);
        // Every other attribute overwrites one field, so the whole vertex is
        // written here and the defaults come from Vertex3D itself.
        for (result.vertices, positions) |*vertex, position|
            vertex.* = .{
                .position = position,
                .normal = .{ 0.0, 1.0, 0.0 },
                .uv = .{ 0.0, 0.0 },
                .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
            };
    }

    if (primitive.normal) |accessor| {
        const normals = try readVectors(3, allocator, doc, accessor);
        defer allocator.free(normals);
        for (result.vertices, normals) |*vertex, normal| vertex.normal = normal;
    }

    if (primitive.tangent) |accessor| {
        const tangents = try readVectors(4, allocator, doc, accessor);
        defer allocator.free(tangents);
        for (result.vertices, tangents) |*vertex, tangent| vertex.tangent = tangent;
    }

    if (primitive.texcoord_0) |accessor| {
        const uvs = try readVectors(2, allocator, doc, accessor);
        defer allocator.free(uvs);
        for (result.vertices, uvs) |*vertex, uv| vertex.uv = uv;
    }

    if (primitive.texcoord_1) |accessor| {
        const uvs = try readVectors(2, allocator, doc, accessor);
        defer allocator.free(uvs);
        for (result.vertices, uvs) |*vertex, uv| vertex.uv1 = uv;
    }

    if (primitive.color_0) |accessor| try readColours(allocator, doc, accessor, result.vertices);
    if (primitive.joints_0) |accessor| try readJoints(allocator, doc, accessor, result.vertices);
    if (primitive.weights_0) |accessor| try readWeights(allocator, doc, accessor, result.vertices);

    if (primitive.targets.len > 0)
        result.morph = try readMorphDeltas(allocator, doc, primitive.targets, vertex_count);

    result.indices = try readIndices(allocator, doc, primitive.indices, vertex_count);

    // A tangent basis for a primitive that can sample a normal map and ships
    // none. Without it those vertices keep the constant (1, 0, 0, 1) above, and
    // a tangent space normal map reads as noise because the basis is not
    // aligned to the UV gradient.
    if (primitive.tangent == null and primitive.normal != null and primitive.texcoord_0 != null)
        try generateTangents(allocator, result.vertices, result.indices);

    return result;
}

// Read a float or normalized integer attribute as floats, in the element order
// the accessor stores. The result is arrays rather than vectors because a
// three-lane vector occupies sixteen bytes while the file packs twelve, so a
// slice of vectors is not a reinterpretation of the bytes. Assigning an element
// into a Vertex3D field coerces it.
//
// Section 3.11 states the decoding equations: f = c / 255 for an unsigned byte
// and f = c / 65535 for an unsigned short. validate.zig has already restricted
// every attribute that reaches here to float or one of those two, so the
// TypeMismatch below is unreachable through the parser. It is an error rather
// than an `unreachable` because a shipping build removes the safety check that
// would have caught the difference.
fn readVectors(
    comptime arity: comptime_int,
    allocator: Allocator,
    doc: *const Document,
    accessor_index: u32,
) Error![][arity]f32 {
    const count = doc.accessors[accessor_index].count;
    const output = try allocator.alloc([arity]f32, count);
    errdefer allocator.free(output);

    switch (doc.accessors[accessor_index].component_type) {
        .f32 => try doc.read([arity]f32, accessor_index, output),
        inline .u8, .u16 => |component_type| {
            const Component = if (component_type == .u8) u8 else u16;
            const raw = try allocator.alloc([arity]Component, count);
            defer allocator.free(raw);
            try doc.read([arity]Component, accessor_index, raw);

            const scale = 1.0 / @as(f32, std.math.maxInt(Component));
            for (output, raw) |*element, value| {
                inline for (0..arity) |lane|
                    element[lane] = @as(f32, @floatFromInt(value[lane])) * scale;
            }
        },
        else => return error.TypeMismatch,
    }
    return output;
}

// COLOR_0 folded to unorm8 rgba, which is what Vertex3D carries. Section 3.7.2
// allows VEC3 or VEC4 in float, normalized unsigned byte or normalized unsigned
// short, and every component is in zero through one, so all six spellings fold
// here without a range check. VEC3 supplies an opaque alpha.
fn readColours(
    allocator: Allocator,
    doc: *const Document,
    accessor_index: u32,
    vertices: []Vertex3D,
) Error!void {
    switch (doc.accessors[accessor_index].kind) {
        .vec4 => {
            const colours = try readVectors(4, allocator, doc, accessor_index);
            defer allocator.free(colours);
            for (vertices, colours) |*vertex, colour|
                vertex.colour = .{
                    unorm8(colour[0]), unorm8(colour[1]),
                    unorm8(colour[2]), unorm8(colour[3]),
                };
        },
        .vec3 => {
            const colours = try readVectors(3, allocator, doc, accessor_index);
            defer allocator.free(colours);
            for (vertices, colours) |*vertex, colour|
                vertex.colour = .{
                    unorm8(colour[0]), unorm8(colour[1]),
                    unorm8(colour[2]), 255,
                };
        },
        else => return error.TypeMismatch,
    }
}

fn unorm8(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}

// JOINTS_0 widened to the u16 slot Vertex3D carries. Section 3.7.3.3 fixes the
// component type to unsigned byte or unsigned short, so the widening is exact
// and no value can be lost.
fn readJoints(
    allocator: Allocator,
    doc: *const Document,
    accessor_index: u32,
    vertices: []Vertex3D,
) Error!void {
    switch (doc.accessors[accessor_index].component_type) {
        inline .u8, .u16 => |component_type| {
            const Component = if (component_type == .u8) u8 else u16;
            const joints = try allocator.alloc([4]Component, vertices.len);
            defer allocator.free(joints);
            try doc.read([4]Component, accessor_index, joints);
            for (vertices, joints) |*vertex, value|
                vertex.joints = .{ value[0], value[1], value[2], value[3] };
        },
        else => return error.TypeMismatch,
    }
}

// WEIGHTS_0, renormalized so the four weights sum to one. Section 3.7.3.3 only
// says the sum SHOULD be as close as reasonably possible to 1.0, so an exporter
// is within the specification while being visibly off, and a skinning shader
// scales the vertex by whatever the sum happens to be.
//
// A vertex with no influence at all keeps its zero weights rather than being
// handed to joint zero: the sum is left alone below the threshold, and inventing
// an influence would move geometry that the asset placed deliberately.
fn readWeights(
    allocator: Allocator,
    doc: *const Document,
    accessor_index: u32,
    vertices: []Vertex3D,
) Error!void {
    const weights = try readVectors(4, allocator, doc, accessor_index);
    defer allocator.free(weights);

    for (vertices, weights) |*vertex, weight| {
        const influence: Vec4 = weight;
        const sum = @reduce(.Add, influence);
        vertex.weights = if (sum > 1e-4) influence / @as(Vec4, @splat(sum)) else influence;
    }
}

// POSITION and NORMAL deltas for every target, interleaved into the layout
// MorphDeltas documents. A target that omits an attribute contributes zeros,
// which the memset below already provides.
fn readMorphDeltas(
    allocator: Allocator,
    doc: *const Document,
    targets: []const types.MorphTarget,
    vertex_count: u32,
) Error!MorphDeltas {
    const elements = @as(usize, vertex_count) * targets.len;

    var any_normal = false;
    for (targets) |target| {
        if (target.normal != null) any_normal = true;
    }

    var deltas: MorphDeltas = .{
        .positions = try allocator.alloc(f32, elements * 3),
        .normals = &.{},
        .target_count = @intCast(targets.len),
    };
    errdefer deltas.deinit(allocator);
    @memset(deltas.positions, 0.0);
    if (any_normal) {
        deltas.normals = try allocator.alloc(f32, elements * 3);
        @memset(deltas.normals, 0.0);
    }

    for (targets, 0..) |target, index| {
        if (target.position) |accessor|
            try scatterDeltas(allocator, doc, accessor, deltas.positions, targets.len, index);
        if (target.normal) |accessor|
            try scatterDeltas(allocator, doc, accessor, deltas.normals, targets.len, index);
    }
    return deltas;
}

fn scatterDeltas(
    allocator: Allocator,
    doc: *const Document,
    accessor_index: u32,
    destination: []f32,
    target_count: usize,
    target: usize,
) Error!void {
    const deltas = try readVectors(3, allocator, doc, accessor_index);
    defer allocator.free(deltas);

    for (deltas, 0..) |delta, vertex| {
        const at = (vertex * target_count + target) * 3;
        destination[at + 0] = delta[0];
        destination[at + 1] = delta[1];
        destination[at + 2] = delta[2];
    }
}

// Indices as u32, or the sequence 0..vertex_count for non-indexed geometry.
//
// The range check is not redundant with the document parser: an accessor's
// bounds say where its bytes are, not what they mean, and these values index
// this primitive's vertex array. generateTangents below reads through them, so
// an out of range index is an out of bounds read in a build without safety
// rather than a wrong picture. The reference left them unchecked.
fn readIndices(
    allocator: Allocator,
    doc: *const Document,
    accessor_index: ?u32,
    vertex_count: u32,
) Error![]u32 {
    const index = accessor_index orelse {
        const sequence = try allocator.alloc(u32, vertex_count);
        for (sequence, 0..) |*value, position| value.* = @intCast(position);
        return sequence;
    };

    const indices = try allocator.alloc(u32, doc.accessors[index].count);
    errdefer allocator.free(indices);
    switch (doc.accessors[index].component_type) {
        .u32 => try doc.read(u32, index, indices),
        inline .u8, .u16 => |component_type| {
            const Component = if (component_type == .u8) u8 else u16;
            const raw = try allocator.alloc(Component, indices.len);
            defer allocator.free(raw);
            try doc.read(Component, index, raw);
            for (indices, raw) |*value, narrow| value.* = narrow;
        },
        else => return error.TypeMismatch,
    }

    for (indices) |value| {
        if (value >= vertex_count) return error.VertexIndexOutOfRange;
    }
    return indices;
}

fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

// Any unit vector orthogonal to n, for a vertex whose UV gradient vanishes
// because every triangle around it has zero UV area. Picking the world axis
// least aligned with n and orthogonalizing keeps the basis well formed instead
// of leaving a zero tangent, which a shader would normalize into NaN.
fn orthogonalTo(normal: Vec3) Vec3 {
    const magnitude = @abs(normal);
    const axis: Vec3 = if (magnitude[0] <= magnitude[1] and magnitude[0] <= magnitude[2])
        .{ 1.0, 0.0, 0.0 }
    else if (magnitude[1] <= magnitude[2])
        .{ 0.0, 1.0, 0.0 }
    else
        .{ 0.0, 0.0, 1.0 };
    return normalize(axis - normal * @as(Vec3, @splat(dot(normal, axis))));
}

fn normalize(v: Vec3) Vec3 {
    const length = @sqrt(dot(v, v));
    if (length <= 1e-8) return .{ 1.0, 0.0, 0.0 };
    return v / @as(Vec3, @splat(length));
}

// Per-triangle tangents and bitangents weighted by the UV gradient, accumulated
// per vertex and then orthogonalized against the vertex normal, with the
// handedness that reconstructs the bitangent stored in w.
//
// Eric Lengyel, "Computing Tangent Space Basis Vectors for an Arbitrary Mesh",
// Terathon Software 3D Graphics Library, 2001. The specification RECOMMENDS
// MikkTSpace instead, section 3.7.2.1; this is the simpler accumulation, exact
// for a planar UV mapping and close on a smoothly shaded mesh. It is
// deterministic and allocates two scratch arrays that are freed before return.
fn generateTangents(allocator: Allocator, vertices: []Vertex3D, indices: []const u32) Error!void {
    const tangents = try allocator.alloc(Vec3, vertices.len);
    defer allocator.free(tangents);
    const bitangents = try allocator.alloc(Vec3, vertices.len);
    defer allocator.free(bitangents);
    @memset(tangents, @splat(0.0));
    @memset(bitangents, @splat(0.0));

    var triangle: usize = 0;
    while (triangle + 3 <= indices.len) : (triangle += 3) {
        const corners = indices[triangle..][0..3].*;
        const origin = vertices[corners[0]];
        const edge1 = vertices[corners[1]].position - origin.position;
        const edge2 = vertices[corners[2]].position - origin.position;
        const uv1 = vertices[corners[1]].uv - origin.uv;
        const uv2 = vertices[corners[2]].uv - origin.uv;

        // Zero UV area leaves the triangle out of the accumulation rather than
        // dividing by it. A vertex with no other triangle then falls through to
        // orthogonalTo below.
        const determinant = uv1[0] * uv2[1] - uv2[0] * uv1[1];
        if (@abs(determinant) <= 1e-12) continue;
        const inverse: Vec3 = @splat(1.0 / determinant);

        const tangent = (edge1 * @as(Vec3, @splat(uv2[1])) - edge2 * @as(Vec3, @splat(uv1[1]))) * inverse;
        const bitangent = (edge2 * @as(Vec3, @splat(uv1[0])) - edge1 * @as(Vec3, @splat(uv2[0]))) * inverse;
        for (corners) |corner| {
            tangents[corner] += tangent;
            bitangents[corner] += bitangent;
        }
    }

    for (vertices, tangents, bitangents) |*vertex, accumulated, bitangent| {
        const normal = vertex.normal;
        // Gram-Schmidt against the normal, so the basis stays orthogonal where
        // the accumulated tangent leans out of the surface.
        const projected = accumulated - normal * @as(Vec3, @splat(dot(normal, accumulated)));
        const length = @sqrt(dot(projected, projected));
        const tangent = if (length > 1e-8)
            projected / @as(Vec3, @splat(length))
        else
            orthogonalTo(normal);
        const handedness: f32 = if (dot(cross(normal, tangent), bitangent) < 0.0) -1.0 else 1.0;
        vertex.tangent = .{ tangent[0], tangent[1], tangent[2], handedness };
    }
}
