/**
 * Where the display's calibration comes from, in order of preference:
 *
 * 1. Looking Glass Bridge's HoloPlay driver websocket (what the official
 *    WebXR library uses) — needs Bridge running.
 * 2. Bridge's REST API on :33334 (calibration as a JSON string).
 * 3. The on-disk cache Rust keeps in ~/.margie/lkg/calibration.json, written
 *    after any successful live read, so the hologram works without Bridge.
 */
import { invoke } from "@tauri-apps/api/core";
import { Client } from "holoplay-core";
import { defaultQuiltFor, type Calibration, type QuiltSettings } from "./lkgConfig";

export type CalibrationSource = "bridge-driver" | "bridge-rest" | "cache" | "placeholder";

export interface CalibrationBundle {
  calibration: Calibration;
  quilt: QuiltSettings;
  source: CalibrationSource;
}

const DRIVER_TIMEOUT_MS = 2500;
const REST_BASE = "http://localhost:33334";

function isCalibration(x: unknown): x is Calibration {
  if (!x || typeof x !== "object") return false;
  const c = x as Record<string, unknown>;
  const v = (k: string) =>
    typeof (c[k] as { value?: unknown } | undefined)?.value === "number";
  return (
    v("pitch") && v("slope") && v("center") && v("screenW") && v("screenH") && v("DPI")
  );
}

/** Bridge's quilt object → ours. Accepts either naming scheme. */
function parseQuilt(q: unknown, serial: string): QuiltSettings {
  const d = defaultQuiltFor(serial);
  if (!q || typeof q !== "object") return d;
  const o = q as Record<string, unknown>;
  const num = (...keys: string[]) => {
    for (const k of keys) {
      const raw = o[k];
      const n = typeof raw === "object" && raw ? (raw as { value?: unknown }).value : raw;
      if (typeof n === "number" && n > 0) return n;
    }
    return undefined;
  };
  return {
    columns: num("tileX", "columns") ?? d.columns,
    rows: num("tileY", "rows") ?? d.rows,
    width: num("quiltX", "quiltWidth", "width") ?? d.width,
    height: num("quiltY", "quiltHeight", "height") ?? d.height,
  };
}

/** Parse a value that may be JSON text or an already-parsed object. */
function maybeJson(x: unknown): unknown {
  if (typeof x === "string") {
    try {
      return JSON.parse(x);
    } catch {
      return undefined;
    }
  }
  if (x && typeof x === "object" && "value" in (x as object)) {
    return maybeJson((x as { value: unknown }).value) ?? x;
  }
  return x;
}

/** Depth-first search of a response for a device carrying a calibration. */
function findDevice(node: unknown, depth = 0): { calibration: Calibration; quilt?: unknown } | null {
  if (!node || typeof node !== "object" || depth > 8) return null;
  const o = node as Record<string, unknown>;
  if ("calibration" in o) {
    const cal = maybeJson(o.calibration);
    if (isCalibration(cal)) {
      return { calibration: cal, quilt: maybeJson(o.defaultQuilt) };
    }
  }
  for (const v of Object.values(o)) {
    const hit = findDevice(v, depth + 1);
    if (hit) return hit;
  }
  return null;
}

async function fromDriver(): Promise<CalibrationBundle> {
  return new Promise((resolve, reject) => {
    let done = false;
    let client: Client | null = null;
    const finish = (fn: () => void) => {
      if (done) return;
      done = true;
      window.clearTimeout(timer);
      try {
        client?.disconnect();
      } catch {
        // ignore
      }
      fn();
    };
    const timer = window.setTimeout(
      () => finish(() => reject(new Error("Bridge driver: timeout"))),
      DRIVER_TIMEOUT_MS,
    );
    client = new Client(
      (msg: unknown) => {
        const hit = findDevice(msg);
        if (!hit) {
          finish(() => reject(new Error("Bridge driver: no Looking Glass device reported")));
          return;
        }
        const quilt = parseQuilt(hit.quilt, hit.calibration.serial ?? "");
        finish(() => resolve({ calibration: hit.calibration, quilt, source: "bridge-driver" }));
      },
      () => finish(() => reject(new Error("Bridge driver: connection failed"))),
      () => finish(() => reject(new Error("Bridge driver: closed"))),
    );
  });
}

