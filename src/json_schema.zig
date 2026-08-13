const std = @import("std");
const types = @import("types.zig");

pub const Root = struct {
    asset: Asset,
    scene: ?u32 = null,
    scenes: []const Scene = &.{},
    nodes: []const Node = &.{},
    meshes: []const Mesh = &.{},
    accessors: []const Accessor = &.{},
    bufferViews: []const BufferView = &.{},
    buffers: []const Buffer = &.{},
    materials: []const Material = &.{},
    textures: []const Texture = &.{},
    images: []const Image = &.{},
    samplers: []const Sampler = &.{},
    skins: []const Skin = &.{},
    animations: []const Animation = &.{},
    cameras: []const Camera = &.{},
    extensions: RootExtensions = .{},
    extensionsRequired: []const []const u8 = &.{},
    extensionsUsed: []const []const u8 = &.{},
};

pub const Asset = struct {
    version: []const u8,
    minVersion: ?[]const u8 = null,
};

pub const RootExtensions = struct {
    KHR_lights_punctual: ?struct {
        lights: []const Light = &.{},
    } = null,
};

pub const Scene = struct {
    nodes: []const u32 = &.{},
};

pub const NodeExtensions = struct {
    KHR_lights_punctual: ?struct {
        light: u32,
    } = null,
    // KHR_node_visibility gives `visible` the default true, so an extension
    // object present with no member reads as visible.
    KHR_node_visibility: ?struct {
        visible: bool = true,
    } = null,
};

pub const Node = struct {
    name: ?[]const u8 = null,
    children: []const u32 = &.{},
    mesh: ?u32 = null,
    skin: ?u32 = null,
    camera: ?u32 = null,
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    matrix: ?[16]f32 = null,
    weights: ?[]const f32 = null,
    extensions: NodeExtensions = .{},
};

pub const CameraType = enum {
    perspective,
    orthographic,
};

pub const PerspectiveCamera = struct {
    aspectRatio: ?f32 = null,
    yfov: f32,
    znear: f32,
    zfar: ?f32 = null,
};

pub const OrthographicCamera = struct {
    xmag: f32,
    ymag: f32,
    znear: f32,
    zfar: f32,
};

pub const Camera = struct {
    name: ?[]const u8 = null,
    type: CameraType,
    perspective: ?PerspectiveCamera = null,
    orthographic: ?OrthographicCamera = null,
};

pub const LightType = enum {
    directional,
    point,
    spot,
};

pub const Spot = struct {
    innerConeAngle: f32 = 0.0,
    outerConeAngle: f32 = std.math.pi / 4.0,
};

pub const Light = struct {
    name: ?[]const u8 = null,
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity: f32 = 1.0,
    type: LightType,
    range: ?f32 = null,
    spot: ?Spot = null,
};

pub const Mesh = struct {
    primitives: []const Primitive = &.{},
    weights: ?[]const f32 = null,
};

pub const Primitive = struct {
    attributes: Attributes,
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: u32 = 4,
    targets: ?[]const MorphTarget = null,
};

pub const MorphTarget = struct {
    POSITION: ?u32 = null,
    NORMAL: ?u32 = null,
    TANGENT: ?u32 = null,
};

pub const Attributes = struct {
    POSITION: ?u32 = null,
    NORMAL: ?u32 = null,
    TANGENT: ?u32 = null,
    TEXCOORD_0: ?u32 = null,
    TEXCOORD_1: ?u32 = null,
    COLOR_0: ?u32 = null,
    JOINTS_0: ?u32 = null,
    WEIGHTS_0: ?u32 = null,
};

pub const Accessor = struct {
    bufferView: ?u32 = null,
    byteOffset: u32 = 0,
    componentType: types.ComponentType,
    count: u32,
    type: ElementKind,
    normalized: bool = false,
    sparse: ?Sparse = null,
};

pub const Sparse = struct {
    count: u32,
    indices: SparseIndices,
    values: SparseValues,
};

pub const SparseIndices = struct {
    bufferView: u32,
    byteOffset: u32 = 0,
    componentType: types.ComponentType,
};

pub const SparseValues = struct {
    bufferView: u32,
    byteOffset: u32 = 0,
};

pub const ElementKind = enum {
    SCALAR,
    VEC2,
    VEC3,
    VEC4,
    MAT2,
    MAT3,
    MAT4,
};

pub const BufferView = struct {
    buffer: u32,
    byteOffset: u32 = 0,
    byteLength: u32,
    byteStride: ?u32 = null,
};

pub const Buffer = struct {
    uri: ?[]const u8 = null,
    byteLength: u32,
};

pub const TextureTransform = struct {
    offset: [2]f32 = .{ 0.0, 0.0 },
    rotation: f32 = 0.0,
    scale: [2]f32 = .{ 1.0, 1.0 },
    texCoord: ?u32 = null,
};

pub const TextureInfoExtensions = struct {
    KHR_texture_transform: ?TextureTransform = null,
};

pub const TextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    scale: f32 = 1.0,
    strength: f32 = 1.0,
    extensions: TextureInfoExtensions = .{},
};

pub const PbrMetallicRoughness = struct {
    baseColorTexture: ?TextureInfo = null,
    baseColorFactor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    metallicRoughnessTexture: ?TextureInfo = null,
    metallicFactor: f32 = 1.0,
    roughnessFactor: f32 = 1.0,
};

pub const AlphaMode = enum {
    OPAQUE,
    MASK,
    BLEND,
};

pub const MaterialExtensions = struct {
    KHR_materials_emissive_strength: ?struct {
        emissiveStrength: f32 = 1.0,
    } = null,
    // KHR_materials_unlit adds no properties: the extension object is empty and
    // its presence is the whole signal. The extension permits further members
    // and leaves their meaning undefined, which is what the parser's
    // ignore_unknown_fields already does with them.
    KHR_materials_unlit: ?struct {} = null,
};

pub const Material = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: PbrMetallicRoughness = .{},
    normalTexture: ?TextureInfo = null,
    occlusionTexture: ?TextureInfo = null,
    emissiveTexture: ?TextureInfo = null,
    emissiveFactor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    alphaMode: AlphaMode = .OPAQUE,
    alphaCutoff: f32 = 0.5,
    doubleSided: bool = false,
    extensions: MaterialExtensions = .{},
};

pub const Texture = struct {
    source: ?u32 = null,
    sampler: ?u32 = null,
};

pub const Image = struct {
    uri: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    bufferView: ?u32 = null,
};

pub const Sampler = struct {
    magFilter: ?types.MagFilter = null,
    minFilter: ?types.MinFilter = null,
    wrapS: types.WrapMode = .repeat,
    wrapT: types.WrapMode = .repeat,
};

pub const Skin = struct {
    joints: []const u32 = &.{},
    skeleton: ?u32 = null,
    inverseBindMatrices: ?u32 = null,
};

pub const Animation = struct {
    name: ?[]const u8 = null,
    channels: []const AnimationChannel = &.{},
    samplers: []const AnimationSampler = &.{},
};

pub const AnimationChannel = struct {
    sampler: u32,
    target: AnimationTarget,
};

pub const AnimationTarget = struct {
    node: ?u32 = null,
    path: []const u8,
};

pub const Interpolation = enum {
    LINEAR,
    STEP,
    CUBICSPLINE,
};

pub const AnimationSampler = struct {
    input: u32,
    output: u32,
    interpolation: Interpolation = .LINEAR,
};
