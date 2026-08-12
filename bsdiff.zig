// Copyright 2003-2005 Colin Percival
// Copyright 2024 Yoav Givati
// All rights reserved
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted providing that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
// IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

// Note: This is a modified version of bsdiff from Colin Percival.
// The goal is to move compression from bzip2 sections in the patch file to zstd for the whole patch file,
// explore other performance improvements leveraging zig, and potentially optimize for tar file diffing
// used by electrobun.

// todo:
// 1. implement qsufsort and split
// 2. implement search and matchlen
// 3. implement diffb
// 4. add wrapper that takes two absolute file paths and test creating patches
// 5. implement bspatch.zig
// 6. test applying a patch file with checksum
// 7. compare TRDIFF10 with zstd compression with bsdiff4.
// 8. create a cli interace that takes two file paths and creates a patch file
// 9. make build zig fast and small to compare sizes and perf and use in cli
// 10. consider making a standalone repo
const std = @import("std");
const builtin = @import("builtin");

const zstd = @cImport({
    @cInclude("zstd.h");
});

const libsais = @cImport({
    @cInclude("zig_wrapper.h");
});

const vectorSize = std.simd.suggestVectorLength(u8) orelse 4;

// Result from processing a single chunk
const ChunkResult = struct {
    // Control block entries: each entry is 3 x i64 (forwardLen, extraLen, seekBy)
    controlData: []u8,
    controlLen: usize,
    // Diff bytes
    diffData: []u8,
    diffLen: usize,
    // Extra bytes
    extraData: []u8,
    extraLen: usize,
    // Where this chunk actually ended in newData (may extend past nominal boundary)
    actualEndPos: usize,
    // Where this chunk started
    startPos: usize,
};

// 1. create a bsdiff implementation that supports bzip2 classic bsdiff, and a mode that doesn't compress the patch file at all (so you can apply any compression to the whole file)
// since only the electrobun cli needs to compress the file size doesn't matter, we just need prebuilt binaries to electrobun build on different platforms
// 2. compile binaries for every target platform of bsdiff and bspatch with/without bzip2 compression.
// 2. the electrobun launcher will import the bzip-less bspatch.zig implementation and use the bspatch.zig directly in launcher.zig
// 4. the launcher will have an alternate mode to decompress a zstd file.
// 5. the cli will just use exec to run bsdiff against two tar files, it can do this in parallel to compare multiple versions at the same time.
// 6. the cli will then compress all the patch files with the zstd node library, also in parallel. support maybe the last 5 versions of the app. (configurable)
// 5. the electrobun bun api will call the launcher in the mode when it needs to decompress a zstd compressed patch file and apply it.

// 1. update bsdiff to take file path args instead of hardcoded
// 2. build bsdiff binary for arm and make it available to the cli
// 3. update electrobun cli to use bsdiff and the node zstd to generate patches in parallel by spawning multiple processes
// Note: patches don't contain all the information to create the old file from the new file, so the last x versions need to be kept and downloaded.
// 4. write the cli logic to download, generate patches, and create the artifacts folder
// 5. update the launcher binary to include zstd decompress and bspatch.zig directly.
// 6. create electrobun update api to check for updates, download, apply patches, and restart the app.

// 7. then later move bsdiff to its own repo, implement bzip backwards compatability, and a npm package with typescript wrapper.
pub fn main(init: std.process.Init) !void {
    var allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const oldFilePath: []const u8 = if (args.len > 1) args[1] else "";
    const newFilePath: []const u8 = if (args.len > 2) args[2] else "";
    const patchFilePath: []const u8 = if (args.len > 3) args[3] else "";
    // By default we compress the blocks with bzip2 to make patches compatible with
    // the original bsdiff implementation.
    // In electrobun we disable block compression and compress the whole patch file with zstd
    // in a separate process.
    var useZstd = false;
    // Pathological inputs can make the match search grind for hours advancing
    // one byte at a time. The search effort factor deterministically bounds
    // that: unproductive search work is charged against a per-window allowance
    // of (window size x effort); a window that exhausts it is emitted as
    // literal extra data and matching resumes at the next window. Deterministic
    // by construction, so identical inputs produce identical patches on any
    // machine.
    var searchEffort: u64 = defaultSearchEffort;
    const flagArgs = if (args.len > 4) args[4..] else args[0..0];
    for (flagArgs) |arg| {
        if (std.mem.eql(u8, arg, "--use-zstd")) {
            useZstd = true;
        } else if (std.mem.startsWith(u8, arg, "--search-effort=")) {
            const value = arg["--search-effort=".len..];
            searchEffort = std.fmt.parseInt(u64, value, 10) catch {
                std.debug.print("Invalid --search-effort value: {s}\n", .{value});
                std.process.exit(1);
            };
        }
    }

    if (oldFilePath.len == 0 or newFilePath.len == 0 or patchFilePath.len == 0) {
        std.debug.print("Usage: bsdiff <oldFilePath> <newFilePath> <patchFilePath>\n", .{});
        std.debug.print("Usage: bsdiff <oldFilePath> <newFilePath> <patchFilePath> --use-zstd\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --search-effort=<n>  Unproductive-search allowance per window as a multiple of window size (default {d}, 0 = unlimited)\n", .{defaultSearchEffort});
        std.process.exit(1);
    }

    const oldFileBuff = try std.Io.Dir.cwd().readFileAlloc(io, oldFilePath, allocator, .unlimited);
    defer allocator.free(oldFileBuff);

    const newFileBuff = try std.Io.Dir.cwd().readFileAlloc(io, newFilePath, allocator, .unlimited);
    defer allocator.free(newFileBuff);

    // Log system info and file sizes
    const cpuCount = try std.Thread.getCpuCount();
    const oldSizeMB = @as(f64, @floatFromInt(oldFileBuff.len)) / (1024.0 * 1024.0);
    const newSizeMB = @as(f64, @floatFromInt(newFileBuff.len)) / (1024.0 * 1024.0);

    std.debug.print("System Info:\n", .{});
    std.debug.print("  CPUs: {d}\n", .{cpuCount});
    std.debug.print("  Platform: {s}\n", .{@tagName(builtin.target.cpu.arch)});
    std.debug.print("  SIMD vector size: {d} bytes ({s})\n", .{vectorSize, if (vectorSize > 1) "enabled" else "disabled"});
    std.debug.print("\n", .{});
    std.debug.print("Input Files:\n", .{});
    std.debug.print("  File A (old): {d:.1} MB\n", .{oldSizeMB});
    std.debug.print("  File B (new): {d:.1} MB\n", .{newSizeMB});
    std.debug.print("\n", .{});
    std.debug.print("Generating Patch file to turn File A into File B...", .{});
    std.debug.print("\n", .{});

    const patch = try calculateDifferences(&allocator, io, oldFileBuff, newFileBuff, useZstd, searchEffort);

    // Write the patch file, internal blocks compressed with bzip2
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = patchFilePath, .data = patch });
}

/// Millisecond monotonic-ish timestamp used for phase timing logs.
fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// The search-effort window. Budget accounting resets at window granularity so
/// a degenerate region only degrades its own windows, not the whole chunk.
pub const searchEffortWindowSize: usize = 1024 * 1024;

/// Default unproductive-search allowance per window, as a multiple of the
/// window size. Healthy scans charge well under 32x: random regions charge a
/// few dozen units per byte and matching regions advance by whole matches
/// without charging. Only a degenerate scan — long matches repeatedly rejected
/// by the extension score while advancing one byte at a time — exceeds it.
pub const defaultSearchEffort: u64 = 32;

