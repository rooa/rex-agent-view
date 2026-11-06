import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync, realpathSync, unlinkSync, renameSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = '/Applications/Rex Beta.app';
const destination = resolve(root, 'build/Rex Agent View.app');
const binary = resolve(destination, 'Contents/MacOS/Rex');
const dylibPath = '@executable_path/../Frameworks/RexAgent.dylib';

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.status !== 0) throw new Error(`${command}: ${result.stderr || result.error || result.status}`);
  return result.stdout;
}

// Only the project-local copy is ever altered. The official app and its server remain signed and untouched.
if (!existsSync(destination)) run('/usr/bin/ditto', [source, destination]);
if (!realpathSync(destination).startsWith(realpathSync(resolve(root, 'build')) + '/')) throw new Error('Refusing to prepare an app outside this project build directory.');
const fileInfo = run('/usr/bin/file', [binary]);
// A fresh inode avoids macOS retaining the code signature of a previously mapped build.
copyFileSync(binary, binary + '.next');
renameSync(binary + '.next', binary);
if (fileInfo.includes('universal binary')) {
  const thin = binary + '.arm64';
  run('/usr/bin/lipo', [binary, '-thin', 'arm64', '-output', thin]);
  copyFileSync(thin, binary);
}
if (existsSync(binary + '.arm64')) unlinkSync(binary + '.arm64');

// Append one weak dylib load command in existing Mach-O header padding.
// Format follows mach-o/loader.h. No executable instructions are changed.
const bytes = readFileSync(binary);
if (bytes.readUInt32LE(0) !== 0xfeedfacf) throw new Error('Expected a 64-bit little-endian Mach-O.');
const ncmds = bytes.readUInt32LE(16);
const sizeofcmds = bytes.readUInt32LE(20);
let offset = 32;
let firstSection = bytes.length;
let present = false;
for (let i = 0; i < ncmds; i++) {
  const command = bytes.readUInt32LE(offset);
  const size = bytes.readUInt32LE(offset + 4);
  if (size < 8 || offset + size > 32 + sizeofcmds) throw new Error('Invalid Mach-O load command.');
  if (command === 0xc || command === 0x80000018) {
    const nameOffset = offset + bytes.readUInt32LE(offset + 8);
    const end = bytes.indexOf(0, nameOffset);
    if (bytes.toString('utf8', nameOffset, end) === dylibPath) present = true;
  }
  if (command === 0x19) {
    const count = bytes.readUInt32LE(offset + 64);
    for (let j = 0; j < count; j++) {
      const section = offset + 72 + j * 80;
      const start = bytes.readUInt32LE(section + 48);
      const type = bytes.readUInt32LE(section + 64) & 0xff;
      if (start && ![1, 0xc, 0x12].includes(type)) firstSection = Math.min(firstSection, start);
    }
  }
  offset += size;
}
if (!present) {
  const commandSize = Math.ceil((24 + Buffer.byteLength(dylibPath) + 1) / 8) * 8;
  const start = 32 + sizeofcmds;
  if (start + commandSize > firstSection || bytes.subarray(start, start + commandSize).some(x => x !== 0)) throw new Error('No free header padding for native pane module.');
  bytes.writeUInt32LE(0x80000018, start);
  bytes.writeUInt32LE(commandSize, start + 4);
  bytes.writeUInt32LE(24, start + 8);
  bytes.writeUInt32LE(2, start + 12);
  bytes.writeUInt32LE(0x10000, start + 16);
  bytes.writeUInt32LE(0x10000, start + 20);
  bytes.write(dylibPath, start + 24);
  bytes.writeUInt32LE(ncmds + 1, 16);
  bytes.writeUInt32LE(sizeofcmds + commandSize, 20);
  writeFileSync(binary, bytes);
}
mkdirSync(resolve(destination, 'Contents/Frameworks'), { recursive: true });
const copiedLibrary = resolve(destination, 'Contents/Frameworks/RexAgent.dylib');
copyFileSync(resolve(root, 'build/RexAgent.dylib'), copiedLibrary + '.next');
renameSync(copiedLibrary + '.next', copiedLibrary);
const plist = resolve(destination, 'Contents/Info.plist');
run('/usr/libexec/PlistBuddy', ['-c', 'Set :CFBundleDisplayName Rex Agent View', plist]);
run('/usr/libexec/PlistBuddy', ['-c', 'Set :CFBundleIdentifier com.superlogical.rex.agent.experimental', plist]);
// Disable the updater only in the copied bundle; never change shared user defaults.
for (const key of ['SUEnableAutomaticChecks', 'SUAutomaticallyUpdate']) {
  const exists = spawnSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist]).status === 0;
  run('/usr/libexec/PlistBuddy', ['-c', exists ? `Set :${key} false` : `Add :${key} bool false`, plist]);
}
const entitlements = resolve(root, 'build/experimental-entitlements.plist');
const originalEntitlements = run('/usr/bin/codesign', ['-d', '--entitlements', '-', '--xml', source]);
writeFileSync(entitlements, originalEntitlements.replace('</dict>', '<key>com.apple.security.cs.disable-library-validation</key><true/></dict>'));
run('/usr/bin/codesign', ['-f', '-s', '-', '--options', 'runtime', '--entitlements', entitlements, destination]);
run('/usr/bin/codesign', ['--verify', '--strict', destination]);
console.log(`Prepared ${destination}`);
