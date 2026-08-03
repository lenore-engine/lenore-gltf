const std = @import("std");
const zm = @import("zmath");

const gltf = @import("lenore-gltf");
const resources = @import("lenore-resources");
const document = gltf.document;
const importer = gltf.importer;

const testing = std.testing;

fn floats(comptime values: []const f32) [values.len * 4]u8 {
    var bytes: [values.len * 4]u8 = undefined;
    for (values, 0..) |value, index| {
        const element: f32 = value;
        @memcpy(bytes[index * 4 ..][0..4], std.mem.asBytes(&element));
    }
    return bytes;
}

fn shorts(comptime values: []const u16) [values.len * 2]u8 {
    var bytes: [values.len * 2]u8 = undefined;
    for (values, 0..) |value, index| {
        const element: u16 = value;
        @memcpy(bytes[index * 2 ..][0..2], std.mem.asBytes(&element));
    }
    return bytes;
}

// Accessors in the order the pieces are concatenated:
//
//   0 positions   1 times      2 translations   3 deltas
//   4 joints      5 weights
//
// View 6 holds image bytes and has no accessor.
const positions = floats(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 });
const times = floats(&.{ 0.0, 1.0 });
const translations = floats(&.{ 5, 0, 0, 6, 0, 0 });
const deltas = floats(&.{ 1, 0, 0, 1, 0, 0, 1, 0, 0 });
const joints = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
const weights = floats(&.{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 });
const image_bytes = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

const samples = positions ++ times ++ translations ++ deltas ++
    joints ++ weights ++ image_bytes;

const prelude =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"byteLength":172,"uri":"a.bin"}],
    \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},
    \\                {"buffer":0,"byteOffset":36,"byteLength":8},
    \\                {"buffer":0,"byteOffset":44,"byteLength":24},
    \\                {"buffer":0,"byteOffset":68,"byteLength":36},
    \\                {"buffer":0,"byteOffset":104,"byteLength":12},
    \\                {"buffer":0,"byteOffset":116,"byteLength":48},
    \\                {"buffer":0,"byteOffset":164,"byteLength":8}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
    \\              {"bufferView":1,"componentType":5126,"count":2,"type":"SCALAR"},
    \\              {"bufferView":2,"componentType":5126,"count":2,"type":"VEC3"},
    \\              {"bufferView":3,"componentType":5126,"count":3,"type":"VEC3"},
    \\              {"bufferView":4,"componentType":5121,"count":3,"type":"VEC4"},
    \\              {"bufferView":5,"componentType":5126,"count":3,"type":"VEC4"}],
;

fn load(comptime body: []const u8) !document.Document {
    var doc = try document.Document.initJson(testing.allocator, prelude ++ body);
    errdefer doc.deinit();
    try doc.attachBuffers(&.{&samples});
    return doc;
}

fn expectVec3(expected: [3]f32, actual: resources.Vec3) !void {
    inline for (0..3) |lane|
        try testing.expectApproxEqAbs(expected[lane], actual[lane], 1e-5);
}

// Finds the mesh a node produced, since merged groups come after the separate
// ones and neither order is part of the contract.
fn meshOf(model: importer.Model, node: ?u32) importer.Mesh {
    for (model.meshes) |mesh| {
        if (mesh.source_node == node) return mesh;
    }
    unreachable;
}

const one_triangle =
    \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
;