/// searchEffort semantics: 0 disables the budget; otherwise each window of
/// newData gets searchEffort x window-size charge units of unproductive search
/// work before it is emitted as literal data. Deterministic for fixed inputs.
pub fn calculateDifferences(allocator: *std.mem.Allocator, io: std.Io, oldData: []const u8, newData: []const u8, useZstd: bool, searchEffort: u64) ![]u8 {
    if (!useZstd) {
        std.debug.print("Block compression with bzip2 not yet implemented.\n", .{});
    }

    // Allocate memory for the suffix array based on the length of the old data
    const suffixIndexes = try allocator.alloc(i64, oldData.len + 1);
    defer allocator.free(suffixIndexes);

    std.debug.print("Building suffix array with libsais64...\n", .{});
    const saisStart = nowMs(io);

    // Use libsais64 for fast suffix array construction (3-7x faster than qsufsort)
    const oldDataLen: i64 = @intCast(oldData.len);
    const result = libsais.zig_libsais64_wrapper(
        oldData.ptr,
        suffixIndexes.ptr,
        oldDataLen,
    );

    if (result != 0) {
        std.debug.print("libsais64 failed with error code: {d}\n", .{result});
        return error.SuffixArrayConstructionFailed;
    }

    const saisTime = nowMs(io) - saisStart;
    const saisTimeSec = @as(f64, @floatFromInt(saisTime)) / 1000.0;
    std.debug.print("Suffix array built in {d:.2}s\n", .{saisTimeSec});

    // Add sentinel value at the end (used by the original algorithm)
    suffixIndexes[oldData.len] = @intCast(oldData.len);

    const newsize = newData.len;

    // Timing for diff phase
    const diffPhaseStart = nowMs(io);

    // Determine number of chunks based on CPU count
    const cpuCount = std.Thread.getCpuCount() catch 4;
    // Use all available CPUs, but ensure chunks are at least 1MB to avoid excessive overhead
    const minChunkSize: usize = 1024 * 1024; // 1MB minimum
    const maxChunksBySize = newsize / minChunkSize;
    const numChunks = @max(1, @min(cpuCount, maxChunksBySize));

    std.debug.print("Parallel diff with {d} chunks on {d} CPUs...\n", .{ numChunks, cpuCount });

    // Calculate chunk boundaries
    const chunkSize = (newsize + numChunks - 1) / numChunks;

    // Allocate results array and threads array
    var chunkResults = try allocator.alloc(ChunkResult, numChunks);
    defer allocator.free(chunkResults);

    // Track completed chunks for progress reporting
    var completedChunks: usize = 0;

    var threads = try allocator.alloc(std.Thread, numChunks);
    defer allocator.free(threads);

    // Spawn threads for each chunk
    for (0..numChunks) |i| {
        const chunkStart = i * chunkSize;
        const nominalEnd = @min((i + 1) * chunkSize, newsize);

        threads[i] = try std.Thread.spawn(.{}, processChunkThread, .{
            &chunkResults[i],
            allocator.*,
            suffixIndexes,
            oldData,
            newData,
            chunkStart,
            nominalEnd,
            i,
            searchEffort,
            &completedChunks,
        });
    }

    // Start a progress reporting thread
    var progressRunning: bool = true;
    const progressStart = nowMs(io);
    const progressThread = try std.Thread.spawn(.{}, reportDiffProgress, .{
        io,
        &progressRunning,
        &completedChunks,
        numChunks,
        progressStart,
    });

    // Wait for all chunk threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Stop the progress thread
    @atomicStore(bool, &progressRunning, false, .seq_cst);
    progressThread.join();

    // Report diff phase timing
    const diffPhaseTime = nowMs(io) - diffPhaseStart;
    const diffPhaseSec = @as(f64, @floatFromInt(diffPhaseTime)) / 1000.0;
    std.debug.print("Diff phase: {d:.2}s (parallel)\n", .{diffPhaseSec});

    // Merge chunk results, handling overlaps
    // Strategy: Skip all entries from chunk N+1 that overlap with chunk N's actual end.
    // If there's a gap (chunk N+1's first kept entry starts after chunk N's end),
    // fill it with extra data copied directly from newData.

    // First pass: calculate skip offsets and gaps for each chunk
    const ChunkMergeInfo = struct {
        controlSkip: usize, // bytes to skip in control data
        diffSkip: usize, // bytes to skip in diff data
        extraSkip: usize, // bytes to skip in extra data
        gapStart: usize, // where the gap starts in newData (= prevActualEnd)
        gapEnd: usize, // where the gap ends (= first kept entry's start position)
        firstKeptEntryStart: usize, // newData position where first kept entry starts
    };

    var chunkMergeInfo = try allocator.alloc(ChunkMergeInfo, numChunks);
    defer allocator.free(chunkMergeInfo);

    var totalControlLen: usize = 0;
    var totalDiffLen: usize = 0;
    var totalExtraLen: usize = 0;
    var totalGapBytes: usize = 0;

    // Track the maximum coverage seen so far (not just previous chunk's end)
    // This is critical because chunk N might extend further than chunk N+1
    var maxActualEndSoFar: usize = 0;

    for (0..numChunks) |i| {
        if (i == 0) {
            // First chunk: no overlap possible
            chunkMergeInfo[i] = .{
                .controlSkip = 0,
                .diffSkip = 0,
                .extraSkip = 0,
                .gapStart = 0,
                .gapEnd = 0,
                .firstKeptEntryStart = chunkResults[i].startPos,
            };
            totalControlLen += chunkResults[i].controlLen;
            totalDiffLen += chunkResults[i].diffLen;
            totalExtraLen += chunkResults[i].extraLen;
            maxActualEndSoFar = chunkResults[i].actualEndPos;
        } else {
            // Use the maximum coverage seen so far, not just the previous chunk's end
            // This handles cases where chunk N extends further than chunks N+1, N+2, etc.
            const prevActualEnd = maxActualEndSoFar;
            const thisStart = chunkResults[i].startPos;


            if (prevActualEnd <= thisStart) {
                // No overlap - but there might be a gap
                chunkMergeInfo[i] = .{
                    .controlSkip = 0,
                    .diffSkip = 0,
                    .extraSkip = 0,
                    .gapStart = prevActualEnd,
                    .gapEnd = thisStart,
                    .firstKeptEntryStart = thisStart,
                };
                const gapSize = thisStart - prevActualEnd;
                totalGapBytes += gapSize;
                totalControlLen += chunkResults[i].controlLen;
                totalDiffLen += chunkResults[i].diffLen;
                totalExtraLen += chunkResults[i].extraLen;
            } else {
                // Overlap: skip entries until we're past prevActualEnd
                var newDataCovered: usize = thisStart;
                var controlOffset: usize = 0;
                var diffOffset: usize = 0;
                var extraOffset: usize = 0;

                while (controlOffset < chunkResults[i].controlLen) {
                    const forwardLen = offtin(chunkResults[i].controlData[controlOffset..][0..8]);
                    const extraLen = offtin(chunkResults[i].controlData[controlOffset + 8 ..][0..16][0..8]);
                    const entryEnd = newDataCovered + @as(usize, @intCast(forwardLen + extraLen));

                    if (entryEnd <= prevActualEnd) {
                        // Entry fully within overlap - skip it
                        newDataCovered = entryEnd;
                        controlOffset += 24;
                        diffOffset += @intCast(forwardLen);
                        extraOffset += @intCast(extraLen);
                    } else if (newDataCovered >= prevActualEnd) {
                        // Entry starts at or after overlap - keep it
                        break;
                    } else {
                        // Entry crosses the boundary - skip it entirely
                        // The gap will be filled with extra data
                        newDataCovered = entryEnd;
                        controlOffset += 24;
                        diffOffset += @intCast(forwardLen);
                        extraOffset += @intCast(extraLen);
                    }
                }

                // Calculate gap: from prevActualEnd to where we are now
                const gapSize = if (newDataCovered > prevActualEnd) newDataCovered - prevActualEnd else 0;

                chunkMergeInfo[i] = .{
                    .controlSkip = controlOffset,
                    .diffSkip = diffOffset,
                    .extraSkip = extraOffset,
                    .gapStart = prevActualEnd,
                    .gapEnd = newDataCovered,
                    .firstKeptEntryStart = newDataCovered,
                };

                totalGapBytes += gapSize;
                // Use saturating subtraction to handle edge cases where all entries are skipped
                const controlKept = if (chunkResults[i].controlLen > controlOffset) chunkResults[i].controlLen - controlOffset else 0;
                const diffKept = if (chunkResults[i].diffLen > diffOffset) chunkResults[i].diffLen - diffOffset else 0;
                const extraKept = if (chunkResults[i].extraLen > extraOffset) chunkResults[i].extraLen - extraOffset else 0;
                totalControlLen += controlKept;
                totalDiffLen += diffKept;
                totalExtraLen += extraKept;
            }

            // Update max coverage tracking
            maxActualEndSoFar = @max(maxActualEndSoFar, chunkResults[i].actualEndPos);
        }
    }

    // Account for gap fill entries: each gap needs one control entry (24 bytes) and extra data
    const numGaps = blk: {
        var count: usize = 0;
        for (0..numChunks) |i| {
            if (chunkMergeInfo[i].gapEnd > chunkMergeInfo[i].gapStart) count += 1;
        }
        break :blk count;
    };
    totalControlLen += numGaps * 24;
    totalExtraLen += totalGapBytes;

    // Account for seek-only entries: each chunk after the first with kept entries needs one
    // to adjust oldpos before reading the first kept entry's diff
    const numSeekEntries = blk: {
        var count: usize = 0;
        for (1..numChunks) |i| {
            if (chunkResults[i].controlLen > chunkMergeInfo[i].controlSkip) count += 1;
        }
        break :blk count;
    };
    totalControlLen += numSeekEntries * 24;

    // Allocate merged buffers
    var controlBlockStream = try allocator.alloc(u8, @max(totalControlLen, 64 * 1024));
    var diffBlockStream = try allocator.alloc(u8, @max(totalDiffLen, 1024));
    var extraBlockStream = try allocator.alloc(u8, @max(totalExtraLen + totalGapBytes, 1024));

    // Copy data from chunks, inserting gap-fill entries where needed
    // Track oldpos for adjusting seekBy values at chunk boundaries
    var controlOffset: usize = 0;
    var diffOffset: usize = 0;
    var extraOffset: usize = 0;
    var prevChunkEndOldpos: i64 = 0;

    for (0..numChunks) |i| {
        const info = chunkMergeInfo[i];

        // If there's a gap, insert a control entry to fill it with extra data
        // Clamp gap to valid range within newData
        const clampedGapEnd = @min(info.gapEnd, newsize);
        const clampedGapStart = @min(info.gapStart, clampedGapEnd);
        const actualGapSize = clampedGapEnd - clampedGapStart;

        if (actualGapSize > 0) {
            // Control entry: diffBy=0, extraBy=gapSize, seekBy=0
            // This tells bspatch to copy gapSize bytes from extra block to output
            // Note: oldpos doesn't change (seekBy=0, diffBy=0)
            offtout(0, controlBlockStream[controlOffset..][0..8]); // diffBy = 0
            controlOffset += 8;
            offtout(@intCast(actualGapSize), controlBlockStream[controlOffset..][0..8]); // extraBy = gapSize
            controlOffset += 8;
            offtout(0, controlBlockStream[controlOffset..][0..8]); // seekBy = 0
            controlOffset += 8;

            // Copy the gap bytes from newData to extra block
            @memcpy(extraBlockStream[extraOffset..][0..actualGapSize], newData[clampedGapStart..clampedGapEnd]);
            extraOffset += actualGapSize;
        }

        // Calculate skippedOldposDelta: how much oldpos would have moved through skipped entries
        var skippedOldposDelta: i64 = 0;
        var ctrlPos: usize = 0;
        while (ctrlPos < info.controlSkip) {
            const forwardLen = offtin(chunkResults[i].controlData[ctrlPos..][0..8]);
            const seekByVal = offtin(chunkResults[i].controlData[ctrlPos + 16 ..][0..8]);
            skippedOldposDelta += forwardLen + seekByVal;
            ctrlPos += 24;
        }

        // Copy this chunk's remaining control/diff/extra data
        const controlToCopy = chunkResults[i].controlLen - info.controlSkip;
        const diffToCopy = chunkResults[i].diffLen - info.diffSkip;
        const extraToCopy = chunkResults[i].extraLen - info.extraSkip;

        if (controlToCopy > 0) {
            // For chunks after the first, insert a "seek-only" entry to adjust oldpos
            // The diff data was computed using the chunk's internal oldpos tracking,
            // so we need oldpos to be at skippedOldposDelta before reading the first entry
            if (i > 0) {
                const seekAdjustment = skippedOldposDelta - prevChunkEndOldpos;
                offtout(0, controlBlockStream[controlOffset..][0..8]); // diffBy = 0
                controlOffset += 8;
                offtout(0, controlBlockStream[controlOffset..][0..8]); // extraBy = 0
                controlOffset += 8;
                offtout(seekAdjustment, controlBlockStream[controlOffset..][0..8]); // seekBy = adjustment
                controlOffset += 8;
                // After this entry: oldpos = prevChunkEndOldpos + 0 + seekAdjustment = skippedOldposDelta
                prevChunkEndOldpos = skippedOldposDelta;
            }

            // Copy the chunk's kept entries unchanged (no seekBy adjustment needed)
            @memcpy(controlBlockStream[controlOffset..][0..controlToCopy], chunkResults[i].controlData[info.controlSkip..][0..controlToCopy]);

            // Calculate where oldpos ends after this chunk's remaining entries
            var chunkOldposDelta: i64 = 0;
            var pos: usize = info.controlSkip;
            while (pos < chunkResults[i].controlLen) {
                const forwardLen = offtin(chunkResults[i].controlData[pos..][0..8]);
                const seekByVal = offtin(chunkResults[i].controlData[pos + 16 ..][0..8]);
                chunkOldposDelta += forwardLen + seekByVal;
                pos += 24;
            }

            prevChunkEndOldpos += chunkOldposDelta;
            controlOffset += controlToCopy;
        }

        if (diffToCopy > 0) {
            @memcpy(diffBlockStream[diffOffset..][0..diffToCopy], chunkResults[i].diffData[info.diffSkip..][0..diffToCopy]);
            diffOffset += diffToCopy;
        }

        if (extraToCopy > 0) {
            @memcpy(extraBlockStream[extraOffset..][0..extraToCopy], chunkResults[i].extraData[info.extraSkip..][0..extraToCopy]);
            extraOffset += extraToCopy;
        }

        // Free chunk data
        allocator.free(chunkResults[i].controlData);
        allocator.free(chunkResults[i].diffData);
        allocator.free(chunkResults[i].extraData);
    }

    // Now compress the merged data
    std.debug.print("Compressing...\n", .{});
    const compressStart = nowMs(io);

    var controlBlockInput = zstd.ZSTD_inBuffer{ .src = controlBlockStream.ptr, .size = controlOffset, .pos = 0 };
    const controlBlockCompressed = try allocator.alloc(u8, zstd.ZSTD_compressBound(controlOffset));
    var controlBlockOutput = zstd.ZSTD_outBuffer{ .dst = controlBlockCompressed.ptr, .size = controlBlockCompressed.len, .pos = 0 };
    const controlBlockThread = try std.Thread.spawn(.{}, compressBlockStream, .{ &controlBlockInput, &controlBlockOutput });

    var diffBlockInput = zstd.ZSTD_inBuffer{ .src = diffBlockStream.ptr, .size = diffOffset, .pos = 0 };
    const diffBlockCompressed = try allocator.alloc(u8, zstd.ZSTD_compressBound(diffOffset));
    var diffBlockOutput = zstd.ZSTD_outBuffer{ .dst = diffBlockCompressed.ptr, .size = diffBlockCompressed.len, .pos = 0 };
    const diffBlockThread = try std.Thread.spawn(.{}, compressBlockStream, .{ &diffBlockInput, &diffBlockOutput });

    var extraBlockInput = zstd.ZSTD_inBuffer{ .src = extraBlockStream.ptr, .size = extraOffset, .pos = 0 };
    const extraBlockCompressed = try allocator.alloc(u8, zstd.ZSTD_compressBound(extraOffset));
    var extraBlockOutput = zstd.ZSTD_outBuffer{ .dst = extraBlockCompressed.ptr, .size = extraBlockCompressed.len, .pos = 0 };
    const extraBlockThread = try std.Thread.spawn(.{}, compressBlockStream, .{ &extraBlockInput, &extraBlockOutput });

    controlBlockThread.join();
    diffBlockThread.join();
    extraBlockThread.join();

    const compressTime = nowMs(io) - compressStart;
    const compressTimeSec = @as(f64, @floatFromInt(compressTime)) / 1000.0;
    std.debug.print("Compression: {d:.2}s\n", .{compressTimeSec});

    // Header is
    // 0 8 "BSDIFF40" or "TRDIFF10"
    // 8 8 length of ctrl block  i64
    // 16 8 length of diff block  i64
    // 24 8 length of new file    i64

    // Placeholder for the buffer used in offtout
    var buffer = [_]u8{0} ** 8;

    // Combine header, diffBlock, and extraBlock into a single byte slice to return
    const headerLength = 32;

    var patch = try allocator.alloc(u8, headerLength + controlBlockOutput.pos + diffBlockOutput.pos + extraBlockOutput.pos);
    // write the header compressed
    @memcpy(patch[0..8], "TRDIFF10");

    offtout(@intCast(controlBlockOutput.pos), &buffer);
    @memcpy(patch[8..16], &buffer);

    offtout(@intCast(diffBlockOutput.pos), &buffer);
    @memcpy(patch[16..24], &buffer);

    offtout(@intCast(newsize), &buffer);
    @memcpy(patch[24..32], &buffer);

    var patchFileOffset: usize = headerLength;
    @memcpy(patch[patchFileOffset..][0..controlBlockOutput.pos], controlBlockCompressed.ptr);
    patchFileOffset += controlBlockOutput.pos;

    @memcpy(patch[patchFileOffset..][0..diffBlockOutput.pos], diffBlockCompressed.ptr);
    patchFileOffset += diffBlockOutput.pos;

    @memcpy(patch[patchFileOffset..][0..extraBlockOutput.pos], extraBlockCompressed.ptr);
    patchFileOffset += extraBlockOutput.pos;

    const patchSizeKB = @as(f64, @floatFromInt(patch.len)) / 1024.0;
    const compressionRatio = (@as(f64, @floatFromInt(patch.len)) / @as(f64, @floatFromInt(newData.len))) * 100.0;
    std.debug.print("Completed - Patch: {d:.2} KB ({d:.1}% of new size)\n", .{ patchSizeKB, compressionRatio });

    return patch;
}

