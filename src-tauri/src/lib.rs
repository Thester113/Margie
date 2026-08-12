mod brain;
mod stt;
mod stt_stream;

use tauri::{LogicalSize, Manager, RunEvent};

/// Margie's visual forms. The frontend asks Rust to resize the overlay
/// window to match whichever form it is rendering.
#[derive(Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
enum Form {
    Orb,
    Bar,
    Panel,
    Settings,
}

impl Form {
    fn size(self) -> LogicalSize<f64> {
        match self {
            Form::Orb => LogicalSize::new(120.0, 120.0),
            Form::Bar => LogicalSize::new(560.0, 72.0),
            Form::Panel => LogicalSize::new(440.0, 640.0),
            Form::Settings => LogicalSize::new(440.0, 560.0),
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

/// Path to the persisted config file (keys kept out of the repo).
fn config_path() -> Option<std::path::PathBuf> {
    Some(std::path::Path::new(&std::env::var("HOME").ok()?).join(".margie/config.json"))
}

/// Read a field from ~/.margie/config.json.
fn config_field(field: &str) -> Option<String> {
    let text = std::fs::read_to_string(config_path()?).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    json.get(field)?
        .as_str()
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
}

/// User-editable settings persisted to ~/.margie/config.json. Note that the
/// matching env vars (ELEVENLABS_API_KEY, OPENAI_API_KEY, MARGIE_TTS_VOICE)
/// still take precedence at read time — see `tts_config`.
#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Settings {
    #[serde(default)]
    elevenlabs_api_key: String,
    #[serde(default)]
    openai_api_key: String,
    #[serde(default)]
    voice: String,
}

/// Load the persisted settings; missing file or fields yield empty strings.
#[tauri::command]
fn read_settings() -> Settings {
    config_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Persist settings, merging into any existing config so unrelated fields
/// (e.g. hand-added keys) are preserved.
#[tauri::command]
fn write_settings(settings: Settings) -> Result<(), String> {
    let path = config_path().ok_or("HOME not set")?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut json: serde_json::Value = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    if let Some(obj) = json.as_object_mut() {
        obj.insert("elevenlabs_api_key".into(), settings.elevenlabs_api_key.into());
        obj.insert("openai_api_key".into(), settings.openai_api_key.into());
        obj.insert("voice".into(), settings.voice.into());
    }
    let text = serde_json::to_string_pretty(&json).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| e.to_string())
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

/// Drain queued voice announcements written by background jobs (e.g. the Slack
/// watcher) to ~/.margie/announce/*.txt. Each file's text is returned once and
/// then deleted, so the frontend can speak them aloud.
#[tauri::command]
fn take_announcements() -> Vec<String> {
    let mut out = Vec::new();
    let Ok(home) = std::env::var("HOME") else {
        return out;
    };
    let dir = std::path::Path::new(&home).join(".margie/announce");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return out;
    };
    let mut paths: Vec<std::path::PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "txt"))
        .collect();
    paths.sort(); // oldest first (filenames are timestamps)
    for p in paths {
        if let Ok(text) = std::fs::read_to_string(&p) {
            let text = text.trim().to_string();
            if !text.is_empty() {
                out.push(text);
            }
        }
        let _ = std::fs::remove_file(&p);
    }
    out
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
        .manage(stt_stream::SttStream::default())
        .invoke_handler(tauri::generate_handler![
            set_form,
            tts_config,
            read_settings,
            write_settings,
            dbg_log,
            save_wav,
            take_announcements,
            brain::ask_brain,
            stt::stt_status,
            stt::start_stt,
            stt::stop_stt,
            stt_stream::stt_stream_start,
            stt_stream::stt_stream_feed,
            stt_stream::stt_stream_stop
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
