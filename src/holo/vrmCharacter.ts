/**
 * VRM adapter (VRoid and any VRM 0.x / 1.0 model) for `CharacterBase`:
 * expressions via the VRM expression manager, gaze via VRM lookAt, posture
 * on the normalised humanoid bones, spring bones through `vrm.update`.
 */
import * as THREE from "three";
import type { GLTF } from "three/addons/loaders/GLTFLoader.js";
import { VRMUtils, type VRM } from "@pixiv/three-vrm";
import { CharacterBase, type ExprWeights } from "./character";

export class VrmCharacter extends CharacterBase {
  private gazeTarget = new THREE.Object3D();
  private head: THREE.Object3D | null;
  private neck: THREE.Object3D | null;
  private spine: THREE.Object3D | null;
  private chest: THREE.Object3D | null;
  private headRest = new THREE.Quaternion();
  private neckRest = new THREE.Quaternion();
  private spineRest = new THREE.Quaternion();
  private chestRest = new THREE.Quaternion();
  private q = new THREE.Quaternion();

  private constructor(readonly vrm: VRM) {
    super(vrm.scene);
    this.root.add(this.gazeTarget);
    const h = vrm.humanoid;
    this.head = h?.getNormalizedBoneNode("head") ?? null;
    this.neck = h?.getNormalizedBoneNode("neck") ?? null;
    this.spine = h?.getNormalizedBoneNode("spine") ?? null;
    this.chest =
      h?.getNormalizedBoneNode("chest") ?? h?.getNormalizedBoneNode("upperChest") ?? null;
    if (this.head) this.headRest.copy(this.head.quaternion);
    if (this.neck) this.neckRest.copy(this.neck.quaternion);
    if (this.spine) this.spineRest.copy(this.spine.quaternion);
    if (this.chest) this.chestRest.copy(this.chest.quaternion);
    if (vrm.lookAt) {
      vrm.lookAt.target = this.gazeTarget;
      vrm.lookAt.autoUpdate = true;
    }
  }

  static fromGltf(gltf: GLTF): VrmCharacter {
    const vrm = gltf.userData.vrm as VRM;
    VRMUtils.removeUnnecessaryVertices(gltf.scene);
    VRMUtils.combineSkeletons(gltf.scene);
    if (vrm.meta.metaVersion === "0") VRMUtils.rotateVRM0(vrm); // VRM 0.x faces -Z
    return new VrmCharacter(vrm);
  }

  headPosition(out = new THREE.Vector3()): THREE.Vector3 {
    this.root.updateMatrixWorld(true);
    if (this.head) return this.head.getWorldPosition(out);
    return out.set(0, 1.4, 0);
  }

  protected applyExpressions(w: ExprWeights): void {
    const em = this.vrm.expressionManager;
    if (!em) return;
    for (const [name, v] of Object.entries(w)) em.setValue(name, v);
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
    if (this.chest) {
      q.setFromEuler(new THREE.Euler(breathe, 0, 0));
      this.chest.quaternion.copy(this.chestRest).multiply(q);
    }
    if (this.spine) {
      q.setFromEuler(new THREE.Euler(lean + (this.chest ? 0 : breathe), 0, 0));
      this.spine.quaternion.copy(this.spineRest).multiply(q);
    }
  }

  protected applyGaze(target: THREE.Vector3): void {
    this.gazeTarget.position.copy(target);
  }

  protected tick(dt: number): void {
    this.vrm.update(dt);
  }

  dispose(): void {
    VRMUtils.deepDispose(this.vrm.scene);
  }
}