/// Process a chunk of the new file, finding matches in the old file.
/// If a match extends past the nominal boundary, we continue until the match ends.
fn processChunk(
    allocator: std.mem.Allocator,
    suffixIndexes: []i64,
    oldData: []const u8,
    newData: []const u8,
    chunkStart: usize,
    nominalEnd: usize,
    chunkIndex: usize,
    searchEffort: u64,
) !ChunkResult {
    const newsize = newData.len;
    const oldsize = oldData.len;

    // Allocate buffers for this chunk's output
    // Chunks can extend significantly past their boundary if there's a long match
    // Allocate generously - up to the full remaining file size in worst case
    const remainingSize = newData.len - chunkStart;
    const maxControlSize = @max((remainingSize / 8) * 24, 64 * 1024); // Rough estimate
    var controlData = try allocator.alloc(u8, maxControlSize);
    var controlLen: usize = 0;

    var diffData = try allocator.alloc(u8, remainingSize);
    var diffLen: usize = 0;

    var extraData = try allocator.alloc(u8, remainingSize);
    var extraLen: usize = 0;

    // Initialize variables for tracking positions and scores
    var scanIndex: i64 = @intCast(chunkStart);
    var matchLength: i64 = 0;
    var lastScanIndex: i64 = @intCast(chunkStart);
    var lastMatchPosition: i64 = 0;
    var lastOffset: i64 = 0;
    var matchScore: i64 = 0;
    var matchPosition: i64 = 0;

    var scoreCounter: i64 = 0;
    var forwardScore: i64 = 0;
    var forwardLength: i64 = 0;
    var backwardScore: i64 = 0;
    var backwardLength: i64 = 0;

    var overlapLength: i64 = 0;
    var bestOverlapScore: i64 = 0;
    var bestOverlapLength: i64 = 0;

    // Track if we're in the middle of a match when we hit the boundary
    var actualEndPos: usize = chunkStart;

    // Deterministic search budget: unproductive search work — long matches the
    // extension score keeps rejecting while the scan advances one byte at a
    // time — is charged against a per-window allowance. A window that exhausts
    // it is emitted as literal extra data and matching resumes at the next
    // window, so a degenerate region only degrades itself.
    const windowBudget: u64 = searchEffort * @as(u64, searchEffortWindowSize);
    var windowCharge: u64 = 0;
    var windowBoundary: usize = chunkStart + searchEffortWindowSize;
    var degradedBytes: usize = 0;

    // Main diff loop for this chunk
    outer: while (scanIndex < newsize) {
        matchScore = 0;
        scanIndex += matchLength;
        scoreCounter = scanIndex;

        // Search for matches
        while (scanIndex < newsize) {
            if (@as(usize, @intCast(scanIndex)) >= windowBoundary) {
                windowCharge = 0;
                windowBoundary = @as(usize, @intCast(scanIndex)) + searchEffortWindowSize;
            }
            if (searchEffort != 0 and windowCharge > windowBudget) {
                // This window is degenerate; cover the rest of it with one
                // literal entry (diffBy=0, extraBy=len, seekBy=0 keeps oldpos
                // unchanged) and resume matching at the window boundary.
                const coveredEnd: usize = @intCast(lastScanIndex);
                const literalEnd = @min(@max(windowBoundary, coveredEnd), newsize);
                if (literalEnd > coveredEnd) {
                    const literalLen = literalEnd - coveredEnd;
                    offtout(0, controlData[controlLen..][0..8]);
                    controlLen += 8;
                    offtout(@intCast(literalLen), controlData[controlLen..][0..8]);
                    controlLen += 8;
                    offtout(0, controlData[controlLen..][0..8]);
                    controlLen += 8;
                    @memcpy(extraData[extraLen..][0..literalLen], newData[coveredEnd..literalEnd]);
                    extraLen += literalLen;
                    degradedBytes += literalLen;
                }
                lastScanIndex = @intCast(literalEnd);
                actualEndPos = literalEnd;
                scanIndex = @intCast(literalEnd);
                matchLength = 0;
                windowCharge = 0;
                windowBoundary = literalEnd + searchEffortWindowSize;
                if (literalEnd >= nominalEnd) break :outer;
                continue :outer;
            }

            matchLength = @intCast(searchWithLCP(suffixIndexes, oldData, newData[@intCast(scanIndex)..], 0, @intCast(oldsize), &matchPosition));

            while (scoreCounter < scanIndex + matchLength) {
                const currentScanPos = scoreCounter + lastOffset;
                if (currentScanPos >= 0 and currentScanPos < oldsize and oldData[@intCast(currentScanPos)] == newData[@intCast(scoreCounter)]) {
                    matchScore += 1;
                }
                scoreCounter += 1;
            }

            if (matchLength == matchScore and matchLength != 0) {
                break;
            }
            if (matchLength > matchScore + 8) {
                break;
            }
            if (scanIndex + lastOffset >= 0 and scanIndex + lastOffset < oldsize and oldData[@intCast(scanIndex + lastOffset)] == newData[@intCast(scanIndex)]) {
                matchScore -= 1;
            }

            // Advancing byte-by-byte after a rejected match is the unproductive
            // path; charge the work the search just did against this window.
            windowCharge += @as(u64, @intCast(matchLength)) + 16;
            scanIndex += 1;
        }

        // Process the match
        if (matchLength != matchScore or scanIndex >= newsize) {
            scoreCounter = 0;
            forwardScore = 0;
            forwardLength = 0;
            var i: i64 = 0;

            // Calculate forward length
            // When scanIndex >= newsize, we need to clamp to the actual file boundary
            // to avoid creating control entries that extend past the new file
            const effectiveScanIndex = @min(scanIndex, @as(i64, @intCast(newsize)));
            while (lastScanIndex + i < effectiveScanIndex and lastMatchPosition + i < oldsize) {
                if (oldData[@intCast(lastMatchPosition + i)] == newData[@intCast(lastScanIndex + i)]) {
                    scoreCounter += 1;
                }
                i += 1;
                if (scoreCounter * 2 - i > forwardScore * 2 - forwardLength) {
                    forwardScore = scoreCounter;
                    forwardLength = i;
                }
            }

            // Calculate backward length
            backwardLength = 0;
            if (scanIndex < newsize) {
                scoreCounter = 0;
                backwardScore = 0;
                i = 1;
                while (scanIndex >= lastScanIndex + i and matchPosition >= i) {
                    if (oldData[@intCast(matchPosition - i)] == newData[@intCast(scanIndex - i)]) {
                        scoreCounter += 1;
                    }
                    if (scoreCounter * 2 - i > backwardScore * 2 - backwardLength) {
                        backwardScore = scoreCounter;
                        backwardLength = i;
                    }
                    i += 1;
                }
            }

            // Handle overlaps
            if (lastScanIndex + forwardLength > scanIndex - backwardLength) {
                overlapLength = (lastScanIndex + forwardLength) - (scanIndex - backwardLength);
                scoreCounter = 0;
                bestOverlapScore = 0;
                bestOverlapLength = 0;
                i = 0;

                while (i < overlapLength) {
                    if (newData[@intCast(lastScanIndex + forwardLength - overlapLength + i)] == oldData[@intCast(lastMatchPosition + forwardLength - overlapLength + i)]) {
                        scoreCounter += 1;
                    }
                    if (newData[@intCast(scanIndex - backwardLength + i)] == oldData[@intCast(matchPosition - backwardLength + i)]) {
                        scoreCounter -= 1;
                    }
                    if (scoreCounter > bestOverlapScore) {
                        bestOverlapScore = scoreCounter;
                        bestOverlapLength = i + 1;
                    }
                    i += 1;
                }

                forwardLength += bestOverlapLength - overlapLength;
                backwardLength -= bestOverlapLength;
            }

            // Write diff data
            i = 0;
            while (i < forwardLength) {
                if (i + vectorSize <= forwardLength) {
                    const oldpos: usize = @intCast(lastMatchPosition + i);
                    const newpos: usize = @intCast(lastScanIndex + i);

                    const newVec: @Vector(vectorSize, u8) = newData[newpos..][0..vectorSize].*;
                    const oldVec: @Vector(vectorSize, u8) = oldData[oldpos..][0..vectorSize].*;
                    const resultVec = @subWithOverflow(newVec, oldVec)[0];
                    const resultArray: [vectorSize]u8 = resultVec;
                    @memcpy(diffData[diffLen + @as(usize, @intCast(i)) ..][0..vectorSize], &resultArray);

                    i += vectorSize;
                    continue;
                }

                const newByte: u8 = newData[@intCast(lastScanIndex + i)];
                const oldByte: u8 = oldData[@intCast(lastMatchPosition + i)];
                diffData[diffLen + @as(usize, @intCast(i))] = @subWithOverflow(newByte, oldByte)[0];
                i += 1;
            }

            // Write extra data
            const newBytesAdded = (scanIndex - backwardLength) - (lastScanIndex + forwardLength);
            i = 0;
            while (i < newBytesAdded) {
                extraData[extraLen + @as(usize, @intCast(i))] = newData[@intCast(lastScanIndex + forwardLength + i)];
                i += 1;
            }

            // Write control block
            const readDiffBy = forwardLength;
            const readExtraBy = newBytesAdded;
            const seekBy = (matchPosition - backwardLength) - (lastMatchPosition + forwardLength);

            offtout(readDiffBy, controlData[controlLen..][0..8]);
            controlLen += 8;
            offtout(readExtraBy, controlData[controlLen..][0..8]);
            controlLen += 8;
            offtout(seekBy, controlData[controlLen..][0..8]);
            controlLen += 8;

            diffLen += @intCast(readDiffBy);
            extraLen += @intCast(readExtraBy);

            // Update positions
            lastScanIndex = scanIndex - backwardLength;
            lastMatchPosition = matchPosition - backwardLength;
            lastOffset = matchPosition - scanIndex;

            // Update actual end position
            actualEndPos = @intCast(lastScanIndex);

            // Check if we've passed the nominal boundary after completing this match
            // We stop once we've finished a match that ends past the boundary
            if (@as(usize, @intCast(lastScanIndex)) >= nominalEnd) {
                break;
            }
        }
    }

    if (degradedBytes > 0) {
        const degradedMB = @as(f64, @floatFromInt(degradedBytes)) / (1024.0 * 1024.0);
        std.debug.print("Chunk {d}: search effort budget hit; {d:.1} MB emitted as literal data\n", .{ chunkIndex, degradedMB });
    }

    return ChunkResult{
        .controlData = controlData,
        .controlLen = controlLen,
        .diffData = diffData,
        .diffLen = diffLen,
        .extraData = extraData,
        .extraLen = extraLen,
        .actualEndPos = actualEndPos,
        .startPos = chunkStart,
    };
}

