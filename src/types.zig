pub const ComponentType = enum(u16) {
    i8 = 5120,
    u8 = 5121,
    i16 = 5122,
    u16 = 5123,
    u32 = 5125,
    f32 = 5126,

    pub fn size(self: ComponentType) u32 {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .u32, .f32 => 4,
        };
    }
};

pub const ElementKind = enum {
    scalar,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,
    mat4,

    pub fn componentCount(self: ElementKind) u32 {
        return switch (self) {
            .scalar => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            .mat2 => 4,
            .mat3 => 9,
            .mat4 => 16,
        };
    }
};

// The overlay of a sparse accessor: `count` elements that differ from the base
// array, their positions in one view and their values in another. Both views are
// tightly packed and carry no stride. Values share the base accessor's component
// type and element shape, so their size comes from the accessor rather than from
// anything stored here.
pub const Sparse = struct {
    count: u32,
    index_buffer_view: u32,
    index_byte_offset: u32,
    index_component_type: ComponentType,
    value_buffer_view: u32,
    value_byte_offset: u32,
};

pub const Accessor = struct {
    // Undefined together with a sparse overlay means the base array is zeros.
    buffer_view: ?u32,
    byte_offset: u32,
    component_type: ComponentType,
    kind: ElementKind,
    count: u32,
    normalized: bool,
    sparse: ?Sparse,

    pub fn elementSize(self: Accessor) u32 {
        return self.component_type.size() * self.kind.componentCount();
    }
};

pub const BufferView = struct {
    buffer: u32,
    byte_offset: u32,
    byte_length: u32,
    byte_stride: ?u32,
};

pub const BufferDesc = struct {
    // Null identifies the GLB BIN chunk. Other values remain unresolved URI
    // references until the importer supplies the corresponding bytes.
    uri: ?[]const u8,
    byte_length: u32,
};

pub const MorphTarget = struct {
    position: ?u32,
    normal: ?u32,
    tangent: ?u32,
};

pub const Primitive = struct {
    position: ?u32,
    normal: ?u32,
    tangent: ?u32,
    texcoord_0: ?u32,
    texcoord_1: ?u32,
    color_0: ?u32,
    joints_0: ?u32,
    weights_0: ?u32,
    indices: ?u32,
    material: ?u32,
    targets: []const MorphTarget,
};

pub const Mesh = struct {
    primitives: []const Primitive,
    weights: []const f32,
};

pub const Node = struct {
    name: ?[]const u8,
    children: []const u32,
    mesh: ?u32,
    skin: ?u32,
    camera: ?u32,
    light: ?u32,
    translation: ?[3]f32,
    rotation: ?[4]f32,
    scale: ?[3]f32,
    matrix: ?[16]f32,
    weights: []const f32,
    // This node's own KHR_node_visibility flag, not the inherited one. A scene
    // walk carries the inherited value, because a false here hides the whole
    // subtree below it.
    visible: bool,
};

pub const PerspectiveCamera = struct {
    aspect_ratio: ?f32,
    yfov: f32,
    znear: f32,
    zfar: ?f32,
};

pub const OrthographicCamera = struct {
    xmag: f32,
    ymag: f32,
    znear: f32,
    zfar: f32,
};

pub const Camera = struct {
    name: ?[]const u8,
    projection: union(enum) {
        perspective: PerspectiveCamera,
        orthographic: OrthographicCamera,
    },
};

pub const LightKind = enum {
    directional,
    point,
    spot,
};

pub const SpotCone = struct {
    inner_angle: f32,
    outer_angle: f32,
};

// Document-shaped KHR_lights_punctual data. Placement comes from the node that
// references the light; conversion to a renderer layout belongs to the scene.
pub const Light = struct {
    name: ?[]const u8,
    color: [3]f32,
    intensity: f32,
    kind: LightKind,
    range: ?f32,
    spot: ?SpotCone,
};

pub const Scene = struct {
    nodes: []const u32,
};

// `opaque` is a Zig keyword. The suffix keeps ordinary field access syntax.
pub const AlphaMode = enum {
    opaque_mode,
    mask,
    blend,
};

pub const TexCoord = struct {
    set: u32 = 0,
    offset: [2]f32 = .{ 0.0, 0.0 },
    rotation: f32 = 0.0,
    scale: [2]f32 = .{ 1.0, 1.0 },
};

pub const Material = struct {
    name: ?[]const u8,
    base_color_texture: ?u32,
    base_color_factor: [4]f32,
    base_color_uv: TexCoord,
    metallic_roughness_texture: ?u32,
    metallic_factor: f32,
    roughness_factor: f32,
    metallic_roughness_uv: TexCoord,
    normal_texture: ?u32,
    normal_scale: f32,
    normal_uv: TexCoord,
    occlusion_texture: ?u32,
    occlusion_strength: f32,
    occlusion_uv: TexCoord,
    emissive_texture: ?u32,
    emissive_factor: [3]f32,
    emissive_strength: f32,
    emissive_uv: TexCoord,
    alpha_mode: AlphaMode,
    alpha_cutoff: f32,
    double_sided: bool,
    // KHR_materials_unlit. The extension carries no value of its own, so the
    // document's flag is its presence and the fields above stay as the file
    // gave them: the extension calls them a fallback for clients without it,
    // and stripping them here would decide for a consumer that may want them.
    unlit: bool,
};

pub const Texture = struct {
    source: ?u32,
    sampler: ?u32,
};

pub const Image = struct {
    uri: ?[]const u8,
    buffer_view: ?u32,
    mime_type: ?ImageMimeType,
};

pub const ImageMimeType = enum {
    png,
    jpeg,
};

pub const MagFilter = enum(u16) {
    nearest = 9728,
    linear = 9729,
};

pub const MinFilter = enum(u16) {
    nearest = 9728,
    linear = 9729,
    nearest_mipmap_nearest = 9984,
    linear_mipmap_nearest = 9985,
    nearest_mipmap_linear = 9986,
    linear_mipmap_linear = 9987,
};

pub const WrapMode = enum(u16) {
    clamp_to_edge = 33071,
    mirrored_repeat = 33648,
    repeat = 10497,
};

pub const Sampler = struct {
    mag_filter: ?MagFilter,
    min_filter: ?MinFilter,
    wrap_s: WrapMode,
    wrap_t: WrapMode,
};

pub const Skin = struct {
    joints: []const u32,
    skeleton: ?u32,
    inverse_bind_matrices: ?u32,
};

pub const Interpolation = enum {
    linear,
    step,
    cubicspline,
};

pub const TargetPath = enum {
    translation,
    rotation,
    scale,
    weights,
};

pub const AnimationSampler = struct {
    input: u32,
    output: u32,
    interpolation: Interpolation,
};

pub const AnimationChannel = struct {
    sampler: u32,
    target_node: u32,
    target_path: TargetPath,
};

pub const Animation = struct {
    name: ?[]const u8,
    samplers: []const AnimationSampler,
    channels: []const AnimationChannel,
};
