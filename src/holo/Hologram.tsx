/**
 * The hologram window (Tauri label `holo`), full-screen on the Looking Glass.
 *
 * Loads the display calibration, builds the quilt/lenticular pipeline, puts
 * Margie's avatar (or a test cube) in front of the rig, and follows the
 * overlay window's state over the holo bus. Nothing here is interactive.
 *
 * Query flags (Rust appends $MARGIE_HOLO_DEBUG to the URL): `debug=center|quilt|cube`,
 * `hud=1`, `calib=placeholder` (render without Bridge; the picture won't align),
 * `demo=1` (cycle through her states with synthetic speech, no overlay needed).
 */
import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import * as THREE from "three";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import "./holo.css";
import { loadCalibration, placeholderCalibration, type CalibrationBundle } from "./calibration";
import { DEFAULT_VIEW, LkgConfig, type ViewSettings } from "./lkgConfig";
import { QuiltRenderer, VIEW_CENTER, VIEW_QUILT, VIEW_SWIZZLED } from "./quilt";
import { loadCharacter, type CharacterBase } from "./character";
import { Caption } from "./caption";
import { subscribeHolo, type HoloStatus } from "../lib/holoBus";

type Phase = "loading" | "ready" | "error";

interface HoloConfig {
  hologram_target_diam?: number;
  hologram_fovy?: number; // degrees
  hologram_depthiness?: number;
  hologram_quilt_size?: number;
  hologram_frame_y?: number; // metres, added to the head height
  hologram_focus_z?: number; // metres in front of the head bone (the face surface)
  hologram_hair_color?: string; // e.g. "#c8c8d0" to grey the avatar's hair
  hologram_env_intensity?: number; // image-based light strength for PBR models
  hologram_light?: number; // multiplier on the key/fill/rim lights (1 = default)
  hologram_lipsync_offset?: number; // seconds; negative moves the mouth earlier
  hologram_caption?: string; // "off" to hide captions
  hologram_filter_mode?: number;
}

function num(v: unknown, fallback: number): number {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isFinite(n) ? n : fallback;
}

/**
 * The holo window has no devtools in front of anyone, so its console errors
 * and warnings (three.js shader failures, WebGL loss…) are copied to
 * ~/.margie/debug.log via the `dbg_log` command.
 */
function forwardConsoleToLog(): void {
  const send = (kind: string, args: unknown[]) => {
    const line = args
      .map((a) =>
        a instanceof Error
          ? `${a.name}: ${a.message}\n${a.stack ?? ""}`
          : typeof a === "string"
            ? a
            : JSON.stringify(a),
      )
      .join(" ")
      .slice(0, 4000);
    void invoke("dbg_log", { line: `${new Date().toISOString()} [holo:${kind}] ${line}` }).catch(() => {});
  };
  for (const kind of ["error", "warn"] as const) {
    const orig = console[kind].bind(console);
    console[kind] = (...args: unknown[]) => {
      orig(...args);
      send(kind, args);
    };
  }
  window.addEventListener("error", (e) => send("uncaught", [e.message, e.filename, e.lineno]));
  window.addEventListener("unhandledrejection", (e) => send("rejection", [e.reason]));
}

