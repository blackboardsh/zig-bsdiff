#!/usr/bin/env node
/**
 * Post-install script that downloads the appropriate zig-bsdiff binaries
 * for the current platform from GitHub releases.
 */

import { createWriteStream, existsSync, mkdirSync, chmodSync } from 'fs';
import { get } from 'https';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { pipeline } from 'stream/promises';
import { createGunzip } from 'zlib';
import { extract } from 'tar';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const rootDir = join(__dirname, '..');

// Get package version
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const packageJson = require('../package.json');
const VERSION = packageJson.version;

const GITHUB_REPO = 'blackboardsh/zig-bsdiff';
const BIN_DIR = join(rootDir, 'bin');

// Platform mapping
const PLATFORM_MAP = {
  darwin: 'darwin',
  linux: 'linux',
  win32: 'win32',
};

const ARCH_MAP = {
  x64: 'x64',
  arm64: 'arm64',
};

function getPlatformInfo() {
  const platform = PLATFORM_MAP[process.platform];
  const arch = ARCH_MAP[process.arch];

  if (!platform || !arch) {
    throw new Error(
      `Unsupported platform/architecture: ${process.platform}-${process.arch}\n` +
      `Supported: darwin-arm64, darwin-x64, linux-x64, linux-arm64, win32-x64`
    );
  }

  return { platform, arch };
}

function getDownloadUrl(platform, arch) {
  const filename = `zig-bsdiff-${platform}-${arch}.tar.gz`;
  return `https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${filename}`;
}

async function downloadBinary(url, destDir) {
  return new Promise((resolve, reject) => {
    console.log(`Downloading zig-bsdiff binaries from ${url}...`);

    get(url, (response) => {
      if (response.statusCode === 302 || response.statusCode === 301) {
        // Follow redirect
        return downloadBinary(response.headers.location, destDir)
          .then(resolve)
          .catch(reject);
      }

      if (response.statusCode !== 200) {
        reject(
          new Error(
            `Failed to download binaries: HTTP ${response.statusCode}\n` +
            `URL: ${url}\n\n` +
            `This usually means:\n` +
            `1. Version v${VERSION} hasn't been released yet on GitHub\n` +
            `2. The release exists but binaries weren't uploaded\n` +
            `3. You're offline or behind a firewall\n\n` +
            `Please check: https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}`
          )
        );
        return;
      }

      // Create bin directory if it doesn't exist
      if (!existsSync(destDir)) {
        mkdirSync(destDir, { recursive: true });
      }

      // Extract tar.gz directly to bin directory
      const gunzip = createGunzip();
      const extractStream = extract({ cwd: destDir, strip: 0 });

      pipeline(response, gunzip, extractStream)
        .then(() => {
          console.log('✓ Binaries downloaded and extracted successfully');

          // Make binaries executable on Unix-like systems
          if (process.platform !== 'win32') {
            const bsdiffPath = join(destDir, 'bsdiff');
            const bspatchPath = join(destDir, 'bspatch');

            if (existsSync(bsdiffPath)) chmodSync(bsdiffPath, 0o755);
            if (existsSync(bspatchPath)) chmodSync(bspatchPath, 0o755);
          }

          resolve();
        })
        .catch(reject);
    }).on('error', reject);
  });
}

async function main() {
  try {
    const { platform, arch } = getPlatformInfo();
    const url = getDownloadUrl(platform, arch);

    // Check if binaries already exist (e.g., from cache)
    const binExt = platform === 'win32' ? '.exe' : '';
    const bsdiffPath = join(BIN_DIR, `bsdiff${binExt}`);
    const bspatchPath = join(BIN_DIR, `bspatch${binExt}`);

    if (existsSync(bsdiffPath) && existsSync(bspatchPath)) {
      console.log('✓ zig-bsdiff binaries already installed');
      return;
    }

    await downloadBinary(url, BIN_DIR);

    console.log(`\n✅ zig-bsdiff v${VERSION} installed successfully`);
    console.log(`   Platform: ${platform}-${arch}`);
    console.log(`   Binaries: ${BIN_DIR}/`);
  } catch (error) {
    console.error('\n❌ Failed to install zig-bsdiff binaries:');
    console.error(error.message);
    console.error('\nYou can try:');
    console.error('1. Check your internet connection');
    console.error('2. Manually download binaries from GitHub releases');
    console.error(`3. Build from source: npm run build\n`);
    process.exit(1);
  }
}

main();
