/**
 * Captions on the hologram: what Margie is saying, as a text plane sitting
 * exactly on the focal plane (zero depth) so it stays crisp on a lenticular
 * display. Long replies are shown in chunks that follow the speech progress
 * the overlay window reports.
 */
import * as THREE from "three";

const CANVAS_W = 1024;
const CANVAS_H = 320;
const FONT = "500 46px -apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif";
const LINE_H = 60;
const MAX_LINES = 4;
const PAD = 28;
/** Rough characters per chunk so a chunk fits MAX_LINES at FONT size. */
const CHUNK_CHARS = 150;

export class Caption {
  readonly mesh: THREE.Mesh;
  private canvas = document.createElement("canvas");
  private ctx: CanvasRenderingContext2D;
  private texture: THREE.CanvasTexture;
  private material: THREE.MeshBasicMaterial;
  private chunks: string[] = [];
  private chunkIndex = -1;
  private targetOpacity = 0;
  private hideAt = 0;

  constructor(width: number) {
    this.canvas.width = CANVAS_W;
    this.canvas.height = CANVAS_H;
    this.ctx = this.canvas.getContext("2d")!;
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.colorSpace = THREE.SRGBColorSpace;
    // Drawn last and without depth testing so the body can't hide it; it
    // still sits (almost) on the focal plane, which keeps it sharp.
    this.material = new THREE.MeshBasicMaterial({
      map: this.texture,
      transparent: true,
      opacity: 0,
      depthWrite: false,
      depthTest: false,
      side: THREE.DoubleSide,
    });
    const height = (width * CANVAS_H) / CANVAS_W;
    this.mesh = new THREE.Mesh(new THREE.PlaneGeometry(width, height), this.material);
    this.mesh.renderOrder = 100;
    this.mesh.frustumCulled = false;
    this.mesh.visible = false;
  }

  /** New utterance: chunk it and show the first part. */
  setText(text: string): void {
    this.chunks = chunk(text.trim(), CHUNK_CHARS);
    this.chunkIndex = -1;
    this.hideAt = 0;
    this.setProgress(0);
    this.targetOpacity = this.chunks.length ? 1 : 0;
  }

  /** 0..1 through the utterance: picks the chunk to display. */
  setProgress(p: number): void {
    if (!this.chunks.length) return;
    const idx = Math.min(this.chunks.length - 1, Math.max(0, Math.floor(p * this.chunks.length)));
    if (idx !== this.chunkIndex) {
      this.chunkIndex = idx;
      this.draw(this.chunks[idx]);
    }
  }

  /** Fade out after a short linger (called when she stops speaking). */
  hide(delayMs = 1200): void {
    this.hideAt = performance.now() + delayMs;
  }

  update(dt: number): void {
    if (this.hideAt && performance.now() >= this.hideAt) {
      this.targetOpacity = 0;
      this.hideAt = 0;
    }
    const cur = this.material.opacity;
    const next = cur + (this.targetOpacity - cur) * Math.min(1, dt * 6);
    this.material.opacity = next;
    this.mesh.visible = next > 0.01;
  }

  private draw(text: string): void {
    const c = this.ctx;
    c.clearRect(0, 0, CANVAS_W, CANVAS_H);
    c.font = FONT;
    c.textBaseline = "top";
    const lines = wrap(c, text, CANVAS_W - PAD * 2).slice(0, MAX_LINES);
    const blockH = lines.length * LINE_H;
    const top = Math.max(PAD, (CANVAS_H - blockH) / 2);
    // Soft dark plate behind the text so it reads over any background.
    c.fillStyle = "rgba(0, 0, 0, 0.55)";
    roundRect(c, PAD / 2, top - 16, CANVAS_W - PAD, blockH + 32, 24);
    c.fill();
    c.fillStyle = "#e8fbff";
    c.textAlign = "center";
    lines.forEach((line, i) => c.fillText(line, CANVAS_W / 2, top + i * LINE_H));
    this.texture.needsUpdate = true;
  }

  dispose(): void {
    this.texture.dispose();
    this.material.dispose();
    this.mesh.geometry.dispose();
  }
}

function wrap(c: CanvasRenderingContext2D, text: string, maxW: number): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let line = "";
  for (const w of words) {
    const trial = line ? `${line} ${w}` : w;
    if (c.measureText(trial).width <= maxW || !line) {
      line = trial;
    } else {
      lines.push(line);
      line = w;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/** Split on sentence ends, then merge/split so chunks are ~max chars. */
function chunk(text: string, max: number): string[] {
  if (!text) return [];
  const sentences = text.match(/[^.!?]+[.!?]+["')\]]?\s*|[^.!?]+$/g) ?? [text];
  const out: string[] = [];
  let cur = "";
  for (const s of sentences) {
    const piece = s.trim();
    if (!piece) continue;
    if (piece.length > max) {
      if (cur) out.push(cur);
      cur = "";
      const words = piece.split(/\s+/);
      let part = "";
      for (const w of words) {
        if ((part + " " + w).trim().length > max && part) {
          out.push(part);
          part = w;
        } else {
          part = (part + " " + w).trim();
        }
      }
      if (part) cur = part;
      continue;
    }
    if ((cur + " " + piece).trim().length > max && cur) {
      out.push(cur);
      cur = piece;
    } else {
      cur = (cur + " " + piece).trim();
    }
  }
  if (cur) out.push(cur);
  return out;
}

function roundRect(
  c: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
): void {
  c.beginPath();
  c.moveTo(x + r, y);
  c.arcTo(x + w, y, x + w, y + h, r);
  c.arcTo(x + w, y + h, x, y + h, r);
  c.arcTo(x, y + h, x, y, r);
  c.arcTo(x, y, x + w, y, r);
  c.closePath();
}
