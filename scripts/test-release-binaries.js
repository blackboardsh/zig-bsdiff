import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const directory = resolve(process.argv[2] ?? 'dist');
const arch = process.argv[3] ?? process.arch;
const binaries = ['bsdiff', 'bspatch'].map((name) => join(directory, `${name}${process.platform === 'win32' ? '.exe' : ''}`));
if (process.platform === 'win32') {
  assert.equal(process.arch, arch, 'Run release validation in a native target process');
  for (const binary of binaries) {
    const bytes = readFileSync(binary);
    const pe = bytes.readUInt32LE(0x3c);
    assert.equal(bytes.readUInt32LE(pe), 0x4550, 'PE signature');
    assert.equal(bytes.readUInt16LE(pe + 4), { arm64: 0xaa64, x64: 0x8664 }[arch], `${binary} PE architecture`);
  }
}
const temporary = mkdtempSync(join(tmpdir(), 'zig-bsdiff-release-'));
try {
  const original = join(temporary, 'original.bin');
  const updated = join(temporary, 'updated.bin');
  const patch = join(temporary, 'patch.bin');
  const restored = join(temporary, 'restored.bin');
  const before = Buffer.from('Windows ARM64 binary patch roundtrip\n'.repeat(4096));
  const after = Buffer.concat([before.subarray(0, 10000), Buffer.from('modified content'), before.subarray(10500)]);
  writeFileSync(original, before);
  writeFileSync(updated, after);
  execFileSync(binaries[0], [original, updated, patch, '--use-zstd'], { stdio: 'inherit' });
  execFileSync(binaries[1], [original, restored, patch], { stdio: 'inherit' });
  assert.deepEqual(readFileSync(restored), after);
  console.log(`Validated ${arch} release binaries and binary patch roundtrip`);
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
