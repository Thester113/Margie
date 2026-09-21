import { appendFileSync, readFileSync } from "node:fs";

/**
 * Jev — TypeSafe's "System One" model: typed questions against a state, back
 * come probabilities and a confidence, in ~300 ms. The brain never calls this;
 * the deterministic code around the brain does (the confirm gate, the brief
 * picker), where a regex used to guess. Stateless: no history, no tools, no
 * text generation — so it can sit inside a gate without loosening it.
 *
 * Fails closed: disabled, no key, timeout or a bad response → null, and the
 * caller keeps its regex answer. Every call is one line in ~/.margie/jev.log.
 */

const HOME = process.env.HOME || "/";
const URL = process.env.TYPESAFE_URL || "https://api.typesafe.ai/v1/systemone";

function cfg(key: string): string | undefined {
  try {
    const v = JSON.parse(readFileSync(`${HOME}/.margie/config.json`, "utf8"))[key];
    return typeof v === "string" ? v : v === undefined ? undefined : String(v);
  } catch {
    return undefined;
  }
}

export type Question =
  | { type: "noul"; instructions: unknown; criteria?: { true?: unknown; false?: unknown } }
  | { type: "choice"; instructions: unknown; criteria: Record<string, unknown> }
  | { type: "score"; instructions: unknown; criteria: unknown[] };
export type Answer =
  | { type: "noul"; noul: number }
  | { type: "choice"; choice: string; confidence: number; probabilities: Record<string, number> }
  | { type: "score"; score: number; confidence: number; probabilities: Record<string, number>; legend: Record<string, string> };

export function jevEnabled(): boolean {
  const on = (process.env.MARGIE_JEV || cfg("jev") || "on").toLowerCase();
  return on !== "off" && !!cfg("typesafe_api_key");
}

function log(line: string) {
  try { appendFileSync(`${HOME}/.margie/jev.log`, `${new Date().toISOString()} ${line}\n`); } catch { /* ignore */ }
}

/** One evaluation. `tag` names the decision in the log. */
export async function jev(tag: string, state: unknown, questions: Record<string, Question>, timeoutMs = 6000): Promise<Record<string, Answer> | null> {
  if (!jevEnabled()) return null;
  const key = cfg("typesafe_api_key")!;
  // op:// references are resolved only by the helper scripts; the sidecar reads a plain key.
  if (key.startsWith("op://")) { log(`${tag}: typesafe_api_key is an op:// ref — the sidecar needs the plain key`); return null; }
  const t0 = Date.now();
  try {
    const resp = await fetch(URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ state, model: cfg("jev_model") || "jev-latest", questions }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!resp.ok) { log(`${tag} error ${resp.status} ${Date.now() - t0}ms: ${(await resp.text()).slice(0, 200)}`); return null; }
    const data = (await resp.json()) as { answers?: Record<string, Answer> };
    if (!data.answers) { log(`${tag} malformed response ${Date.now() - t0}ms`); return null; }
    const brief = Object.entries(data.answers).map(([k, a]) =>
      a.type === "noul" ? `${k}=${a.noul}` : a.type === "choice" ? `${k}=${a.choice}@${a.confidence}` : `${k}=${a.score}@${a.confidence}`).join(" ");
    log(`${tag} ${Date.now() - t0}ms ${brief}`);
    return data.answers;
  } catch (e) {
    log(`${tag} failed ${Date.now() - t0}ms: ${(e as Error).message}`);
    return null;
  }
}

/** Convenience: a Choice answer only when it is confident enough, else null. */
export function confident(a: Answer | undefined, min: number): string | null {
  if (!a || a.type !== "choice" || a.confidence < min) return null;
  return a.choice;
}
