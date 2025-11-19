# zig-bsdiff

Fast binary diff/patch implementation in Zig with zstd compression.

This is a high-performance port of bsdiff/bspatch that uses zstd compression instead of bzip2, providing better compression ratios and faster decompression speeds.

## Features

- **Fast**: Optimized with SIMD operations and efficient algorithms
- **Small patches**: Uses zstd compression for minimal patch sizes
- **Cross-platform**: Works on Linux, macOS, and Windows
- **Multi-threaded**: Parallel compression for faster patch generation
- **TRDIFF10 format**: Compatible format with zstd compression

We built this to power the built-in update diffing in Electrobun apps where it's used to diff the tar file of two versions of your app.

Hence TRDIFF (TR for Tar)

## Installation

```bash
npm install zig-bsdiff
```

Platform-specific binaries are automatically downloaded from GitHub releases during installation. No manual setup required!

## Usage

### Command Line

The package includes two binaries: `bsdiff` and `bspatch`.

```bash
# Create a patch
bsdiff <oldfile> <newfile> <patchfile> [--use-zstd]

# Apply a patch
bspatch <oldfile> <newfile> <patchfile>
```

### Programmatic API

```javascript
import { getBinaryPath, getBinaries } from 'zig-bsdiff';

// Get path to a specific binary
const bsdiffPath = getBinaryPath('bsdiff');
const bspatchPath = getBinaryPath('bspatch');

// Or get both at once
const { bsdiff, bspatch } = getBinaries();

// Use with child_process
import { spawn } from 'child_process';
spawn(bsdiffPath, ['old.bin', 'new.bin', 'patch.bin', '--use-zstd']);
```

## How it works

When you install this package, the postinstall script automatically:
1. Detects your platform and architecture
2. Downloads the appropriate pre-built binaries from GitHub releases
3. Extracts them to `node_modules/zig-bsdiff/bin/`

This means:
- ✅ No compilation required
- ✅ Fast installation (only downloads your platform's binaries)
- ✅ Works offline after first install (binaries are cached)
- ✅ Small npm package size (~10KB)

## Building from source

For development or if you want to build from source:

```bash
# Clone the repository
git clone https://github.com/blackboardsh/zig-bsdiff.git
cd zig-bsdiff

# Single command
bun dev

This will 
- run setup (vendor zig and init zstd submodule)
- build bsdiff/bspatch
- run the zig tests (only outputs if one fails)
- run a full end-to-end test creating and applying a diff of two random 2MB files with output
```

### Manual Zig installation

If you have Zig 0.13.0+ installed:

```bash
zig build -Doptimize=ReleaseFast
zig build test
```

## Algorithm

This implementation uses:
- Suffix array sorting with qsufsort algorithm
- Binary search for match finding
- SIMD vector operations for performance
- Multi-threaded zstd compression
- Three separate compressed blocks: control, diff, and extra data

## License

MIT

## Credits

Based on the original bsdiff by Colin Percival.
Ported to Zig with zstd compression by Yoav Givati at Blackboard Technologies Inc.
