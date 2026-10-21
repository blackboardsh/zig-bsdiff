#!/usr/bin/env node

import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageJson = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const version = process.argv[2] || packageJson.version;
const arch = process.argv[3] || process.arch;
assert.match(version, /^\d+\.\d+\.\d+(?:-[\w.-]+)?(?:\+[\w.-]+)?$/, 'Expected a release version');
assert.equal(process.platform, 'darwin', 'Run release validation on macOS');
assert.ok(['arm64', 'x64'].includes(arch), `Unsupported architecture: ${arch}`);
assert.equal(process.arch, arch, 'Run release validation in a native target process');
const translated = spawnSync('sysctl', ['-in', 'sysctl.proc_translated'], { encoding: 'utf8' });
assert.notEqual(translated.stdout?.trim(), '1', 'Run release validation without Rosetta');
const machoArch = arch === 'x64' ? 'x86_64' : 'arm64';
assert.equal(execFileSync('uname', ['-m'], { encoding: 'utf8' }).trim(), machoArch, 'Native host architecture');

const product = 'zig-bsdiff';
const target = `darwin-${arch}`;
const baseUrl = `https://electrobun-artifacts.blackboard.sh/${product}/releases/${version}`;
const temporary = mkdtempSync(join(tmpdir(), `${product}-verify-`));

function download(url, destination) {
  execFileSync('curl', ['--fail', '--location', '--silent', '--show-error', '--retry', '3', '--output', destination, url], { stdio: 'inherit' });
}

try {
  const manifestPath = join(temporary, 'manifest.json');
  download(`${baseUrl}/manifest.json`, manifestPath);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  assert.equal(manifest.schemaVersion, 1, 'Release manifest schema');
  assert.equal(manifest.product, product, 'Release manifest product');
  assert.equal(manifest.version, version, 'Release manifest version');
  const artifact = manifest.artifacts?.[target];
  assert.ok(artifact, `Missing ${target} in release manifest`);
  const archiveName = `${product}-${target}.tar.gz`;
  assert.equal(artifact.url, `${baseUrl}/${archiveName}`, 'Artifact must use the exact immutable release URL');
  assert.match(artifact.sha256, /^[a-f0-9]{64}$/, 'Release artifact SHA-256');
  assert.ok(Number.isSafeInteger(artifact.size) && artifact.size > 0, 'Release artifact size');

  const archivePath = join(temporary, archiveName);
  download(artifact.url, archivePath);
  const archive = readFileSync(archivePath);
  assert.equal(archive.length, artifact.size, 'Downloaded artifact size');
  assert.equal(createHash('sha256').update(archive).digest('hex'), artifact.sha256, 'Downloaded artifact SHA-256');
  execFileSync('tar', ['-xzf', archivePath, '-C', temporary], { stdio: 'inherit' });

  for (const name of ['bsdiff', 'bspatch']) {
    const binary = join(temporary, name);
    const description = execFileSync('file', ['-b', binary], { encoding: 'utf8' }).trim();
    assert.match(description, /Mach-O.*executable/, `${name} must be a Mach-O executable`);
    assert.equal(execFileSync('lipo', ['-archs', binary], { encoding: 'utf8' }).trim(), machoArch, `${name} architecture`);
    const loadCommands = execFileSync('otool', ['-l', binary], { encoding: 'utf8' });
    const deploymentTargets = [...loadCommands.matchAll(/^\s*minos\s+(\S+)/gm)].map((match) => match[1]);
    assert.equal(deploymentTargets.length, 1, `${name} must declare one macOS deployment target`);
    assert.match(deploymentTargets[0], /^14\.0(?:\.0)?$/, `${name} must target macOS 14.0`);
    const dependencies = execFileSync('otool', ['-L', binary], { encoding: 'utf8' })
      .trim().split('\n').slice(1).map((line) => line.trim().split(' (')[0]);
    assert.ok(dependencies.length > 0, `${name} must declare system dependencies`);
    for (const dependency of dependencies) {
      assert.ok(dependency.startsWith('/usr/lib/') || dependency.startsWith('/System/Library/'), `${name} has a non-system dependency: ${dependency}`);
    }
    console.log(`${name}: ${description}; macOS ${deploymentTargets[0]}; system dependencies only`);
  }

  execFileSync(process.execPath, [fileURLToPath(new URL('./test-release-binaries.js', import.meta.url)), temporary, arch], { stdio: 'inherit' });
  console.log(`Verified published ${product} ${version} for ${target}`);
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