async function post(path: string, body: unknown): Promise<unknown> {
  const ctl = new AbortController();
  const timer = window.setTimeout(() => ctl.abort(), DRIVER_TIMEOUT_MS);
  try {
    const res = await fetch(`${REST_BASE}/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    if (!res.ok) throw new Error(`Bridge REST ${path}: HTTP ${res.status}`);
    return await res.json();
  } finally {
    window.clearTimeout(timer);
  }
}

/** Find the orchestration token in whatever envelope Bridge used. */
function findToken(node: unknown, depth = 0): string | null {
  if (typeof node === "string" && node.length >= 8 && !node.includes(" ")) return node;
  if (!node || typeof node !== "object" || depth > 6) return null;
  const o = node as Record<string, unknown>;
  for (const key of ["orchestration", "payload", "value", "token"]) {
    if (key in o) {
      const t = findToken(o[key], depth + 1);
      if (t) return t;
    }
  }
  return null;
}

async function fromRest(): Promise<CalibrationBundle> {
  const entered = await post("enter_orchestration", { name: "margie" });
  const token = findToken(entered) ?? "default";
  const devices = await post("available_output_devices", { orchestration: token });
  const hit = findDevice(devices);
  if (!hit) throw new Error("Bridge REST: no Looking Glass device reported");
  const quilt = parseQuilt(hit.quilt, hit.calibration.serial ?? "");
  return { calibration: hit.calibration, quilt, source: "bridge-rest" };
}

async function fromCache(): Promise<CalibrationBundle> {
  const text = await invoke<string | null>("lkg_calibration_read");
  if (!text) throw new Error("no cached calibration");
  const parsed = JSON.parse(text) as { calibration?: unknown; quilt?: unknown };
  if (!isCalibration(parsed.calibration)) throw new Error("cached calibration unreadable");
  return {
    calibration: parsed.calibration,
    quilt: parseQuilt(parsed.quilt, parsed.calibration.serial ?? ""),
    source: "cache",
  };
}

async function writeCache(b: CalibrationBundle): Promise<void> {
  try {
    await invoke("lkg_calibration_write", {
      text: JSON.stringify({ calibration: b.calibration, quilt: b.quilt }, null, 2),
    });
  } catch {
    // Cache is a convenience; never fatal.
  }
}

/**
 * Generic Go-like calibration for pipeline smoke tests without Bridge. The
 * picture will NOT line up with a real lens array — every panel has its own
 * pitch/centre — so this is never cached and never used unless asked for.
 */
export function placeholderCalibration(): CalibrationBundle {
  const v = (value: number) => ({ value });
  const calibration: Calibration = {
    configVersion: "placeholder",
    pitch: v(45),
    slope: v(-5),
    center: v(-0.5),
    viewCone: v(40),
    invView: v(1),
    verticalAngle: v(0),
    DPI: v(338),
    screenW: v(1440),
    screenH: v(2560),
    flipImageX: v(0),
    flipImageY: v(0),
    flipSubp: v(0),
    serial: "LKG-E-PLACEHOLDER",
    subpixelCells: [],
  };
  return { calibration, quilt: defaultQuiltFor(calibration.serial), source: "placeholder" };
}

/**
 * Load the calibration. Throws with a human-readable message when nothing
 * works (typically: Looking Glass Bridge has never been run on this Mac).
 */
export async function loadCalibration(): Promise<CalibrationBundle> {
  const errors: string[] = [];
  for (const attempt of [fromDriver, fromRest]) {
    try {
      const b = await attempt();
      await writeCache(b);
      return b;
    } catch (e) {
      errors.push(e instanceof Error ? e.message : String(e));
    }
  }
  try {
    return await fromCache();
  } catch (e) {
    errors.push(e instanceof Error ? e.message : String(e));
  }
  throw new Error(
    "No Looking Glass calibration. Install Looking Glass Bridge (look.glass/bridge), " +
      "open it with the display connected, then restart Margie. " +
      `(${errors.join("; ")})`,
  );
}
