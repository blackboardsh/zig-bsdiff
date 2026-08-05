const std = @import("std");

pub fn build(b: *std.Build) void {
    // zig build -Doptimize=Debug to enable debug mode
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Link pre-compiled libsais (compiled with `zig cc` during setup)
    // Note: We don't use Zig's build system to compile libsais because it has
    // incompatibilities. Instead, setup.js compiles it with `zig cc`.

    const zstd_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Disable assembly optimizations to avoid linking issues with missing HUF assembly functions
    zstd_module.addCMacro("ZSTD_DISABLE_ASM", "1");

    zstd_module.addCSourceFiles(.{
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

    const libzstd = b.addLibrary(.{
        .name = "zstd",
        .linkage = .static,
        .root_module = zstd_module,
    });

    const bsdiff_module = b.createModule(.{
        .root_source_file = b.path("bsdiff.zig"),
        .target = target,
        .optimize = optimize,
    });
    bsdiff_module.linkLibrary(libzstd);
    bsdiff_module.addObjectFile(b.path("vendors/libsais/libsais.a"));

    // This is for the cImport to import the .h files
    bsdiff_module.addIncludePath(b.path("zstd/lib"));
    bsdiff_module.addIncludePath(b.path("vendors/libsais"));
    bsdiff_module.addIncludePath(b.path("src/libsais-wrapper"));

    const bsdiff = b.addExecutable(.{
        .name = "bsdiff",
        .root_module = bsdiff_module,
    });

    b.installArtifact(bsdiff);

    const bspatch_module = b.createModule(.{
        .root_source_file = b.path("bspatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    bspatch_module.linkLibrary(libzstd);
    bspatch_module.addIncludePath(b.path("zstd/lib"));

    const bspatch = b.addExecutable(.{
        .name = "bspatch",
        .root_module = bspatch_module,
    });

    b.installArtifact(bspatch);

    // Separate step to build only bspatch (used on Windows CI to rebuild with MSVC ABI
    // without triggering bsdiff's libsais link which requires MinGW)
    const bspatch_only = b.step("bspatch-only", "Build only bspatch");
    bspatch_only.dependOn(&b.addInstallArtifact(bspatch, .{}).step);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_module.addIncludePath(b.path("zstd/lib"));
    tests_module.addIncludePath(b.path("vendors/libsais"));
    tests_module.addIncludePath(b.path("src/libsais-wrapper"));
    tests_module.linkLibrary(libzstd);
    tests_module.addObjectFile(b.path("vendors/libsais/libsais.a"));

    const tests = b.addTest(.{
        .root_module = tests_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run bsdiff/bspatch roundtrip tests");
    test_step.dependOn(&run_tests.step);
}
