/**
 * Text-timed lip-sync: turn ElevenLabs' per-character alignment into a
 * track of mouth shapes over time. Rule-based grapheme → viseme is crude
 * next to a phonemiser, but with real timings it reads as speech rather
 * than flapping, which amplitude alone never does.
 */

/** Mouth shape classes the character adapters understand. */
export type Viseme = "aa" | "ee" | "ih" | "oh" | "ou" | "closed" | "rest";

export interface VisemeCue {
  /** Seconds from the start of the audio. */
  t0: number;
  t1: number;
  viseme: Viseme;
  /** How open this shape is, 0..1 (consonants are small, vowels large). */
  open: number;
}

/** ElevenLabs `alignment` object from the with-timestamps endpoint. */
export interface Alignment {
  characters: string[];
  character_start_times_seconds: number[];
  character_end_times_seconds: number[];
}

const VOWELS: Record<string, [Viseme, number]> = {
  a: ["aa", 1.0],
  e: ["ee", 0.75],
  i: ["ih", 0.7],
  o: ["oh", 0.9],
  u: ["ou", 0.8],
  y: ["ih", 0.5],
};

/** Consonants that close the lips. */
const CLOSED = new Set(["m", "b", "p"]);
/** Consonants shaped with rounded lips. */
const ROUND = new Set(["w", "q"]);
/** Consonants with a small, wide opening (teeth showing). */
const WIDE = new Set(["s", "z", "c", "t", "d", "n", "l", "r", "k", "g", "j", "x", "h", "f", "v"]);

function classify(ch: string): [Viseme, number] {
  const c = ch.toLowerCase();
  if (VOWELS[c]) return VOWELS[c];
  if (CLOSED.has(c)) return ["closed", 0];
  if (ROUND.has(c)) return ["ou", 0.5];
  if (WIDE.has(c)) return ["ih", 0.3];
  return ["rest", 0];
}

/** Build the cue list; adjacent identical shapes are merged. */
export function visemesFromAlignment(a: Alignment): VisemeCue[] {
  const cues: VisemeCue[] = [];
  const n = Math.min(
    a.characters.length,
    a.character_start_times_seconds.length,
    a.character_end_times_seconds.length,
  );
  for (let i = 0; i < n; i++) {
    const [viseme, open] = classify(a.characters[i]);
    const t0 = a.character_start_times_seconds[i];
    const t1 = a.character_end_times_seconds[i];
    if (!(t1 > t0)) continue;
    const last = cues[cues.length - 1];
    if (last && last.viseme === viseme && Math.abs(last.t1 - t0) < 0.02) {
      last.t1 = t1;
      last.open = Math.max(last.open, open);
    } else {
      cues.push({ t0, t1, viseme, open });
    }
  }
  return cues;
}

/**
 * The shape in effect at time `t`, blending across cue boundaries so the
 * mouth glides rather than snaps. Returns weights per shape plus openness.
 */
export function sampleVisemes(
  cues: VisemeCue[],
  t: number,
): { weights: Record<Exclude<Viseme, "closed" | "rest">, number>; open: number } {
  const weights = { aa: 0, ee: 0, ih: 0, oh: 0, ou: 0 };
  if (cues.length === 0) return { weights, open: 0 };
  // Binary search for the cue containing t (or the nearest before it).
  let lo = 0;
  let hi = cues.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (cues[mid].t0 <= t) lo = mid;
    else hi = mid - 1;
  }
  const cur = cues[lo];
  const next = cues[lo + 1];
  const blendIn = 0.06; // seconds to glide into the next shape
  let mix = 0;
  if (next && next.t0 - t < blendIn && t >= cur.t0) {
    mix = 1 - Math.max(0, next.t0 - t) / blendIn;
  }
  const add = (c: VisemeCue, w: number) => {
    if (w <= 0 || c.viseme === "closed" || c.viseme === "rest") return;
    weights[c.viseme] += w;
  };
  const inCur = t >= cur.t0 && t <= cur.t1 + 0.04;
  add(cur, inCur ? 1 - mix : 0);
  if (next) add(next, mix);
  const open = (inCur ? cur.open * (1 - mix) : 0) + (next ? next.open * mix : 0);
  return { weights, open };
}
