import type { CSSProperties } from "react";
import type { VoiceStatus } from "../hooks/useVoice";

interface OrbProps {
  status: VoiceStatus;
  micLevel: number;
  onOpen?: () => void;
  small?: boolean;
}

/** Margie's resting form: a draggable, animated orb. Click to open the bar. */
export function Orb({ status, micLevel, onOpen, small }: OrbProps) {
  return (
    <div
      className={`orb-wrap ${small ? "orb-wrap--small" : ""}`}
      data-tauri-drag-region
    >
      <button
        type="button"
        className={`orb orb--${status}`}
        style={{ "--level": micLevel } as CSSProperties}
        onClick={onOpen}
        aria-label="Open Margie"
        title="Margie"
      >
        <span className="orb__core" />
      </button>
    </div>
  );
}