/// Progress reporting thread for parallel diff
fn reportDiffProgress(
    io: std.Io,
    running: *bool,
    completedChunks: *usize,
    numChunks: usize,
    startTime: i64,
) void {
    var lastPrintTime: i64 = startTime;

    while (@atomicLoad(bool, running, .seq_cst)) {
        std.Io.sleep(io, .fromSeconds(1), .awake) catch {}; // Check every second

        const now = nowMs(io);
        const elapsed = now - startTime;
        const elapsedSec = @as(f64, @floatFromInt(elapsed)) / 1000.0;
        const timeSinceLastPrint = now - lastPrintTime;

        // Print every 10 seconds if still running
        if (timeSinceLastPrint >= 10000) {
            const completed = @atomicLoad(usize, completedChunks, .seq_cst);
            if (completed < numChunks) {
                const percent = (@as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(numChunks))) * 100.0;
                std.debug.print("Diffing... {d}/{d} chunks complete ({d:.0}%) - {d:.0}s elapsed\n", .{ completed, numChunks, percent, elapsedSec });
                lastPrintTime = now;
            }
        }
    }
}

/// Thread wrapper for processChunk
fn processChunkThread(
    result: *ChunkResult,
    allocator: std.mem.Allocator,
    suffixIndexes: []i64,
    oldData: []const u8,
    newData: []const u8,
    chunkStart: usize,
    nominalEnd: usize,
    chunkIndex: usize,
    searchEffort: u64,
    completedChunks: *usize,
) void {
    result.* = processChunk(allocator, suffixIndexes, oldData, newData, chunkStart, nominalEnd, chunkIndex, searchEffort) catch |err| {
        std.debug.print("Chunk processing error: {}\n", .{err});
        _ = @atomicRmw(usize, completedChunks, .Add, 1, .seq_cst);
        return;
    };
    _ = @atomicRmw(usize, completedChunks, .Add, 1, .seq_cst);
}

