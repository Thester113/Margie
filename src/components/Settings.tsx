import { useEffect, useState } from "react";
import {
  readSettings,
  writeSettings,
  type Settings as SettingsData,
} from "../lib/settings";

interface SettingsProps {
  onCollapse: () => void;
}

const EMPTY: SettingsData = {
  elevenlabs_api_key: "",
  openai_api_key: "",
  voice: "",
};

type SaveState = "loading" | "idle" | "saving" | "saved" | "error";

/** Settings form: view and persist the ~/.margie/config.json values. */
export function Settings({ onCollapse }: SettingsProps) {
  const [values, setValues] = useState<SettingsData>(EMPTY);
  const [state, setState] = useState<SaveState>("loading");
  const [error, setError] = useState("");

  useEffect(() => {
    readSettings()
      .then((s) => {
        setValues({ ...EMPTY, ...s });
        setState("idle");
      })
      .catch((e) => {
        setError(e instanceof Error ? e.message : String(e));
        setState("error");
      });
  }, []);

  const update =
    (field: keyof SettingsData) =>
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const v = e.currentTarget.value;
      setValues((prev) => ({ ...prev, [field]: v }));
      setState("idle");
    };

  const save = async () => {
    setState("saving");
    try {
      await writeSettings(values);
      setState("saved");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setState("error");
    }
  };

  // Whichever key is set decides which cloud voice Margie uses.
  const provider = values.elevenlabs_api_key
    ? "ElevenLabs"
    : values.openai_api_key
      ? "OpenAI"
      : "System voice";

  return (
    <div className="panel settings">
      <header className="panel__header" data-tauri-drag-region>
        <span className="panel__title">Settings</span>
        <span className="panel__status">{provider}</span>
        <button
          type="button"
          className="icon-btn"
          onClick={onCollapse}
          title="Back to conversation"
        >
          ⤡
        </button>
      </header>

      <div className="settings__body">
        <label className="settings__field">
          <span className="settings__label">ElevenLabs API key</span>
          <input
            className="panel__input"
            type="password"
            autoComplete="off"
            spellCheck={false}
            placeholder="Preferred — natural cloud voice"
            value={values.elevenlabs_api_key}
            onChange={update("elevenlabs_api_key")}
          />
        </label>

        <label className="settings__field">
          <span className="settings__label">OpenAI API key</span>
          <input
            className="panel__input"
            type="password"
            autoComplete="off"
            spellCheck={false}
            placeholder="Fallback cloud voice"
            value={values.openai_api_key}
            onChange={update("openai_api_key")}
          />
        </label>

        <label className="settings__field">
          <span className="settings__label">Voice</span>
          <input
            className="panel__input"
            autoComplete="off"
            spellCheck={false}
            placeholder="Voice ID or name (leave blank for default)"
            value={values.voice}
            onChange={update("voice")}
          />
        </label>

        <p className="settings__note">
          Stored in <code>~/.margie/config.json</code>. Matching environment
          variables override these while Margie runs.
        </p>
      </div>

      <footer className="panel__footer settings__footer">
        {state === "error" && (
          <span className="settings__msg settings__msg--error">{error}</span>
        )}
        {state === "saved" && (
          <span className="settings__msg settings__msg--ok">Saved</span>
        )}
        <button
          type="button"
          className="settings__save"
          onClick={save}
          disabled={state === "loading" || state === "saving"}
        >
          {state === "saving" ? "Saving…" : "Save"}
        </button>
      </footer>
    </div>
  );
}
