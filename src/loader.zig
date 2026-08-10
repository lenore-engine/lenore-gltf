const std = @import("std");

const document = @import("document.zig");
const uri = @import("uri.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;

// The half of the work that needs no filesystem, so a caller resolving a
// reference for its own use does not have to handle an open failure.
pub const ResolveError = uri.DecodeError || uri.ReferenceError || error{PathEscapesRoot};

pub const Error = ResolveError ||
    document.Error ||
    uri.DataUriError ||
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.OpenError ||
    error{SymlinkRefused};

// The one place in this module that opens a file. Everything above it takes a
// parsed document and never touches the filesystem, which is what keeps the rest
// of the module testable without one.
//
// A document and the blobs it borrows. The document holds slices into them, so
// they are freed together and never separately.
pub const Loaded = struct {
    document: Document,
    // Where the document was read from, relative to the root, and what every
    // reference inside it resolves against. Owned, because a caller's path is
    // not required to outlive the load.
    directory: []const u8,
    blobs: [][]u8,

    pub fn deinit(self: *Loaded, allocator: Allocator) void {
        self.document.deinit();
        for (self.blobs) |blob| allocator.free(blob);
        allocator.free(self.blobs);
        allocator.free(self.directory);
        self.* = undefined;
    }
};

// Read a document and resolve every buffer it names. `path` is relative to
// `root`, and so is everything the document goes on to reference: a reference
// that would leave the root is refused rather than followed.
//
// The container is chosen by the magic bytes rather than by the extension.
// Section 4.2 gives a GLB the ASCII magic "glTF", and a file named .gltf that
// begins with it is a GLB whatever the name says.
pub fn open(
    allocator: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
) Error!Loaded {
    const normalized = try resolveConfined(allocator, "", path);
    defer allocator.free(normalized);

    const directory = try allocator.dupe(u8, std.fs.path.dirname(normalized) orelse "");
    errdefer allocator.free(directory);

    var blobs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (blobs.items) |blob| allocator.free(blob);
        blobs.deinit(allocator);
    }

    // Reserved before the read, so the blob is owned by the list the instant it
    // exists and no error path can drop it on the floor.
    try blobs.ensureUnusedCapacity(allocator, 1);
    const bytes = try readBeneath(allocator, io, root, normalized);
    blobs.appendAssumeCapacity(bytes);

    var parsed = if (std.mem.startsWith(u8, bytes, "glTF"))
        try Document.initGlb(allocator, bytes)
    else
        try Document.initJson(allocator, bytes);
    errdefer parsed.deinit();

    // A GLB whose only buffer is its BIN chunk is already complete. Anything
    // else needs the table built, and the two containers build it the same way:
    // a descriptor with no URI is the BIN chunk, and one with a URI is a data
    // URI or a file beside the document.
    if (!parsed.buffers_attached) {
        try attachBuffers(allocator, io, root, directory, &parsed, &blobs);
    }

    return .{
        .document = parsed,
        .directory = directory,
        .blobs = try blobs.toOwnedSlice(allocator),
    };
}

fn attachBuffers(
    allocator: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    directory: []const u8,
    parsed: *Document,
    blobs: *std.ArrayList([]u8),
) Error!void {
    const table = try allocator.alloc([]const u8, parsed.buffer_descs.len);
    defer allocator.free(table);

    for (parsed.buffer_descs, table) |descriptor, *slice| {
        const reference = descriptor.uri orelse {
            // Only a GLB has an unnamed buffer, only its first one, and only
            // when the BIN chunk is there: initJson refuses one outright and
            // validateGlbBuffers refuses the other two cases, both with the
            // error repeated here. It is an error rather than an unwrap because
            // a shipping build removes the check that would have caught the
            // difference.
            slice.* = parsed.embedded_bin orelse return error.InvalidStructure;
            continue;
        };

        try blobs.ensureUnusedCapacity(allocator, 1);
        const blob = if (uri.isDataUri(reference))
            try uri.decodeBufferDataUriAlloc(allocator, reference)
        else blob: {
            const file = try resolveConfined(allocator, directory, reference);
            defer allocator.free(file);
            break :blob try readBeneath(allocator, io, root, file);
        };
        blobs.appendAssumeCapacity(blob);
        slice.* = blob;
    }

    try parsed.attachBuffers(table);
}

