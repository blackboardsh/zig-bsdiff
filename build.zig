const std = @import("std");

pub fn build(b: *std.Build) void {
    // zig build -Doptimize=Debug to enable debug mode
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Link pre-compiled libsais (compiled with clang during setup)
    // Note: We don't use Zig's C backend to compile libsais because it has
    // incompatibilities. Instead, setup.js compiles it with clang.

    const libzstd = b.addStaticLibrary(.{
        .name = "zstd",
        .target = target,
        .optimize = optimize,
    });

    // Disable assembly optimizations to avoid linking issues with missing HUF assembly functions
    libzstd.defineCMacro("ZSTD_DISABLE_ASM", "1");
    
    libzstd.addCSourceFiles(.{
        .files = &[_][]const u8{
            "zstd/lib/common/debug.c",
            "zstd/lib/common/entropy_common.c",
            "zstd/lib/common/error_private.c",
            "zstd/lib/common/fse_decompress.c",
            "zstd/lib/common/pool.c",
            "zstd/lib/common/threading.c",
            "zstd/lib/common/xxhash.c",
            "zstd/lib/common/zstd_common.c",

            "zstd/lib/compress/fse_compress.c",
            "zstd/lib/compress/hist.c",
            "zstd/lib/compress/huf_compress.c",
            "zstd/lib/compress/zstd_compress_literals.c",
            "zstd/lib/compress/zstd_compress_sequences.c",
            "zstd/lib/compress/zstd_compress_superblock.c",
            "zstd/lib/compress/zstd_compress.c",
            "zstd/lib/compress/zstd_double_fast.c",
            "zstd/lib/compress/zstd_fast.c",
            "zstd/lib/compress/zstd_lazy.c",
            "zstd/lib/compress/zstd_ldm.c",
            "zstd/lib/compress/zstd_opt.c",
            "zstd/lib/compress/zstd_preSplit.c",
            "zstd/lib/compress/zstdmt_compress.c",

            // zig tree shakes so bspatch and bsdiff only ends up with the zstd stuff they actually use
            "zstd/lib/decompress/zstd_decompress.c",
            "zstd/lib/decompress/zstd_ddict.c",
            "zstd/lib/decompress/zstd_decompress_block.c",
            "zstd/lib/decompress/huf_decompress.c",
        },
    });

    libzstd.linkLibC();

    const bsdiff = b.addExecutable(.{
        .name = "bsdiff",
        .root_source_file = b.path("bsdiff.zig"),
        .target = target,
        .optimize = optimize,
    });

    bsdiff.linkLibrary(libzstd);
    bsdiff.addObjectFile(b.path("vendors/libsais/libsais.a"));

    // This is for the cImport to import the .h files
    bsdiff.addIncludePath(b.path("zstd/lib"));
    bsdiff.addIncludePath(b.path("vendors/libsais"));
    bsdiff.addIncludePath(b.path("src/libsais-wrapper"));

    b.installArtifact(bsdiff);

    const bspatch = b.addExecutable(.{
        .name = "bspatch",
        .root_source_file = b.path("bspatch.zig"),
        .target = target,
        .optimize = optimize,
    });

    bspatch.linkLibrary(libzstd);
    bspatch.addIncludePath(b.path("zstd/lib"));

    b.installArtifact(bspatch);

    const tests = b.addTest(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    tests.addIncludePath(b.path("zstd/lib"));
    tests.addIncludePath(b.path("vendors/libsais"));
    tests.addIncludePath(b.path("src/libsais-wrapper"));
    tests.linkLibrary(libzstd);
    tests.addObjectFile(b.path("vendors/libsais/libsais.a"));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run bsdiff/bspatch roundtrip tests");
    test_step.dependOn(&run_tests.step);
}
