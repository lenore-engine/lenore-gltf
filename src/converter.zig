const resources = @import("lenore-resources");

const types = @import("types.zig");

// Value mappings from a document type to a lenore-resources type: no allocation,
// no document lookups, nothing that can fail. Anything needing the document or
// the filesystem belongs to the importer instead, which is why the material
// conversion is not here.

// Section 5.26: both filters are optional, and a client picks its own default
// when either is absent. Linear is that choice on both axes, because an exporter
// that states nothing is not asking for the coarsest sampling available.
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

// The value both halves below fall back to when `minFilter` is absent. It is
// spelled as the trilinear filter and not as LINEAR, because those two are no
// longer the same request: LINEAR names the original image alone, and defaulting
// to it would switch mipmapping off for every asset that omits the property.
const absent_min_filter: types.MinFilter = .linear_mipmap_linear;

// The minification filter carries two decisions in one value: how to sample
// within a level, and how to move between levels. This is the first.
pub fn minFilter(filter: ?types.MinFilter) resources.Filter {
    return switch (filter orelse absent_min_filter) {
        .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear => .nearest,
        .linear, .linear_mipmap_nearest, .linear_mipmap_linear => .linear,
    };
}

// And this is the second. NEAREST and LINEAR name no mipmap behaviour because
// they ask for none: specification 3.8.4.2 has them sampling the original image
// where the other four select a pre-minified one.
pub fn mipmapMode(filter: ?types.MinFilter) resources.MipmapMode {
    return switch (filter orelse absent_min_filter) {
        .nearest, .linear => .none,
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
