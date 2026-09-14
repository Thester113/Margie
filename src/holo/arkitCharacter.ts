/**
 * ARKit-blendshape adapter for `CharacterBase`: any glTF/GLB whose face
 * meshes carry the ARKit-52 morph targets (jawOpen, mouthFunnel,
 * eyeBlinkLeft…), optionally the Oculus visemes (viseme_aa, viseme_O…), and
 * a humanoid skeleton with Head/Neck/Spine bones. That covers the realistic
 * avatar creators (Avaturn, Avatar SDK MetaPerson, Hyper3D ChatAvatar,
 * Character Creator exports, most Sketchfab "ARKit" characters).
 *
 * Gaze uses eye bones when the rig has them, else the eyeLook* blendshapes.
 */
import * as THREE from "three";
import type { GLTF } from "three/addons/loaders/GLTFLoader.js";
import { CharacterBase, type Expr, type ExprWeights } from "./character";

/**
 * Our channels → ARKit / viseme morph names with gains. The first name that
 * exists on the model is used for each entry, so both naming families work.
 */
const MORPHS: Record<Expr, Array<[string[], number]>> = {
  aa: [[["viseme_aa", "jawOpen", "mouthOpen"], 1.0]],
  oh: [[["viseme_O", "mouthFunnel"], 1.0]],
  ou: [[["viseme_U", "mouthPucker"], 1.0]],
  ih: [[["viseme_I", "mouthStretchLeft"], 0.7], [["mouthStretchRight"], 0.7]],
  ee: [[["viseme_E", "mouthSmileLeft"], 0.5], [["mouthSmileRight"], 0.5]],
  blink: [[["eyeBlinkLeft", "eyesClosed"], 1.0], [["eyeBlinkRight"], 1.0]],
  happy: [[["mouthSmileLeft", "mouthSmile"], 0.8], [["mouthSmileRight"], 0.8], [["cheekSquintLeft"], 0.3], [["cheekSquintRight"], 0.3]],
  relaxed: [[["eyeSquintLeft"], 0.25], [["eyeSquintRight"], 0.25]],
  surprised: [[["browInnerUp"], 0.9], [["browOuterUpLeft"], 0.6], [["browOuterUpRight"], 0.6], [["eyeWideLeft"], 0.5], [["eyeWideRight"], 0.5]],
  sad: [[["mouthFrownLeft"], 0.7], [["mouthFrownRight"], 0.7], [["browDownLeft"], 0.3], [["browDownRight"], 0.3]],
};

interface MorphMesh {
  mesh: THREE.Mesh;
  dict: Record<string, number>;
}

/** Prefer a real bone; fall back to any node with the name (head-only rigs). */
function findBone(root: THREE.Object3D, re: RegExp): THREE.Object3D | null {
  let bone: THREE.Object3D | null = null;
  let node: THREE.Object3D | null = null;
  let mesh: THREE.Object3D | null = null;
  root.traverse((o) => {
    if (!re.test(o.name)) return;
    if ((o as THREE.Bone).isBone) bone ??= o;
    else if ((o as THREE.Mesh).isMesh) mesh ??= o;
    else node ??= o;
  });
  return bone ?? node ?? mesh;
}

/**
 * Exporters spell the ARKit names two ways: Apple's `eyeBlinkLeft` and the
 * Face Cap / Blender `eyeBlink_L`. Try both.
 */
function variants(name: string): string[] {
  const alt = name.replace(/Left$/, "_L").replace(/Right$/, "_R");
  return alt === name ? [name] : [name, alt];
}

/**
 * Creators export in metres, centimetres or arbitrary units. Bring the model
 * to human size: ~1.65 m for a full body, ~0.26 m for a head-only model.
 */
function normaliseScale(scene: THREE.Object3D): void {
  scene.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(scene);
  const height = box.max.y - box.min.y;
  if (!(height > 0)) return;
  const hasBody = findBone(scene, /hips|pelvis|spine/i) !== null;
  const target = hasBody ? 1.65 : 0.26;
  const k = target / height;
  if (k > 0.75 && k < 1.33) return; // already about right; don't fight the author
  scene.scale.multiplyScalar(k);
  scene.updateMatrixWorld(true);
  console.warn(`[holo] model rescaled x${k.toFixed(3)} (was ${height.toFixed(2)} units tall)`);
}

export class ArkitCharacter extends CharacterBase {
  private morphs: MorphMesh[] = [];
  private head: THREE.Object3D | null;
  private neck: THREE.Object3D | null;
  private spine: THREE.Object3D | null;
  private eyeL: THREE.Object3D | null;
  private eyeR: THREE.Object3D | null;
  private headRest = new THREE.Quaternion();
  private neckRest = new THREE.Quaternion();
  private spineRest = new THREE.Quaternion();
  private eyeLRest = new THREE.Quaternion();
  private eyeRRest = new THREE.Quaternion();
  private q = new THREE.Quaternion();
  private tmp = new THREE.Vector3();
  private tmp2 = new THREE.Vector3();
  private gazeYaw = 0;
  private gazePitch = 0;

  private constructor(scene: THREE.Object3D) {
    super(scene);
    scene.traverse((o) => {
      const mesh = o as THREE.Mesh;
      if (mesh.isMesh && mesh.morphTargetDictionary && mesh.morphTargetInfluences) {
        this.morphs.push({ mesh, dict: mesh.morphTargetDictionary });
      }
    });
    this.head = findBone(scene, /^(mixamorig:?)?head$/i) ?? findBone(scene, /head/i);
    this.neck = findBone(scene, /neck/i);
    this.spine = findBone(scene, /spine2|upperchest|chest/i) ?? findBone(scene, /spine/i);
    this.eyeL = findBone(scene, /left.?eye|eye.?left|eye[_.]?l$/i);
    this.eyeR = findBone(scene, /right.?eye|eye.?right|eye[_.]?r$/i);
    if (this.head) this.headRest.copy(this.head.quaternion);
    if (this.neck) this.neckRest.copy(this.neck.quaternion);
    if (this.spine) this.spineRest.copy(this.spine.quaternion);
    if (this.eyeL) this.eyeLRest.copy(this.eyeL.quaternion);
    if (this.eyeR) this.eyeRRest.copy(this.eyeR.quaternion);
  }

