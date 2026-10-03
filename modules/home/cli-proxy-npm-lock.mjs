// Complete upstream's missing registry metadata without changing any version.
// Nix pins this output and the dependency cache separately.
import fs from 'node:fs';
const lock = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const missing = Object.entries(lock.packages).filter(([location, entry]) =>
  !entry.link && !entry.resolved && location.includes('node_modules/'));
for (let offset = 0; offset < missing.length; offset += 8) {
  await Promise.all(missing.slice(offset, offset + 8).map(async ([location, entry]) => {
    if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(entry.version)) {
      throw new Error(`Unrecognized registry version at ${location}`);
    }
    const name = location.split('node_modules/').at(-1);
    const basename = name.split('/').at(-1);
    const response = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}/${entry.version}`);
    if (!response.ok) throw new Error(`Registry metadata failed for ${name}: ${response.status}`);
    const metadata = await response.json();
    const expectedURL = `https://registry.npmjs.org/${name}/-/${basename}-${entry.version}.tgz`;
    if (metadata.version !== entry.version || metadata.dist?.tarball !== expectedURL ||
        !/^sha512-[A-Za-z0-9+/]+=*$/.test(metadata.dist?.integrity ?? '')) {
      throw new Error(`Unexpected registry metadata for ${name}`);
    }
    entry.resolved = expectedURL;
    entry.integrity = metadata.dist.integrity;
  }));
}
fs.writeFileSync(process.argv[3], JSON.stringify(lock, null, 2) + '\n');
