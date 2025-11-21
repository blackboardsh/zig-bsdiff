# zig-bsdiff

Fast binary diff/patch implementation in Zig with zstd compression.

This is a high-performance port of bsdiff/bspatch that uses zstd compression instead of bzip2, providing better compression ratios and faster decompression speeds.

zig-bsdiff powers [Electrobun](https://github.com/blackboardsh/electrobun/)'s batteries-included update api delivering update patches as small as 4KB for your apps.

## Features

- **Fast**: Optimized with SIMD operations and efficient algorithms
- **Small patches**: Uses zstd compression for minimal patch sizes
- **Cross-platform**: Works on Linux, macOS, and Windows
- **Multi-threaded**: Parallel compression for faster patch generation
- **TRDIFF10 format**: Compatible format with zstd compression

We built this to power the built-in update diffing in Electrobun apps where it's used to diff the tar file of two versions of your app.

Hence TRDIFF (TR for Tar)

## Installation

Download pre-built binaries from the [GitHub Releases](https://github.com/blackboardsh/zig-bsdiff/releases) page.

Available for:
- macOS (arm64, x64)
- Linux (arm64, x64)
- Windows (x64)

Extract the tarball for your platform:

```bash
tar -xzf zig-bsdiff-darwin-arm64.tar.gz
```

This will give you two binaries: `bsdiff` and `bspatch`.

## Usage

### Create a patch

```bash
./bsdiff oldfile newfile patchfile --use-zstd
```

The `--use-zstd` flag creates patches with zstd compression (TRDIFF10 format). Without it, creates traditional bsdiff patches with bzip2 compression.

### Apply a patch

```bash
./bspatch oldfile newfile patchfile
```

Automatically detects the patch format (zstd or bzip2).

## Building from Source

### Prerequisites

- Bun (or Node.js)
- Git

### Build Steps

```bash
# Clone the repository
git clone https://github.com/blackboardsh/zig-bsdiff.git
cd zig-bsdiff

# Setup (vendors Zig and initializes submodules)
bun run setup

# Build
bun run build

# Or build with optimizations
bun run build:release

# Test
bun run zig-test

# End to End test
bun run test

# Dev (runs everything [setup, build, tests, end to end test])
bun dev
```

The binaries will be in `zig-out/bin/`.

## How it Works

Based on Colin Percival's bsdiff algorithm with modifications:

1. **Suffix array construction** - Builds a sorted index of all file positions
2. **Matching** - Finds the longest matching sequences between old and new files
3. **Diff generation** - Creates three streams:
   - Control: Copy/insert instructions
   - Diff: Byte-wise differences for matched sections
   - Extra: New data to insert
4. **Compression** - Compresses all three streams with zstd

The result is a small patch file that can efficiently update the old file to the new version.

## Performance

Compared to traditional bsdiff:

- **Compression**: zstd provides similar or better compression ratios
- **Speed**: ~2-3x faster decompression (zstd vs bzip2)
- **Memory**: Efficient memory usage with streaming compression

Benchmark diffing two 50MB app tarballs:
- Patch size: ~8MB (zstd) vs ~9MB (bzip2)
- Generation time: ~3s
- Application time: ~1s (zstd) vs ~2.5s (bzip2)

## License

MIT - Based on Colin Percival's original bsdiff (BSD licensed)

## Credits

- Original bsdiff algorithm: Colin Percival (2003-2005)
- Zig port with zstd: Yoav Givati / Blackboard Technologies (2024)
- zstd compression: Facebook/Meta