  static fromGltf(gltf: GLTF): ArkitCharacter {
    normaliseScale(gltf.scene);
    const c = new ArkitCharacter(gltf.scene);
    if (c.morphs.length === 0) {
      console.warn("[holo] model has no blendshapes: she will not emote or lip-sync");
    }
    return c;
  }

  headPosition(out = new THREE.Vector3()): THREE.Vector3 {
    this.root.updateMatrixWorld(true);
    if (this.head) return this.head.getWorldPosition(out);
    // No skeleton: aim for the top fifth of the model.
    const box = new THREE.Box3().setFromObject(this.scene);
    return out.set(
      (box.min.x + box.max.x) / 2,
      box.max.y - (box.max.y - box.min.y) * 0.12,
      (box.min.z + box.max.z) / 2,
    );
  }

  protected applyExpressions(w: ExprWeights): void {
    if (this.morphs.length === 0) return;
    // Accumulate per morph name (several channels can touch the same shape).
    const acc = new Map<string, number>();
    for (const [expr, entries] of Object.entries(MORPHS) as Array<[Expr, Array<[string[], number]>]>) {
      const v = w[expr];
      if (v <= 0.0005) continue;
      for (const [names, gain] of entries) {
        const name = names.flatMap(variants).find((n) => this.morphs.some((m) => n in m.dict));
        if (!name) continue;
        acc.set(name, Math.min(1, (acc.get(name) ?? 0) + v * gain));
      }
    }
    // Gaze via blendshapes when there are no eye bones.
    if (!this.eyeL && !this.eyeR) {
      const yaw = this.gazeYaw;
      const pitch = this.gazePitch;
      const set = (canonical: string, v: number) => {
        if (v <= 0) return;
        const n = variants(canonical).find((x) => this.morphs.some((m) => x in m.dict));
        if (n) acc.set(n, Math.min(1, (acc.get(n) ?? 0) + v));
      };
      set("eyeLookOutLeft", Math.max(0, -yaw));
      set("eyeLookInRight", Math.max(0, -yaw));
      set("eyeLookInLeft", Math.max(0, yaw));
      set("eyeLookOutRight", Math.max(0, yaw));
      set("eyeLookUpLeft", Math.max(0, pitch));
      set("eyeLookUpRight", Math.max(0, pitch));
      set("eyeLookDownLeft", Math.max(0, -pitch));
      set("eyeLookDownRight", Math.max(0, -pitch));
    }
    for (const { mesh, dict } of this.morphs) {
      const inf = mesh.morphTargetInfluences!;
      for (const name in dict) {
        const target = acc.get(name) ?? 0;
        const i = dict[name];
        // Only touch shapes we drive; leave any authored default alone.
        if (target > 0 || inf[i] > 0) inf[i] = target;
      }
    }
  }

  protected applyPose(head: THREE.Euler, breathe: number, lean: number): void {
    const q = this.q;
    if (this.head) {
      q.setFromEuler(head);
      this.head.quaternion.copy(this.headRest).multiply(q);
    }
    if (this.neck) {
      q.setFromEuler(new THREE.Euler(head.x * 0.4, head.y * 0.4, head.z * 0.4));
      this.neck.quaternion.copy(this.neckRest).multiply(q);
    }
    if (this.spine) {
      q.setFromEuler(new THREE.Euler(breathe + lean, 0, 0));
      this.spine.quaternion.copy(this.spineRest).multiply(q);
    }
  }

  protected applyGaze(target: THREE.Vector3): void {
    const head = this.head;
    if (!head) return;
    // Direction to the target in head-local space → yaw/pitch, clamped so
    // the eyes never roll into the corners.
    head.updateWorldMatrix(true, false);
    const local = this.tmp.copy(target);
    head.worldToLocal(local);
    const forward = this.tmp2.set(0, 0, 1);
    const dist = local.length() || 1;
    const dir = local.divideScalar(dist);
    // Most rigs face +Z; if the target lands behind, flip so gaze stays sane.
    const sign = dir.dot(forward) < 0 ? -1 : 1;
    this.gazeYaw = THREE.MathUtils.clamp(Math.atan2(dir.x * sign, Math.abs(dir.z)) / 0.6, -1, 1);
    this.gazePitch = THREE.MathUtils.clamp(Math.asin(dir.y) / 0.45, -1, 1);
    const rot = new THREE.Euler(-this.gazePitch * 0.25, this.gazeYaw * 0.35, 0);
    if (this.eyeL) {
      this.q.setFromEuler(rot);
      this.eyeL.quaternion.copy(this.eyeLRest).multiply(this.q);
    }
    if (this.eyeR) {
      this.q.setFromEuler(rot);
      this.eyeR.quaternion.copy(this.eyeRRest).multiply(this.q);
    }
  }

  protected tick(): void {
    // Nothing dynamic beyond bones and morphs.
  }

  dispose(): void {
    this.scene.traverse((o) => {
      const mesh = o as THREE.Mesh;
      if (!mesh.isMesh) return;
      mesh.geometry?.dispose();
      const mats = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
      for (const m of mats) m?.dispose();
    });
  }
}
