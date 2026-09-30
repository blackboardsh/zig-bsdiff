import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveBuildTarget } from './build-target.js';

test('explicit ARM64 target takes precedence over an x64 build host', () => {
  assert.equal(resolveBuildTarget({ args: ['--target=aarch64-windows-msvc'], env: {}, platform: 'win32', arch: 'x64' }), 'aarch64-windows-msvc');
});
test('target environment supports cross compilation', () => {
  assert.equal(resolveBuildTarget({ args: [], env: { ZIG_TARGET: 'aarch64-windows-msvc' }, platform: 'win32', arch: 'x64' }), 'aarch64-windows-msvc');
});
test('native Windows ARM64 uses MSVC and x64 retains the GNU ABI', () => {
  assert.equal(resolveBuildTarget({ args: [], env: {}, platform: 'win32', arch: 'arm64' }), 'aarch64-windows-msvc');
  assert.equal(resolveBuildTarget({ args: [], env: {}, platform: 'win32', arch: 'x64' }), 'x86_64-windows-gnu');
});
test('invalid targets fail before invoking the compiler', () => {
  assert.throws(() => resolveBuildTarget({ args: ['--target=arm64;bad'], env: {} }), /Unsupported build target/);
});
