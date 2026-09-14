/**
 * Margie's character on the hologram, independent of the model format.
 *
 * `CharacterBase` owns the behaviour — blinking, breathing, gaze, per-state
 * posture and expressions, amplitude-driven lip-sync — and hands the results
 * to a format adapter through a handful of primitives:
 *
 * - `VrmCharacter`   (vrmCharacter.ts)   VRM 0.x / 1.0, e.g. VRoid exports
 * - `ArkitCharacter` (arkitCharacter.ts) any glTF/GLB with ARKit-52 blendshapes
 *                                         (Avaturn, MetaPerson, ChatAvatar…)
 *
 * The model lives outside the repo (~/.margie/avatar/margie.vrm|glb) so the
 * harness stays identity-generic; see scripts/avatar.sh.
 */
import * as THREE from "three";
import { GLTFLoader, type GLTF } from "three/addons/loaders/GLTFLoader.js";
import { DRACOLoader } from "three/addons/loaders/DRACOLoader.js";
import { KTX2Loader } from "three/addons/loaders/KTX2Loader.js";
import { MeshoptDecoder } from "three/addons/libs/meshopt_decoder.module.js";
import { VRMLoaderPlugin } from "@pixiv/three-vrm";
import type { HoloStatus } from "../lib/holoBus";
import { sampleVisemes, type VisemeCue } from "../lib/visemes";

/** Format-neutral expression channels the behaviour layer drives. */
export type Expr =
  | "aa"
  | "ih"
  | "ou"
  | "ee"
  | "oh"
  | "blink"
  | "happy"
  | "relaxed"
  | "surprised"
  | "sad";

export type ExprWeights = Record<Expr, number>;

const MOUTH: Expr[] = ["aa", "ih", "ou", "ee", "oh"];
const MOOD_CHANNELS: Expr[] = ["blink", "happy", "relaxed", "surprised", "sad"];

/** Target expression weights per state (mouth shapes are handled separately). */
const MOOD: Record<HoloStatus, Partial<Record<Expr, number>>> = {
  idle: { relaxed: 0.2, happy: 0.08 },
  listening: { surprised: 0.12, happy: 0.15 },
  thinking: { relaxed: 0.35 },
  speaking: { happy: 0.25 },
};

/** Head pose per state: [pitch (x), yaw (y), roll (z)] in radians. */
const HEAD_POSE: Record<HoloStatus, [number, number, number]> = {
  idle: [0, 0, 0],
  listening: [0.05, 0.04, 0.1], // lean in, tilt an ear
  thinking: [-0.14, 0.2, -0.03], // look up and away
  speaking: [0.02, 0, 0],
};

/** Where the eyes go, relative to the viewer, per state. */
const GAZE_OFFSET: Record<HoloStatus, [number, number, number]> = {
  idle: [0, 0, 0],
  listening: [0, 0, 0],
  thinking: [-0.6, 0.5, 0],
  speaking: [0, 0, 0],
};

export abstract class CharacterBase {
  readonly root = new THREE.Group();
  protected status: HoloStatus = "idle";
  private level = 0;
  private centroid = 0.5;
  private mouthOpen = 0;
  private nod = 0;
  private lastLevel = 0;
  private expr: ExprWeights = {
    aa: 0, ih: 0, ou: 0, ee: 0, oh: 0, blink: 0, happy: 0, relaxed: 0, surprised: 0, sad: 0,
  };
  private blinkAt = 0;
  private blinkT = -1;
  private t = 0;
  private headCur = new THREE.Euler();
  private gaze = new THREE.Vector3();
  /** Timed mouth shapes for the current utterance (empty = amplitude only). */
  private cues: VisemeCue[] = [];
  /** Audio time last reported by the overlay, and when we heard it. */
  private audioTime = 0;
  private audioTimeAt = 0;
  private mouth = { aa: 0, ee: 0, ih: 0, oh: 0, ou: 0 };
  /** Seconds added to the audio clock for the mouth (negative = mouth earlier). */
  lipsyncOffset = 0;

  protected constructor(readonly scene: THREE.Object3D) {
    this.root.add(scene);
    this.scheduleBlink();
    // Every view sees a slightly different slice; never let culling drop her.
    scene.traverse((o) => {
      o.frustumCulled = false;
    });
  }