var totalCompressedSize: usize = 0;

// Notes on Zstd:
// compressed output between single shot and streaming with a single frame is roughly the same.
// with a single frame zstd takes roughly 20% longer to compress the same data. but with streaming you can compress in parallel to the actual diffing in another thread.
fn compressBlock(allocator: *std.mem.Allocator, block: []const u8) !void {
    // non-streaming
    const maxCompressedSize = zstd.ZSTD_compressBound(block.len);
    const compressedBlock = try allocator.alloc(u8, maxCompressedSize);
    // defer allocator.free(compressedBlock);

    const compressedSize = zstd.ZSTD_compress(compressedBlock.ptr, compressedBlock.len, block.ptr, block.len, 22);
    totalCompressedSize += compressedSize;
    // return compressedSize;
    // return compressedBlock[0..compressedSize];
}

fn compressBlockStream(input: *zstd.ZSTD_inBuffer, output: *zstd.ZSTD_outBuffer) void {
    const cstream = zstd.ZSTD_createCStream();
    defer {
        _ = zstd.ZSTD_freeCStream(cstream);
    }

    // Note: Experimentally there's no significant difference between 19 and 22 with regard to compression output
    // creates smaller output at 19 than bzip2. However there is a huge time cost between 19 and 22, roughly 20% longer.
    // setting this to 22 the total bsdiff time matches the original bsdiff c implementation
    // setting this to 19 the total bsdiff time is roughly 20% faster than the original bsdiff c implementation
    // in both cases the output is roughly 10% smaller.
    // obviously this will vary based on the data being compressed.
    _ = zstd.ZSTD_initCStream(cstream, 19);

    // The input buffer is fully populated before the thread is spawned, so we
    // can drain it and end the stream without any polling.
    while (input.pos < input.size) {
        _ = zstd.ZSTD_compressStream(cstream, output, input);
    }

    _ = zstd.ZSTD_endStream(cstream, output);
}

