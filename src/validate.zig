const std = @import("std");
const schema = @import("json_schema.zig");
const types = @import("types.zig");

const ArenaAllocator = std.heap.ArenaAllocator;

pub const Error = error{
    OutOfMemory,
    UnsupportedVersion,
    UnsupportedExtension,
    UnsupportedPrimitiveMode,
    UnsupportedTexCoord,
    UnsupportedMatrixPadding,
    InvalidImageMimeType,
    IndexOutOfRange,
    InvalidStructure,
    NodeGraphTooDeep,
};

// The limit on node nesting, and the one thing that lets every tree walk in this
// module recurse. Depth is the only property of a document that turns into stack
// consumption, and a walk that overflows the stack crashes instead of returning
// an error, which is not what this parser does with anything else a file
// controls. Bounding it once, here, is what makes the walks safe by
// construction rather than by the observation that assets are shallow.
//
// Both numbers behind the value are measured, not assumed.
//
// Across the Khronos glTF-Sample-Assets collection and this project's own level
// and object files, 355 documents, the deepest nesting is 30, in
// RecursiveSkeletons, the sample built to nest. The 95th percentile is 8 and the
// median is 1. The limit is thirty-four times the deepest of them.
//
// Cost at the limit: the graph walk in dynamic_nodes.zig compiles to a 256-byte
// frame on x86-64 in Debug (`subq $0xf0, %rsp` plus the saved base pointer and
// the return address), so 1024 levels is 256 KiB of stack. That fits a thread
// stack an order of magnitude smaller than any default, and Debug is the worst
// case: the same frame is 112 bytes in ReleaseFast.
//
// Without the limit the same walk segfaults at 65 536 levels given a 16 MiB
// stack, which is that size divided by the frame exactly, and the file that
// reaches it is 1.4 MB of JSON. Halve the stack and halve the depth.
const max_node_depth = 1024;

pub const Result = struct {
    default_scene: ?u32,
    scenes: []const types.Scene,
    nodes: []const types.Node,
    meshes: []const types.Mesh,
    accessors: []const types.Accessor,
    buffer_views: []const types.BufferView,
    buffer_descs: []const types.BufferDesc,
    materials: []const types.Material,
    textures: []const types.Texture,
    images: []const types.Image,
    samplers: []const types.Sampler,
    skins: []const types.Skin,
    animations: []const types.Animation,
    cameras: []const types.Camera,
    lights: []const types.Light,
};

const supported_extensions = [_][]const u8{
    "KHR_texture_transform",
    "KHR_lights_punctual",
    "KHR_materials_emissive_strength",
    "KHR_materials_unlit",
    "KHR_node_visibility",
};

pub fn convert(arena: *ArenaAllocator, root: *const schema.Root) Error!Result {
    const allocator = arena.allocator();
    try validateVersion(root.asset);
    try validateExtensions(root);
    try validateTopLevelCounts(root);

    const buffer_views = try convertBufferViews(allocator, root);
    const accessors = try convertAccessors(allocator, root);
    const buffer_descs = try convertBuffers(allocator, root);
    const cameras = try convertCameras(allocator, root);
    const lights = try convertLights(allocator, root);
    const meshes = try convertMeshes(allocator, root, accessors);
    try validateSharedViewStride(allocator, root);
    const materials = try convertMaterials(allocator, root);
    const textures = try convertTextures(allocator, root);
    const images = try convertImages(allocator, root);
    const samplers = try convertSamplers(allocator, root);

    const parent = try validateNodeForest(allocator, root);
    const nodes = try convertNodes(allocator, root, meshes, lights.len);
    const scenes = try convertScenes(allocator, root, parent);
    const skins = try convertSkins(allocator, root, accessors, parent);
    const animations = try convertAnimations(allocator, root, accessors, meshes);

    const default_scene = root.scene;
    if (default_scene) |index| try checkIndex(index, scenes.len);

    return .{
        .default_scene = default_scene,
        .scenes = scenes,
        .nodes = nodes,
        .meshes = meshes,
        .accessors = accessors,
        .buffer_views = buffer_views,
        .buffer_descs = buffer_descs,
        .materials = materials,
        .textures = textures,
        .images = images,
        .samplers = samplers,
        .skins = skins,
        .animations = animations,
        .cameras = cameras,
        .lights = lights,
    };
}

// Sections 5.9.3 and 5.9.4 give both fields the pattern ^[0-9]+\.[0-9]+$ and
// make minVersion what a client compares against its own support. Major 2 minor
// 0 is what this parser implements, so a higher minVersion is refused rather
// than attempted. The specification's own constraint, that minVersion is not
// greater than version, needs no separate check: anything it would reject is
// already outside the one release supported here.
fn validateVersion(asset: schema.Asset) Error!void {
    const target = parseVersion(asset.version) orelse return error.UnsupportedVersion;
    if (target.major != 2) return error.UnsupportedVersion;
    if (asset.minVersion) |minimum| {
        const version = parseVersion(minimum) orelse return error.UnsupportedVersion;
        if (version.major != 2 or version.minor > 0) return error.UnsupportedVersion;
    }
}

