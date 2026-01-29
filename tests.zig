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

// Test with files that have truly independent regions to force partial chunk overlaps
// This creates a "stripe" pattern where old and new are identical in odd regions
// but completely different in even regions, forcing chunks to stop at stripe boundaries
test "bsdiff/bspatch roundtrip with striped content (partial overlaps)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Create 8MB files (enough for 8 chunks of 1MB each)
    const fileSize: usize = 8 * 1024 * 1024;
    const stripeSize: usize = 512 * 1024; // 512KB stripes

    var oldFile = try allocator.alloc(u8, fileSize);
    var newFile = try allocator.alloc(u8, fileSize);

    var prng = std.Random.DefaultPrng.init(77777);
    var random = prng.random();

    // Fill oldFile with random data
    for (0..fileSize) |i| {
        oldFile[i] = random.int(u8);
    }

    // For newFile:
    // - Odd stripes (1, 3, 5, ...): SAME as oldFile (good matches)
    // - Even stripes (0, 2, 4, ...): DIFFERENT data (no matches, forces extra block)
    var prng2 = std.Random.DefaultPrng.init(88888);
    var random2 = prng2.random();

    for (0..fileSize) |i| {
        const stripeIdx = i / stripeSize;
        if (stripeIdx % 2 == 0) {
            // Even stripe: completely different data
            newFile[i] = random2.int(u8);
        } else {
            // Odd stripe: same as oldFile
            newFile[i] = oldFile[i];
        }
    }

    var allocator_handle = allocator;
    const patchData = try bsdiff.calculateDifferences(&allocator_handle, oldFile, newFile, true);

    allocator_handle = allocator;
    const patchedFile = try bspatch.applyPatch(&allocator_handle, oldFile, patchData);

    try std.testing.expectEqual(newFile.len, patchedFile.len);
    try std.testing.expectEqualSlices(u8, newFile, patchedFile);
}