test "importer: a primitive with no material gets the one the specification defines" {
    var doc = try load(one_triangle ++
        \\ "materials":[{"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1]}}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    // The document declares one material and the primitive names none, so a
    // second is appended rather than the first being reused.
    try testing.expectEqual(@as(usize, 2), model.materials.len);
    try testing.expectEqualStrings("default", model.materials[1].name);
    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    try testing.expectEqual(@as(u32, 1), model.meshes[0].material);
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, model.materials[1].factors.base_colour);
    // The declared one is untouched and keeps its synthesized name.
    try testing.expectEqualStrings("material_0", model.materials[0].name);
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, model.materials[0].factors.base_colour);
}

test "importer: two nodes of one mesh merge into one draw, baked into place" {
    var doc = try load(one_triangle ++
        \\ "materials":[{}],
        \\ "nodes":[{"mesh":0,"material":0,"translation":[10,0,0]},
        \\          {"mesh":0,"translation":[0,10,0]}],
        \\ "scenes":[{"nodes":[0,1]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    const merged = model.meshes[0];
    try testing.expectEqual(@as(?u32, null), merged.source_node);
    try testing.expectEqual(@as(?u32, null), merged.anchor);
    try testing.expectEqual(@as(usize, 6), merged.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, merged.indices);

    // The first node's three vertices carry its translation and the second
    // node's carry its own, which is what baking means.
    try expectVec3(.{ 10, 0, 0 }, merged.vertices[0].position);
    try expectVec3(.{ 11, 0, 0 }, merged.vertices[1].position);
    try expectVec3(.{ 0, 10, 0 }, merged.vertices[3].position);
    try expectVec3(.{ 1, 10, 0 }, merged.vertices[4].position);
}

test "importer: blended geometry is never merged" {
    var doc = try load(
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]},
        \\           {"primitives":[{"attributes":{"POSITION":0},"material":1}]}],
        \\ "materials":[{},{"alphaMode":"BLEND"}],
        \\ "nodes":[{"mesh":0},{"mesh":1,"translation":[0,0,7]}],
        \\ "scenes":[{"nodes":[0,1]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    // Sorting a blended draw back to front needs it to stay its own draw.
    try testing.expectEqual(@as(usize, 2), model.meshes.len);
    const blended = meshOf(model, 1);
    try testing.expectEqual(resources.MaterialInfo.Rendering.AlphaMode.blend, model.materials[blended.material].rendering.alpha_mode);
    try testing.expectEqual(@as(usize, 3), blended.vertices.len);
    // It is still baked, only not merged.
    try expectVec3(.{ 0, 0, 7 }, blended.vertices[0].position);

    const opaque_mesh = meshOf(model, null);
    try testing.expectEqual(@as(usize, 3), opaque_mesh.vertices.len);
}

test "importer: a morph primitive keeps its own buffers and its deltas follow" {
    // The node scales x, so a delta along x is scaled and a translation would
    // have moved it if the linear part were not taken alone.
    var doc = try load(
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},
        \\                           "targets":[{"POSITION":3}]}]}],
        \\ "nodes":[{"mesh":0,"scale":[2,1,1],"translation":[100,0,0]}],
        \\ "scenes":[{"nodes":[0]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    const mesh = model.meshes[0];
    try testing.expectEqual(@as(?u32, 0), mesh.source_node);

    const morph = mesh.morph orelse return error.TestExpectedMorph;
    try testing.expectEqual(@as(u32, 1), morph.target_count);
    // Scaled by two and not moved by a hundred: a delta is a difference of
    // positions and takes no translation.
    try testing.expectApproxEqAbs(@as(f32, 2.0), morph.positions[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), morph.positions[1], 1e-5);
    // The base vertices did take it.
    try expectVec3(.{ 100, 0, 0 }, mesh.vertices[0].position);
    try expectVec3(.{ 102, 0, 0 }, mesh.vertices[1].position);
}

test "importer: skinned geometry stays in its own space" {
    var doc = try load(
        \\ "meshes":[{"primitives":[{"attributes":
        \\   {"POSITION":0,"JOINTS_0":4,"WEIGHTS_0":5}}]}],
        \\ "nodes":[{"mesh":0,"skin":0,"translation":[10,0,0]},{}],
        \\ "skins":[{"joints":[1]}],
        \\ "scenes":[{"nodes":[0,1]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    const mesh = model.meshes[0];
    try testing.expectEqual(@as(?u32, 0), mesh.skin);
    try testing.expectEqual(@as(?u32, null), mesh.anchor);
    try testing.expect(mesh.streams.skinned);
    // The node's translation is not baked in: the joint matrices carry it, and
    // baking would apply it twice.
    try expectVec3(.{ 0, 0, 0 }, mesh.vertices[0].position);

    try testing.expectEqual(@as(usize, 1), model.skins.len);
    try testing.expectEqual(@as(u32, 0), model.skins[0].index);
    try testing.expectEqual(@as(usize, 0), model.skins[0].clips.len);
}

test "importer: a skinned mesh on a driven node takes no anchor" {
    // The node the mesh hangs on is driven, so the walk reports it as an anchor.
    // A skinned mesh must still refuse one: its transform arrives through the
    // joint matrices, and routing an instance matrix to it as well would apply
    // the motion twice.
    var doc = try load(
        \\ "meshes":[{"primitives":[{"attributes":
        \\   {"POSITION":0,"JOINTS_0":4,"WEIGHTS_0":5}}]}],
        \\ "nodes":[{"mesh":0,"skin":0},{}],
        \\ "skins":[{"joints":[1]}],
        \\ "scenes":[{"nodes":[0,1]}],
        \\ "animations":[{"samplers":[{"input":1,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    const animation = model.node_animation orelse return error.TestExpectedAnimation;
    try testing.expectEqual(@as(usize, 1), animation.slotCount());

    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    try testing.expectEqual(@as(?u32, 0), model.meshes[0].skin);
    try testing.expectEqual(@as(?u32, null), model.meshes[0].anchor);
}

test "importer: an image is named, and only an embedded one is read" {
    var doc = try load(one_triangle ++
        \\ "images":[{"uri":"textures/skin%20a.png"},
        \\           {"bufferView":6,"mimeType":"image/png"},
        \\           {"uri":"data:image/png;base64,iVBORw0KGgo="}],
        \\ "samplers":[{"wrapS":33071}],
        \\ "textures":[{"source":0,"sampler":0},{"source":1},{"source":2}],
        \\ "materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}},
        \\               "normalTexture":{"index":1},
        \\               "emissiveTexture":{"index":2},
        \\               "emissiveFactor":[1,1,1],
        \\               "extensions":{"KHR_materials_emissive_strength":{"emissiveStrength":3}}}],
        \\ "extensionsUsed":["KHR_materials_emissive_strength"],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "models/character");
    defer model.deinit(testing.allocator);

    // A file is named relative to the root and not read, and the name is the
    // decoded one.
    try testing.expectEqualStrings("models/character/textures/skin a.png", model.images[0].key);
    try testing.expectEqual(@as(?[]const u8, null), model.images[0].bytes);

    // An image inside the document has no path, so its key says so and its bytes
    // are copied out before the buffers go.
    try testing.expectEqualStrings("embedded:1", model.images[1].key);
    try testing.expectEqualSlices(u8, &image_bytes, model.images[1].bytes.?);
    try testing.expectEqual(gltf.document.ImageMimeType.png, model.images[1].mime.?);

    try testing.expectEqualStrings("embedded:2", model.images[2].key);
    try testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }, model.images[2].bytes.?);

    // A slot names its image by the same key and carries its own sampler.
    const textures = model.materials[0].textures;
    try testing.expectEqualStrings("models/character/textures/skin a.png", textures.base_colour.path.?);
    try testing.expectEqual(resources.AddressMode.clamp_to_edge, textures.base_colour.sampler.address_mode_u);
    try testing.expectEqualStrings("embedded:1", textures.normal.path.?);
    // A slot with no texture has no path and the default sampler.
    try testing.expectEqual(@as(?[]const u8, null), textures.occlusion.path);

    // KHR_materials_emissive_strength scales the factor rather than standing
    // beside it, so the product is what the material carries.
    try testing.expectEqual([3]f32{ 3, 3, 3 }, model.materials[0].factors.emissive);
}

test "importer: a light carries the transform of the node that references it" {
    var doc = try load(one_triangle ++
        \\ "extensionsUsed":["KHR_lights_punctual"],
        \\ "extensions":{"KHR_lights_punctual":{"lights":[
        \\   {"type":"point","color":[1,0,0],"intensity":5}]}},
        \\ "nodes":[{"children":[1],"translation":[10,0,0]},
        \\          {"translation":[0,4,0],
        \\           "extensions":{"KHR_lights_punctual":{"light":0}}}],
        \\ "scenes":[{"nodes":[0]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), model.lights.len);
    try testing.expectEqual(gltf.document.LightKind.point, model.lights[0].source.kind);
    try testing.expectEqual([3]f32{ 1, 0, 0 }, model.lights[0].source.color);
    // The whole chain above the light, not just its own node.
    const world = model.lights[0].world;
    try testing.expectApproxEqAbs(@as(f32, 10.0), world[3][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 4.0), world[3][1], 1e-5);
}

test "importer: a morph clip carries the pose the mesh declares" {
    var doc = try load(
        \\ "meshes":[{"weights":[0.25],
        \\            "primitives":[{"attributes":{"POSITION":0},
        \\                           "targets":[{"POSITION":3}]}]}],
        \\ "nodes":[{"mesh":0}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":1}],
        \\                "channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), model.morph_clips.len);
    const clip = model.morph_clips[0];
    try testing.expectEqual(@as(u32, 0), clip.node);
    try testing.expectEqual(@as(u32, 1), clip.target_count);
    // Section 3.7.2.2 makes the mesh's weights the pose before any clip plays.
    try testing.expectEqualSlices(f32, &.{0.25}, clip.defaults);
}

test "importer: rigid animation anchors the geometry it moves" {
    var doc = try load(one_triangle ++
        \\ "nodes":[{"children":[1],"translation":[10,0,0]},
        \\          {"mesh":0,"translation":[0,3,0]}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":1,"path":"translation"}}]}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    // Node 1 is driven, so it is the anchor and its own transform is not baked:
    // the animator writes it every frame.
    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    try testing.expectEqual(@as(?u32, 1), model.meshes[0].anchor);
    try expectVec3(.{ 0, 0, 0 }, model.meshes[0].vertices[0].position);

    const animation = model.node_animation orelse return error.TestExpectedAnimation;
    try testing.expectEqual(@as(usize, 1), animation.slotCount());
    // The static ancestor above the anchor reaches it as the prefix instead.
    try testing.expectApproxEqAbs(@as(f32, 10.0), animation.prefix[0][3][0], 1e-5);
}

test "importer: a document with no scene produces no geometry and still parses" {
    var doc = try load(one_triangle ++
        \\ "materials":[{}],
        \\ "nodes":[{"mesh":0}]}
    );
    defer doc.deinit();

    var model = try importer.build(testing.allocator, &doc, "");
    defer model.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), model.meshes.len);
    try testing.expectEqual(@as(usize, 2), model.materials.len);
}

test "importer: every allocation failure is propagated and nothing leaks" {
    var doc = try load(
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0},
        \\                          {"attributes":{"POSITION":0}}]}],
        \\ "materials":[{"alphaMode":"BLEND"}],
        \\ "images":[{"uri":"skin.png"}],
        \\ "samplers":[{}],
        \\ "textures":[{"source":0,"sampler":0}],
        \\ "nodes":[{"children":[1],"translation":[10,0,0]},{"mesh":0}],
        \\ "skins":[{"joints":[1]}],
        \\ "scenes":[{"nodes":[0]}],
        \\ "animations":[{"samplers":[{"input":1,"output":2}],
        \\                "channels":[{"sampler":0,"target":{"node":1,"path":"translation"}}]}]}
    );
    defer doc.deinit();

    var index: usize = 0;
    while (true) : (index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = index });
        if (importer.build(failing.allocator(), &doc, "models")) |value| {
            var model = value;
            model.deinit(failing.allocator());
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(index > 20);
}
