const std = @import("std");
const bsdiff = @import("bsdiff.zig");
const bspatch = @import("bspatch.zig");

const FileSpec = struct {
    path: []const u8,
    contents: []const u8,
};

const originalSpecs = [_]FileSpec{
    .{
        .path = "co(lab)-canary/app/notes.txt",
        .contents =
        \\Alpha
        \\Beta
        \\Gamma
        \\Delta
        ,
    },
    .{
        .path = "co(lab)-canary/app/config/settings.json",
        .contents =
        \\{
        \\  "theme": "dark",
        \\  "autosave": true,
        \\  "fontSize": 14
        \\}
        ,
    },
    .{
        .path = "co(lab)-canary/app/bin/runner",
        .contents = "chunk-a\nchunk-b\nchunk-c\n",
    },
};

const updatedSpecs = [_]FileSpec{
    .{
        .path = "co(lab)-canary/app/notes.txt",
        .contents =
        \\Alpha
        \\Beta
        \\Gamma
        \\Echo
        ,
    },
    .{
        .path = "co(lab)-canary/app/config/settings.json",
        .contents =
        \\{
        \\  "theme": "light",
        \\  "autosave": false,
        \\  "fontSize": 16
        \\}
        ,
    },
    .{
        .path = "co(lab)-canary/app/bin/runner",
        .contents = "chunk-a\nchunk-b\nchunk-d\n",
    },
    .{
        .path = "co(lab)-canary/app/README.md",
        .contents = "# Release Notes\nThis file was added in the update.\n",
    },
};

test "bsdiff/bspatch roundtrip across tar archives" {
    try runRoundTripPatch(true);
}

fn runRoundTripPatch(useZstd: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const originalTar = try buildTarArchive(allocator, originalSpecs[0..]);
    const updatedTar = try buildTarArchive(allocator, updatedSpecs[0..]);

    var allocator_handle = allocator;
    const patch = try bsdiff.calculateDifferences(&allocator_handle, std.testing.io, originalTar, updatedTar, useZstd);

    allocator_handle = allocator;
    const patchedTar = try bspatch.applyPatch(&allocator_handle, originalTar, patch);

    try std.testing.expectEqualSlices(u8, updatedTar, patchedTar);
}

fn buildTarArchive(allocator: std.mem.Allocator, specs: []const FileSpec) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    var tar_writer: std.tar.Writer = .{ .underlying_writer = &allocating.writer };

    for (specs) |spec| {
        try tar_writer.writeFileBytes(spec.path, spec.contents, .{ .mode = 0o644, .mtime = 0 });
    }

    // Writes the two trailing zero blocks that terminate a tar archive.
    try tar_writer.finishPedantically();

    return allocating.toOwnedSlice();
}

// Direct roundtrip on raw binary fixtures where the new file grows and
// shrinks relative to the old file, exercising patches that change the
// output size in both directions.
test "bsdiff/bspatch roundtrip with binary size changes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var prng = std.Random.DefaultPrng.init(99);
    var random = prng.random();

    const oldFile = try allocator.alloc(u8, 256 * 1024);
    random.bytes(oldFile);

    // Grown file: original content with a small edit plus an appended section
    const grown = try allocator.alloc(u8, oldFile.len + 32 * 1024);
    @memcpy(grown[0..oldFile.len], oldFile);
    @memcpy(grown[1024..][0..11], "hello world");
    random.bytes(grown[oldFile.len..]);

    // Shrunk file: the first half of the original with a small edit
    const shrunk = try allocator.dupe(u8, oldFile[0 .. oldFile.len / 2]);
    @memcpy(shrunk[2048..][0..9], "truncated");

    for ([_][]const u8{ grown, shrunk }) |newFile| {
        var allocator_handle = allocator;
        const patchData = try bsdiff.calculateDifferences(&allocator_handle, std.testing.io, oldFile, newFile, true);

        allocator_handle = allocator;
        const patchedFile = try bspatch.applyPatch(&allocator_handle, oldFile, patchData);

        try std.testing.expectEqual(newFile.len, patchedFile.len);
        try std.testing.expectEqualSlices(u8, newFile, patchedFile);
    }
}

