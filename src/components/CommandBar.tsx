import { useState } from "react";
import type { VoiceStatus } from "../hooks/useVoice";
import { Orb } from "./Orb";

interface CommandBarProps {
  status: VoiceStatus;
  micLevel: number;
  onSend: (text: string) => void;
  onToggleMic: () => void;
  onExpand: () => void;
  onCollapse: () => void;
}

const STATUS_HINT: Record<VoiceStatus, string> = {
  idle: "Ask Margie anything…",
  listening: "Listening…",
  thinking: "Thinking…",
  speaking: "Speaking…",
};

/** Compact one-line form for firing off quick commands. */
export function CommandBar({
  status,
  micLevel,
  onSend,
  onToggleMic,
  onExpand,
  onCollapse,
}: CommandBarProps) {
  const [text, setText] = useState("");

  const submit = () => {
    onSend(text);
    setText("");
  };

  return (
    <div className="bar" data-tauri-drag-region>
      <Orb status={status} micLevel={micLevel} onOpen={onCollapse} small />
      <input
        className="bar__input"
        value={text}
        autoFocus
        placeholder={STATUS_HINT[status]}
        onChange={(e) => setText(e.currentTarget.value)}
        onKeyDown={(e) => e.key === "Enter" && submit()}
      />
      <button
        type="button"
        className={`icon-btn ${status === "listening" ? "icon-btn--active" : ""}`}
        onClick={onToggleMic}
        title="Toggle microphone"
      >
        🎙
      </button>
      <button
        type="button"
        className="icon-btn"
        onClick={onExpand}
        title="Expand to panel"
      >
        ⤢
      </button>
    </div>
  );
}
