export function resolveBuildTarget({ args = process.argv.slice(2), env = process.env, platform = process.platform, arch = process.arch } = {}) {
  const requested = args.find((arg) => arg.startsWith('--target='))?.slice('--target='.length) ?? env.ZIG_TARGET;
  if (requested) {
    if (!/^(aarch64|x86_64)-(windows|linux|macos)(?:[.\w-]*)$/.test(requested)) {
      throw new Error(`Unsupported build target: ${requested}`);
    }
    return requested;
  }
  if (!['arm64', 'x64'].includes(arch)) throw new Error(`Unsupported architecture: ${arch}`);
  const cpu = arch === 'arm64' ? 'aarch64' : 'x86_64';
  const os = { win32: arch === 'arm64' ? 'windows-msvc' : 'windows-gnu', darwin: 'macos', linux: 'linux-gnu' }[platform];
  if (!os) throw new Error(`Unsupported platform: ${platform}`);
  return `${cpu}-${os}`;
}
