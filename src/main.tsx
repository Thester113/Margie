import ReactDOM from "react-dom/client";
import App from "./App";

// No StrictMode: Margie owns singleton hardware resources (mic capture,
// AudioContext, whisper-server). StrictMode's dev double-mount spins those
// up twice, corrupting captured audio and doubling STT load.
ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <App />,
);