  // ---- adapter primitives -------------------------------------------------

  /** World position of the head (for framing). */
  abstract headPosition(out?: THREE.Vector3): THREE.Vector3;
  /** Push the current expression weights into the model. */
  protected abstract applyExpressions(w: ExprWeights): void;
  /** Rotate the head (and a share of the neck) by `head`, breathe with the chest. */
  protected abstract applyPose(head: THREE.Euler, breathe: number, lean: number): void;
  /** Point the eyes at a world position. */
  protected abstract applyGaze(target: THREE.Vector3): void;
  /** Per-frame model housekeeping (spring bones, etc.). */
  protected abstract tick(dt: number): void;
  abstract dispose(): void;

  // ---- behaviour ----------------------------------------------------------

  setStatus(s: HoloStatus): void {
    this.status = s;
    if (s !== "speaking") {
      this.level = 0;
      this.cues = [];
    }
  }

  /** New utterance with word timing: the mouth follows these, not the level. */
  setVisemes(cues: VisemeCue[] | undefined): void {
    this.cues = cues ?? [];
    this.audioTime = 0;
    this.audioTimeAt = performance.now();
  }

  /** Where the audio is (seconds); we extrapolate between reports. */
  setAudioTime(t: number): void {
    this.audioTime = t;
    this.audioTimeAt = performance.now();
  }

  /** Loudness (0..1) of whoever is talking, and her voice's brightness. */
  setLevel(level: number, centroid?: number): void {
    this.level = Math.max(0, Math.min(1, level));
    if (typeof centroid === "number") this.centroid = Math.max(0, Math.min(1, centroid));
  }

  /** `viewer` = where the person is (the rig's centre camera). */
  update(dt: number, viewer: THREE.Vector3): void {
    this.t += dt;
    const s = this.status;
    const k = Math.min(1, dt * 5); // damping

    // Gaze: at the viewer, offset by state (thinking looks away).
    const [gx, gy, gz] = GAZE_OFFSET[s];
    const wander = s === "idle" ? Math.sin(this.t * 0.35) * 0.15 : 0;
    this.gaze.set(viewer.x + gx + wander, viewer.y + gy, viewer.z + gz);
    this.applyGaze(this.gaze);

    // Mouth. With word timing: the shape comes from the viseme track and the
    // voice level only gates it (silence closes the mouth even mid-word).
    // Without timing: amplitude opens the jaw, spectral brightness picks a shape.
    let mouth: Partial<ExprWeights>;
    if (s === "speaking" && this.cues.length > 0) {
      const t = this.audioTime + (performance.now() - this.audioTimeAt) / 1000 + this.lipsyncOffset;
      const { weights, open } = sampleVisemes(this.cues, t);
      const gate = Math.min(1, 0.35 + this.level * 1.2);
      const target = open * gate;
      this.mouthOpen += (target - this.mouthOpen) * Math.min(1, dt * 22);
      const k2 = Math.min(1, dt * 22);
      for (const key of ["aa", "ee", "ih", "oh", "ou"] as const) {
        const w = weights[key] * this.mouthOpen * (key === "aa" ? 0.7 : 0.8);
        this.mouth[key] += (w - this.mouth[key]) * k2;
      }
      mouth = { ...this.mouth };
    } else {
      const targetOpen = s === "speaking" ? Math.min(1, this.level * 1.3) : 0;
      this.mouthOpen += (targetOpen - this.mouthOpen) * Math.min(1, dt * 18);
      const m = this.mouthOpen;
      const c = this.centroid;
      mouth = {
        aa: m * 0.55,
        oh: m * Math.max(0, 0.55 - c) * 0.9,
        ou: m * Math.max(0, 0.35 - c) * 0.6,
        ih: m * Math.max(0, c - 0.55) * 0.8,
        ee: m * Math.max(0, c - 0.7) * 0.6,
      };
      for (const key of ["aa", "ee", "ih", "oh", "ou"] as const) this.mouth[key] = mouth[key] ?? 0;
    }

    // Nod on syllable onsets while speaking.
    const onset = s === "speaking" && this.level - this.lastLevel > 0.18;
    this.lastLevel = this.level;
    if (onset) this.nod = 1;
    this.nod *= Math.max(0, 1 - dt * 7);

    // Mood expressions ease toward the state's targets.
    const mood = MOOD[s];
    for (const name of MOOD_CHANNELS) {
      const target = name === "blink" ? this.blinkWeight(dt) : (mood[name] ?? 0);
      this.expr[name] += (target - this.expr[name]) * (name === "blink" ? 1 : k);
    }
    for (const name of MOUTH) this.expr[name] = mouth[name] ?? 0;
    this.applyExpressions(this.expr);

    // Posture: breathing + state pose + nod + idle sway.
    const breathe = Math.sin(this.t * 1.1) * 0.012;
    const sway = s === "idle" ? Math.sin(this.t * 0.5) * 0.02 : 0;
    const [px, py, pz] = HEAD_POSE[s];
    const listenBob = s === "listening" ? this.level * 0.05 : 0;
    const tx = px + this.nod * 0.06 + listenBob + Math.sin(this.t * 0.8) * 0.006;
    const ty = py + sway;
    const tz = pz + Math.sin(this.t * 0.6) * 0.008;
    this.headCur.x += (tx - this.headCur.x) * k;
    this.headCur.y += (ty - this.headCur.y) * k;
    this.headCur.z += (tz - this.headCur.z) * k;
    this.applyPose(this.headCur, breathe, s === "listening" ? 0.04 : 0);

    this.tick(dt);
  }

