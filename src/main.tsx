import { lazy, Suspense } from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

// One bundle, two windows: the overlay (`main`) mounts the assistant UI; the
// Looking Glass window (`holo`, opened by Rust with ?view=holo) mounts only the
// hologram renderer. The renderer (three.js + VRM) is code-split so the
// overlay never loads it.
const Hologram = lazy(() =>
  import("./holo/Hologram").then((m) => ({ default: m.Hologram })),
);
const view = new URLSearchParams(window.location.search).get("view");

// No StrictMode: Margie owns singleton hardware resources (mic capture,
// AudioContext, whisper-server). StrictMode's dev double-mount spins those
// up twice, corrupting captured audio and doubling STT load.
ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  view === "holo" ? (
    <Suspense fallback={null}>
      <Hologram />
    </Suspense>
  ) : (
    <App />
  ),
);
