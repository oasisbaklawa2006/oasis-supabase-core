import {
  computeCanonicalMediaArchiveContentHash,
  countMediaBinaryEntries,
} from "./media_archive_content_hash.ts";

async function createFixtureZip(path: string): Promise<void> {
  const dir = await Deno.makeTempDir();
  await Deno.writeTextFile(`${dir}/_chat.txt`, "fixture chat");
  await Deno.writeTextFile(`${dir}/alpha.jpg`, "alpha-bytes");
  await Deno.writeTextFile(`${dir}/beta.jpg`, "beta-bytes");
  try {
    await Deno.remove(path);
  } catch {
    // path may not exist yet
  }
  const proc = await new Deno.Command("zip", {
    args: ["-j", path, `${dir}/_chat.txt`, `${dir}/alpha.jpg`, `${dir}/beta.jpg`],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!proc.success) {
    const stderr = new TextDecoder().decode(proc.stderr);
    throw new Error(`failed to create fixture zip: ${stderr}`);
  }
  await Deno.remove(dir, { recursive: true });
}

Deno.test({
  name: "canonical media archive content hash is deterministic",
  permissions: { read: true, write: true, run: true },
}, async () => {
  const zipPath = `${await Deno.makeTempDir()}/fixture.zip`;
  try {
    await createFixtureZip(zipPath);
    const count = await countMediaBinaryEntries(zipPath);
    if (count !== 2) throw new Error(`expected 2 binary entries, got ${count}`);
    const first = await computeCanonicalMediaArchiveContentHash(zipPath);
    const second = await computeCanonicalMediaArchiveContentHash(zipPath);
    if (!first || first.length !== 64) throw new Error("invalid content hash");
    if (first !== second) throw new Error("content hash not deterministic");
  } finally {
    const parent = zipPath.replace(/\/fixture\.zip$/, "");
    await Deno.remove(parent, { recursive: true });
  }
});