fn parseVersion(text: []const u8) ?struct { major: u32, minor: u32 } {
    const separator = std.mem.indexOfScalar(u8, text, '.') orelse return null;
    if (separator == 0 or separator + 1 == text.len) return null;
    if (std.mem.indexOfScalarPos(u8, text, separator + 1, '.') != null) return null;
    return .{
        .major = std.fmt.parseUnsigned(u32, text[0..separator], 10) catch return null,
        .minor = std.fmt.parseUnsigned(u32, text[separator + 1 ..], 10) catch return null,
    };
}

// Section 3.12: every extension an asset uses is listed in extensionsUsed, and
// "extensionsRequired is a subset of extensionsUsed". Being listed as used is
// not a reason to refuse a document. Being listed as required is, because the
// asset is then declaring it does not load without behaviour this parser has
// not got.
fn validateExtensions(root: *const schema.Root) Error!void {
    try validateUniqueStrings(root.extensionsUsed);
    try validateUniqueStrings(root.extensionsRequired);

    for (root.extensionsRequired) |required| {
        if (!containsString(root.extensionsUsed, required)) return error.InvalidStructure;
        if (!containsString(&supported_extensions, required))
            return error.UnsupportedExtension;
    }

    if (root.extensions.KHR_lights_punctual != null)
        try requireExtension(root, "KHR_lights_punctual");

    for (root.materials) |material| {
        if (material.extensions.KHR_materials_emissive_strength != null)
            try requireExtension(root, "KHR_materials_emissive_strength");
        if (material.extensions.KHR_materials_unlit != null)
            try requireExtension(root, "KHR_materials_unlit");
        inline for (.{
            material.pbrMetallicRoughness.baseColorTexture,
            material.pbrMetallicRoughness.metallicRoughnessTexture,
            material.normalTexture,
            material.occlusionTexture,
            material.emissiveTexture,
        }) |info| {
            if (info) |texture_info| {
                if (texture_info.extensions.KHR_texture_transform != null)
                    try requireExtension(root, "KHR_texture_transform");
            }
        }
    }

    for (root.nodes) |node| {
        if (node.extensions.KHR_lights_punctual != null)
            try requireExtension(root, "KHR_lights_punctual");
        if (node.extensions.KHR_node_visibility != null)
            try requireExtension(root, "KHR_node_visibility");
    }
}

fn requireExtension(root: *const schema.Root, name: []const u8) Error!void {
    if (!containsString(root.extensionsUsed, name)) return error.InvalidStructure;
}

fn validateUniqueStrings(values: []const []const u8) Error!void {
    for (values, 0..) |value, i| {
        for (values[0..i]) |previous| {
            if (std.mem.eql(u8, value, previous)) return error.InvalidStructure;
        }
    }
}

fn containsString(values: []const []const u8, sought: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, sought)) return true;
    }
    return false;
}

fn validateTopLevelCounts(root: *const schema.Root) Error!void {
    inline for (.{
        root.scenes.len,
        root.nodes.len,
        root.meshes.len,
        root.accessors.len,
        root.bufferViews.len,
        root.buffers.len,
        root.materials.len,
        root.textures.len,
        root.images.len,
        root.samplers.len,
        root.skins.len,
        root.animations.len,
        root.cameras.len,
    }) |len| {
        if (len > std.math.maxInt(u32)) return error.InvalidStructure;
    }
}

