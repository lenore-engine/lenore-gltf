const std = @import("std");
const zm = @import("zmath");
const resources = @import("lenore-resources");

const animation_parser = @import("animation_parser.zig");
const converter = @import("converter.zig");
const document = @import("document.zig");
const dynamic_nodes = @import("dynamic_nodes.zig");
const loader = @import("loader.zig");
const mesh_merger = @import("mesh_merger.zig");
const mesh_parser = @import("mesh_parser.zig");
const scene_graph = @import("scene_graph.zig");
const types = @import("types.zig");
const uri = @import("uri.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const MaterialInfo = resources.MaterialInfo;
const Slot = resources.Slot;
const Vertex3D = resources.Vertex3D;

pub const AnchorError = error{
    // A node the scene walk anchored geometry to earned no animator slot. The
    // two walks derive the slotted set from the same document, so this is a
    // disagreement between them rather than anything an asset can express.
    AnchorWithoutSlot,

    // A primitive with morph targets whose node earned no weight template. Both
    // sets come from the same document by different walks, so this is the same
    // kind of disagreement, and it would otherwise leave the geometry blended by
    // nothing while reporting a morphed mesh.
    MorphWithoutTemplate,
};

pub const Error = document.Error ||
    animation_parser.Error ||
    mesh_parser.Error ||
    mesh_merger.Error ||
    loader.ResolveError ||
    uri.DataUriError ||
    scene_graph.Error ||
    resources.MorphTemplate.InitError ||
    AnchorError;

// An image as the asset names it, never as pixels. Decoding, compressing and
// caching are a separate concern with its own dependencies, and a loader that
// decoded here would drag them into every build that only wants geometry.
pub const Image = struct {
    // Owned, and the identity a texture cache keys on. For a file it is the path
    // relative to the root the document was opened against, so an on-disk
    // artifact cache can use it as it stands.
    key: []const u8,
    // Owned. Null means the image lives at `key` and has not been read.
    bytes: ?[]const u8,
    mime: ?types.ImageMimeType,

    pub fn deinit(self: *Image, allocator: Allocator) void {
        allocator.free(self.key);
        if (self.bytes) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

// One draw's worth of geometry, in the space its anchor moves.
pub const Mesh = struct {
    vertices: []Vertex3D,
    indices: []u32,
    streams: resources.VertexStreams,
    morph: ?mesh_parser.MorphDeltas,
    // Always resolved. A primitive declaring none is given the default material
    // section 3.7.2.1 defines, which this importer appends when one is needed.
    material: u32,
    // The animator slot whose world transform moves this geometry, and null when
    // it is fully static. The vertices are baked relative to that slot's node,
    // so the draw's model matrix is the slot's world transform with whatever
    // placement the caller gives the model composed after it.
    //
    // A slot rather than the document node it came from: the node index has no
    // consumer past load, and resolving it per draw would mean carrying the map
    // that resolves it for as long as the model is alive.
    anchor: ?Slot,
    // The skin this geometry is bound to. A skinned mesh keeps its vertices in
    // local space, because the joint matrices carry the transform.
    skin: ?u32,
    // The weights that blend this geometry's morph targets, as an index into
    // Model.morph_templates, and null when it has none. Present exactly when
    // `morph` is.
    //
    // An index into that array rather than the document node the weights came
    // from, for the reason `anchor` is a slot: the node index has no consumer
    // past load, and resolving it per draw would mean carrying the map that
    // resolves it for as long as the model is alive.
    morph_template: ?u32,

    pub fn deinit(self: *Mesh, allocator: Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
        if (self.morph) |*morph| morph.deinit(allocator);
        self.* = undefined;
    }
};

// A KHR_lights_punctual light with the world transform of the node that
// references it. Kept as the extension defines it rather than packed into a
// shader layout: packing belongs to whoever owns that layout.
//
// The transform is the one the walk found at load. A light on an animated node
// holds that pose rather than following the animation.
pub const Light = struct {
    source: types.Light,
    world: zm.Mat,
};

pub const Skin = struct {
    skeleton: resources.SkeletonTemplate,
    // Every clip in the document, addressed by this skeleton's slots. All of
    // them, not the first: which clip plays is playback's choice.
    clips: []resources.Animation,
    index: u32,

    pub fn deinit(self: *Skin, allocator: Allocator) void {
        self.skeleton.deinit(allocator);
        for (self.clips) |*clip| clip.deinit(allocator);
        allocator.free(self.clips);
        self.* = undefined;
    }
};

// Everything a document produces, with nothing resident on a device. What turns
// this into draws is composition and belongs to the engine.
pub const Model = struct {
    meshes: []Mesh,
    materials: []MaterialInfo,
    // Indexed by the document's image indices, so a material's texture key is
    // found without a search.
    images: []Image,
    lights: []Light,
    skins: []Skin,
    node_animation: ?resources.NodeTemplate,
    // One per node that instantiates a mesh with morph targets. Per node and not
    // per mesh: section 3.7.4 makes the weights a property of the instantiation,
    // so two nodes sharing one mesh blend it independently.
    morph_templates: []resources.MorphTemplate,

    pub fn deinit(self: *Model, allocator: Allocator) void {
        for (self.meshes) |*mesh| mesh.deinit(allocator);
        allocator.free(self.meshes);
        for (self.materials) |*material| material.deinit(allocator);
        allocator.free(self.materials);
        for (self.images) |*image| image.deinit(allocator);
        allocator.free(self.images);
        allocator.free(self.lights);
        for (self.skins) |*skin| skin.deinit(allocator);
        allocator.free(self.skins);
        if (self.node_animation) |*animation| animation.deinit(allocator);
        for (self.morph_templates) |*template| template.deinit(allocator);
        allocator.free(self.morph_templates);
        self.* = undefined;
    }
};

// Turn a parsed document into a model. `directory` is where the document was
// read from, relative to the root, and is what image references resolve against;
// loader.open returns it.
//
// Nothing here opens a file. That is what lets the whole assembly be tested on
// documents built in memory, and it is the reason reading is a separate file.
pub fn build(
    allocator: Allocator,
    doc: *const Document,
    directory: []const u8,
) Error!Model {
    var model: Model = .{
        .meshes = &.{},
        .materials = &.{},
        .images = &.{},
        .lights = &.{},
        .skins = &.{},
        .node_animation = null,
        .morph_templates = &.{},
    };
    errdefer model.deinit(allocator);

    model.images = try buildImages(allocator, doc, directory);
    model.materials = try buildMaterials(allocator, doc, model.images);
    model.skins = try buildSkins(allocator, doc);

    // Load-time scratch, both of them. One turns the scene walk's node anchors
    // into the slots the meshes carry and the other its morphed nodes into
    // template indices. Once the geometry is built neither answers a question
    // anybody asks.
    const node_to_slot = try allocator.alloc(?Slot, doc.nodes.len);
    defer allocator.free(node_to_slot);
    const node_to_morph = try allocator.alloc(?u32, doc.nodes.len);
    defer allocator.free(node_to_morph);

    model.node_animation = try animation_parser.parseNodeAnimation(allocator, doc, node_to_slot);
    model.morph_templates = try buildMorphTemplates(allocator, doc, node_to_morph);
    try buildGeometry(allocator, doc, &model, node_to_slot, node_to_morph);
    return model;
}

// One entry per image the document declares, in its own index space, so a
// material's texture slot resolves without a search.
fn buildImages(
    allocator: Allocator,
    doc: *const Document,
    directory: []const u8,
) Error![]Image {
    const images = try allocator.alloc(Image, doc.images.len);
    var built: usize = 0;
    errdefer {
        for (images[0..built]) |*image| image.deinit(allocator);
        allocator.free(images);
    }

    for (doc.images, images, 0..) |source, *image, index| {
        image.* = try buildImage(allocator, doc, directory, source, index);
        built += 1;
    }
    return images;
}

fn buildImage(
    allocator: Allocator,
    doc: *const Document,
    directory: []const u8,
    source: types.Image,
    index: usize,
) Error!Image {
    if (source.uri) |reference| {
        if (!uri.isDataUri(reference)) {
            // A file, named but not read. An artifact cache may already hold a
            // converted form and never need the original.
            return .{
                .key = try loader.resolveConfined(allocator, directory, reference),
                .bytes = null,
                .mime = source.mime_type,
            };
        }
        const bytes = try uri.decodeImageDataUriAlloc(allocator, reference);
        errdefer allocator.free(bytes);
        return .{ .key = try embeddedKey(allocator, index), .bytes = bytes, .mime = source.mime_type };
    }

    // Section 5.18.1 gives an image a URI or a buffer view and validate.zig
    // refuses one with neither, so this is the second case rather than a third.
    const view = source.buffer_view orelse return error.InvalidStructure;
    const bytes = try allocator.dupe(u8, try doc.bufferViewBytes(view));
    errdefer allocator.free(bytes);
    return .{ .key = try embeddedKey(allocator, index), .bytes = bytes, .mime = source.mime_type };
}

// An identity for an image that has no path. It names the document's own index
// space and is not a path: the model says which of the two a key is by whether
// the image carries bytes, so the two never have to be told apart by spelling.
fn embeddedKey(allocator: Allocator, index: usize) Error![]u8 {
    return std.fmt.allocPrint(allocator, "embedded:{d}", .{index});
}

fn buildMaterials(
    allocator: Allocator,
    doc: *const Document,
    images: []const Image,
) Error![]MaterialInfo {
    // Section 3.7.2.1: a primitive may omit `material`, and it then renders with
    // the default material rather than with the document's first one. One is
    // appended when a primitive needs it, so a conformant document is untouched.
    var needs_default = false;
    for (doc.meshes) |mesh| {
        for (mesh.primitives) |primitive| {
            if (primitive.material == null) needs_default = true;
        }
    }

    const materials = try allocator.alloc(MaterialInfo, doc.materials.len + @intFromBool(needs_default));
    var built: usize = 0;
    errdefer {
        for (materials[0..built]) |*material| material.deinit(allocator);
        allocator.free(materials);
    }

    for (doc.materials, materials[0..doc.materials.len], 0..) |source, *material, index| {
        material.* = try buildMaterial(allocator, doc, images, source, index);
        built += 1;
    }
    if (needs_default) {
        // Every field of MaterialInfo already defaults to what the section
        // defines, so only the name needs storage.
        materials[built] = .{
            .name = try allocator.dupe(u8, "default"),
            .textures = .{},
            .factors = .{},
            .rendering = .{},
        };
        built += 1;
    }
    return materials;
}

fn buildMaterial(
    allocator: Allocator,
    doc: *const Document,
    images: []const Image,
    source: types.Material,
    index: usize,
) Error!MaterialInfo {
    const name = if (source.name) |declared|
        try allocator.dupe(u8, declared)
    else
        try std.fmt.allocPrint(allocator, "material_{d}", .{index});
    errdefer allocator.free(name);

    var textures: MaterialInfo.TextureMaps = .{};
    errdefer textures.deinit(allocator);
    textures.base_colour = try buildSlot(allocator, doc, images, source.base_color_texture, source.base_color_uv);
    textures.metallic_roughness = try buildSlot(allocator, doc, images, source.metallic_roughness_texture, source.metallic_roughness_uv);
    textures.normal = try buildSlot(allocator, doc, images, source.normal_texture, source.normal_uv);
    textures.emissive = try buildSlot(allocator, doc, images, source.emissive_texture, source.emissive_uv);
    textures.occlusion = try buildSlot(allocator, doc, images, source.occlusion_texture, source.occlusion_uv);

    return .{
        .name = name,
        .textures = textures,
        .factors = .{
            .base_colour = source.base_color_factor,
            .metallic = source.metallic_factor,
            .roughness = source.roughness_factor,
            // KHR_materials_emissive_strength scales the factor rather than
            // standing beside it, and folding it here is exact: the extension
            // defines the emitted radiance as the product.
            .emissive = .{
                source.emissive_factor[0] * source.emissive_strength,
                source.emissive_factor[1] * source.emissive_strength,
                source.emissive_factor[2] * source.emissive_strength,
            },
            .normal_scale = source.normal_scale,
            .occlusion_strength = source.occlusion_strength,
        },
        .rendering = .{
            .alpha_mode = switch (source.alpha_mode) {
                .opaque_mode => .@"opaque",
                .mask => .mask,
                .blend => .blend,
            },
            .alpha_cutoff = source.alpha_cutoff,
            .double_sided = source.double_sided,
            // KHR_materials_unlit is outside this stage's extension set, so the
            // document carries no such flag and every material is lit.
            .unlit = false,
        },
    };
}

fn buildSlot(
    allocator: Allocator,
    doc: *const Document,
    images: []const Image,
    texture: ?u32,
    uv: types.TexCoord,
) Error!MaterialInfo.TextureMaps.Slot {
    const index = texture orelse return .{ .uv = uvTransform(uv) };
    const source = doc.textures[index];

    // Section 3.8.2 lets a texture name a sampler and no image, which is a
    // texture an extension supplies and this loader has none of. The slot then
    // has no image and the material falls back to its factors.
    const path = if (source.source) |image|
        try allocator.dupe(u8, images[image].key)
    else
        null;

    return .{
        .path = path,
        .sampler = if (source.sampler) |sampler|
            converter.samplerConfig(doc.samplers[sampler])
        else
            .{},
        .uv = uvTransform(uv),
    };
}

fn uvTransform(uv: types.TexCoord) MaterialInfo.TextureMaps.UvTransform {
    return .{ .set = uv.set, .offset = uv.offset, .rotation = uv.rotation, .scale = uv.scale };
}

fn buildSkins(allocator: Allocator, doc: *const Document) Error![]Skin {
    var skins: std.ArrayList(Skin) = .empty;
    errdefer {
        for (skins.items) |*skin| skin.deinit(allocator);
        skins.deinit(allocator);
    }

    for (0..doc.skins.len) |index| {
        var hierarchy = (try animation_parser.buildJointHierarchy(
            allocator,
            doc,
            @intCast(index),
        )) orelse continue;
        defer hierarchy.deinit(allocator);

        var skeleton = try resources.SkeletonTemplate.init(allocator, hierarchy.templateInit());
        errdefer skeleton.deinit(allocator);

        const clips = try allocator.alloc(resources.Animation, doc.animations.len);
        var parsed: usize = 0;
        errdefer {
            for (clips[0..parsed]) |*clip| clip.deinit(allocator);
            allocator.free(clips);
        }
        for (clips, 0..) |*clip, animation| {
            clip.* = try animation_parser.parseClip(
                allocator,
                doc,
                @intCast(animation),
                hierarchy.node_to_slot,
            );
            parsed += 1;
        }

        try skins.append(allocator, .{
            .skeleton = skeleton,
            .clips = clips,
            .index = @intCast(index),
        });
    }
    return skins.toOwnedSlice(allocator);
}

// One template per node that instantiates a mesh with morph targets, and the map
// from the document's nodes onto them that the geometry walk reads.
//
// A node with such a mesh earns a template whether or not anything animates it:
// section 3.7.4 gives it a pose of its own, and a mesh whose weights never change
// still has to be blended by them.
fn buildMorphTemplates(
    allocator: Allocator,
    doc: *const Document,
    node_to_morph: []?u32,
) Error![]resources.MorphTemplate {
    @memset(node_to_morph, null);

    var templates: std.ArrayList(resources.MorphTemplate) = .empty;
    errdefer {
        for (templates.items) |*template| template.deinit(allocator);
        templates.deinit(allocator);
    }

    for (doc.nodes, node_to_morph, 0..) |node, *mapped, index| {
        const mesh = node.mesh orelse continue;
        const target_count = morphTargetCount(doc.meshes[mesh]);
        if (target_count == 0) continue;

        const parts = try morphTemplateParts(allocator, doc, @intCast(index), node, target_count);
        // Template.init owns both arrays from this call, including on failure,
        // so nothing above unwinds them.
        var template = try resources.MorphTemplate.init(allocator, parts);
        errdefer template.deinit(allocator);

        mapped.* = @intCast(templates.items.len);
        try templates.append(allocator, template);
    }
    return templates.toOwnedSlice(allocator);
}

// The clips and the default pose one node's weights need, owned by the caller and
// destroyed here if either half fails. Handing them over as the fields of a
// template rather than as two returns is what keeps the ownership transfer to
// Template.init a single expression.
fn morphTemplateParts(
    allocator: Allocator,
    doc: *const Document,
    node_index: u32,
    node: types.Node,
    target_count: usize,
) Error!resources.MorphTemplate {
    var clips: std.ArrayList(resources.Animation) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit(allocator);
        clips.deinit(allocator);
    }

    // Every animation that drives this node's weights, not the first of them:
    // which clip plays is playback's choice, as it is for a skin. Section 5.5.1
    // forbids two channels of one animation from sharing a target, so each
    // animation contributes at most one clip.
    for (0..doc.animations.len) |index| {
        var parsed = (try animation_parser.parseMorphWeights(
            allocator,
            doc,
            @intCast(index),
            node_index,
        )) orelse continue;
        errdefer parsed.animation.deinit(allocator);
        try clips.append(allocator, parsed.animation);
    }

    const owned = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned) |*clip| clip.deinit(allocator);
        allocator.free(owned);
    }
    return .{ .clips = owned, .defaults = try morphDefaults(allocator, doc, node, target_count) };
}

