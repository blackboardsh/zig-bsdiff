#!/usr/bin/env node
/**
 * Package binaries for npm distribution
 * Copies the built binaries from zig-out/bin to dist/
 */

import { mkdir, copyFile, access } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const rootDir = join(__dirname, '..');

const platform = process.platform;
const binExt = platform === 'win32' ? '.exe' : '';

async function packageBinaries() {
  const distDir = join(rootDir, 'dist');
  const zigOutBin = join(rootDir, 'zig-out', 'bin');

  // Create dist directory
  await mkdir(distDir, { recursive: true });

  // Copy binaries
  const binaries = ['bsdiff', 'bspatch'];

  for (const bin of binaries) {
    const src = join(zigOutBin, bin + binExt);
    const dest = join(distDir, bin + binExt);

    try {
      await access(src);
      await copyFile(src, dest);
      console.log(`Copied ${bin}${binExt} to dist/`);
    } catch (err) {
      console.error(`Warning: Could not copy ${bin}${binExt}:`, err.message);
      throw new Error(`Failed to package ${bin}${binExt}. Make sure to run 'npm run build:release' first.`);
    }
  }

  console.log('Binaries packaged successfully!');
}

packageBinaries().catch(err => {
  console.error('Error packaging binaries:', err);
  process.exit(1);
});
