import { useEffect, useRef, useState } from "react";
import type { Message } from "../App";
import type { VoiceStatus } from "../hooks/useVoice";
import type { useCamera } from "../hooks/useCamera";

interface PanelProps {
  status: VoiceStatus;
  micLevel: number;
  messages: Message[];
  camera: ReturnType<typeof useCamera>;
  onSend: (text: string) => void;
  onToggleMic: () => void;
  onCollapse: () => void;
  onSettings: () => void;
}

/** Full conversation form: message history, camera preview, input. */
export function Panel({
  status,
  messages,
  camera,
  onSend,
  onToggleMic,
  onCollapse,
  onSettings,
}: PanelProps) {
  const [text, setText] = useState("");
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
  }, [messages]);

  const submit = () => {
    onSend(text);
    setText("");
  };

  return (
    <div className="panel">
      <header className="panel__header" data-tauri-drag-region>
        <span className="panel__title">Margie</span>
        <span className={`panel__status panel__status--${status}`}>
          {status}
        </span>
        <button
          type="button"
          className="icon-btn"
          onClick={() => (camera.active ? camera.stop() : void camera.start())}
          title={camera.active ? "Stop camera" : "Let Margie see you"}
        >
          {camera.active ? "📷✓" : "📷"}
        </button>
        <button
          type="button"
          className="icon-btn"
          onClick={onSettings}
          title="Settings"
        >
          ⚙
        </button>
        <button
          type="button"
          className="icon-btn"
          onClick={onCollapse}
          title="Collapse to bar"
        >
          ⤡
        </button>
      </header>

      <div
        className={`panel__camera ${camera.active ? "panel__camera--active" : ""}`}
      >
        <video ref={camera.videoRef} muted playsInline />
        {camera.error && <p className="panel__camera-error">{camera.error}</p>}
      </div>

      <div className="panel__messages" ref={scrollRef}>
        {messages.length === 0 && (
          <p className="panel__empty">
            Hi, I'm Margie. Ask me something, or give me a task for Claude
            Code.
          </p>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`msg msg--${m.role}`}>
            {m.text}
          </div>
        ))}
      </div>

      <footer className="panel__footer">
        <button
          type="button"
          className={`icon-btn ${status === "listening" ? "icon-btn--active" : ""}`}
          onClick={onToggleMic}
          title="Toggle microphone"
        >
          🎙
        </button>
        <input
          className="panel__input"
          value={text}
          autoFocus
          placeholder="Message Margie…"
          onChange={(e) => setText(e.currentTarget.value)}
          onKeyDown={(e) => e.key === "Enter" && submit()}
        />
        <button type="button" className="icon-btn" onClick={submit} title="Send">
          ➤
        </button>
      </footer>
    </div>
  );
}
