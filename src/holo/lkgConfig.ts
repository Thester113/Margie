/**
 * Looking Glass display configuration: the device calibration plus the quilt
 * and camera settings, with the computed values the lenticular shader and
 * the multi-view camera rig need.
 *
 * Derived from `LookingGlassConfig` in Looking Glass Factory's
 * looking-glass-webxr (Apache-2.0), trimmed to what Margie uses and without
 * the WebXR/popup machinery (which can't run inside a Tauri webview).
 */

export interface Value {
  value: number;
}

export interface SubpixelCell {
  ROffsetX: number;
  ROffsetY: number;
  GOffsetX: number;
  GOffsetY: number;
  BOffsetX: number;
  BOffsetY: number;
}

/** Calibration as Bridge reports it (every scalar wrapped in `{value}`). */
export interface Calibration {
  configVersion?: string;
  pitch: Value;
  slope: Value;
  center: Value;
  viewCone: Value;
  invView: Value;
  verticalAngle: Value;
  DPI: Value;
  screenW: Value;
  screenH: Value;
  flipImageX: Value;
  flipImageY: Value;
  flipSubp: Value;
  serial: string;
  subpixelCells?: SubpixelCell[];
  CellPatternMode?: Value;
}

export interface QuiltSettings {
  columns: number;
  rows: number;
  width: number;
  height: number;
}

export interface ViewSettings {
  /** Focal point of the camera rig (world units). */
  targetX: number;
  targetY: number;
  targetZ: number;
  /** Diameter of the volume in focus; bigger = smaller subject. */
  targetDiam: number;
  /** Vertical field of view in radians. */
  fovy: number;
  /** Multiplies the calibration's view cone: more = deeper, more ghosting. */
  depthiness: number;
  trackballX: number;
  trackballY: number;
  /** Shader view filtering: 0 nearest, 1 lerp (default), 2/3 gaussian. */
  filterMode: number;
  gaussianSigma: number;
  subpixelMode: number;
}

export const DEFAULT_VIEW: ViewSettings = {
  targetX: 0,
  targetY: 0,
  targetZ: 0,
  targetDiam: 0.55,
  fovy: (14 / 180) * Math.PI,
  depthiness: 1.0,
  trackballX: 0,
  trackballY: 0,
  filterMode: 1,
  gaussianSigma: 0.01,
  subpixelMode: 1,
};

/** Quilt layout per product line, keyed by calibration serial prefix. */
const QUILT_BY_SERIAL: Array<[string, QuiltSettings]> = [
  ["LKG-E", { columns: 11, rows: 6, width: 4092, height: 4092 }], // Go
  ["LKG-P", { columns: 8, rows: 6, width: 3360, height: 3360 }], // Portrait
  ["LKG-F", { columns: 8, rows: 6, width: 3360, height: 3360 }], // Kiosk
  ["LKG-H", { columns: 11, rows: 6, width: 5995, height: 6000 }], // 16" OLED portrait
  ["LKG-J", { columns: 7, rows: 7, width: 5999, height: 5999 }], // 16" OLED landscape
  ["LKG-K", { columns: 11, rows: 6, width: 8184, height: 8184 }], // 32" portrait
  ["LKG-L", { columns: 7, rows: 7, width: 8190, height: 8190 }], // 32" landscape
  ["LKG-D", { columns: 8, rows: 9, width: 8192, height: 8192 }], // 65"
  ["LKG-2K", { columns: 5, rows: 9, width: 4096, height: 4096 }],
  ["LKG-4K", { columns: 5, rows: 9, width: 4096, height: 4096 }],
  ["LKG-8K", { columns: 5, rows: 9, width: 8192, height: 8192 }],
  ["LKG-A", { columns: 5, rows: 9, width: 4096, height: 4096 }],
  ["LKG-B", { columns: 5, rows: 9, width: 8192, height: 8192 }],
];

