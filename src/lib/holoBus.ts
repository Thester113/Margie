/**
 * One-way state bus from the overlay window (where Margie listens, thinks
 * and talks) to the hologram window on the Looking Glass. Tauri events are
 * broadcast to every window, so the hologram simply subscribes.
 *
 * Nothing on this bus reaches the brain or the outside world.
 */
import { emit, listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { VisemeCue } from "./visemes";

export type HoloStatus = "idle" | "listening" | "thinking" | "speaking";

export interface HoloEvent {
  /** Her current state (sent on every change). */
  status?: HoloStatus;
  /** The sentence she is about to say (sent once per utterance). */
  text?: string;
  /** Timed mouth shapes for that sentence, when the voice provider gives timing. */
  visemes?: VisemeCue[];
  /** Seconds into the current utterance's audio (with level updates). */
  time?: number;
  /** 0..1 loudness: mic level while listening, her voice while speaking. */
  level?: number;
  /** 0..1 spectral brightness of her voice (low = "oh", high = "ee"). */
  centroid?: number;
  /** 0..1 progress through the current utterance. */
  progress?: number;
}

const EVENT = "margie:holo";
const LEVEL_HZ = 30;

function send(ev: HoloEvent): void {
  void emit(EVENT, ev).catch(() => {
    // Not running inside Tauri (plain browser dev) — nothing to reach.
  });
}

export function publishStatus(status: HoloStatus): void {
  send({ status });
}

export function publishCaption(text: string, visemes?: VisemeCue[]): void {
  send({ text, visemes });
}

let lastLevelAt = 0;

/** Throttled to LEVEL_HZ so the IPC bridge isn't flooded from rAF loops. */
export function publishLevel(
  level: number,
  centroid?: number,
  progress?: number,
  time?: number,
): void {
  const now = performance.now();
  if (now - lastLevelAt < 1000 / LEVEL_HZ) return;
  lastLevelAt = now;
  send({ level, centroid, progress, time });
}

export function subscribeHolo(cb: (ev: HoloEvent) => void): () => void {
  let unlisten: UnlistenFn | null = null;
  let cancelled = false;
  void listen<HoloEvent>(EVENT, (e) => cb(e.payload))
    .then((fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    })
    .catch(() => {
      // Not inside Tauri.
    });
  return () => {
    cancelled = true;
    unlisten?.();
  };
}