  /**
   * Recolour the hair materials (creators name them "…Hair…"). A cheap way
   * to age a placeholder model until the real one exists.
   */
  tintHair(css: string): void {
    const color = new THREE.Color(css);
    this.scene.traverse((o) => {
      const mesh = o as THREE.Mesh;
      if (!mesh.isMesh) return;
      const mats = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
      for (const m of mats) {
        if (!/hair/i.test(`${m.name ?? ""} ${mesh.name ?? ""}`)) continue;
        const mt = m as THREE.Material & {
          color?: THREE.Color;
          shadeColorFactor?: THREE.Color;
          map?: THREE.Texture | null;
        };
        // The base texture carries the original colour; drop it so the tint
        // reads as the hair colour rather than a wash over dark strands.
        if (mt.map) mt.map = null;
        mt.color?.set(color);
        mt.shadeColorFactor?.set(color.clone().multiplyScalar(0.72));
        mt.needsUpdate = true;
      }
    });
  }

  private scheduleBlink(): void {
    this.blinkAt = this.t + 2.5 + Math.random() * 3.5;
  }

  /** Blink envelope: quick close, slightly slower open. */
  private blinkWeight(dt: number): number {
    if (this.blinkT < 0) {
      if (this.t >= this.blinkAt) this.blinkT = 0;
      else return 0;
    }
    this.blinkT += dt;
    const d = 0.18;
    if (this.blinkT >= d) {
      this.blinkT = -1;
      this.scheduleBlink();
      return 0;
    }
    const x = this.blinkT / d;
    return x < 0.4 ? x / 0.4 : 1 - (x - 0.4) / 0.6;
  }
}

/**
 * Parse a .vrm or .glb from memory and pick the adapter that fits. Creator
 * exports are often Draco- or meshopt-compressed with KTX2 textures, so all
 * three decoders are registered (decoder binaries come from
 * public/decoders, see scripts/sync-decoders.sh).
 */
export async function loadCharacter(
  bytes: ArrayBuffer,
  renderer: THREE.WebGLRenderer,
): Promise<CharacterBase> {
  const loader = new GLTFLoader();
  loader.register((parser) => new VRMLoaderPlugin(parser));
  const draco = new DRACOLoader().setDecoderPath("/decoders/draco/");
  loader.setDRACOLoader(draco);
  loader.setMeshoptDecoder(MeshoptDecoder);
  const ktx2 = new KTX2Loader().setTranscoderPath("/decoders/basis/").detectSupport(renderer);
  loader.setKTX2Loader(ktx2);
  const gltf = await new Promise<GLTF>((resolve, reject) =>
    loader.parse(bytes, "", resolve, reject),
  );
  draco.dispose();
  ktx2.dispose();
  if (gltf.userData.vrm) {
    const { VrmCharacter } = await import("./vrmCharacter");
    return VrmCharacter.fromGltf(gltf);
  }
  const { ArkitCharacter } = await import("./arkitCharacter");
  return ArkitCharacter.fromGltf(gltf);
}
