const std = @import("std");
const bsdiff = @import("bsdiff.zig");
const bspatch = @import("bspatch.zig");

const Header = std.tar.output.Header;
const block_size: usize = 512;

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
    const patch = try bsdiff.calculateDifferences(&allocator_handle, originalTar, updatedTar, useZstd);

    allocator_handle = allocator;
    const patchedTar = try bspatch.applyPatch(&allocator_handle, originalTar, patch);

    try std.testing.expectEqualSlices(u8, updatedTar, patchedTar);
}

fn buildTarArchive(allocator: std.mem.Allocator, specs: []const FileSpec) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var writer = buffer.writer();

    for (specs) |spec| {
        var header = Header.init();
        try setName(&header, spec.path);
        try writeOctal7(header.mode[0..header.mode.len], 0o644);
        try writeOctal7(header.uid[0..header.uid.len], 0);
        try writeOctal7(header.gid[0..header.gid.len], 0);
        try header.setSize(spec.contents.len);
        try writeOctal11(header.mtime[0..header.mtime.len], 0);
        header.typeflag = .regular;
        try header.updateChecksum();

        try writer.writeAll(std.mem.asBytes(&header));
        try writer.writeAll(spec.contents);

        const remainder = spec.contents.len % block_size;
        const padding = if (remainder == 0) 0 else block_size - remainder;
        if (padding > 0) {
            try writer.writeByteNTimes(0, padding);
        }
    }

    try writer.writeByteNTimes(0, block_size * 2);

    return buffer.toOwnedSlice();
}

fn setName(header: *Header, name: []const u8) !void {
    if (name.len > header.name.len) return error.PathTooLong;
    @memset(header.name[0..], 0);
    @memcpy(header.name[0..name.len], name);
}

fn writeOctal7(buffer: []u8, value: u64) !void {
    if (buffer.len < 7) return error.BufferTooSmall;
    _ = try std.fmt.bufPrint(buffer[0..7], "{o:0>7}", .{value});
}

fn writeOctal11(buffer: []u8, value: u64) !void {
    if (buffer.len < 11) return error.BufferTooSmall;
    _ = try std.fmt.bufPrint(buffer[0..11], "{o:0>11}", .{value});
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
    const patchData = try bsdiff.calculateDifferences(&allocator_handle, oldFile, newFile, true);

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
    const patchData = try bsdiff.calculateDifferences(&allocator_handle, oldFile, newFile, true);

    allocator_handle = allocator;
    const patchedFile = try bspatch.applyPatch(&allocator_handle, oldFile, patchData);

    try std.testing.expectEqual(newFile.len, patchedFile.len);
    try std.testing.expectEqualSlices(u8, newFile, patchedFile);
}