// offtin reads an int64 (little endian) from buf
fn offtin(buf: []const u8) i64 {
    var y: u64 = @as(u64, buf[0]);
    y |= @as(u64, buf[1]) << 8;
    y |= @as(u64, buf[2]) << 16;
    y |= @as(u64, buf[3]) << 24;
    y |= @as(u64, buf[4]) << 32;
    y |= @as(u64, buf[5]) << 40;
    y |= @as(u64, buf[6]) << 48;
    y |= @as(u64, buf[7]) << 56;

    if (y & 0x8000000000000000 != 0) {
        return -@as(i64, @bitCast(y & 0x7FFFFFFFFFFFFFFF));
    }
    return @as(i64, @bitCast(y));
}

// offtout puts an int64 (little endian) to buf
fn offtout(x: i64, buf: []u8) void {
    var y: u64 = undefined;
    if (x < 0) {
        y = @as(u64, @bitCast(-x)) | 0x8000000000000000;
    } else {
        y = @as(u64, @bitCast(x));
    }

    buf[0] = @intCast(y & 0xFF);
    buf[1] = @intCast((y >> 8) & 0xFF);
    buf[2] = @intCast((y >> 16) & 0xFF);
    buf[3] = @intCast((y >> 24) & 0xFF);
    buf[4] = @intCast((y >> 32) & 0xFF);
    buf[5] = @intCast((y >> 40) & 0xFF);
    buf[6] = @intCast((y >> 48) & 0xFF);
    buf[7] = @intCast((y >> 56) & 0xFF);
}

/// Boundary-tracking binary search to find the longest match.
/// By tracking match lengths at boundaries, we skip redundant comparisons,
/// achieving O(m + log n) instead of O(m * log n).
fn searchWithLCP(suffixIndexes: []i64, oldData: []const u8, newData: []const u8, from: usize, to: usize, bestMatchPosition: *i64) usize {
    // Use iterative approach with LCP acceleration
    var lo: usize = from;
    var hi: usize = to;
    var loMatch: usize = 0; // chars matching at lo boundary
    var hiMatch: usize = 0; // chars matching at hi boundary

    const oldDataSize = oldData.len;
    const newDataSize = newData.len;

    // Initial match lengths at boundaries
    loMatch = matchlenFast(oldData[@intCast(suffixIndexes[lo])..], newData);
    hiMatch = matchlenFast(oldData[@intCast(suffixIndexes[hi])..], newData);

    var bestMatch: usize = loMatch;
    bestMatchPosition.* = suffixIndexes[lo];
    if (hiMatch > bestMatch) {
        bestMatch = hiMatch;
        bestMatchPosition.* = suffixIndexes[hi];
    }

    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        const midSuffixPos: usize = @intCast(suffixIndexes[mid]);

        // Start comparison from the minimum of the two boundary matches
        // This is the key LCP optimization - we know at least this many chars must match
        const skipLen = @min(loMatch, hiMatch);

        // Compare starting from skipLen
        const compareLen = @min(oldDataSize - midSuffixPos, newDataSize);
        var midMatch: usize = skipLen;

        // Continue matching from skipLen
        if (skipLen < compareLen) {
            midMatch += matchlenFrom(oldData[midSuffixPos + skipLen ..], newData[skipLen..]);
        }

        // Update best match if this is better
        if (midMatch > bestMatch) {
            bestMatch = midMatch;
            bestMatchPosition.* = suffixIndexes[mid];
        }

        // Decide which half to search based on lexicographic comparison
        if (midMatch < compareLen and midMatch < newDataSize) {
            // We stopped matching at position midMatch
            if (midSuffixPos + midMatch < oldDataSize and oldData[midSuffixPos + midMatch] < newData[midMatch]) {
                // Suffix at mid is less than query, search right half
                lo = mid;
                loMatch = midMatch;
            } else {
                // Suffix at mid is greater than query, search left half
                hi = mid;
                hiMatch = midMatch;
            }
        } else {
            // Full match up to the limit, decide based on lengths
            if (compareLen <= newDataSize) {
                // Need longer suffixes, search left (smaller indices = longer suffixes in sorted order when equal prefix)
                hi = mid;
                hiMatch = midMatch;
            } else {
                lo = mid;
                loMatch = midMatch;
            }
        }
    }

    return bestMatch;
}

/// Helper function: match length starting from an offset (for LCP-accelerated search)
fn matchlenFrom(oldData: []const u8, newData: []const u8) usize {
    const minSize = @min(oldData.len, newData.len);
    var i: usize = 0;

    // Use 8-byte lookahead for speed
    while (i + 8 <= minSize) {
        const oldSlice: *const [8]u8 = @ptrCast(&oldData[i]);
        const newSlice: *const [8]u8 = @ptrCast(&newData[i]);
        const oldAs64 = std.mem.readInt(u64, oldSlice, std.builtin.Endian.big);
        const newAs64 = std.mem.readInt(u64, newSlice, std.builtin.Endian.big);

        if (oldAs64 != newAs64) {
            // Find exact mismatch position within the 8 bytes
            while (i < minSize and oldData[i] == newData[i]) {
                i += 1;
            }
            return i;
        }
        i += 8;
    }

    // Handle remaining bytes
    while (i < minSize and oldData[i] == newData[i]) {
        i += 1;
    }

    return i;
}