// The pose an instantiation starts from. glTF 2.0 specification, 3.7.4: the
// weights come from node.weights, from mesh.weights when that is undefined, and
// are all zero when both are.
//
// An absent array reaches here as an empty one, so a non-empty node array is a
// declared one: validate.zig requires either, where present, to be exactly as
// long as the target list, and a morphed mesh has at least one target.
fn morphDefaults(
    allocator: Allocator,
    doc: *const Document,
    node: types.Node,
    target_count: usize,
) Allocator.Error![]f32 {
    const declared = if (node.weights.len > 0)
        node.weights
    else
        doc.meshes[node.mesh.?].weights;

    const defaults = try allocator.alloc(f32, target_count);
    @memset(defaults, 0.0);
    const copied = @min(defaults.len, declared.len);
    @memcpy(defaults[0..copied], declared[0..copied]);
    return defaults;
}

// Section 3.7.2.2 gives every primitive of a mesh the same number of targets and
// validate.zig refuses a mesh whose primitives disagree, so the first answers for
// the whole mesh.
fn morphTargetCount(mesh: types.Mesh) usize {
    if (mesh.primitives.len == 0) return 0;
    return mesh.primitives[0].targets.len;
}

// The scene walk, and the only place where the parsed halves meet.
const Builder = struct {
    allocator: Allocator,
    doc: *const Document,
    model: *Model,
    // Every mesh's primitives, parsed once and read once per node that names the
    // mesh. A document routinely instances one mesh from several nodes.
    parsed: []const []mesh_parser.Primitive,
    merger: *mesh_merger.Merger,
    meshes: *std.ArrayList(Mesh),
    lights: *std.ArrayList(Light),
    default_material: u32,
    // Dense over the document's nodes, so a node index the walk produced indexes
    // either without a bound.
    node_to_slot: []const ?Slot,
    node_to_morph: []const ?u32,

    // The scene walk anchors geometry to a slotted node, and the animation parser
    // gave a slot to exactly the slotted nodes the default scene reaches. Both
    // sets come from dynamic_nodes.collect over the same document and the walk
    // here covers the same scene, so the lookup cannot miss.
    //
    // It is checked rather than assumed because the two derivations sit in
    // different files and neither reads the other. A miss would drop the anchor
    // and freeze the geometry at its bind pose, which looks like an asset with no
    // animation in it and reports nothing.
    fn anchorSlot(self: *const Builder, node: scene_graph.Node) AnchorError!?Slot {
        const index = node.anchor orelse return null;
        return self.node_to_slot[index] orelse error.AnchorWithoutSlot;
    }

    pub fn visit(self: *Builder, node: scene_graph.Node) Error!bool {
        if (self.doc.nodes[node.index].light) |light| {
            try self.lights.append(self.allocator, .{
                .source = self.doc.lights[light],
                .world = node.world,
            });
        }

        const mesh = node.mesh orelse return true;
        const skin = self.doc.nodes[node.index].skin;

        // A skinned mesh ignores its node transform entirely, because the joint
        // matrices carry it, so it is never baked, never merged and never
        // anchored to a node slot.
        const anchor: ?Slot = if (skin == null) try self.anchorSlot(node) else null;

        for (self.parsed[mesh]) |primitive| {
            const material = primitive.material orelse self.default_material;
            const alpha = self.model.materials[material].rendering.alpha_mode;

            // Blended geometry stays separate so that sorting it back to front
            // keeps working, and a morph target primitive stays separate because
            // the shader indexes its deltas by vertex within one primitive.
            const mergeable = skin == null and alpha != .blend and primitive.morph == null;
            if (mergeable) {
                const destination = try self.merger.appendPrimitive(
                    self.allocator,
                    anchor,
                    material,
                    primitive.streams,
                    @intCast(primitive.vertices.len),
                    primitive.indices,
                );
                bake(destination, primitive.vertices, node.relative);
                continue;
            }

            try self.appendSeparate(node, primitive, material, skin, anchor);
        }
        return true;
    }

    fn appendSeparate(
        self: *Builder,
        node: scene_graph.Node,
        primitive: mesh_parser.Primitive,
        material: u32,
        skin: ?u32,
        anchor: ?Slot,
    ) Error!void {
        // Checked rather than assumed, for the reason anchorSlot is: the
        // template list is built by a walk over the document's nodes and this is
        // a walk over the scene, and neither reads the other.
        const morph_template: ?u32 = if (primitive.morph == null)
            null
        else
            self.node_to_morph[node.index] orelse return error.MorphWithoutTemplate;

        var mesh: Mesh = .{
            .vertices = try self.allocator.dupe(Vertex3D, primitive.vertices),
            .indices = &.{},
            .streams = primitive.streams,
            .morph = null,
            .material = material,
            .anchor = anchor,
            .skin = skin,
            .morph_template = morph_template,
        };
        errdefer mesh.deinit(self.allocator);
        mesh.indices = try self.allocator.dupe(u32, primitive.indices);

        if (skin == null) bake(mesh.vertices, primitive.vertices, node.relative);

        if (primitive.morph) |source| {
            // Assigned before the second allocation, so a failure there leaves
            // the first one owned by the mesh the errdefer above destroys.
            mesh.morph = .{
                .positions = try self.allocator.dupe(f32, source.positions),
                .normals = &.{},
                .target_count = source.target_count,
            };
            mesh.morph.?.normals = try self.allocator.dupe(f32, source.normals);

            // A delta is a difference of positions, so it takes the transform's
            // linear part and never its translation. The base vertices above
            // were baked by the same matrix, and a delta left in local space
            // would be added to them in a space they no longer occupy.
            if (skin == null) {
                bakeDeltas(mesh.morph.?.positions, node.relative, false);
                bakeDeltas(mesh.morph.?.normals, node.relative, true);
            }
        }

        try self.meshes.append(self.allocator, mesh);
    }
};

