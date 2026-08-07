import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";
import { askBrain, setForm, type Form } from "./lib/brain";
import { useVoice } from "./hooks/useVoice";
import { useCamera } from "./hooks/useCamera";
import { useWakeWord } from "./hooks/useWakeWord";
import { Orb } from "./components/Orb";
import { CommandBar } from "./components/CommandBar";
import { Panel } from "./components/Panel";
import { Settings } from "./components/Settings";

export interface Message {
  role: "user" | "margie";
  text: string;
}

function App() {
  const [form, setFormState] = useState<Form>("orb");
  const [messages, setMessages] = useState<Message[]>([]);
  const [interim, setInterim] = useState("");
  const voice = useVoice();
  const camera = useCamera();

  // Latest form + speaking state, read from the audio callback without
  // re-subscribing it.
  const formRef = useRef<Form>(form);
  formRef.current = form;
  // Mute capture while she's thinking or speaking so she doesn't transcribe
  // her own voice or start an overlapping turn.
  const mutedRef = useRef(false);
  mutedRef.current = voice.status === "speaking" || voice.status === "thinking";
  // Set after `wake` exists; lets sendCommand reopen the listening window.
  const continueConvRef = useRef<() => void>(() => {});

  const changeForm = useCallback(async (next: Form) => {
    await setForm(next);
    setFormState(next);
  }, []);

  const sendCommand = useCallback(
    async (text: string, resume = false) => {
      if (!text.trim()) return;
      setInterim("");
      setMessages((m) => [...m, { role: "user", text }]);
      voice.setStatus("thinking");
      try {
        const t0 = performance.now();
        const reply = await askBrain(text, resume);
        const t1 = performance.now();
        setMessages((m) => [...m, { role: "margie", text: reply }]);
        await voice.speak(reply);
        const t2 = performance.now();
        void invoke("dbg_log", {
          line: `${new Date().toISOString()} LATENCY brain=${Math.round(t1 - t0)}ms tts=${Math.round(t2 - t1)}ms`,
        });
      } catch (e) {
        const err = e instanceof Error ? e.message : String(e);
        setMessages((m) => [
          ...m,
          { role: "margie", text: `Something went wrong: ${err}` },
        ]);
        voice.setStatus("idle");
      } finally {
        // Reopen the listening window so a follow-up needs no wake word.
        continueConvRef.current();
      }
    },
    [voice],
  );

  const wake = useWakeWord({
    onWake: () => {
      setInterim("");
      voice.setStatus("listening");
      if (formRef.current === "orb") void changeForm("bar");
    },
    onCommand: sendCommand,
    onPartial: setInterim,
    getMuted: () => mutedRef.current,
  });
  continueConvRef.current = wake.continueConversation;

  // Start always-on wake listening once the UI mounts.
  const wakeStart = wake.start;
  useEffect(() => {
    void wakeStart();
  }, [wakeStart]);

  const toggleWake = useCallback(() => {
    if (wake.state === "off" || wake.state === "error") void wake.start();
    else wake.stop();
  }, [wake]);

  // Escape steps back down a form: settings -> panel -> bar -> orb.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      const back: Form =
        form === "settings" ? "panel" : form === "panel" ? "bar" : "orb";
      void changeForm(back);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [form, changeForm]);

  const wakeHint =
    wake.state === "awake"
      ? interim || "Listening…"
      : wake.state === "asleep"
        ? 'Say "Margie"'
        : wake.state === "error"
          ? wake.error ?? "Voice off"
          : "";

  return (
    <div className={`margie margie--${form}`}>
      {form === "orb" && (
        <Orb
          status={voice.status}
          micLevel={voice.micLevel}
          onOpen={() => void changeForm("bar")}
        />
      )}
      {form === "bar" && (
        <CommandBar
          status={voice.status}
          micLevel={voice.micLevel}
          onSend={sendCommand}
          onToggleMic={toggleWake}
          onExpand={() => void changeForm("panel")}
          onCollapse={() => void changeForm("orb")}
        />
      )}
      {form === "panel" && (
        <Panel
          status={voice.status}
          micLevel={voice.micLevel}
          messages={messages}
          camera={camera}
          onSend={sendCommand}
          onToggleMic={toggleWake}
          onCollapse={() => void changeForm("bar")}
          onSettings={() => void changeForm("settings")}
        />
      )}
      {form === "settings" && (
        <Settings onCollapse={() => void changeForm("panel")} />
      )}

      {form !== "orb" && wakeHint && (
        <div className={`wake-chip wake-chip--${wake.state}`}>
          <span className="wake-dot" />
          {wakeHint}
        </div>
      )}
    </div>
  );
}

export default App;
