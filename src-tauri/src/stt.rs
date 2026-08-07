//! Local speech-to-text via whisper.cpp's `whisper-server`.
//!
//! Rust owns the server process lifecycle only. The webview captures the
//! mic, does voice-activity detection, and POSTs 16kHz WAV phrases straight
//! to `http://127.0.0.1:8178/inference` — so all audio stays on-device and
//! the model loads exactly once.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use tauri::State;

const PORT: u16 = 8178;

/// Managed handle to the running whisper-server child, if any.
pub struct Whisper(pub Mutex<Option<Child>>);

impl Default for Whisper {
    fn default() -> Self {
        Whisper(Mutex::new(None))
    }
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

fn model_path() -> PathBuf {
    home().join(".margie/models/ggml-base.en.bin")
}

/// GUI apps launched from Finder don't inherit the shell PATH, so probe the
/// usual Homebrew locations before falling back to a bare PATH lookup.
fn whisper_server_bin() -> String {
    for p in [
        "/opt/homebrew/bin/whisper-server",
        "/usr/local/bin/whisper-server",
    ] {
        if Path::new(p).exists() {
            return p.to_string();
        }
    }
    "whisper-server".to_string()
}

/// Is the STT model present? The UI uses this to decide whether wake-word
/// listening can be offered.
#[tauri::command]
pub fn stt_status() -> Result<bool, String> {
    Ok(model_path().exists())
}

/// Start whisper-server if it isn't already running; return its base URL.
#[tauri::command]
pub fn start_stt(state: State<Whisper>) -> Result<String, String> {
    let base = format!("http://127.0.0.1:{PORT}");
    let mut guard = state.0.lock().map_err(|e| e.to_string())?;
    if guard.is_some() {
        return Ok(base);
    }

    let model = model_path();
    if !model.exists() {
        return Err(format!(
            "Speech model missing. Expected it at {}.",
            model.display()
        ));
    }

    let log_dir = home().join(".margie");
    std::fs::create_dir_all(&log_dir).map_err(|e| e.to_string())?;
    let log = std::fs::File::create(log_dir.join("whisper-server.log"))
        .map_err(|e| e.to_string())?;
    let log_err = log.try_clone().map_err(|e| e.to_string())?;

    let child = Command::new(whisper_server_bin())
        .args([
            "-m",
            model.to_str().unwrap(),
            "--host",
            "127.0.0.1",
            "--port",
            &PORT.to_string(),
        ])
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .map_err(|e| format!("Couldn't start whisper-server: {e}"))?;

    *guard = Some(child);
    Ok(base)
}

/// Stop the whisper-server child, if running.
#[tauri::command]
pub fn stop_stt(state: State<Whisper>) -> Result<(), String> {
    if let Some(mut child) = state.0.lock().map_err(|e| e.to_string())?.take() {
        let _ = child.kill();
    }
    Ok(())
}
