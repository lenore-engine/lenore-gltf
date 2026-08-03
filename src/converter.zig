const resources = @import("lenore-resources");

const types = @import("types.zig");

// Value mappings from a document type to a lenore-resources type: no allocation,
// no document lookups, nothing that can fail. Anything needing the document or
// the filesystem belongs to the importer instead, which is why the material
// conversion is not here.

// Section 5.26: both filters are optional, and a client picks its own default
// when either is absent. Linear is that choice, because it is what an exporter
// omitting the property means in practice and what every viewer shows.
pub fn samplerConfig(sampler: types.Sampler) resources.SamplerConfig {
    return .{
        .mag_filter = magFilter(sampler.mag_filter),
        .min_filter = minFilter(sampler.min_filter),
        .mipmap_mode = mipmapMode(sampler.min_filter),
        .address_mode_u = addressMode(sampler.wrap_s),
        .address_mode_v = addressMode(sampler.wrap_t),
        // glTF has no third axis: section 3.8.1 samples every texture with two
        // coordinates, so the mode that cannot be reached keeps the default.
        .address_mode_w = .repeat,
    };
}

pub fn magFilter(filter: ?types.MagFilter) resources.Filter {
    return switch (filter orelse .linear) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

// The minification filter carries two decisions in one value: how to sample
// within a level, and how to move between levels. This is the first.
pub fn minFilter(filter: ?types.MinFilter) resources.Filter {
    return switch (filter orelse .linear) {
        .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear => .nearest,
        .linear, .linear_mipmap_nearest, .linear_mipmap_linear => .linear,
    };
}

// And this is the second.
//
// NEAREST and LINEAR name no mipmap behaviour because they ask for no
// mipmapping at all, which SamplerConfig cannot express: turning mipmaps off is
// a level-of-detail clamp rather than a mode, and the type carries no clamp.
// They map to linear, so an asset asking for none gets blending between levels
// wherever the engine generated them. Visible on pixel art at distance and
// nowhere else, and the place to fix it is SamplerConfig.
pub fn mipmapMode(filter: ?types.MinFilter) resources.MipmapMode {
    return switch (filter orelse .linear) {
        .nearest, .linear => .linear,
        .nearest_mipmap_nearest, .linear_mipmap_nearest => .nearest,
        .nearest_mipmap_linear, .linear_mipmap_linear => .linear,
    };
}

pub fn addressMode(wrap: types.WrapMode) resources.AddressMode {
    return switch (wrap) {
        .clamp_to_edge => .clamp_to_edge,
        .mirrored_repeat => .mirrored_repeat,
        .repeat => .repeat,
    };
}