/// Do a binary search to find the longest match of `newData` within `oldData` using precomputed suffixIndexes.
fn search(suffixIndexes: []i64, oldData: []const u8, newData: []const u8, from: usize, to: usize, bestMatchPosition: *i64) usize {
    var midPoint: usize = 0;
    var matchLength: usize = 0;
    const oldDataSize = oldData.len;
    const newDataSize = newData.len;
    const searchLength = to - from;

    // Base case: If the search range is less than 2, directly compare the matches at the start and end points.
    if (searchLength < 2) {
        midPoint = matchlenFast(oldData[@intCast(suffixIndexes[from])..], newData);
        matchLength = matchlenFast(oldData[@intCast(suffixIndexes[to])..], newData);

        if (midPoint > matchLength) {
            bestMatchPosition.* = suffixIndexes[from];
            return midPoint;
        }
        bestMatchPosition.* = suffixIndexes[to];
        return matchLength;
    }

    // Calculate the midpoint of the current search range.
    midPoint = from + @divTrunc((searchLength), 2);
    // Determine the length to compare based on the remaining length in `oldData` and the total length of `newData`.
    const compareLength = @min(oldDataSize - @as(usize, @intCast(suffixIndexes[midPoint])), newDataSize);
    const compareFrom: usize = @intCast(suffixIndexes[midPoint]);
    // Compare the substring of `oldData` starting from `compareStart` with the beginning of `newData`.
    const compareResult = compareSlicesFast(oldData[compareFrom .. compareFrom + compareLength], newData[0..compareLength]);

    // Recursively search in the half of the range where the comparison indicates the match might be found.
    if (compareResult < 0) {
        return search(suffixIndexes, oldData, newData, midPoint, to, bestMatchPosition);
    } else {
        return search(suffixIndexes, oldData, newData, from, midPoint, bestMatchPosition);
    }
}

fn compareSlicesOrig(a: []const u8, b: []const u8) i64 {
    const minSize = @min(a.len, b.len);
    // std.debug.print("minSize: {}\n", .{minSize});
    for (0..minSize) |i| {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }

    // If all compared elements are equal, decide based on length
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

// For two 48MB files doing lookaheads makes it about 6.5 seconds (30%) faster
// this is because for software updates the files are typically mostly the same
// and this function tends to compare large swaths of the file in one go as it
// bisects down
fn compareSlicesFast(a: []const u8, b: []const u8) i64 {
    const minSize = @min(a.len, b.len);
    var i: usize = 0;
    var lookAheadIndex: usize = 0;
    const lookAheadDistance: usize = 8;

    while (i < minSize) {
        if (i >= lookAheadIndex and i + lookAheadDistance < minSize) {
            while (i + lookAheadDistance < minSize) {
                lookAheadIndex = i + lookAheadDistance;

                const aSlice = a[i..lookAheadIndex];
                const bSlice = b[i..lookAheadIndex];

                const aSlicePointer: *const [8]u8 = @ptrCast(&aSlice[0]);
                const bSlicePointer: *const [8]u8 = @ptrCast(&bSlice[0]);

                const aAs64 = std.mem.readInt(u64, aSlicePointer, std.builtin.Endian.big);
                const bAs64 = std.mem.readInt(u64, bSlicePointer, std.builtin.Endian.big);

                if (aAs64 == bAs64) {
                    i = lookAheadIndex;
                } else {
                    break;
                }
            }
        }

        // perf: 0 and -1 tend to be most common, so check those first
        if (a[i] == b[i]) {
            i += 1;
            continue;
        } else if (a[i] < b[i]) {
            return -1;
        } else {
            return 1;
        }

        if (a[i] == b[i]) {
            i += 1;
            continue;
        } else if (a[i] < b[i]) {
            return -1;
        } else {
            return 1;
        }

        // i += 1;
        // std.debug.print("match: {}\n", .{i});
    }
    // If all compared elements are equal, decide based on length
    // perf: when used in the diffing algorithm search function
    // these tend to be equal when we get here, so check that first
    // this saves a surprising amount of time. for file diffs that take 20 seconds
    // with the c bsdiff, this saves about 500ms.
    if (a.len == b.len) {
        return 0;
    } else if (a.len < b.len) {
        return -1;
    } else {
        return 1;
    }
}

/// Calculates the length of the longest prefix match between two byte arrays using a lookahead optimization.
// in practice the total iterations using matchlenFast are around 16% of the total iterations needed by a brute force matchlen
// eg: diff did 297,101,075 total iterations instead of 1,852,824,342
// on m1 max it shaves about 4% off the total time when diffing two 48MB files
fn matchlenFast(oldData: []const u8, newData: []const u8) usize {
    var matchLength: usize = 0;
    var lookAheadIndex: usize = 0;
    // This works well with 8, you tend be able to skip more iteration loops and get more matches with 7
    // eg: in a 48MB file diff, you skip an additional 50 million iterations with 7 than with 8
    const lookAheadDistance: usize = 7;

    const oldsize = oldData.len;
    const newsize = newData.len;
    const minSize = @min(oldsize, newsize);

    while (matchLength < minSize) {
        // perf: Go faster by comparing 7 bytes at a time
        if (matchLength >= lookAheadIndex and matchLength + lookAheadDistance < minSize) {
            while (matchLength + lookAheadDistance < minSize) {
                lookAheadIndex = matchLength + lookAheadDistance;

                const oldSlice = oldData[matchLength..lookAheadIndex];
                const newSlice = newData[matchLength..lookAheadIndex];

                const oldSlicePointer: *const [7]u8 = @ptrCast(&oldSlice[0]);
                const newSlicePointer: *const [7]u8 = @ptrCast(&newSlice[0]);

                const oldAs56 = std.mem.readInt(u56, oldSlicePointer, std.builtin.Endian.big);
                const newAs56 = std.mem.readInt(u56, newSlicePointer, std.builtin.Endian.big);

                if (oldAs56 == newAs56) {
                    matchLength = lookAheadIndex;
                } else {
                    break;
                }
            }
        }

        if (oldData[matchLength] != newData[matchLength]) {
            break;
        }
        matchLength += 1;
    }
    return matchLength;
}

fn qsufsortFast(allocator: *std.mem.Allocator, suffixIndexes: []i64, buf: []const u8, progressBytes: *usize, progressPercent: *f32) !void {
    // perf: instead of creating a buckets array of 256 elements, and shifting them over one index back and forth in the alogirthm,
    // we can create a slightly longer array, and just reposition the slice which should be a bit faster

    var _buckets: [257]i64 = [_]i64{0} ** 257;
    var buckets = _buckets[1..];

    // inverse of the suffix array, sorted array of suffixes. indexes are suffixes sorted longest to shortest, values the index of the first character group in the sorted array
    const inverseSuffix = try allocator.alloc(i64, suffixIndexes.len);
    defer allocator.free(inverseSuffix);
    const bufzise = buf.len;
    const bufzisePlusOne: i64 = @intCast(buf.len + 1);

    for (buf) |b| {
        buckets[b] += 1;
    }

    // looping up, set each element to the sum of the previous elements
    // bucket[1] = bucket[0] + bucket[1];
    // this effectively makes them the starting index of the next bucket
    for (1..256) |i| {
        buckets[i] += buckets[i - 1];
    }

    // looping down, shift each element one index to the right
    // bucket[255] = bucket[254];
    // then set bucket[0] = 0;
    buckets = _buckets[0..256];

    buckets[0] = 0;
    // incrementing each 'starting index' for each bucket to get the 'next index for that bucket'
    // use the index to set the position of each suffix
    for (buf, 0..) |b, i| {
        buckets[b] += 1;
        // Note: in zig array indexes are assumed to be usize, so we need to cast i64 to usize
        suffixIndexes[@intCast(buckets[@intCast(b)])] = @intCast(i);
    }
    // at this point we have the suffixes sorted by bucket

    suffixIndexes[0] = @intCast(bufzise);

    // create inverseSuffix that maps each suffix to the last index of
    // that suffix grouping in the semi-sorted array.
    for (buf, 0..) |b, i| {
        inverseSuffix[i] = buckets[b];
    }

    inverseSuffix[bufzise] = 0;

    for (1..256) |i| {
        if (buckets[i] == buckets[i - 1] + 1) {
            suffixIndexes[@intCast(buckets[i])] = -1;
        }
    }

    suffixIndexes[0] = -1;

    var h: i64 = 1;
    while (suffixIndexes[0] != -bufzisePlusOne) {
        var ln: i64 = 0;
        var i: i64 = 0;
        while (i < bufzisePlusOne) {
            const suffixIndexesI = suffixIndexes[@intCast(i)];
            if (suffixIndexesI < 0) {
                ln -= suffixIndexesI;
                i -= suffixIndexesI;
            } else {
                if (ln != 0) {
                    suffixIndexes[@intCast(i - ln)] = -ln;
                }
                ln = inverseSuffix[@intCast(suffixIndexesI)] + 1 - i;
                split(suffixIndexes, inverseSuffix, i, ln, h);
                i += ln;
                ln = 0;
            }

            // Update progress (based on oldData size since we're sorting oldData's suffixes)
            // Note: We scale to bufzise instead of bufzisePlusOne for percentage, but use actual i for bytes
            progressBytes.* = @intCast(i);
            progressPercent.* = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bufzise))) * 100.0;
        }
        if (ln != 0) {
            suffixIndexes[@intCast(i - ln)] = -ln;
        }
        h += h;
    }

    for (0..buf.len) |i| {
        suffixIndexes[@intCast(inverseSuffix[@intCast(i)])] = @intCast(i);
    }

    suffixIndexes[0] = 0;
}

