#!/usr/bin/env node
/**
 * Setup script for zig-bsdiff development
 * - Initializes git submodules (zstd)
 * - Vendors Zig compiler if not already present
 * Based on electrobun and colab's vendoring approach
 */

import { execSync } from 'child_process';
import { existsSync } from 'fs';
import { join } from 'path';

const ZIG_VERSION = '0.13.0';

async function initSubmodules() {
  console.log('Initializing git submodules...');
  try {
    execSync('git submodule update --init --recursive', { stdio: 'inherit' });
    console.log('✓ Submodules initialized');
  } catch (error) {
    console.error('Failed to initialize submodules:', error.message);
    process.exit(1);
  }
}

async function vendorZig() {
  const platform = process.platform;
  const zigBinary = platform === 'win32' ? 'zig.exe' : 'zig';
  const zigBinPath = join(process.cwd(), 'vendors', 'zig', zigBinary);

  // Check if Zig is already vendored
  if (existsSync(zigBinPath)) {
    console.log('✓ Zig already vendored');
    return;
  }

  console.log('Vendoring Zig compiler...');

  const arch = process.arch === 'arm64' ? 'aarch64' : 'x86_64';

  try {
    if (platform === 'darwin') {
      const url = `https://ziglang.org/download/${ZIG_VERSION}/zig-macos-${arch}-${ZIG_VERSION}.tar.xz`;
      execSync(
        `mkdir -p vendors/zig && curl -L ${url} | tar -xJ --strip-components=1 -C vendors/zig zig-macos-${arch}-${ZIG_VERSION}/zig zig-macos-${arch}-${ZIG_VERSION}/lib zig-macos-${arch}-${ZIG_VERSION}/doc`,
        { stdio: 'inherit' }
      );
      console.log('✓ Zig vendored for macOS');
    } else if (platform === 'linux') {
      const url = `https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${arch}-${ZIG_VERSION}.tar.xz`;
      execSync(
        `mkdir -p vendors/zig && curl -L ${url} | tar -xJ --strip-components=1 -C vendors/zig zig-linux-${arch}-${ZIG_VERSION}/zig zig-linux-${arch}-${ZIG_VERSION}/lib zig-linux-${arch}-${ZIG_VERSION}/doc`,
        { stdio: 'inherit' }
      );
      console.log('✓ Zig vendored for Linux');
    } else if (platform === 'win32') {
      const zigFolder = `zig-windows-${arch}-${ZIG_VERSION}`;
      execSync(
        `mkdir -p vendors/zig && curl -L https://ziglang.org/download/${ZIG_VERSION}/${zigFolder}.zip -o vendors/zig.zip && powershell -ExecutionPolicy Bypass -Command "Expand-Archive -Path vendors/zig.zip -DestinationPath vendors/zig-temp" && move vendors/zig-temp/${zigFolder}/zig.exe vendors/zig && move vendors/zig-temp/${zigFolder}/lib vendors/zig/`,
        { stdio: 'inherit' }
      );
      console.log('✓ Zig vendored for Windows');
    } else {
      console.error(`Unsupported platform: ${platform}`);
      process.exit(1);
    }
  } catch (error) {
    console.error('Failed to vendor Zig:', error.message);
    process.exit(1);
  }
}

async function setup() {
  await initSubmodules();
  await vendorZig();
  console.log('\n✅ Setup complete! You can now run: npm run build');
}

setup().catch((err) => {
  console.error('Error:', err);
  process.exit(1);
});
