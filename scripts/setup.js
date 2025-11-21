#!/usr/bin/env node
/**
 * Setup script for zig-bsdiff development
 * - Initializes git submodules (zstd)
 * - Vendors Zig compiler if not already present
 * - Vendors libsais for fast suffix array construction
 * Based on electrobun and colab's vendoring approach
 */

import { execSync } from 'child_process';
import { existsSync, mkdirSync, rmSync, unlinkSync, renameSync } from 'fs';
import { join } from 'path';

const ZIG_VERSION = '0.13.0';
const LIBSAIS_VERSION = '2.8.6';

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

async function vendorLibsais() {
  const libsaisDir = join(process.cwd(), 'vendors', 'libsais');
  const libsaisLib = join(libsaisDir, 'libsais.a');

  // Check if libsais is already compiled
  if (existsSync(libsaisLib)) {
    console.log('✓ libsais already vendored and compiled');
    return;
  }

  const platform = process.platform;

  console.log('Vendoring libsais...');

  try {
    // Create vendors directory if it doesn't exist
    mkdirSync(join(process.cwd(), 'vendors'), { recursive: true });

    // Download and extract libsais if not already downloaded
    if (!existsSync(join(libsaisDir, 'libsais.h'))) {
      mkdirSync(libsaisDir, { recursive: true });
      const url = `https://github.com/IlyaGrebnov/libsais/archive/refs/tags/v${LIBSAIS_VERSION}.tar.gz`;
      execSync(
        `curl -L ${url} | tar -xz --strip-components=2 -C ${libsaisDir} libsais-${LIBSAIS_VERSION}/src libsais-${LIBSAIS_VERSION}/include`,
        { stdio: 'inherit' }
      );
      console.log('✓ libsais source downloaded');
    }

    // Compile libsais (Zig's C backend has issues with libsais)
    console.log('Compiling libsais...');

    // Use clang/gcc on all platforms for consistency
    // This produces .a libraries that work with Zig's linker
    execSync(
      `cd ${libsaisDir} && ${platform === 'win32' ? 'gcc' : 'clang'} -c -O3 -std=c99 libsais.c libsais64.c zig_wrapper.c && ar rcs libsais.a libsais.o libsais64.o zig_wrapper.o`,
      { stdio: 'inherit' }
    );

    // Clean up object files
    const objFiles = ['libsais.o', 'libsais64.o', 'zig_wrapper.o'];
    for (const obj of objFiles) {
      const objPath = join(libsaisDir, obj);
      if (existsSync(objPath)) {
        unlinkSync(objPath);
      }
    }

    console.log('✓ libsais compiled');
  } catch (error) {
    console.error('Failed to vendor/compile libsais:', error.message);
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
    const vendorsDir = join(process.cwd(), 'vendors', 'zig');
    mkdirSync(vendorsDir, { recursive: true });

    if (platform === 'darwin') {
      const url = `https://ziglang.org/download/${ZIG_VERSION}/zig-macos-${arch}-${ZIG_VERSION}.tar.xz`;
      execSync(
        `curl -L ${url} | tar -xJ --strip-components=1 -C vendors/zig zig-macos-${arch}-${ZIG_VERSION}/zig zig-macos-${arch}-${ZIG_VERSION}/lib zig-macos-${arch}-${ZIG_VERSION}/doc`,
        { stdio: 'inherit' }
      );
      console.log('✓ Zig vendored for macOS');
    } else if (platform === 'linux') {
      const url = `https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${arch}-${ZIG_VERSION}.tar.xz`;
      execSync(
        `curl -L ${url} | tar -xJ --strip-components=1 -C vendors/zig zig-linux-${arch}-${ZIG_VERSION}/zig zig-linux-${arch}-${ZIG_VERSION}/lib zig-linux-${arch}-${ZIG_VERSION}/doc`,
        { stdio: 'inherit' }
      );
      console.log('✓ Zig vendored for Linux');
    } else if (platform === 'win32') {
      const zigFolder = `zig-windows-${arch}-${ZIG_VERSION}`;
      const zipPath = join(process.cwd(), 'vendors', 'zig.zip');
      const tempDir = join(process.cwd(), 'vendors', 'zig-temp');

      // Download zip file
      execSync(
        `curl -L https://ziglang.org/download/${ZIG_VERSION}/${zigFolder}.zip -o "${zipPath}"`,
        { stdio: 'inherit' }
      );

      // Extract using PowerShell
      execSync(
        `powershell -ExecutionPolicy Bypass -Command "Expand-Archive -Path '${zipPath}' -DestinationPath '${tempDir}' -Force"`,
        { stdio: 'inherit' }
      );

      // Move files using PowerShell
      execSync(
        `powershell -ExecutionPolicy Bypass -Command "Move-Item -Path '${tempDir}\\${zigFolder}\\zig.exe' -Destination '${vendorsDir}' -Force; Move-Item -Path '${tempDir}\\${zigFolder}\\lib' -Destination '${vendorsDir}' -Force"`,
        { stdio: 'inherit' }
      );

      // Clean up
      if (existsSync(zipPath)) {
        unlinkSync(zipPath);
      }
      if (existsSync(tempDir)) {
        rmSync(tempDir, { recursive: true, force: true });
      }

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
  await vendorLibsais();
  console.log('\n✅ Setup complete! You can now run: npm run build');
}

setup().catch((err) => {
  console.error('Error:', err);
  process.exit(1);
});