fn convertBufferViews(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.BufferView {
    const output = try allocator.alloc(types.BufferView, root.bufferViews.len);
    for (root.bufferViews, output) |source, *destination| {
        try checkIndex(source.buffer, root.buffers.len);
        // Section 5.11.3: byteLength has minimum 1.
        if (source.byteLength == 0) return error.InvalidStructure;
        // Section 5.11.4 gives byteStride minimum 4 and maximum 252, and the
        // bufferView schema printed with it adds "multipleOf": 4. The prose
        // reason is in section 3.6.2.4: each element of a vertex attribute is
        // aligned to a four-byte boundary inside the view, so byteStride is a
        // multiple of 4.
        if (source.byteStride) |stride| {
            if (stride < 4 or stride > 252 or stride % 4 != 0)
                return error.InvalidStructure;
        }
        destination.* = .{
            .buffer = source.buffer,
            .byte_offset = source.byteOffset,
            .byte_length = source.byteLength,
            .byte_stride = source.byteStride,
        };
    }
    return output;
}

fn convertAccessors(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.Accessor {
    const output = try allocator.alloc(types.Accessor, root.accessors.len);
    for (root.accessors, output) |source, *destination| {
        if (source.bufferView) |view| try checkIndex(view, root.bufferViews.len);
        // Section 3.6.2.3: a base array with no bufferView is zeros, which is
        // only a document if a sparse overlay says what differs from them.
        if (source.bufferView == null and source.sparse == null)
            return error.InvalidStructure;
        // Section 5.1.5: count has minimum 1. Everything below, and the span
        // arithmetic the document performs at attach time, reads count - 1.
        if (source.count == 0) return error.InvalidStructure;
        // Section 5.1.4: normalized "MUST NOT be set to true for accessors with
        // FLOAT or UNSIGNED_INT component type".
        if (source.normalized and (source.componentType == .f32 or source.componentType == .u32))
            return error.InvalidStructure;
        // Section 3.6.2.4: the accessor's offset into the view, and its offset
        // into the buffer, are both multiples of the component size. The second
        // is checked below, where the view is in hand.
        if (source.byteOffset % source.componentType.size() != 0)
            return error.InvalidStructure;

        const kind: types.ElementKind = switch (source.type) {
            .SCALAR => .scalar,
            .VEC2 => .vec2,
            .VEC3 => .vec3,
            .VEC4 => .vec4,
            .MAT2 => .mat2,
            .MAT3 => .mat3,
            .MAT4 => .mat4,
        };
        if (matrixNeedsPadding(source.componentType, kind))
            return error.UnsupportedMatrixPadding;
        if (source.bufferView) |view_index| {
            const view = root.bufferViews[view_index];
            if ((@as(u64, view.byteOffset) + source.byteOffset) % source.componentType.size() != 0)
                return error.InvalidStructure;
            // Section 3.6.2.4: a defined byteStride is a multiple of the
            // component size, and an element has to fit within one stride.
            if (view.byteStride) |stride| {
                const element_size = source.componentType.size() * kind.componentCount();
                if (stride < element_size or stride % source.componentType.size() != 0)
                    return error.InvalidStructure;
            }
        }

        destination.* = .{
            .buffer_view = source.bufferView,
            .byte_offset = source.byteOffset,
            .component_type = source.componentType,
            .kind = kind,
            .count = source.count,
            .normalized = source.normalized,
            .sparse = if (source.sparse) |sparse|
                try convertSparse(root, source, sparse)
            else
                null,
        };
    }
    return output;
}

// Section 3.6.2.3 and the property tables in sections 5.2 to 5.4. Everything
// checkable without the buffer bytes is checked here; that the indices strictly
// increase and stay below the base count needs the bytes and is checked when
// they are attached.
fn convertSparse(
    root: *const schema.Root,
    accessor: schema.Accessor,
    sparse: schema.Sparse,
) Error!types.Sparse {
    // Section 5.2.1 gives count minimum 1, and section 3.6.2.3 says it "MUST NOT
    // be greater than the number of the base accessor elements".
    if (sparse.count == 0 or sparse.count > accessor.count) return error.InvalidStructure;
    // Section 5.3.3: the index type is one of the three unsigned integers.
    switch (sparse.indices.componentType) {
        .u8, .u16, .u32 => {},
        .i8, .i16, .f32 => return error.InvalidStructure,
    }

    try checkIndex(sparse.indices.bufferView, root.bufferViews.len);
    try checkIndex(sparse.values.bufferView, root.bufferViews.len);
    const index_view = root.bufferViews[sparse.indices.bufferView];
    const value_view = root.bufferViews[sparse.values.bufferView];

    // Sections 5.3.1 and 5.4.1: neither view may define byteStride. Both hold
    // tightly packed data, and a stride would describe something else.
    if (index_view.byteStride != null or value_view.byteStride != null)
        return error.InvalidStructure;

    // Section 5.3.1: the index view and its byteOffset are aligned to the index
    // component size. Section 5.4 puts the values under the base accessor's own
    // alignment rule instead, which is its component size.
    const index_size = sparse.indices.componentType.size();
    if ((@as(u64, index_view.byteOffset) + sparse.indices.byteOffset) % index_size != 0)
        return error.InvalidStructure;
    const value_size = accessor.componentType.size();
    if ((@as(u64, value_view.byteOffset) + sparse.values.byteOffset) % value_size != 0)
        return error.InvalidStructure;

    return .{
        .count = sparse.count,
        .index_buffer_view = sparse.indices.bufferView,
        .index_byte_offset = sparse.indices.byteOffset,
        .index_component_type = sparse.indices.componentType,
        .value_buffer_view = sparse.values.bufferView,
        .value_byte_offset = sparse.values.byteOffset,
    };
}

// A buffer view shared by two vertex attributes has to declare its stride.
// Nothing downstream can recover from its absence: a reader with no stride uses
// the tightly packed one, so interleaved data comes back as though it were
// packed and the geometry is silently wrong rather than rejected.
//
// The specification states this twice and not identically. Section 5.11.4 says
// "when two or more accessors use the same buffer view", section 3.6.2.4 says
// "when two or more vertex attribute accessors use the same bufferView". The
// narrower sentence is the one implemented, because the wider one would reject
// two index accessors sharing a view, which is a layout the same section
// permits: byteStride belongs to vertex attribute data, and section 3.6.1.1
// forbids it on views holding anything else.
//
// Runs after the meshes are converted, which is where an attribute's accessor
// index is checked.
fn validateSharedViewStride(
    allocator: std.mem.Allocator,
    root: *const schema.Root,
) Error!void {
    // Attributes are marked before views are counted, so an accessor two
    // primitives share is one user of its view rather than two.
    const is_attribute = try allocator.alloc(bool, root.accessors.len);
    @memset(is_attribute, false);
    for (root.meshes) |mesh| {
        for (mesh.primitives) |primitive| {
            const attributes = primitive.attributes;
            inline for (.{
                attributes.POSITION,
                attributes.NORMAL,
                attributes.TANGENT,
                attributes.TEXCOORD_0,
                attributes.TEXCOORD_1,
                attributes.COLOR_0,
                attributes.JOINTS_0,
                attributes.WEIGHTS_0,
            }) |index| {
                if (index) |accessor_index| is_attribute[accessor_index] = true;
            }
            for (primitive.targets orelse &.{}) |target| {
                inline for (.{ target.POSITION, target.NORMAL, target.TANGENT }) |index| {
                    if (index) |accessor_index| is_attribute[accessor_index] = true;
                }
            }
        }
    }

    const users = try allocator.alloc(u32, root.bufferViews.len);
    @memset(users, 0);
    for (root.accessors, is_attribute) |accessor, attribute| {
        if (!attribute) continue;
        users[accessor.bufferView orelse continue] += 1;
    }
    for (users, root.bufferViews) |count, view| {
        if (count > 1 and view.byteStride == null) return error.InvalidStructure;
    }
}

// Section 3.6.2.4: matrix data is column-major and each column starts on a
// four-byte boundary, so when ROWS * SIZE_OF_COMPONENT is not a multiple of 4
// the file carries padding at the end of every column. The same section lists
// the only three configurations that need it: 2x2 and 3x3 with one-byte
// components, 3x3 with two-byte components. This reader copies elements whole
// and does not unpack columns, so it names those three rather than mis-reading
// them.
fn matrixNeedsPadding(component_type: types.ComponentType, kind: types.ElementKind) bool {
    const rows: u32 = switch (kind) {
        .mat2 => 2,
        .mat3 => 3,
        .mat4 => 4,
        else => return false,
    };
    return rows * component_type.size() % 4 != 0;
}

fn convertBuffers(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.BufferDesc {
    const output = try allocator.alloc(types.BufferDesc, root.buffers.len);
    for (root.buffers, output) |source, *destination| {
        // Section 5.10.2: byteLength has minimum 1.
        if (source.byteLength == 0) return error.InvalidStructure;
        destination.* = .{ .uri = source.uri, .byte_length = source.byteLength };
    }
    return output;
}

fn convertCameras(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.Camera {
    const output = try allocator.alloc(types.Camera, root.cameras.len);
    for (root.cameras, output) |source, *destination| {
        destination.name = source.name;
        destination.projection = switch (source.type) {
            .perspective => block: {
                if (source.orthographic != null) return error.InvalidStructure;
                const perspective = source.perspective orelse return error.InvalidStructure;
                if (perspective.aspectRatio) |aspect_ratio| {
                    if (aspect_ratio <= 0.0) return error.InvalidStructure;
                }
                if (perspective.yfov <= 0.0 or perspective.yfov >= std.math.pi or perspective.znear <= 0.0)
                    return error.InvalidStructure;
                if (perspective.zfar) |far| {
                    if (far <= perspective.znear) return error.InvalidStructure;
                }
                break :block .{ .perspective = .{
                    .aspect_ratio = perspective.aspectRatio,
                    .yfov = perspective.yfov,
                    .znear = perspective.znear,
                    .zfar = perspective.zfar,
                } };
            },
            .orthographic => block: {
                if (source.perspective != null) return error.InvalidStructure;
                const orthographic = source.orthographic orelse return error.InvalidStructure;
                if (orthographic.xmag == 0.0 or orthographic.ymag == 0.0 or
                    orthographic.znear < 0.0 or orthographic.zfar <= orthographic.znear)
                    return error.InvalidStructure;
                break :block .{ .orthographic = .{
                    .xmag = orthographic.xmag,
                    .ymag = orthographic.ymag,
                    .znear = orthographic.znear,
                    .zfar = orthographic.zfar,
                } };
            },
        };
    }
    return output;
}

fn convertLights(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.Light {
    const source_lights = if (root.extensions.KHR_lights_punctual) |extension|
        extension.lights
    else
        &.{};
    const output = try allocator.alloc(types.Light, source_lights.len);
    for (source_lights, output) |source, *destination| {
        if (source.intensity < 0.0) return error.InvalidStructure;
        if (source.range) |range| {
            if (range <= 0.0) return error.InvalidStructure;
        }
        for (source.color) |component| {
            if (component < 0.0 or component > 1.0) return error.InvalidStructure;
        }

        const spot: ?types.SpotCone = if (source.type == .spot) block: {
            const cone = source.spot orelse return error.InvalidStructure;
            if (cone.innerConeAngle < 0.0 or cone.innerConeAngle >= cone.outerConeAngle or
                cone.outerConeAngle > std.math.pi / 2.0)
                return error.InvalidStructure;
            break :block .{
                .inner_angle = cone.innerConeAngle,
                .outer_angle = cone.outerConeAngle,
            };
        } else block: {
            if (source.spot != null) return error.InvalidStructure;
            break :block null;
        };

        destination.* = .{
            .name = source.name,
            .color = source.color,
            .intensity = source.intensity,
            .kind = switch (source.type) {
                .directional => .directional,
                .point => .point,
                .spot => .spot,
            },
            .range = source.range,
            .spot = spot,
        };
    }
    return output;
}

fn convertMeshes(
    allocator: std.mem.Allocator,
    root: *const schema.Root,
    accessors: []const types.Accessor,
) Error![]const types.Mesh {
    const output = try allocator.alloc(types.Mesh, root.meshes.len);
    for (root.meshes, output) |source, *destination| {
        const primitives = try allocator.alloc(types.Primitive, source.primitives.len);
        var target_count: ?usize = null;
        for (source.primitives, primitives) |primitive, *converted| {
            if (primitive.mode != 4) return error.UnsupportedPrimitiveMode;
            try validatePrimitiveAttributes(primitive, accessors);
            if (primitive.material) |material| try checkIndex(material, root.materials.len);

            const source_targets = primitive.targets orelse &.{};
            if (target_count) |count| {
                if (source_targets.len != count) return error.InvalidStructure;
            } else {
                target_count = source_targets.len;
            }
            const targets = try allocator.alloc(types.MorphTarget, source_targets.len);
            for (source_targets, targets) |target, *converted_target| {
                inline for (.{ target.POSITION, target.NORMAL, target.TANGENT }) |index| {
                    if (index) |accessor_index| {
                        try checkIndex(accessor_index, accessors.len);
                        const accessor = accessors[accessor_index];
                        if (accessor.component_type != .f32 or accessor.kind != .vec3)
                            return error.InvalidStructure;
                        if (primitive.attributes.POSITION) |position| {
                            if (accessor.count != accessors[position].count)
                                return error.InvalidStructure;
                        }
                    }
                }
                converted_target.* = .{
                    .position = target.POSITION,
                    .normal = target.NORMAL,
                    .tangent = target.TANGENT,
                };
            }

            converted.* = .{
                .position = primitive.attributes.POSITION,
                .normal = primitive.attributes.NORMAL,
                .tangent = primitive.attributes.TANGENT,
                .texcoord_0 = primitive.attributes.TEXCOORD_0,
                .texcoord_1 = primitive.attributes.TEXCOORD_1,
                .color_0 = primitive.attributes.COLOR_0,
                .joints_0 = primitive.attributes.JOINTS_0,
                .weights_0 = primitive.attributes.WEIGHTS_0,
                .indices = primitive.indices,
                .material = primitive.material,
                .targets = targets,
            };
        }

        const weights = source.weights orelse &.{};
        if (source.weights != null and weights.len != (target_count orelse 0))
            return error.InvalidStructure;
        destination.* = .{ .primitives = primitives, .weights = weights };
    }
    return output;
}

fn validatePrimitiveAttributes(primitive: schema.Primitive, accessors: []const types.Accessor) Error!void {
    const attributes = primitive.attributes;
    inline for (.{
        attributes.POSITION,
        attributes.NORMAL,
        attributes.TANGENT,
        attributes.TEXCOORD_0,
        attributes.TEXCOORD_1,
        attributes.COLOR_0,
        attributes.JOINTS_0,
        attributes.WEIGHTS_0,
    }) |index| {
        if (index) |accessor_index| try checkIndex(accessor_index, accessors.len);
    }
    if (primitive.indices) |index| try checkIndex(index, accessors.len);

    if (attributes.POSITION) |index| try expectAccessor(accessors[index], .f32, .vec3, false);
    if (attributes.NORMAL) |index| try expectAccessor(accessors[index], .f32, .vec3, false);
    if (attributes.TANGENT) |index| try expectAccessor(accessors[index], .f32, .vec4, false);
    inline for (.{ attributes.TEXCOORD_0, attributes.TEXCOORD_1 }) |index| {
        if (index) |accessor_index| {
            const accessor = accessors[accessor_index];
            if (accessor.kind != .vec2 or !isFloatOrNormalizedUnsigned(accessor))
                return error.InvalidStructure;
        }
    }
    if (attributes.COLOR_0) |index| {
        const accessor = accessors[index];
        if ((accessor.kind != .vec3 and accessor.kind != .vec4) or
            !isFloatOrNormalizedUnsigned(accessor))
            return error.InvalidStructure;
    }
    if (attributes.JOINTS_0) |index| {
        const accessor = accessors[index];
        if (accessor.kind != .vec4 or accessor.normalized or
            (accessor.component_type != .u8 and accessor.component_type != .u16))
            return error.InvalidStructure;
    }
    if (attributes.WEIGHTS_0) |index| {
        const accessor = accessors[index];
        if (accessor.kind != .vec4 or !isFloatOrNormalizedUnsigned(accessor))
            return error.InvalidStructure;
    }
    if (primitive.indices) |index| {
        const accessor = accessors[index];
        if (accessor.kind != .scalar or accessor.normalized or
            (accessor.component_type != .u8 and accessor.component_type != .u16 and
                accessor.component_type != .u32))
            return error.InvalidStructure;
    }

    const count = if (attributes.POSITION) |index| accessors[index].count else null;
    if (count) |vertex_count| {
        inline for (.{
            attributes.NORMAL,
            attributes.TANGENT,
            attributes.TEXCOORD_0,
            attributes.TEXCOORD_1,
            attributes.COLOR_0,
            attributes.JOINTS_0,
            attributes.WEIGHTS_0,
        }) |index| {
            if (index) |accessor_index| {
                if (accessors[accessor_index].count != vertex_count)
                    return error.InvalidStructure;
            }
        }
    }
}

fn expectAccessor(
    accessor: types.Accessor,
    component_type: types.ComponentType,
    kind: types.ElementKind,
    normalized: bool,
) Error!void {
    if (accessor.component_type != component_type or accessor.kind != kind or
        accessor.normalized != normalized)
        return error.InvalidStructure;
}

fn isFloatOrNormalizedUnsigned(accessor: types.Accessor) bool {
    return (accessor.component_type == .f32 and !accessor.normalized) or
        ((accessor.component_type == .u8 or accessor.component_type == .u16) and accessor.normalized);
}

fn convertMaterials(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.Material {
    const output = try allocator.alloc(types.Material, root.materials.len);
    for (root.materials, output) |source, *destination| {
        inline for (.{
            source.pbrMetallicRoughness.baseColorTexture,
            source.pbrMetallicRoughness.metallicRoughnessTexture,
            source.normalTexture,
            source.occlusionTexture,
            source.emissiveTexture,
        }) |info| {
            if (info) |texture_info| try checkIndex(texture_info.index, root.textures.len);
        }
        if (!componentsInUnitRange(&source.pbrMetallicRoughness.baseColorFactor) or
            source.pbrMetallicRoughness.metallicFactor < 0.0 or
            source.pbrMetallicRoughness.metallicFactor > 1.0 or
            source.pbrMetallicRoughness.roughnessFactor < 0.0 or
            source.pbrMetallicRoughness.roughnessFactor > 1.0 or
            !componentsInUnitRange(&source.emissiveFactor) or
            source.alphaCutoff < 0.0)
            return error.InvalidStructure;
        if (source.occlusionTexture) |occlusion| {
            if (occlusion.strength < 0.0 or occlusion.strength > 1.0)
                return error.InvalidStructure;
        }
        const emissive_strength = if (source.extensions.KHR_materials_emissive_strength) |extension|
            extension.emissiveStrength
        else
            1.0;
        if (emissive_strength < 0.0) return error.InvalidStructure;

        destination.* = .{
            .name = source.name,
            .base_color_texture = textureIndex(source.pbrMetallicRoughness.baseColorTexture),
            .base_color_factor = source.pbrMetallicRoughness.baseColorFactor,
            .base_color_uv = try resolveTexCoord(source.pbrMetallicRoughness.baseColorTexture),
            .metallic_roughness_texture = textureIndex(source.pbrMetallicRoughness.metallicRoughnessTexture),
            .metallic_factor = source.pbrMetallicRoughness.metallicFactor,
            .roughness_factor = source.pbrMetallicRoughness.roughnessFactor,
            .metallic_roughness_uv = try resolveTexCoord(source.pbrMetallicRoughness.metallicRoughnessTexture),
            .normal_texture = textureIndex(source.normalTexture),
            .normal_scale = if (source.normalTexture) |normal| normal.scale else 1.0,
            .normal_uv = try resolveTexCoord(source.normalTexture),
            .occlusion_texture = textureIndex(source.occlusionTexture),
            .occlusion_strength = if (source.occlusionTexture) |occlusion| occlusion.strength else 1.0,
            .occlusion_uv = try resolveTexCoord(source.occlusionTexture),
            .emissive_texture = textureIndex(source.emissiveTexture),
            .emissive_factor = source.emissiveFactor,
            .emissive_strength = emissive_strength,
            .emissive_uv = try resolveTexCoord(source.emissiveTexture),
            .alpha_mode = switch (source.alphaMode) {
                .OPAQUE => .opaque_mode,
                .MASK => .mask,
                .BLEND => .blend,
            },
            .alpha_cutoff = source.alphaCutoff,
            .double_sided = source.doubleSided,
            .unlit = source.extensions.KHR_materials_unlit != null,
        };
    }
    return output;
}

fn componentsInUnitRange(values: anytype) bool {
    for (values) |value| {
        if (value < 0.0 or value > 1.0) return false;
    }
    return true;
}

fn textureIndex(info: ?schema.TextureInfo) ?u32 {
    return if (info) |texture_info| texture_info.index else null;
}

fn resolveTexCoord(info: ?schema.TextureInfo) Error!types.TexCoord {
    const texture_info = info orelse return .{};
    const transform = texture_info.extensions.KHR_texture_transform;
    const set = if (transform) |value| value.texCoord orelse texture_info.texCoord else texture_info.texCoord;
    if (set > 1) return error.UnsupportedTexCoord;
    return .{
        .set = set,
        .offset = if (transform) |value| value.offset else .{ 0.0, 0.0 },
        .rotation = if (transform) |value| value.rotation else 0.0,
        .scale = if (transform) |value| value.scale else .{ 1.0, 1.0 },
    };
}

fn convertTextures(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.Texture {
    const output = try allocator.alloc(types.Texture, root.textures.len);
    for (root.textures, output) |source, *destination| {
        const image = source.source orelse return error.InvalidStructure;
        try checkIndex(image, root.images.len);
        if (source.sampler) |sampler| try checkIndex(sampler, root.samplers.len);
        destination.* = .{ .source = image, .sampler = source.sampler };
    }
    return output;
}

fn convertImages(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.Image {
    const output = try allocator.alloc(types.Image, root.images.len);
    for (root.images, output) |source, *destination| {
        if ((source.uri == null) == (source.bufferView == null)) return error.InvalidStructure;
        if (source.bufferView != null and source.mimeType == null) return error.InvalidStructure;
        if (source.bufferView) |view| try checkIndex(view, root.bufferViews.len);
        destination.* = .{
            .uri = source.uri,
            .buffer_view = source.bufferView,
            .mime_type = if (source.mimeType) |mime_type|
                if (std.mem.eql(u8, mime_type, "image/png"))
                    .png
                else if (std.mem.eql(u8, mime_type, "image/jpeg"))
                    .jpeg
                else
                    return error.InvalidImageMimeType
            else
                null,
        };
    }
    return output;
}

fn convertSamplers(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const types.Sampler {
    const output = try allocator.alloc(types.Sampler, root.samplers.len);
    for (root.samplers, output) |source, *destination| {
        destination.* = .{
            .mag_filter = source.magFilter,
            .min_filter = source.minFilter,
            .wrap_s = source.wrapS,
            .wrap_t = source.wrapT,
        };
    }
    return output;
}

fn validateNodeForest(allocator: std.mem.Allocator, root: *const schema.Root) Error![]const ?u32 {
    const parent = try allocator.alloc(?u32, root.nodes.len);
    @memset(parent, null);
    for (root.nodes, 0..) |node, parent_index| {
        for (node.children) |child| {
            try checkIndex(child, root.nodes.len);
            if (parent[child] != null) return error.InvalidStructure;
            parent[child] = @intCast(parent_index);
        }
    }

    const queue = try allocator.alloc(u32, root.nodes.len);
    var write_index: usize = 0;
    for (parent, 0..) |node_parent, index| {
        if (node_parent == null) {
            queue[write_index] = @intCast(index);
            write_index += 1;
        }
    }

    // Breadth first, one level per iteration, so the depth falls out of the walk
    // rather than costing an array. Reaching every node from a root is what
    // proves the graph is a forest: a cycle is unreachable from any parentless
    // node, so the count comes up short.
    var level_start: usize = 0;
    var level_end: usize = write_index;
    var depth: u32 = 0;
    while (level_start < level_end) {
        depth += 1;
        if (depth > max_node_depth) return error.NodeGraphTooDeep;
        for (queue[level_start..level_end]) |node| {
            for (root.nodes[node].children) |child| {
                queue[write_index] = child;
                write_index += 1;
            }
        }
        level_start = level_end;
        level_end = write_index;
    }
    if (write_index != root.nodes.len) return error.InvalidStructure;
    return parent;
}

fn convertNodes(
    allocator: std.mem.Allocator,
    root: *const schema.Root,
    meshes: []const types.Mesh,
    light_count: usize,
) Error![]const types.Node {
    const output = try allocator.alloc(types.Node, root.nodes.len);
    for (root.nodes, output) |source, *destination| {
        if (source.mesh) |mesh| try checkIndex(mesh, meshes.len);
        if (source.skin) |skin| {
            try checkIndex(skin, root.skins.len);
            if (source.mesh == null) return error.InvalidStructure;
        }
        if (source.camera) |camera| try checkIndex(camera, root.cameras.len);
        const light = if (source.extensions.KHR_lights_punctual) |extension| extension.light else null;
        if (light) |index| try checkIndex(index, light_count);
        if (source.matrix != null and
            (source.translation != null or source.rotation != null or source.scale != null))
            return error.InvalidStructure;

        const weights = source.weights orelse &.{};
        if (source.weights != null) {
            const mesh_index = source.mesh orelse return error.InvalidStructure;
            const target_count = if (meshes[mesh_index].primitives.len == 0)
                0
            else
                meshes[mesh_index].primitives[0].targets.len;
            if (weights.len != target_count) return error.InvalidStructure;
        }
        if (source.skin != null) {
            const mesh = meshes[source.mesh.?];
            for (mesh.primitives) |primitive| {
                if (primitive.joints_0 == null or primitive.weights_0 == null)
                    return error.InvalidStructure;
            }
        }

        destination.* = .{
            .name = source.name,
            .children = source.children,
            .mesh = source.mesh,
            .skin = source.skin,
            .camera = source.camera,
            .light = light,
            .translation = source.translation,
            .rotation = source.rotation,
            .scale = source.scale,
            .matrix = source.matrix,
            .weights = weights,
            .visible = if (source.extensions.KHR_node_visibility) |extension|
                extension.visible
            else
                true,
        };
    }
    return output;
}

fn convertScenes(
    allocator: std.mem.Allocator,
    root: *const schema.Root,
    parent: []const ?u32,
) Error![]const types.Scene {
    const output = try allocator.alloc(types.Scene, root.scenes.len);
    for (root.scenes, output) |source, *destination| {
        for (source.nodes) |node| {
            try checkIndex(node, root.nodes.len);
            if (parent[node] != null) return error.InvalidStructure;
        }
        destination.* = .{ .nodes = source.nodes };
    }
    return output;
}

fn convertSkins(
    allocator: std.mem.Allocator,
    root: *const schema.Root,
    accessors: []const types.Accessor,
    parent: []const ?u32,
) Error![]const types.Skin {
    const output = try allocator.alloc(types.Skin, root.skins.len);
    for (root.skins, output) |source, *destination| {
        if (source.joints.len == 0) return error.InvalidStructure;
        for (source.joints, 0..) |joint, index| {
            try checkIndex(joint, root.nodes.len);
            for (source.joints[0..index]) |previous| {
                if (joint == previous) return error.InvalidStructure;
            }
        }
        if (source.skeleton) |skeleton| {
            try checkIndex(skeleton, root.nodes.len);
            for (source.joints) |joint| {
                if (!isAncestor(skeleton, joint, parent)) return error.InvalidStructure;
            }
        }
        if (source.inverseBindMatrices) |index| {
            try checkIndex(index, accessors.len);
            try expectAccessor(accessors[index], .f32, .mat4, false);
            if (accessors[index].count != source.joints.len) return error.InvalidStructure;
        }
        destination.* = .{
            .joints = source.joints,
            .skeleton = source.skeleton,
            .inverse_bind_matrices = source.inverseBindMatrices,
        };
    }
    return output;
}

fn isAncestor(ancestor: u32, node: u32, parent: []const ?u32) bool {
    var current: ?u32 = node;
    while (current) |index| : (current = parent[index]) {
        if (index == ancestor) return true;
    }
    return false;
}

fn convertAnimations(
    allocator: std.mem.Allocator,
    root: *const schema.Root,
    accessors: []const types.Accessor,
    meshes: []const types.Mesh,
) Error![]const types.Animation {
    const output = try allocator.alloc(types.Animation, root.animations.len);
    for (root.animations, output) |source, *destination| {
        if (source.channels.len == 0 or source.samplers.len == 0)
            return error.InvalidStructure;
        const samplers = try allocator.alloc(types.AnimationSampler, source.samplers.len);
        for (source.samplers, samplers) |animation_sampler, *converted| {
            try checkIndex(animation_sampler.input, accessors.len);
            try checkIndex(animation_sampler.output, accessors.len);
            try expectAccessor(accessors[animation_sampler.input], .f32, .scalar, false);
            converted.* = .{
                .input = animation_sampler.input,
                .output = animation_sampler.output,
                .interpolation = switch (animation_sampler.interpolation) {
                    .LINEAR => .linear,
                    .STEP => .step,
                    .CUBICSPLINE => .cubicspline,
                },
            };
        }

        var core_channel_count: usize = 0;
        for (source.channels) |channel| {
            try checkIndex(channel.sampler, samplers.len);
            if (coreTargetPath(channel.target.path) != null) {
                const node = channel.target.node orelse return error.InvalidStructure;
                try checkIndex(node, root.nodes.len);
                // Section 3.5.3: "When a node is targeted for animation
                // (referenced by an animation.channel.target), only TRS
                // properties MAY be present; matrix MUST NOT be present." A
                // matrix holds no property a channel can write, so accepting
                // the pair would mean silently ignoring the animation. The
                // sentence is about being targeted at all, so it covers a
                // weights channel as much as a TRS one.
                if (root.nodes[node].matrix != null) return error.InvalidStructure;
                try validateAnimationOutput(channel, samplers, accessors, root, meshes);
                core_channel_count += 1;
            } else if (!std.mem.eql(u8, channel.target.path, "pointer") or
                !containsString(root.extensionsUsed, "KHR_animation_pointer"))
            {
                return error.InvalidStructure;
            }
        }

        const channels = try allocator.alloc(types.AnimationChannel, core_channel_count);
        var channel_index: usize = 0;
        for (source.channels) |channel| {
            const path = coreTargetPath(channel.target.path) orelse continue;
            channels[channel_index] = .{
                .sampler = channel.sampler,
                .target_node = channel.target.node.?,
                .target_path = path,
            };
            channel_index += 1;
        }
        destination.* = .{ .name = source.name, .samplers = samplers, .channels = channels };
    }
    return output;
}

fn validateAnimationOutput(
    channel: schema.AnimationChannel,
    samplers: []const types.AnimationSampler,
    accessors: []const types.Accessor,
    root: *const schema.Root,
    meshes: []const types.Mesh,
) Error!void {
    const path = coreTargetPath(channel.target.path).?;
    const animation_sampler = samplers[channel.sampler];
    const input = accessors[animation_sampler.input];
    const output = accessors[animation_sampler.output];
    const width: u64 = switch (path) {
        .translation, .scale => block: {
            try expectAccessor(output, .f32, .vec3, false);
            break :block 1;
        },
        .rotation => block: {
            try expectAccessor(output, .f32, .vec4, false);
            break :block 1;
        },
        .weights => block: {
            try expectAccessor(output, .f32, .scalar, false);
            const node = root.nodes[channel.target.node.?];
            const mesh_index = node.mesh orelse return error.InvalidStructure;
            const mesh = meshes[mesh_index];
            if (mesh.primitives.len == 0) return error.InvalidStructure;
            break :block mesh.primitives[0].targets.len;
        },
    };
    const interpolation_width: u64 = if (animation_sampler.interpolation == .cubicspline) 3 else 1;
    const expected = @as(u64, input.count) * width * interpolation_width;
    if (output.count != expected) return error.InvalidStructure;
}

fn coreTargetPath(path: []const u8) ?types.TargetPath {
    if (std.mem.eql(u8, path, "translation")) return .translation;
    if (std.mem.eql(u8, path, "rotation")) return .rotation;
    if (std.mem.eql(u8, path, "scale")) return .scale;
    if (std.mem.eql(u8, path, "weights")) return .weights;
    return null;
}

fn checkIndex(index: u32, len: usize) Error!void {
    if (index >= len) return error.IndexOutOfRange;
}
