mod brain;
mod stt;

use tauri::{LogicalSize, Manager, RunEvent};

/// Margie's visual forms. The frontend asks Rust to resize the overlay
/// window to match whichever form it is rendering.
#[derive(Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
enum Form {
    Orb,
    Bar,
    Panel,
}

impl Form {
    fn size(self) -> LogicalSize<f64> {
        match self {
            Form::Orb => LogicalSize::new(120.0, 120.0),
            Form::Bar => LogicalSize::new(560.0, 72.0),
            Form::Panel => LogicalSize::new(440.0, 640.0),
        }
    }
}

/// TTS provider config, sourced from the environment so keys never live in
/// source. Set ELEVENLABS_API_KEY (preferred) or OPENAI_API_KEY; override the
/// voice with MARGIE_TTS_VOICE. Falls back to the OS speechSynthesis voice.
#[derive(serde::Serialize)]
struct TtsConfig {
    provider: String,
    key: String,
    voice: String,
}

/// Read a field from ~/.margie/config.json (keys kept out of the repo).
fn config_field(field: &str) -> Option<String> {
    let path = std::path::Path::new(&std::env::var("HOME").ok()?).join(".margie/config.json");
    let text = std::fs::read_to_string(path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    json.get(field)?
        .as_str()
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
}

#[tauri::command]
fn tts_config() -> TtsConfig {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    // Environment wins; otherwise fall back to the persisted config file.
    let eleven = env("ELEVENLABS_API_KEY").or_else(|| config_field("elevenlabs_api_key"));
    let openai = env("OPENAI_API_KEY").or_else(|| config_field("openai_api_key"));
    let voice_override = env("MARGIE_TTS_VOICE").or_else(|| config_field("voice"));

    if let Some(key) = eleven {
        return TtsConfig {
            provider: "eleven".into(),
            key,
            // Default: "Alice" — a natural British female voice.
            voice: voice_override.unwrap_or_else(|| "Xb7hH8MSUJpSbSDYk0k2".into()),
        };
    }
    if let Some(key) = openai {
        return TtsConfig {
            provider: "openai".into(),
            key,
            voice: voice_override.unwrap_or_else(|| "nova".into()),
        };
    }
    TtsConfig {
        provider: "system".into(),
        key: String::new(),
        voice: String::new(),
    }
}

/// Save the most recent captured phrase to ~/.margie/last-phrase.wav so the
/// exact audio whisper received can be inspected. Debug aid only.
#[tauri::command]
fn save_wav(bytes: Vec<u8>) {
    if let Ok(home) = std::env::var("HOME") {
        let _ = std::fs::write(
            std::path::Path::new(&home).join(".margie/last-phrase.wav"),
            bytes,
        );
    }
}

/// Append a line to ~/.margie/debug.log for troubleshooting the voice loop.
#[tauri::command]
fn dbg_log(line: String) {
    if let Ok(home) = std::env::var("HOME") {
        let path = std::path::Path::new(&home).join(".margie/debug.log");
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            use std::io::Write;
            let _ = writeln!(f, "{line}");
        }
    }
}

#[tauri::command]
fn set_form(window: tauri::WebviewWindow, form: Form) -> Result<(), String> {
    window.set_size(form.size()).map_err(|e| e.to_string())?;
    window
        .set_resizable(matches!(form, Form::Panel))
        .map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(stt::Whisper::default())
        .manage(brain::Brain::default())
        .invoke_handler(tauri::generate_handler![
            set_form,
            tts_config,
            dbg_log,
            save_wav,
            brain::ask_brain,
            stt::stt_status,
            stt::start_stt,
            stt::stop_stt
        ])
        .setup(|app| {
            // Keep a handle around for future subsystems (tray, shortcuts, PTY pool).
            let _window = app.get_webview_window("main");
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            // Make sure whisper-server doesn't outlive the app.
            if let RunEvent::Exit = event {
                if let Some(whisper) = app.try_state::<stt::Whisper>() {
                    if let Ok(mut guard) = whisper.0.lock() {
                        if let Some(mut child) = guard.take() {
                            let _ = child.kill();
                        }
                    }
                }
            }
        });
}