fn buildGeometry(
    allocator: Allocator,
    doc: *const Document,
    model: *Model,
    node_to_slot: []const ?Slot,
    node_to_morph: []const ?u32,
) Error!void {
    var info = try dynamic_nodes.collect(allocator, doc);
    defer info.deinit(allocator);

    const parsed = try parseMeshes(allocator, doc);
    defer freeMeshes(allocator, parsed, parsed.len);

    var merger: mesh_merger.Merger = .empty;
    defer merger.deinit(allocator);

    var meshes: std.ArrayList(Mesh) = .empty;
    errdefer {
        for (meshes.items) |*mesh| mesh.deinit(allocator);
        meshes.deinit(allocator);
    }
    var lights: std.ArrayList(Light) = .empty;
    errdefer lights.deinit(allocator);

    var builder: Builder = .{
        .allocator = allocator,
        .doc = doc,
        .model = model,
        .parsed = parsed,
        .merger = &merger,
        .meshes = &meshes,
        .lights = &lights,
        .default_material = @intCast(doc.materials.len),
        .node_to_slot = node_to_slot,
        .node_to_morph = node_to_morph,
    };

    // Section 3.5.1 leaves `scene` optional; scene zero is the choice made in
    // animation_parser.zig and made the same way here.
    if (doc.scenes.len > 0) {
        try scene_graph.traverse(doc, doc.default_scene orelse 0, &info, &builder);
    }

    // Each merged group becomes one mesh, so a group of primitives that would
    // have been a draw each is a draw once.
    try meshes.ensureUnusedCapacity(allocator, merger.groups.count());
    for (merger.groups.keys(), merger.groups.values()) |key, *group| {
        if (group.vertices.items.len == 0) continue;
        const vertices = try group.vertices.toOwnedSlice(allocator);
        errdefer allocator.free(vertices);
        const indices = try group.indices.toOwnedSlice(allocator);
        meshes.appendAssumeCapacity(.{
            .vertices = vertices,
            .indices = indices,
            .streams = group.streams,
            .morph = null,
            .material = key.material orelse builder.default_material,
            .anchor = key.anchor,
            .skin = null,
            .morph_template = null,
        });
    }

    model.meshes = try meshes.toOwnedSlice(allocator);
    model.lights = try lights.toOwnedSlice(allocator);
}

