import { query } from "@anthropic-ai/claude-agent-sdk";

/**
 * Margie's brain (v0).
 *
 * Protocol: one JSON request on stdin -> one JSON response on stdout.
 *   in:  {"type": "user_text", "text": "..."}
 *   out: {"text": "..."}
 *
 * v1 will make this a long-lived process with a streaming protocol,
 * camera-frame vision input, and the ability to spawn `claude` CLI
 * sessions in PTYs for real coding tasks.
 */

const MARGIE_SYSTEM_PROMPT = `You are Margie, Tom's personal assistant. You live
as an overlay on his Mac. Your replies are spoken aloud via text-to-speech, so
keep them short, conversational, and warm — one to three sentences unless Tom
asks for detail. No markdown, no bullet lists, no code blocks in replies.
When Tom gives you a coding task, acknowledge it and summarize what you'd do —
dispatching real Claude Code sessions arrives in a later version.`;

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  const raw = await readStdin();
  const request = JSON.parse(raw) as { type: string; text: string };

  let reply = "";
  for await (const message of query({
    prompt: request.text,
    options: {
      systemPrompt: MARGIE_SYSTEM_PROMPT,
      // Read-only tools so nothing blocks on a permission prompt.
      allowedTools: ["Read", "Glob", "Grep"],
      maxTurns: 5,
    },
  })) {
    if (message.type === "result" && message.subtype === "success") {
      reply = message.result;
    }
  }

  process.stdout.write(
    JSON.stringify({ text: reply || "Sorry, I came up empty on that one." }),
  );
}

main().catch((err) => {
  process.stdout.write(
    JSON.stringify({ text: `My brain hit an error: ${err.message ?? err}` }),
  );
  process.exit(1);
});
