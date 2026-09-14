/**
 * Quilt renderer: draws the scene from N horizontally spaced cameras into one
 * big "quilt" texture (a grid of views), then runs Looking Glass's lenticular
 * shader over it to produce the image the display's lens array turns into a
 * hologram.
 *
 * Camera maths follows `LookingGlassXRDevice.onFrameStart` in
 * looking-glass-webxr (Apache-2.0): every view shares one focal plane, sits
 * on a baseline in front of it and uses an off-axis (sheared) projection so
 * the focal plane stays put across views.
 */
import * as THREE from "three";
import { Shader } from "holoplay-core";
import type { LkgConfig } from "./lkgConfig";

/** What the swizzle pass outputs. 0 is the real thing; 1/2 are for debugging. */
export type ViewType = 0 | 1 | 2;
export const VIEW_SWIZZLED: ViewType = 0;
export const VIEW_CENTER: ViewType = 1;
export const VIEW_QUILT: ViewType = 2;

const NEAR = 0.05;
const FAR = 50;

// three only draws non-indexed geometry that has a `position` attribute (its
// draw count comes from it), so the quad's corners must use that name.
const VERTEX = `
in vec3 position;
out vec2 v_texcoord;
void main() {
  gl_Position = vec4(position.xy * 2.0 - 1.0, 0.0, 1.0);
  v_texcoord = position.xy;
}
`;

export class QuiltRenderer {
  readonly cameras: THREE.PerspectiveCamera[] = [];
  readonly arrayCamera: THREE.ArrayCamera;
  readonly target: THREE.WebGLRenderTarget;
  private passScene = new THREE.Scene();
  private passCamera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  private material: THREE.RawShaderMaterial;
  private rig = new THREE.Matrix4();

  constructor(
    private renderer: THREE.WebGLRenderer,
    readonly cfg: LkgConfig,
  ) {
    const n = cfg.numViews;
    for (let i = 0; i < n; i++) {
      const cam = new THREE.PerspectiveCamera();
      cam.matrixAutoUpdate = false;
      cam.viewport = new THREE.Vector4();
      this.cameras.push(cam);
    }
    this.arrayCamera = new THREE.ArrayCamera(this.cameras);

    this.target = new THREE.WebGLRenderTarget(cfg.framebufferWidth, cfg.framebufferHeight, {
      depthBuffer: true,
      stencilBuffer: false,
      minFilter: THREE.LinearFilter,
      magFilter: THREE.LinearFilter,
      generateMipmaps: false,
      colorSpace: THREE.SRGBColorSpace,
    });

    this.material = new THREE.RawShaderMaterial({
      glslVersion: THREE.GLSL3,
      vertexShader: VERTEX,
      fragmentShader: stripVersion(Shader(cfg)),
      uniforms: {
        u_texture: { value: this.target.texture },
        u_viewType: { value: VIEW_SWIZZLED },
        subpixelData: { value: padTo(cfg.subpixelCells, 60) },
      },
      depthTest: false,
      depthWrite: false,
    });
    const geom = new THREE.BufferGeometry();
    geom.setAttribute(
      "position",
      new THREE.BufferAttribute(
        new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0]),
        3,
      ),
    );
    const quad = new THREE.Mesh(geom, this.material);
    quad.frustumCulled = false;
    this.passScene.add(quad);

    this.updateCameras();
  }

  setViewType(v: ViewType): void {
    this.material.uniforms.u_viewType.value = v;
  }

  /** Recompute every view's pose and projection from `cfg.view`. */
  updateCameras(): void {
    const cfg = this.cfg;
    const v = cfg.view;
    const n = cfg.numViews;
    const tanHalfFovy = Math.tan(0.5 * cfg.fovy);
    const focalDistance = cfg.focalDistance;
    // Clip planes are measured from the focal plane so depth settings don't
    // depend on how far the rig sits.
    const clipPlaneBias = focalDistance - cfg.targetDiam;
    const near = Math.max(clipPlaneBias + NEAR, 0.01);
    const far = clipPlaneBias + FAR;
    const halfY = near * tanHalfFovy;
    const halfX = cfg.aspect * halfY;

    // Rig: at the focal point, rotated by the trackball, pushed back along +Z.
    const rig = this.rig;
    rig.makeTranslation(v.targetX, v.targetY, v.targetZ);
    rig.multiply(new THREE.Matrix4().makeRotationY(v.trackballX));
    rig.multiply(new THREE.Matrix4().makeRotationX(-v.trackballY));
    rig.multiply(new THREE.Matrix4().makeTranslation(0, 0, focalDistance));

    const tileW = cfg.framebufferWidth / cfg.quiltWidth;
    const tileH = cfg.framebufferHeight / cfg.quiltHeight;
    const offset = new THREE.Matrix4();

    for (let i = 0; i < n; i++) {
      const cam = this.cameras[i];
      const frac = (i + 0.5) / n - 0.5; // -0.5 … 0.5 across the view cone
      const tanAngle = Math.tan(cfg.viewCone * frac);
      const baseline = focalDistance * tanAngle;

      offset.makeTranslation(baseline, 0, 0);
      cam.matrixWorld.multiplyMatrices(rig, offset);
      cam.matrix.copy(cam.matrixWorld); // no parent: local == world
      cam.matrixWorldInverse.copy(cam.matrixWorld).invert();
      cam.matrixWorld.decompose(cam.position, cam.quaternion, cam.scale);

      const mid = near * -tanAngle; // shear so the focal plane is shared
      cam.projectionMatrix.makePerspective(
        mid - halfX,
        mid + halfX,
        halfY,
        -halfY,
        near,
        far,
      );
      cam.projectionMatrixInverse.copy(cam.projectionMatrix).invert();

      const col = i % cfg.quiltWidth;
      const row = Math.floor(i / cfg.quiltWidth);
      cam.viewport!.set(col * tileW, row * tileH, tileW, tileH);
    }

    // The array camera itself only drives frustum culling: use the centre view.
    const centre = this.cameras[Math.floor(n / 2)];
    this.arrayCamera.matrixAutoUpdate = false;
    this.arrayCamera.matrix.copy(centre.matrixWorld);
    this.arrayCamera.matrixWorld.copy(centre.matrixWorld);
    this.arrayCamera.matrixWorldInverse.copy(centre.matrixWorldInverse);
    this.arrayCamera.projectionMatrix.copy(centre.projectionMatrix);
    this.arrayCamera.projectionMatrixInverse.copy(centre.projectionMatrixInverse);
  }

  /** World position of the centre camera (where the viewer "is"). */
  viewerPosition(out = new THREE.Vector3()): THREE.Vector3 {
    return out.setFromMatrixPosition(this.cameras[Math.floor(this.cameras.length / 2)].matrixWorld);
  }

  /** Render `scene` into the quilt, then swizzle it onto the canvas. */
  render(scene: THREE.Scene): void {
    const r = this.renderer;
    r.setRenderTarget(this.target);
    r.setClearColor(0x000000, 1);
    r.clear(true, true, false);
    r.render(scene, this.arrayCamera);
    r.setRenderTarget(null);
    r.render(this.passScene, this.passCamera);
  }

  dispose(): void {
    this.target.dispose();
    this.material.dispose();
  }
}

/** three prepends `#version` itself when glslVersion is set. */
function stripVersion(src: string): string {
  return src.replace(/^\s*#version[^\n]*\n/, "");
}

function padTo(arr: Float32Array, len: number): Float32Array {
  if (arr.length >= len) return arr.slice(0, len);
  const out = new Float32Array(len);
  out.set(arr);
  return out;
}