export function defaultQuiltFor(serial: string): QuiltSettings {
  for (const [prefix, q] of QUILT_BY_SERIAL) {
    if (serial.startsWith(prefix)) return { ...q };
  }
  return { columns: 11, rows: 6, width: 4092, height: 4092 };
}

/**
 * The shape `holoplay-core`'s `Shader(cfg)` reads. Keep the getter names —
 * the shader generator reaches into them by name.
 */
export class LkgConfig {
  constructor(
    public calibration: Calibration,
    public quilt: QuiltSettings,
    public view: ViewSettings = { ...DEFAULT_VIEW },
  ) {
    // Bridge omits the optional fields; the shader generator reads them
    // unguarded (`calibration.subpixelCells.length`).
    this.calibration = {
      ...calibration,
      subpixelCells: calibration.subpixelCells ?? [],
      CellPatternMode: calibration.CellPatternMode ?? { value: 0 },
    };
  }

  // ---- quilt geometry -----------------------------------------------------

  get quiltWidth(): number {
    return this.quilt.columns;
  }
  get quiltHeight(): number {
    return this.quilt.rows;
  }
  get numViews(): number {
    return this.quilt.columns * this.quilt.rows;
  }
  get framebufferWidth(): number {
    return this.quilt.width;
  }
  get framebufferHeight(): number {
    return this.quilt.height;
  }
  get tileWidth(): number {
    return Math.round(this.quilt.width / this.quilt.columns);
  }
  get tileHeight(): number {
    return Math.round(this.quilt.height / this.quilt.rows);
  }

  // ---- display ------------------------------------------------------------

  get screenW(): number {
    return this.calibration.screenW.value;
  }
  get screenH(): number {
    return this.calibration.screenH.value;
  }
  /** Display aspect (width / height): 0.5625 on the portrait Go. */
  get aspect(): number {
    return this.screenW / this.screenH;
  }

  // ---- lenticular parameters (as the official shader expects them) -------

  get pitch(): number {
    const c = this.calibration;
    return (
      ((c.pitch.value * c.screenW.value) / c.DPI.value) *
      Math.cos(Math.atan(1.0 / c.slope.value))
    );
  }
  get tilt(): number {
    const c = this.calibration;
    return (
      (c.screenH.value / (c.screenW.value * c.slope.value)) *
      (c.flipImageX.value ? -1 : 1)
    );
  }
  get subp(): number {
    const c = this.calibration;
    return (1 / (c.screenW.value * 3)) * (c.flipImageX.value ? -1 : 1);
  }
  /** View cone in radians, scaled by depthiness. */
  get viewCone(): number {
    return ((this.calibration.viewCone.value * this.view.depthiness) / 180) * Math.PI;
  }
  /** Subpixel offsets normalised to the screen, 6 floats per cell. */
  get subpixelCells(): Float32Array {
    const cells = this.calibration.subpixelCells ?? [];
    const out = new Float32Array(6 * cells.length);
    const w = this.screenW;
    const h = this.screenH;
    cells.forEach((cell, i) => {
      out[i * 6 + 0] = cell.ROffsetX / w;
      out[i * 6 + 1] = cell.ROffsetY / h;
      out[i * 6 + 2] = cell.GOffsetX / w;
      out[i * 6 + 3] = cell.GOffsetY / h;
      out[i * 6 + 4] = cell.BOffsetX / w;
      out[i * 6 + 5] = cell.BOffsetY / h;
    });
    return out;
  }
  get subpixelMode(): number {
    return this.view.subpixelMode;
  }
  get filterMode(): number {
    return this.view.filterMode;
  }
  get gaussianSigma(): number {
    return this.view.gaussianSigma;
  }

  // ---- camera rig ---------------------------------------------------------

  get fovy(): number {
    return this.view.fovy;
  }
  get targetDiam(): number {
    return this.view.targetDiam;
  }
  /** Distance from the rig's centre camera to the focal point. */
  get focalDistance(): number {
    return (0.5 * this.view.targetDiam) / Math.tan(0.5 * this.view.fovy);
  }
}