// Test with larger files to exercise chunk boundary handling
// This test creates files large enough to trigger multiple chunks (if parallel processing is enabled)
// and includes repeated content patterns that would cause match extension across chunk boundaries
test "bsdiff/bspatch roundtrip with large files" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Create 2MB files with repeated patterns
    // This pattern is designed to trigger match extension: common header, different middle, common footer
    const fileSize: usize = 2 * 1024 * 1024;

    var oldFile = try allocator.alloc(u8, fileSize);
    var newFile = try allocator.alloc(u8, fileSize);

    // Fill with repeating pattern (this creates opportunities for long matches)
    var prng = std.Random.DefaultPrng.init(12345);
    var random = prng.random();

    // Generate a base pattern
    var pattern: [1024]u8 = undefined;
    for (0..pattern.len) |i| {
        pattern[i] = random.int(u8);
    }

    // Fill old file with repeated pattern
    var pos: usize = 0;
    while (pos < fileSize) {
        const copyLen = @min(pattern.len, fileSize - pos);
        @memcpy(oldFile[pos..][0..copyLen], pattern[0..copyLen]);
        pos += copyLen;
    }

    // Copy to new file
    @memcpy(newFile, oldFile);

    // Make small changes scattered throughout
    // This simulates a real update where most content is the same
    const changePositions = [_]usize{ 100, 1000, 50000, 100000, 500000, 1000000, 1500000, 1900000 };
    for (changePositions) |changePos| {
        if (changePos + 10 < fileSize) {
            @memcpy(newFile[changePos..][0..10], "UPDATED!!!");
        }
    }

    var allocator_handle = allocator;
    const patchData = try bsdiff.calculateDifferences(&allocator_handle, std.testing.io, oldFile, newFile, true);

    allocator_handle = allocator;
    const patchedFile = try bspatch.applyPatch(&allocator_handle, oldFile, patchData);

    try std.testing.expectEqual(newFile.len, patchedFile.len);
    try std.testing.expectEqualSlices(u8, newFile, patchedFile);
}

// Test specifically for the parallel chunk merging bug where:
// 1. Chunk N extends further than chunk N+1 (requires maxActualEndSoFar tracking)
// 2. Kept entries at boundaries need correct oldpos (requires seek-only entry)
//
// The bug manifested when:
// - Chunk 0 extended to position X
// - Chunk 1 extended to position Y > X (further than chunk 0)
// - Chunks 2-5 extended to position Z < Y (less than chunk 1)
// - The code incorrectly used chunkResults[i-1].actualEndPos instead of max seen
// - The diff data was computed with chunk's internal oldpos, but seekBy adjustment
//   happened AFTER reading (should be BEFORE via seek-only entry)
test "bsdiff/bspatch parallel chunk boundary handling" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Create 10MB files to trigger multiple chunks (minChunkSize is 1MB)
    // With 10MB and up to 8 threads, we get chunks of ~1.25MB each
    const fileSize: usize = 10 * 1024 * 1024;

    var oldFile = try allocator.alloc(u8, fileSize);
    var newFile = try allocator.alloc(u8, fileSize);

    // Strategy: Create a pattern where chunks extend differently
    // - Region A (0-2MB): identical - chunk 0 processes, may extend
    // - Region B (2MB-3MB): DIFFERENT - creates boundary, forces extra data
    // - Region C (3MB-7MB): identical - chunks can find matches and extend
    // - Region D (7MB-8MB): DIFFERENT - another boundary
    // - Region E (8MB-10MB): identical - final region
    //
    // This pattern causes:
    // - Early chunks to extend through the identical regions
    // - Later chunks starting in different regions to have different extension patterns
    // - Boundaries where kept entries need correct oldpos alignment

    var prng = std.Random.DefaultPrng.init(54321);
    var random = prng.random();

    // Fill oldFile with deterministic pattern
    for (0..fileSize) |i| {
        oldFile[i] = @truncate((i * 7 + 13) % 256);
    }

    // Copy to newFile
    @memcpy(newFile, oldFile);

    // Make regions B and D completely different
    const regionB_start: usize = 2 * 1024 * 1024;
    const regionB_end: usize = 3 * 1024 * 1024;
    const regionD_start: usize = 7 * 1024 * 1024;
    const regionD_end: usize = 8 * 1024 * 1024;

    for (regionB_start..regionB_end) |i| {
        newFile[i] = random.int(u8);
    }
    for (regionD_start..regionD_end) |i| {
        newFile[i] = random.int(u8);
    }

    // Also make small scattered changes to create more interesting diff patterns
    // These changes in the "identical" regions create entries with non-trivial seekBy values
    const changePositions = [_]usize{
        500 * 1024,       // 500KB - in region A
        1500 * 1024,      // 1.5MB - in region A
        4 * 1024 * 1024,  // 4MB - in region C
        5 * 1024 * 1024,  // 5MB - in region C
        6 * 1024 * 1024,  // 6MB - in region C
        9 * 1024 * 1024,  // 9MB - in region E
    };

    for (changePositions) |pos| {
        if (pos + 100 < fileSize) {
            for (0..100) |j| {
                newFile[pos + j] = random.int(u8);
            }
        }
    }

    var allocator_handle = allocator;
    const patchData = try bsdiff.calculateDifferences(&allocator_handle, std.testing.io, oldFile, newFile, true);

    allocator_handle = allocator;
    const patchedFile = try bspatch.applyPatch(&allocator_handle, oldFile, patchData);

    try std.testing.expectEqual(newFile.len, patchedFile.len);
    try std.testing.expectEqualSlices(u8, newFile, patchedFile);
}