var swapTemp: i64 = 0;

fn split(suffixIndexes: []i64, inverseSuffix: []i64, start: i64, ln: i64, h: i64) void {
    var i: i64 = 0;
    var j: i64 = 0;
    var k: i64 = 0;
    var x: i64 = 0;
    var jj: i64 = 0;
    var kk: i64 = 0;

    if (ln < 16) {
        k = start;
        const end = start + ln;
        while (k < end) {
            j = 1;
            x = inverseSuffix[@intCast(suffixIndexes[@intCast(k)] + h)];
            i = 1;

            while (k + i < end) {
                const KplusI: usize = @intCast(k + i);
                const suffixIndexesKplusI: usize = @intCast(suffixIndexes[KplusI]);
                const suffixIndexesKplusIh: usize = @intCast(suffixIndexesKplusI + @as(usize, @intCast(h)));
                const inverseSuffixsuffixIndexeskPlusIh: i64 = inverseSuffix[suffixIndexesKplusIh];

                if (inverseSuffixsuffixIndexeskPlusIh < x) {
                    x = inverseSuffixsuffixIndexeskPlusIh;
                    j = 0;
                }
                if (inverseSuffixsuffixIndexeskPlusIh == x) {
                    const kPlusJ: usize = @intCast(k + j);
                    swapTemp = suffixIndexes[kPlusJ];
                    suffixIndexes[kPlusJ] = @intCast(suffixIndexesKplusI);
                    suffixIndexes[KplusI] = swapTemp;
                    j += 1;
                }

                i += 1;
            }

            const kPlusJMinus1: i64 = k + j - 1;
            const k_usize: usize = @intCast(k);
            for (0..@intCast(j)) |ii| {
                inverseSuffix[@intCast(suffixIndexes[k_usize + ii])] = kPlusJMinus1;
            }

            if (j == 1) suffixIndexes[@intCast(k)] = -1;
            k += j;
        }
        return;
    }

    x = inverseSuffix[@intCast(suffixIndexes[@intCast(start + (@divTrunc(ln, 2)))] + h)];
    kk = 0;
    jj = kk;

    i = start;
    const startPlusLn: i64 = start + ln;
    while (i < startPlusLn) {
        const inverseSuffixsuffixIndexesIPlusH: i64 = inverseSuffix[@intCast(suffixIndexes[@intCast(i)] + h)];
        if (inverseSuffixsuffixIndexesIPlusH < x) {
            jj += 1;
        } else if (inverseSuffixsuffixIndexesIPlusH == x) {
            kk += 1;
        }

        i += 1;
    }

    jj += start;
    kk += jj;

    i = start;
    k = 0;
    j = k;

    while (i < jj) {
        const inverseSuffixsuffixIndexesIPlusH: i64 = inverseSuffix[@intCast(suffixIndexes[@intCast(i)] + h)];
        if (inverseSuffixsuffixIndexesIPlusH < x) {
            i += 1;
        } else if (inverseSuffixsuffixIndexesIPlusH == x) {
            swapTemp = suffixIndexes[@intCast(i)];
            suffixIndexes[@intCast(i)] = suffixIndexes[@intCast(jj + j)];
            suffixIndexes[@intCast(jj + j)] = swapTemp;
            j += 1;
        } else {
            swapTemp = suffixIndexes[@intCast(i)];
            suffixIndexes[@intCast(i)] = suffixIndexes[@intCast(kk + k)];
            suffixIndexes[@intCast(kk + k)] = swapTemp;
            k += 1;
        }
    }

    const kkMinusJJ: i64 = kk - jj;
    while (j < kkMinusJJ) {
        // while (jj + j < kk) {
        const jjPlusJ: usize = @intCast(jj + j);
        if (inverseSuffix[@intCast(suffixIndexes[jjPlusJ] + h)] == x) {
            j += 1;
        } else {
            swapTemp = suffixIndexes[jjPlusJ];
            suffixIndexes[jjPlusJ] = suffixIndexes[@intCast(kk + k)];
            suffixIndexes[@intCast(kk + k)] = swapTemp;
            k += 1;
        }
    }

    if (jj > start) {
        split(suffixIndexes, inverseSuffix, start, jj - start, h);
    }

    i = 0;
    while (i < kk - jj) {
        inverseSuffix[@intCast(suffixIndexes[@intCast(jj + i)])] = kk - 1;
        i += 1;
    }

    if (jj == kk - 1) {
        suffixIndexes[@intCast(jj)] = -1;
    }

    if (start + ln > kk) {
        split(suffixIndexes, inverseSuffix, kk, start + ln - kk, h);
    }
}

fn logProgressPhase(io: std.Io, running: *bool, percent: *f32, bytes: *usize, total: usize, phase: *[]const u8) void {
    while (running.*) {
        std.Io.sleep(io, .fromSeconds(10), .awake) catch {}; // Wait 10s between messages
        if (!running.*) break;
        const bytesMB = @as(f64, @floatFromInt(bytes.*)) / (1024.0 * 1024.0);
        const totalMB = @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0);
        std.debug.print("{s}... {d:.1}/{d:.1} MB ({d:.1}%)\n", .{ phase.*, bytesMB, totalMB, percent.* });
    }
}
