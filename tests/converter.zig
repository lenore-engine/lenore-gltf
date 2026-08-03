const std = @import("std");

const gltf = @import("lenore-gltf");
const resources = @import("lenore-resources");
const converter = gltf.converter;
const types = gltf.document;

const testing = std.testing;

test "converter: an absent filter takes the client's default" {
    // Section 5.26 leaves both filters optional, so this is a choice rather than
    // a reading, and it is the one every viewer makes.
    const sampler: types.Sampler = .{
        .mag_filter = null,
        .min_filter = null,
        .wrap_s = .repeat,
        .wrap_t = .repeat,
    };
    try testing.expectEqual(resources.SamplerConfig{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
    }, converter.samplerConfig(sampler));
}

test "converter: a minification filter splits into a filter and a mipmap mode" {
    // The six values carry two decisions: how to sample inside a level, and how
    // to move between levels.
    const cases = [_]struct {
        filter: types.MinFilter,
        expected_filter: resources.Filter,
        expected_mipmap: resources.MipmapMode,
    }{
        .{ .filter = .nearest, .expected_filter = .nearest, .expected_mipmap = .linear },
        .{ .filter = .linear, .expected_filter = .linear, .expected_mipmap = .linear },
        .{ .filter = .nearest_mipmap_nearest, .expected_filter = .nearest, .expected_mipmap = .nearest },
        .{ .filter = .linear_mipmap_nearest, .expected_filter = .linear, .expected_mipmap = .nearest },
        .{ .filter = .nearest_mipmap_linear, .expected_filter = .nearest, .expected_mipmap = .linear },
        .{ .filter = .linear_mipmap_linear, .expected_filter = .linear, .expected_mipmap = .linear },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected_filter, converter.minFilter(case.filter));
        try testing.expectEqual(case.expected_mipmap, converter.mipmapMode(case.filter));
    }
}

test "converter: each wrap mode maps to its own address mode" {
    // A single map would be invisible if two of the three collapsed, so all
    // three are named and the sampler's two axes are checked separately.
    try testing.expectEqual(resources.AddressMode.repeat, converter.addressMode(.repeat));
    try testing.expectEqual(resources.AddressMode.mirrored_repeat, converter.addressMode(.mirrored_repeat));
    try testing.expectEqual(resources.AddressMode.clamp_to_edge, converter.addressMode(.clamp_to_edge));

    const config = converter.samplerConfig(.{
        .mag_filter = .nearest,
        .min_filter = .nearest_mipmap_nearest,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .mirrored_repeat,
    });
    try testing.expectEqual(resources.AddressMode.clamp_to_edge, config.address_mode_u);
    try testing.expectEqual(resources.AddressMode.mirrored_repeat, config.address_mode_v);
    try testing.expectEqual(resources.Filter.nearest, config.mag_filter);
    try testing.expectEqual(resources.MipmapMode.nearest, config.mipmap_mode);
}
