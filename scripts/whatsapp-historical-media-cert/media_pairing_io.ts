export async function extractChatTextFromZip(zipPath: string): Promise<string> {
  const proc = await new Deno.Command("unzip", {
    args: ["-p", zipPath, "_chat.txt"],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!proc.success) {
    throw new Error(`Failed to extract _chat.txt from ${zipPath}`);
  }
  return new TextDecoder().decode(proc.stdout);
}
