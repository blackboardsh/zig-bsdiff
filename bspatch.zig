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

// Note: This is a modified version of bspatch.
// The goal is to leverage zig's vector and slice operations to speed up the patching process.
// Aside from a compatible port, exploration into an iteration on bsdiff patch file format, and patch
// generation to improve performance and compression ratios. Eg: using zstd, compressing all
// the blocks together, modern suffix sorting, and so on.

const std = @import("std");
const builtin = @import("builtin");

const zstd = @cImport({
    @cInclude("zstd.h");
});

const vectorSize = std.simd.suggestVectorLength(u8) orelse 4;

pub fn main() !void {
    var allocator = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(allocator);

    defer args.deinit();

    // skip the first arg which is the program name
    _ = args.skip();

    const oldFilePath = args.next() orelse "";
    const newFilePath = args.next() orelse "";
    const patchFilePath = args.next() orelse "";

    if (oldFilePath.len == 0 or newFilePath.len == 0 or patchFilePath.len == 0) {
        std.debug.print("Usage: bsdiff <oldFilePath> <newFilePath> <patchFilePath>\n", .{});
        std.process.exit(1);
    }

    const oldFile = try std.fs.cwd().openFile(oldFilePath, .{ .mode = .read_only });
    defer oldFile.close();

    const oldFileSize = try oldFile.getEndPos();
    const oldFileBuff = try allocator.alloc(u8, oldFileSize);
    defer allocator.free(oldFileBuff);
    _ = try oldFile.readAll(oldFileBuff);

    const patchFile = try std.fs.cwd().openFile(patchFilePath, .{ .mode = .read_only });
    defer patchFile.close();

    const patchFileSize = try patchFile.getEndPos();
    const patchFileBuff = try allocator.alloc(u8, patchFileSize);
    defer allocator.free(patchFileBuff);
    _ = try patchFile.readAll(patchFileBuff);

    // Log SIMD capabilities    
    std.debug.print("SIMD Status:\n", .{});
    std.debug.print("  Vector size: {d} bytes\n", .{vectorSize});
    std.debug.print("  Platform: {s}\n", .{@tagName(builtin.target.cpu.arch)});
    std.debug.print("  SIMD support: {s}\n", .{if (vectorSize > 1) "enabled" else "disabled (fallback to scalar)"});
    std.debug.print("\n", .{});

    const newfile = try applyPatch(&allocator, oldFileBuff, patchFileBuff);

    const newFile = try std.fs.cwd().createFile(newFilePath, .{});
    defer newFile.close();

    _ = try newFile.writeAll(newfile);
}

/// Decompression result for parallel decompression
const DecompressResult = struct {
    data: []u8,
    len: usize,
    err: bool,
};

/// Thread function for parallel decompression
fn decompressThread(result: *DecompressResult, buffer: []u8, compressed: []const u8) void {
    const decompressedLen = zstd.ZSTD_decompress(buffer.ptr, buffer.len, compressed.ptr, compressed.len);
    if (zstd.ZSTD_isError(decompressedLen) != 0) {
        result.err = true;
        result.len = 0;
    } else {
        result.err = false;
        result.len = decompressedLen;
    }
    result.data = buffer;
}