// A document reference turned into a path relative to the root, refusing one
// that leaves it.
//
// The confinement check runs on the decoded reference and not on the reference
// itself, which is the whole reason this is a separate step. RFC 3986 section
// 2.2 makes a percent-encoded delimiter data rather than syntax, so `%2e%2e%2f`
// passes every form check uri.zig applies and only becomes `../` afterwards.
// Deciding containment before decoding would decide it about a different string
// than the one the filesystem sees.
//
// It is one of the two halves of containment and it is the lexical one: it
// stops `..` and an absolute path. A symlink is not a string, so readBeneath
// closes that half.
pub fn resolveConfined(
    allocator: Allocator,
    directory: []const u8,
    reference: []const u8,
) ResolveError![]u8 {
    const decoded = try uri.decodePathAlloc(allocator, reference);
    defer allocator.free(decoded);

    // At most one segment per separator plus one, in either half.
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    for ([_][]const u8{ directory, decoded }) |part| {
        var walk = std.mem.splitScalar(u8, part, '/');
        while (walk.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                if (segments.items.len == 0) return error.PathEscapesRoot;
                _ = segments.pop();
                continue;
            }
            try segments.append(allocator, segment);
        }
    }
    if (segments.items.len == 0) return error.PathEscapesRoot;

    return std.mem.join(allocator, "/", segments.items);
}

// Read a file beneath `root`, refusing to traverse a symlink anywhere on the
// way. The lexical check above removed every `..`, so the only remaining way out
// of the root is a link, and the two together are what containment means.
//
// One component at a time, because the option that refuses a link is on the open
// and not on the path: a single call with `a/b/c` follows a link at `a` and at
// `b` however the last component is opened. Walking is also free of the race a
// check-then-open has, since each handle is the directory the next name is
// resolved in and no name is resolved twice.
//
// `resolve_beneath` asks the kernel for the same guarantee in one call, on Linux
// through openat2. It is set as well and it is not relied on: std.Io documents
// that an operating system without it ignores the option silently, so a build on
// an older kernel would lose the guarantee without saying so.
// Names a refused open for what it was. Linux reports a link met by O_NOFOLLOW
// as ELOOP when the target is a file and as ENOTDIR when a directory was asked
// for, and ENOTDIR is also what an ordinary component that is a file gives, so
// the two are told apart by asking rather than by guessing.
//
// This runs only on an error path, so the enforcement above stays one syscall
// per component and stays free of the race a check before an open would have.
// A link created between the two would be labelled wrongly and still refused.
fn refusal(io: std.Io, directory: std.Io.Dir, name: []const u8, err: anytype) Error {
    if (err == error.SymLinkLoop) return error.SymlinkRefused;
    if (err == error.NotDir) {
        const stat = directory.statFile(io, name, .{ .follow_symlinks = false }) catch return err;
        if (stat.kind == .sym_link) return error.SymlinkRefused;
    }
    return err;
}

// Public because resolving a reference and reading it are one job split over
// two calls, and `resolveConfined` is the other half. A consumer holding a key
// this module produced reads it through here rather than reimplementing the
// containment below.
pub fn readBeneath(
    allocator: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    relative: []const u8,
) Error![]u8 {
    var directory = root;
    var owned = false;
    defer if (owned) directory.close(io);

    var walk = std.mem.splitScalar(u8, relative, '/');
    var name = walk.next().?;
    while (walk.next()) |next| {
        const opened = directory.openDir(io, name, .{ .follow_symlinks = false }) catch |err|
            return refusal(io, directory, name, err);
        if (owned) directory.close(io);
        directory = opened;
        owned = true;
        name = next;
    }

    var file = directory.openFile(io, name, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return refusal(io, directory, name, err);
    defer file.close(io);

    // Unlimited rather than the declared byte length: section 3.6.1.1 bounds a
    // view by that length and says nothing about the file, which an exporter is
    // free to leave longer.
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |remaining| return remaining,
    };
}