fn freeMeshes(allocator: Allocator, meshes: [][]mesh_parser.Primitive, built: usize) void {
    for (meshes[0..built]) |primitives| {
        for (primitives) |*primitive| primitive.deinit(allocator);
        allocator.free(primitives);
    }
    allocator.free(meshes);
}

fn parseMeshes(allocator: Allocator, doc: *const Document) Error![][]mesh_parser.Primitive {
    const meshes = try allocator.alloc([]mesh_parser.Primitive, doc.meshes.len);
    var built: usize = 0;
    errdefer freeMeshes(allocator, meshes, built);

    for (doc.meshes, meshes) |mesh, *primitives| {
        const parsed = try allocator.alloc(mesh_parser.Primitive, mesh.primitives.len);
        var count: usize = 0;
        errdefer {
            for (parsed[0..count]) |*primitive| primitive.deinit(allocator);
            allocator.free(parsed);
        }
        for (mesh.primitives, parsed) |source, *primitive| {
            primitive.* = try mesh_parser.parsePrimitive(allocator, doc, source);
            count += 1;
        }
        primitives.* = parsed;
        built += 1;
    }
    return meshes;
}

// Carry vertices into the space their anchor moves. Texture coordinates, colour
// and joint data pass through: none of them is a position or a direction.
fn bake(destination: []Vertex3D, source: []const Vertex3D, matrix: zm.Mat) void {
    const normals = scene_graph.normalMatrix(matrix);
    for (source, destination) |vertex, *baked| {
        baked.* = vertex;
        baked.position = scene_graph.transformPosition(vertex.position, matrix);
        baked.normal = scene_graph.transformDirection(vertex.normal, normals);
        baked.tangent = scene_graph.transformTangent(vertex.tangent, matrix);
    }
}

// The same for flat morph deltas, in place. The w lane is zero, so the
// translation drops out, and the magnitude is meaningful so nothing is
// normalized.
fn bakeDeltas(deltas: []f32, matrix: zm.Mat, is_normal: bool) void {
    const carrier = if (is_normal) scene_graph.normalMatrix(matrix) else matrix;
    var index: usize = 0;
    while (index + 3 <= deltas.len) : (index += 3) {
        const carried = zm.mul(zm.f32x4(deltas[index], deltas[index + 1], deltas[index + 2], 0.0), carrier);
        deltas[index] = carried[0];
        deltas[index + 1] = carried[1];
        deltas[index + 2] = carried[2];
    }
}