pub fn applyPatch(allocator: *std.mem.Allocator, oldfile: []const u8, patch: []const u8) ![]u8 {
    const header = patch[0..32];

    // Check for appropriate magic
    if (std.mem.eql(u8, header[0..8], "TRDIFF10") == false) {
        std.debug.print("corrupt patch {s}\n", .{header[0..8].*});
        return error.CorruptPatch;
    }

    // Read lengths from header
    const controlLen = offtin(header[8..16]);
    const diffLen = offtin(header[16..24]);
    const newSize = offtin(header[24..32]);

    const controlStart: usize = 32;
    const diffStart: usize = controlStart + @as(usize, @intCast(controlLen));
    const extraStart: usize = diffStart + @as(usize, @intCast(diffLen));

    if (controlLen < 0 or diffLen < 0 or newSize < 0) {
        return error.CorruptPatch;
    }

    const newSizeUsize: usize = @intCast(newSize);

    // Pre-allocate the output buffer (key optimization: no ArrayList resizing)
    var newfile = try allocator.alloc(u8, newSizeUsize);

    // Allocate decompression buffers
    var controlBlockBuffer = try allocator.alloc(u8, newSizeUsize);
    var diffBlockBuffer = try allocator.alloc(u8, newSizeUsize);
    var extraBlockBuffer = try allocator.alloc(u8, newSizeUsize);

    // Parallel decompression of all three blocks
    var controlResult = DecompressResult{ .data = undefined, .len = 0, .err = false };
    var diffResult = DecompressResult{ .data = undefined, .len = 0, .err = false };
    var extraResult = DecompressResult{ .data = undefined, .len = 0, .err = false };

    const controlThread = try std.Thread.spawn(.{}, decompressThread, .{
        &controlResult,
        controlBlockBuffer,
        patch[controlStart..diffStart],
    });
    const diffThread = try std.Thread.spawn(.{}, decompressThread, .{
        &diffResult,
        diffBlockBuffer,
        patch[diffStart..extraStart],
    });
    const extraThread = try std.Thread.spawn(.{}, decompressThread, .{
        &extraResult,
        extraBlockBuffer,
        patch[extraStart..],
    });

    // Wait for all decompressions to complete
    controlThread.join();
    diffThread.join();
    extraThread.join();

    if (controlResult.err or diffResult.err or extraResult.err) {
        std.debug.print("Decompression error\n", .{});
        return error.DecompressionFailed;
    }

    const controlBlock = controlBlockBuffer[0..controlResult.len];
    const diffBlock = diffBlockBuffer[0..diffResult.len];
    const extraBlock = extraBlockBuffer[0..extraResult.len];

    var controlpos: usize = 0;
    var diffpos: usize = 0;
    var extrapos: usize = 0;
    var oldpos: usize = 0;
    var newpos: usize = 0;

    // Main patching loop - optimized with direct memory writes
    while (controlpos < controlResult.len) {
        // Read control data
        const readDiffBy: usize = @intCast(offtin(controlBlock[controlpos .. controlpos + 8]));
        controlpos += 8;
        const readExtraBy: usize = @intCast(offtin(controlBlock[controlpos .. controlpos + 8]));
        controlpos += 8;
        const seekBy: i64 = offtin(controlBlock[controlpos .. controlpos + 8]);
        controlpos += 8;

        // Apply diff block: newfile[newpos..] = oldfile[oldpos..] + diffBlock[diffpos..]
        const diffSlice = diffBlock[diffpos .. diffpos + readDiffBy];
        const oldSlice = oldfile[oldpos .. oldpos + readDiffBy];
        const newSlice = newfile[newpos .. newpos + readDiffBy];

        // SIMD-accelerated diff application with direct memory writes
        var i: usize = 0;
        while (i + vectorSize <= readDiffBy) {
            const oldVec: @Vector(vectorSize, u8) = oldSlice[i..][0..vectorSize].*;
            const diffVec: @Vector(vectorSize, u8) = diffSlice[i..][0..vectorSize].*;
            const resultVec = @addWithOverflow(oldVec, diffVec)[0];
            newSlice[i..][0..vectorSize].* = resultVec;
            i += vectorSize;
        }

        // Handle remaining bytes
        while (i < readDiffBy) {
            newSlice[i] = @addWithOverflow(oldSlice[i], diffSlice[i])[0];
            i += 1;
        }

        diffpos += readDiffBy;
        newpos += readDiffBy;

        // Copy extra block directly (no arithmetic needed)
        if (readExtraBy > 0) {
            @memcpy(newfile[newpos .. newpos + readExtraBy], extraBlock[extrapos .. extrapos + readExtraBy]);
            extrapos += readExtraBy;
            newpos += readExtraBy;
        }

        oldpos = @intCast(@as(i64, @intCast(oldpos + readDiffBy)) + seekBy);
    }

    const newSizeMB = @as(f64, @floatFromInt(newfile.len)) / (1024.0 * 1024.0);
    std.debug.print("Completed - New file: {d:.2} MB\n", .{newSizeMB});

    return newfile;
}

// offtin reads an int64 (little endian)
fn offtin(buf: []const u8) i64 {
    var y: i64 = 0;

    y = @as(i64, (@intCast(buf[7] & 0x7f)));
    y = y << 8 | @as(i64, (@intCast(buf[6])));
    y = y << 8 | @as(i64, (@intCast(buf[5])));
    y = y << 8 | @as(i64, (@intCast(buf[4])));
    y = y << 8 | @as(i64, (@intCast(buf[3])));
    y = y << 8 | @as(i64, (@intCast(buf[2])));
    y = y << 8 | @as(i64, (@intCast(buf[1])));
    y = y << 8 | @as(i64, (@intCast(buf[0])));

    if ((buf[7] & 0x80) != 0) {
        y = -y;
    }
    return y;
}

fn logProgressBytes(running: *bool, percent: *f32, bytes: *usize, total: usize, operation: []const u8) void {
    while (running.*) {
        std.time.sleep(std.time.ns_per_s * 10); // Wait 10s between messages
        if (!running.*) break;
        const bytesMB = @as(f64, @floatFromInt(bytes.*)) / (1024.0 * 1024.0);
        const totalMB = @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0);
        std.debug.print("{s}... {d:.1}/{d:.1} MB ({d:.1}%)\n", .{ operation, bytesMB, totalMB, percent.* });
    }
}
