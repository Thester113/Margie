import { useCallback, useEffect, useState } from "react";
import "./App.css";
import { askBrain, setForm, type Form } from "./lib/brain";
import { useVoice } from "./hooks/useVoice";
import { useCamera } from "./hooks/useCamera";
import { Orb } from "./components/Orb";
import { CommandBar } from "./components/CommandBar";
import { Panel } from "./components/Panel";

export interface Message {
  role: "user" | "margie";
  text: string;
}

function App() {
  const [form, setFormState] = useState<Form>("orb");
  const [messages, setMessages] = useState<Message[]>([]);
  const voice = useVoice();
  const camera = useCamera();

  const changeForm = useCallback(async (next: Form) => {
    await setForm(next);
    setFormState(next);
  }, []);

  const toggleMic = useCallback(() => {
    if (voice.status === "listening") {
      voice.stopListening();
    } else {
      void voice.startListening();
    }
  }, [voice]);

  const sendCommand = useCallback(
    async (text: string) => {
      if (!text.trim()) return;
      setMessages((m) => [...m, { role: "user", text }]);
      voice.setStatus("thinking");
      try {
        const reply = await askBrain(text);
        setMessages((m) => [...m, { role: "margie", text: reply }]);
        await voice.speak(reply);
      } catch (e) {
        const err = e instanceof Error ? e.message : String(e);
        setMessages((m) => [
          ...m,
          { role: "margie", text: `Something went wrong: ${err}` },
        ]);
        voice.setStatus("idle");
      }
    },
    [voice],
  );

  // Escape steps back down a form: panel -> bar -> orb.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      void changeForm(form === "panel" ? "bar" : "orb");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [form, changeForm]);

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
          onToggleMic={toggleMic}
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
          onToggleMic={toggleMic}
          onCollapse={() => void changeForm("bar")}
        />
      )}
    </div>
  );
}

export default App;