export function Hologram() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [phase, setPhase] = useState<Phase>("loading");
  const [message, setMessage] = useState("Finding the Looking Glass…");
  const [hud, setHud] = useState("");

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const params = new URLSearchParams(window.location.search);
    const debug = params.get("debug") ?? "";
    const showHud = params.get("hud") === "1" || debug !== "";
    let disposed = false;
    let cleanup: (() => void) | null = null;
    forwardConsoleToLog();

    (async () => {
      let cfgJson: HoloConfig = {};
      try {
        cfgJson = (await invoke<HoloConfig>("hologram_config")) ?? {};
      } catch {
        // Not inside Tauri; defaults apply.
      }

      let bundle: CalibrationBundle;
      try {
        bundle =
          params.get("calib") === "placeholder" ? placeholderCalibration() : await loadCalibration();
      } catch (e) {
        setPhase("error");
        setMessage(e instanceof Error ? e.message : String(e));
        return;
      }
      if (disposed) return;

      const view: ViewSettings = {
        ...DEFAULT_VIEW,
        targetDiam: num(cfgJson.hologram_target_diam, DEFAULT_VIEW.targetDiam),
        fovy: (num(cfgJson.hologram_fovy, 14) / 180) * Math.PI,
        depthiness: num(cfgJson.hologram_depthiness, DEFAULT_VIEW.depthiness),
        filterMode: num(cfgJson.hologram_filter_mode, DEFAULT_VIEW.filterMode),
      };
      const quiltSize = num(cfgJson.hologram_quilt_size, 0);
      const quilt = quiltSize > 0 ? { ...bundle.quilt, width: quiltSize, height: quiltSize } : bundle.quilt;
      const cfg = new LkgConfig(bundle.calibration, quilt, view);

      // The canvas must map 1:1 onto the panel's physical pixels.
      const dpr = window.devicePixelRatio || 1;
      const renderer = new THREE.WebGLRenderer({
        canvas,
        antialias: false,
        alpha: false,
        powerPreference: "high-performance",
      });
      renderer.setPixelRatio(dpr);
      renderer.setSize(cfg.screenW / dpr, cfg.screenH / dpr, true);
      renderer.outputColorSpace = THREE.SRGBColorSpace;

      const scene = new THREE.Scene();
      scene.background = new THREE.Color(0x000000);
      // Realistic (PBR) avatars need image-based light to look like skin;
      // a neutral room environment plus a warm key and a cool rim does it.
      // Toon (VRM/MToon) models mostly ignore the environment and use the lights.
      const pmrem = new THREE.PMREMGenerator(renderer);
      scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
      scene.environmentIntensity = num(cfgJson.hologram_env_intensity, 0.35);
      pmrem.dispose();
      const lightScale = num(cfgJson.hologram_light, 1.0);
      scene.add(new THREE.HemisphereLight(0xdfefff, 0x1a1418, 0.35 * lightScale));
      const key = new THREE.DirectionalLight(0xfff7ee, 1.1 * lightScale);
      key.position.set(0.5, 1.0, 1.2);
      scene.add(key);
      const fill = new THREE.DirectionalLight(0xcfe8ff, 0.35 * lightScale);
      fill.position.set(-0.9, 0.4, 0.8);
      scene.add(fill);
      const rim = new THREE.DirectionalLight(0x66d9ff, 0.8 * lightScale);
      rim.position.set(-0.6, 0.8, -0.8);
      scene.add(rim);

      const quiltRenderer = new QuiltRenderer(renderer, cfg);
      quiltRenderer.setViewType(
        debug === "center" ? VIEW_CENTER : debug === "quilt" ? VIEW_QUILT : VIEW_SWIZZLED,
      );

      // Subject: the avatar, or a test cube when asked / when no model exists.
      let avatar: CharacterBase | null = null;
      let cube: THREE.Mesh | null = null;
      let note = "";
      if (debug !== "cube") {
        try {
          const bytes = await invoke<ArrayBuffer>("read_avatar");
          avatar = await loadCharacter(bytes, renderer);
        } catch (e) {
          note = `avatar: ${e instanceof Error ? e.message : String(e)}`;
        }
      }
      if (disposed) return;

      const focus = new THREE.Vector3(0, 0, 0);
      if (avatar) {
        scene.add(avatar.root);
        avatar.headPosition(focus);
        focus.y += num(cfgJson.hologram_frame_y, 0);
        // The head bone sits inside the skull; put the focal plane on the face
        // itself so her features are the sharpest thing on the display.
        focus.z += num(cfgJson.hologram_focus_z, 0.09);
        avatar.lipsyncOffset = num(cfgJson.hologram_lipsync_offset, 0);
        if (typeof cfgJson.hologram_hair_color === "string" && cfgJson.hologram_hair_color) {
          avatar.tintHair(cfgJson.hologram_hair_color);
        }
      } else {
        cube = new THREE.Mesh(
          new THREE.BoxGeometry(0.12, 0.12, 0.12),
          new THREE.MeshStandardMaterial({ color: 0x22d3ee, roughness: 0.35 }),
        );
        scene.add(cube);
        const grid = new THREE.GridHelper(0.6, 12, 0x2dd4bf, 0x155e75);
        grid.position.y = -0.12;
        scene.add(grid);
        focus.set(0, 0, 0);
      }
      cfg.view.targetX = focus.x;
      cfg.view.targetY = focus.y;
      cfg.view.targetZ = focus.z;
      quiltRenderer.updateCameras();

      // A soft glow behind her: a cheap depth cue on an otherwise black stage.
      const glow = makeGlow();
      glow.position.set(focus.x, focus.y - 0.05, focus.z - 0.35);
      glow.scale.setScalar(cfg.targetDiam * 2.2);
      scene.add(glow);

      const caption = cfgJson.hologram_caption === "off" ? null : new Caption(cfg.targetDiam * cfg.aspect * 0.94);
      if (caption) {
        caption.mesh.position.set(focus.x, focus.y - cfg.targetDiam * 0.36, focus.z + 0.02);
        scene.add(caption.mesh);
      }

      const viewer = quiltRenderer.viewerPosition();
      let status: HoloStatus = "idle";
      const unsubscribe = subscribeHolo((ev) => {
        if (ev.status) {
          if (showHud && ev.status !== status) console.warn(`bus status ${ev.status}`);
          status = ev.status;
          avatar?.setStatus(ev.status);
          if (ev.status !== "speaking") caption?.hide();
        }
        if (typeof ev.text === "string" && ev.text) {
          caption?.setText(ev.text);
          avatar?.setVisemes(ev.visemes);
        }
        if (typeof ev.level === "number") {
          avatar?.setLevel(ev.level, ev.centroid);
          if (typeof ev.time === "number") avatar?.setAudioTime(ev.time);
          if (typeof ev.progress === "number" && status === "speaking") caption?.setProgress(ev.progress);
        }
      });

      setPhase("ready");
      setMessage("");

      // Demo mode: walk through the states on a timer so framing, expressions
      // and captions can be tuned without a conversation.
      let demoTimer = 0;
      let demoLevelTimer = 0;
      if (params.get("demo") === "1") {
        const script: Array<[HoloStatus, number, string?]> = [
          ["idle", 3000],
          ["listening", 3000],
          ["thinking", 3000],
          [
            "speaking",
            9000,
            "Hello dearie. This is Margie on the Looking Glass, lip-syncing to a made-up voice so you can check the framing and the captions.",
          ],
        ];
        let i = 0;
        const step = () => {
          const [st, ms, text] = script[i % script.length];
          i++;
          console.warn(`demo state ${st}`);
          status = st;
          avatar?.setStatus(st);
          if (st !== "speaking") caption?.hide();
          if (text) caption?.setText(text);
          const t0 = performance.now();
          window.clearInterval(demoLevelTimer);
          demoLevelTimer = window.setInterval(() => {
            const t = (performance.now() - t0) / 1000;
            if (st === "speaking") {
              const level = 0.2 + 0.4 * Math.abs(Math.sin(t * 7.1)) * (0.5 + 0.5 * Math.abs(Math.sin(t * 1.9)));
              avatar?.setLevel(level, 0.4 + 0.25 * Math.sin(t * 2.3));
              caption?.setProgress(Math.min(1, (t * 1000) / ms));
            } else if (st === "listening") {
              avatar?.setLevel(0.3 + 0.3 * Math.abs(Math.sin(t * 3)));
            }
          }, 33);
          demoTimer = window.setTimeout(step, ms);
        };
        step();
      }
      if (showHud) {
        // Debug handle for poking at the pipeline from a devtools console.
        (window as unknown as { __holo: unknown }).__holo = { renderer, scene, quiltRenderer, cfg, avatar };
      }

      const clock = new THREE.Clock();
      let frames = 0;
      let totalFrames = 0;
      let fpsAt = performance.now();
      renderer.setAnimationLoop(() => {
        const dt = Math.min(0.1, clock.getDelta());
        if (cube) {
          cube.rotation.x += dt * 0.7;
          cube.rotation.y += dt * 1.1;
        }
        avatar?.update(dt, viewer);
        caption?.update(dt);
        quiltRenderer.render(scene);
        totalFrames++;
        if (showHud && totalFrames === 30) {
          // One-off pipeline probe (debug builds only): is anything drawn?
          try {
            const gl = renderer.getContext();
            const tw = cfg.tileWidth;
            const th = cfg.tileHeight;
            const buf = new Uint8Array(16 * 16 * 4);
            renderer.readRenderTargetPixels(
              quiltRenderer.target,
              Math.floor(cfg.quilt.columns / 2) * tw + tw / 2 - 8,
              Math.floor(cfg.quilt.rows / 2) * th + th / 2 - 8,
              16,
              16,
              buf,
            );
            let quiltSum = 0;
            for (let i = 0; i < buf.length; i += 4) quiltSum += buf[i] + buf[i + 1] + buf[i + 2];
            console.warn(
              `probe quilt=${quiltSum} glErr=${gl.getError()} passCalls=${renderer.info.render.calls} passTris=${renderer.info.render.triangles} maxTex=${renderer.capabilities.maxTextureSize} dpr=${dpr} drawingBuffer=${gl.drawingBufferWidth}x${gl.drawingBufferHeight}`,
            );
          } catch (e) {
            console.warn("probe failed", e);
          }
        }
        if (showHud) {
          frames++;
          const now = performance.now();
          if (now - fpsAt > 1000) {
            setHud(
              `${frames} fps · ${cfg.quilt.columns}x${cfg.quilt.rows} @ ${cfg.quilt.width} · ` +
                `${bundle.source} · ${bundle.calibration.serial} · ${status}` +
                (note ? ` · ${note}` : ""),
            );
            frames = 0;
            fpsAt = now;
          }
        }
      });

      cleanup = () => {
        window.clearTimeout(demoTimer);
        window.clearInterval(demoLevelTimer);
        renderer.setAnimationLoop(null);
        unsubscribe();
        caption?.dispose();
        avatar?.dispose();
        quiltRenderer.dispose();
        renderer.dispose();
      };
      if (note && !showHud) setHud(note);
    })();

    return () => {
      disposed = true;
      cleanup?.();
    };
  }, []);

  return (
    <div className="holo">
      <canvas ref={canvasRef} className="holo__canvas" />
      {phase !== "ready" && (
        <div className={`holo__overlay holo__overlay--${phase}`}>
          <div className="holo__title">Margie</div>
          <div className="holo__msg">{message}</div>
        </div>
      )}
      {hud && <div className="holo__hud">{hud}</div>}
    </div>
  );
}

/** Radial glow sprite on a plane (additive, no depth write). */
function makeGlow(): THREE.Mesh {
  const c = document.createElement("canvas");
  c.width = c.height = 256;
  const ctx = c.getContext("2d")!;
  const g = ctx.createRadialGradient(128, 128, 0, 128, 128, 128);
  g.addColorStop(0, "rgba(34, 211, 238, 0.35)");
  g.addColorStop(0.5, "rgba(34, 211, 238, 0.08)");
  g.addColorStop(1, "rgba(0, 0, 0, 0)");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 256, 256);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  const mesh = new THREE.Mesh(
    new THREE.PlaneGeometry(1, 1),
    new THREE.MeshBasicMaterial({
      map: tex,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    }),
  );
  mesh.frustumCulled = false;
  mesh.renderOrder = -1;
  return mesh;
}
