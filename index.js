#!/usr/bin/env node
/**
 * zig-bsdiff - Fast binary diff/patch with zstd compression
 *
 * This package provides bsdiff and bspatch binaries compiled from Zig.
 * Binaries are automatically downloaded from GitHub releases during installation.
 */

import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { existsSync } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const PLATFORM_MAP = {
  darwin: 'darwin',
  linux: 'linux',
  win32: 'win32',
};

const ARCH_MAP = {
  x64: 'x64',
  arm64: 'arm64',
};

/**
 * Get the path to a zig-bsdiff binary for the current platform
 * @param {string} name - Binary name: 'bsdiff' or 'bspatch'
 * @returns {string} Absolute path to the binary
 * @throws {Error} If platform is unsupported or binary doesn't exist
 */
export function getBinaryPath(name) {
  if (name !== 'bsdiff' && name !== 'bspatch') {
    throw new Error(`Invalid binary name: ${name}. Must be 'bsdiff' or 'bspatch'`);
  }

  const platform = PLATFORM_MAP[process.platform];
  const arch = ARCH_MAP[process.arch];

  if (!platform || !arch) {
    throw new Error(
      `Unsupported platform/architecture: ${process.platform}-${process.arch}\n` +
      `Supported: darwin-arm64, darwin-x64, linux-x64, linux-arm64, win32-x64`
    );
  }

  const binExt = platform === 'win32' ? '.exe' : '';
  const binaryPath = join(__dirname, '.cache', `${name}${binExt}`);

  if (!existsSync(binaryPath)) {
    throw new Error(
      `Binary not found: ${binaryPath}\n` +
      `Binaries will be automatically downloaded on first use.\n` +
      `Run 'bsdiff' or 'bspatch' to trigger the download, or manually download from:\n` +
      `https://github.com/blackboardsh/zig-bsdiff/releases`
    );
  }

  return binaryPath;
}

/**
 * Get paths to both bsdiff and bspatch binaries
 * @returns {{ bsdiff: string, bspatch: string }} Object with paths to both binaries
 */
export function getBinaries() {
  return {
    bsdiff: getBinaryPath('bsdiff'),
    bspatch: getBinaryPath('bspatch'),
  };
}

// Export version
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const packageJson = require('./package.json');
export const version = packageJson.version;

// Default export
export default {
  getBinaryPath,
  getBinaries,
  version,
};
