const std = @import("std");
const glb = @import("glb.zig");
const schema = @import("json_schema.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const ComponentType = types.ComponentType;
pub const ElementKind = types.ElementKind;
pub const Accessor = types.Accessor;
pub const BufferView = types.BufferView;
pub const BufferDesc = types.BufferDesc;
pub const MorphTarget = types.MorphTarget;
pub const Primitive = types.Primitive;
pub const Mesh = types.Mesh;
pub const Node = types.Node;
pub const PerspectiveCamera = types.PerspectiveCamera;
pub const OrthographicCamera = types.OrthographicCamera;
pub const Camera = types.Camera;
pub const LightKind = types.LightKind;
pub const SpotCone = types.SpotCone;
pub const Light = types.Light;
pub const Scene = types.Scene;
pub const AlphaMode = types.AlphaMode;
pub const TexCoord = types.TexCoord;
pub const Material = types.Material;
pub const Texture = types.Texture;
pub const Image = types.Image;
pub const ImageMimeType = types.ImageMimeType;
pub const MagFilter = types.MagFilter;
pub const MinFilter = types.MinFilter;
pub const WrapMode = types.WrapMode;
pub const Sampler = types.Sampler;
pub const Skin = types.Skin;
pub const Interpolation = types.Interpolation;
pub const TargetPath = types.TargetPath;
pub const AnimationSampler = types.AnimationSampler;
pub const AnimationChannel = types.AnimationChannel;
pub const Animation = types.Animation;

pub const Error = validate.Error || glb.Error || error{
    InvalidJson,
    BufferCountMismatch,
    BufferSizeMismatch,
    BufferViewOutOfBounds,
    AccessorOutOfBounds,
    BuffersAlreadyAttached,
    BuffersNotAttached,
    TypeMismatch,
    CountMismatch,
};

const Container = enum {
    json,
    glb,
};

pub const Document = struct {
    // The arena itself is heap-allocated so Allocators derived from it retain a
    // stable context pointer when Document is returned or otherwise moved.
    arena: *ArenaAllocator,
    arena_owner: Allocator,

    default_scene: ?u32,
    scenes: []const Scene,
    nodes: []const Node,
    meshes: []const Mesh,
    accessors: []const Accessor,
    buffer_views: []const BufferView,
    buffer_descs: []const BufferDesc,
    materials: []const Material,
    textures: []const Texture,
    images: []const Image,
    samplers: []const Sampler,
    skins: []const Skin,
    animations: []const Animation,
    cameras: []const Camera,
    lights: []const Light,

    // The slice descriptors are arena-owned; the bytes remain borrowed from
    // the caller and must outlive the document.
    buffers: []const []const u8,
    buffers_attached: bool,

    // A GLB BIN chunk remains borrowed from the input blob. It is exposed
    // separately when the document also names external buffers, because a
    // complete buffer table cannot be attached until those are resolved.
    embedded_bin: ?[]const u8,

    pub fn initJson(gpa: Allocator, json_text: []const u8) Error!Document {
        return parseJson(gpa, json_text, .json);
    }

    pub fn initGlb(gpa: Allocator, blob: []const u8) Error!Document {
        const chunks = try glb.split(blob);
        var document = try parseJson(gpa, chunks.json, .glb);
        errdefer document.deinit();

        try document.validateGlbBuffers(chunks.bin);
        document.embedded_bin = chunks.bin;
        if (chunks.bin) |bin| {
            if (document.buffer_descs.len == 1)
                try document.attachBuffers(&.{bin});
        }
        return document;
    }

    pub fn deinit(self: *Document) void {
        const arena = self.arena;
        const owner = self.arena_owner;
        arena.deinit();
        owner.destroy(arena);
        self.* = undefined;
    }

    // Attaches all binary buffers atomically. The descriptor table is copied
    // into the arena so callers may build it on the stack; only the byte slices
    // themselves are borrowed.
    pub fn attachBuffers(self: *Document, buffers: []const []const u8) Error!void {
        if (self.buffers_attached) return error.BuffersAlreadyAttached;
        if (buffers.len != self.buffer_descs.len) return error.BufferCountMismatch;
        for (buffers, self.buffer_descs) |buffer, description| {
            if (buffer.len < description.byte_length) return error.BufferSizeMismatch;
        }

        // glTF 2.0 section 3.6.1.1 bounds a view by buffer.byteLength, which is
        // not the length of the slice handed in: an exporter leaves whatever it
        // likes after the declared bytes, and a GLB BIN chunk is padded to four.
        // Bounding by the slice would let a view read that tail, so the
        // declaration is the bound and the size check above is what keeps the
        // slice at least that long.
        for (self.buffer_views) |view| {
            const declared = self.buffer_descs[view.buffer].byte_length;
            const end = @as(u64, view.byte_offset) + view.byte_length;
            if (end > declared) return error.BufferViewOutOfBounds;
        }

        for (self.accessors) |accessor| {
            if (accessor.sparse) |sparse| try self.validateSparse(buffers, accessor, sparse);

            const view_index = accessor.buffer_view orelse continue;
            const view = self.buffer_views[view_index];
            const element_size = accessor.elementSize();
            const stride = view.byte_stride orelse element_size;

            // The span the specification states in section 3.6.2.4. The last
            // element ends one element after its own start, not one stride.
            const span = @as(u64, accessor.byte_offset) +
                @as(u64, stride) * (accessor.count - 1) + element_size;
            if (span > view.byte_length) return error.AccessorOutOfBounds;
        }

        const owned = try self.arena.allocator().alloc([]const u8, buffers.len);
        @memcpy(owned, buffers);
        self.buffers = owned;
        self.buffers_attached = true;
    }

    pub fn read(
        self: *const Document,
        comptime T: type,
        accessor_index: u32,
        destination: []T,
    ) Error!void {
        if (accessor_index >= self.accessors.len) return error.IndexOutOfRange;
        const accessor = self.accessors[accessor_index];
        const info = comptime elementInfo(T);
        if (accessor.component_type != info.component_type or
            accessor.kind.componentCount() != info.arity)
            return error.TypeMismatch;
        if (destination.len != accessor.count) return error.CountMismatch;
        if (!self.buffers_attached) return error.BuffersNotAttached;

        const element_size = @sizeOf(T);
        const destination_bytes = std.mem.sliceAsBytes(destination);

        // Section 3.6.2.3: without a bufferView the base array is zeros, which
        // only a sparse overlay then makes meaningful. An accessor with neither
        // is rejected in convertAccessors, so the zero fill below always has an
        // overlay to follow and no third case exists.
        if (accessor.buffer_view) |view_index| {
            const view = self.buffer_views[view_index];
            const base = self.buffers[view.buffer][view.byte_offset..][0..view.byte_length];
            const source = base[accessor.byte_offset..];
            const stride = view.byte_stride orelse element_size;

            if (stride == element_size) {
                const byte_count = element_size * destination.len;
                @memcpy(destination_bytes, source[0..byte_count]);
            } else {
                for (0..destination.len) |index| {
                    @memcpy(
                        destination_bytes[index * element_size ..][0..element_size],
                        source[index * stride ..][0..element_size],
                    );
                }
            }
        } else {
            @memset(destination_bytes, 0);
        }

        // Every position, span and ordering the substitution relies on was
        // established by validateSparse when the buffers were attached.
        if (accessor.sparse) |sparse| {
            const indices = viewBytes(self.buffers, self.buffer_views, sparse.index_buffer_view);
            const values = viewBytes(self.buffers, self.buffer_views, sparse.value_buffer_view);
            for (0..sparse.count) |position| {
                const target = readIndex(indices, sparse, position);
                @memcpy(
                    destination_bytes[target * element_size ..][0..element_size],
                    values[sparse.value_byte_offset + position * element_size ..][0..element_size],
                );
            }
        }
    }

    // Returns the bytes of one view without exposing offset arithmetic to image
    // and importer code. The range was bounded against buffer.byteLength by
    // attachBuffers, which is what makes the slicing below unconditional.
    pub fn bufferViewBytes(self: *const Document, view_index: u32) Error![]const u8 {
        if (view_index >= self.buffer_views.len) return error.IndexOutOfRange;
        if (!self.buffers_attached) return error.BuffersNotAttached;
        const view = self.buffer_views[view_index];
        return self.buffers[view.buffer][view.byte_offset..][0..view.byte_length];
    }

    // The half of section 3.6.2.3 that needs bytes. Both overlay views are
    // tightly packed, so their spans are a count times an element size, and the
    // indices themselves have to be read to know they are ordered and in range.
    //
    // Called from attachBuffers after the views have been bounded, so slicing
    // one here needs no further check. The buffer table is the parameter rather
    // than the field, because nothing is bound until every accessor has passed.
    fn validateSparse(
        self: *const Document,
        buffers: []const []const u8,
        accessor: Accessor,
        sparse: types.Sparse,
    ) Error!void {
        const index_size = sparse.index_component_type.size();
        const index_span = @as(u64, sparse.index_byte_offset) +
            @as(u64, index_size) * sparse.count;
        const index_view = self.buffer_views[sparse.index_buffer_view];
        if (index_span > index_view.byte_length) return error.AccessorOutOfBounds;

        const value_span = @as(u64, sparse.value_byte_offset) +
            @as(u64, accessor.elementSize()) * sparse.count;
        const value_view = self.buffer_views[sparse.value_buffer_view];
        if (value_span > value_view.byte_length) return error.AccessorOutOfBounds;

        // Section 5.2.2: "Indices MUST strictly increase", and section 3.6.2.3
        // puts them below the base element count. Both are checked once here so
        // that read substitutes without comparing anything.
        const indices = viewBytes(buffers, self.buffer_views, sparse.index_buffer_view);
        var previous: ?u32 = null;
        for (0..sparse.count) |position| {
            const index = readIndex(indices, sparse, position);
            if (index >= accessor.count) return error.AccessorOutOfBounds;
            if (previous) |last| {
                if (index <= last) return error.InvalidStructure;
            }
            previous = index;
        }
    }

    fn validateGlbBuffers(self: *const Document, bin: ?[]const u8) Error!void {
        for (self.buffer_descs, 0..) |description, index| {
            if (description.uri == null and index != 0) return error.InvalidStructure;
        }

        if (bin) |bytes| {
            if (self.buffer_descs.len == 0 or self.buffer_descs[0].uri != null)
                return error.InvalidStructure;
            const declared = self.buffer_descs[0].byte_length;
            if (bytes.len < declared or bytes.len - declared > 3)
                return error.BufferSizeMismatch;
        } else if (self.buffer_descs.len != 0 and self.buffer_descs[0].uri == null) {
            return error.BufferCountMismatch;
        }
    }
};

fn parseJson(gpa: Allocator, json_text: []const u8, container: Container) Error!Document {
    const arena = try gpa.create(ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const root = std.json.parseFromSliceLeaky(schema.Root, arena.allocator(), json_text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (container == .json) {
        for (root.buffers) |buffer| {
            if (buffer.uri == null) return error.InvalidStructure;
        }
    }

    const converted = try validate.convert(arena, &root);
    return .{
        .arena = arena,
        .arena_owner = gpa,
        .default_scene = converted.default_scene,
        .scenes = converted.scenes,
        .nodes = converted.nodes,
        .meshes = converted.meshes,
        .accessors = converted.accessors,
        .buffer_views = converted.buffer_views,
        .buffer_descs = converted.buffer_descs,
        .materials = converted.materials,
        .textures = converted.textures,
        .images = converted.images,
        .samplers = converted.samplers,
        .skins = converted.skins,
        .animations = converted.animations,
        .cameras = converted.cameras,
        .lights = converted.lights,
        .buffers = &.{},
        .buffers_attached = converted.buffer_descs.len == 0,
        .embedded_bin = null,
    };
}

fn viewBytes(
    buffers: []const []const u8,
    views: []const BufferView,
    view_index: u32,
) []const u8 {
    const view = views[view_index];
    return buffers[view.buffer][view.byte_offset..][0..view.byte_length];
}

// One sparse index, widened to the u32 the base count is compared in. Section
// 5.3.3 admits only the three unsigned types, and validation rejected the rest
// before this ran.
fn readIndex(indices: []const u8, sparse: types.Sparse, position: usize) u32 {
    const at = sparse.index_byte_offset + position * sparse.index_component_type.size();
    return switch (sparse.index_component_type) {
        .u8 => indices[at],
        .u16 => std.mem.readInt(u16, indices[at..][0..2], .little),
        .u32 => std.mem.readInt(u32, indices[at..][0..4], .little),
        .i8, .i16, .f32 => unreachable,
    };
}

fn elementInfo(comptime T: type) struct { component_type: ComponentType, arity: u32 } {
    const type_info = @typeInfo(T);
    const Component = switch (type_info) {
        .array => |array| array.child,
        else => T,
    };
    const arity: u32 = switch (type_info) {
        .array => |array| @intCast(array.len),
        else => 1,
    };
    const component_type: ComponentType = switch (Component) {
        i8 => .i8,
        u8 => .u8,
        i16 => .i16,
        u16 => .u16,
        u32 => .u32,
        f32 => .f32,
        else => @compileError("unsupported accessor component type: " ++ @typeName(Component)),
    };
    return .{ .component_type = component_type, .arity = arity };
}
