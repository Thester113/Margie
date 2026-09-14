//! Margie on a Looking Glass display.
//!
//! A second, borderless webview window (`holo`) is placed on the holographic
//! display and the webview renders her there (quilt + lenticular pass, see
//! `src/holo/`). This module only owns the window: finding the display,
//! opening/closing the window as the display comes and goes, and a few small
//! IPC helpers (avatar bytes, calibration cache, hologram config).
//!
//! Nothing here talks to the brain or the outside world.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Manager, Monitor, WebviewUrl, WebviewWindowBuilder};

/// Label of the hologram window (also used in `capabilities/default.json`).
pub const LABEL: &str = "holo";

/// Native panel size of the Looking Glass Go (portrait), in physical pixels.
const GO_SIZE: (u32, u32) = (1440, 2560);

/// How often the watcher re-checks the connected displays.
const WATCH_EVERY: Duration = Duration::from_secs(5);

/// macOS drops sleeping displays from the monitor list. Keep the window (and
/// the loaded avatar) through display sleep; only a display that stays gone
/// this long counts as unplugged.
const UNPLUG_GRACE: Duration = Duration::from_secs(90);

/// When the display was first seen missing while the window was open.
static MISSING_SINCE: Mutex<Option<Instant>> = Mutex::new(None);

/// `hologram: "off"` in ~/.margie/config.json disables the feature entirely.
fn enabled() -> bool {
    super::config_field("hologram").map_or(true, |v| v != "off")
}

/// Expand a leading `~/` to $HOME.
fn expand_home(path: &str) -> std::path::PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return std::path::Path::new(&home).join(rest);
        }
    }
    std::path::PathBuf::from(path)
}

fn margie_dir() -> Option<std::path::PathBuf> {
    Some(std::path::Path::new(&std::env::var("HOME").ok()?).join(".margie"))
}

/// Find the Looking Glass among the connected displays.
///
/// tao reports macOS monitors as "Monitor #N", so the display is matched by
/// its physical size (the Go is 1440×2560). `hologram_monitor` in the config
/// overrides the match: either `WIDTHxHEIGHT` or a 0-based index.
pub fn find_lkg_monitor(app: &AppHandle) -> Option<Monitor> {
    let monitors = app.available_monitors().ok()?;
    let want = super::config_field("hologram_monitor");
    if let Some(spec) = want.as_deref() {
        if let Some((w, h)) = spec.split_once('x') {
            let (w, h) = (w.trim().parse::<u32>().ok()?, h.trim().parse::<u32>().ok()?);
            return monitors
                .into_iter()
                .find(|m| m.size().width == w && m.size().height == h);
        }
        if let Ok(idx) = spec.trim().parse::<usize>() {
            return monitors.into_iter().nth(idx);
        }
    }
    monitors.into_iter().find(|m| {
        let s = m.size();
        (s.width, s.height) == GO_SIZE
            || m.name().is_some_and(|n| n.to_uppercase().contains("LKG"))
    })
}

/// Open the hologram window on `monitor` (no-op if it is already open).
///
/// The window is borderless, black, never focused (so it never steals Tom's
/// keyboard), sized to the display and then put into macOS "simple"
/// fullscreen, which hides the menu bar without creating a Space.
pub fn open(app: &AppHandle, monitor: &Monitor) -> tauri::Result<()> {
    if app.get_webview_window(LABEL).is_some() {
        return Ok(());
    }
    let scale = monitor.scale_factor().max(0.1);
    let pos = monitor.position();
    let size = monitor.size();
    // Dev knob: MARGIE_HOLO_DEBUG="debug=cube&hud=1&calib=placeholder" adds
    // query flags the renderer understands (see src/holo/Hologram.tsx).
    let extra = std::env::var("MARGIE_HOLO_DEBUG")
        .ok()
        .filter(|v| !v.is_empty())
        .map(|v| format!("&{v}"))
        .unwrap_or_default();
    let window = WebviewWindowBuilder::new(
        app,
        LABEL,
        WebviewUrl::App(format!("index.html?view=holo{extra}").into()),
    )
    .title("Margie (hologram)")
    .decorations(false)
    .shadow(false)
    .resizable(false)
    .skip_taskbar(true)
    .focused(false)
    .always_on_top(true)
    .position(pos.x as f64 / scale, pos.y as f64 / scale)
    .inner_size(size.width as f64 / scale, size.height as f64 / scale)
    .background_color(tauri::window::Color(0, 0, 0, 255))
    .build()?;
    // Best effort: a plain borderless window at the display's bounds already
    // works; fullscreen just hides the menu bar on that display.
    let _ = window.set_simple_fullscreen(true);
    Ok(())
}

/// Close the hologram window if it is open.
pub fn close(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.close();
    }
}

/// Reconcile the window with the current display list and config, once.
fn reconcile(app: &AppHandle) {
    if !enabled() {
        close(app);
        return;
    }
    let mut missing = MISSING_SINCE.lock().unwrap_or_else(|e| e.into_inner());
    match find_lkg_monitor(app) {
        Some(m) => {
            *missing = None;
            if let Err(e) = open(app, &m) {
                eprintln!("[hologram] could not open window: {e}");
            }
        }
        None => {
            if app.get_webview_window(LABEL).is_none() {
                *missing = None;
                return;
            }
            let since = missing.get_or_insert_with(Instant::now);
            if since.elapsed() >= UNPLUG_GRACE {
                *missing = None;
                close(app);
            }
        }
    }
}

static WATCHING: AtomicBool = AtomicBool::new(false);

/// Keep the hologram window in step with the display (hot-plug) and config.
pub fn start_watch(app: AppHandle) {
    if WATCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || loop {
        let handle = app.clone();
        // Window creation must happen on the main thread.
        let _ = app.run_on_main_thread(move || reconcile(&handle));
        std::thread::sleep(WATCH_EVERY);
    });
}

#[derive(serde::Serialize)]
pub struct HologramStatus {
    /// `hologram` config is not "off".
    pub enabled: bool,
    /// A Looking Glass display is connected right now.
    pub connected: bool,
    /// The `holo` window exists.
    pub open: bool,
    /// Physical size of the matched display, if any.
    pub monitor: Option<String>,
}

#[tauri::command]
pub fn hologram_status(app: AppHandle) -> HologramStatus {
    let monitor = find_lkg_monitor(&app);
    HologramStatus {
        enabled: enabled(),
        connected: monitor.is_some(),
        open: app.get_webview_window(LABEL).is_some(),
        monitor: monitor.map(|m| format!("{}x{}", m.size().width, m.size().height)),
    }
}

/// Turn the hologram on/off (persists `hologram` in the config; the watcher
/// applies it within a few seconds, and we also apply it right away).
#[tauri::command]
pub fn hologram_set(app: AppHandle, enabled: bool) -> Result<(), String> {
    let path = super::config_path().ok_or("HOME not set")?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut json: serde_json::Value = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    if let Some(obj) = json.as_object_mut() {
        obj.insert(
            "hologram".into(),
            serde_json::Value::String(if enabled { "on".into() } else { "off".into() }),
        );
    }
    let text = serde_json::to_string_pretty(&json).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| e.to_string())?;
    reconcile(&app);
    Ok(())
}

/// The `hologram_*` keys of the config, for the renderer (camera framing,
/// quilt size, avatar path…). Unknown/missing keys are simply absent.
#[tauri::command]
pub fn hologram_config() -> serde_json::Value {
    let mut out = serde_json::Map::new();
    if let Some(text) = super::config_path().and_then(|p| std::fs::read_to_string(p).ok()) {
        if let Ok(serde_json::Value::Object(obj)) = serde_json::from_str::<serde_json::Value>(&text)
        {
            for (k, v) in obj {
                if k.starts_with("hologram") {
                    out.insert(k, v);
                }
            }
        }
    }
    serde_json::Value::Object(out)
}

/// Path of the avatar model: `hologram_avatar` in the config, else
/// ~/.margie/avatar/margie.glb or margie.vrm (whichever exists; .glb wins).
fn avatar_path() -> Option<std::path::PathBuf> {
    // Dev knob: try a model without touching the config.
    if let Some(p) = std::env::var("MARGIE_AVATAR").ok().filter(|v| !v.is_empty()) {
        return Some(expand_home(&p));
    }
    if let Some(p) = super::config_field("hologram_avatar") {
        return Some(expand_home(&p));
    }
    let dir = margie_dir()?.join("avatar");
    for name in ["margie.glb", "margie.vrm"] {
        let p = dir.join(name);
        if p.exists() {
            return Some(p);
        }
    }
    Some(dir.join("margie.glb"))
}

/// Raw bytes of the avatar (.vrm/.glb). Returned as a binary IPC payload so a
/// 20 MB model doesn't go through JSON.
#[tauri::command]
pub fn read_avatar() -> Result<tauri::ipc::Response, String> {
    let path = avatar_path().ok_or("HOME not set")?;
    let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(tauri::ipc::Response::new(bytes))
}

/// Where the avatar is expected (for the Settings form / error messages).
#[tauri::command]
pub fn avatar_path_hint() -> String {
    avatar_path()
        .map(|p| p.display().to_string())
        .unwrap_or_default()
}

fn calibration_path() -> Option<std::path::PathBuf> {
    Some(margie_dir()?.join("lkg/calibration.json"))
}

/// Cached Looking Glass calibration (JSON text), if any. The webview reads
/// live calibration from Looking Glass Bridge when it can and caches it here
/// so the hologram still works when Bridge isn't running.
#[tauri::command]
pub fn lkg_calibration_read() -> Option<String> {
    std::fs::read_to_string(calibration_path()?).ok()
}

#[tauri::command]
pub fn lkg_calibration_write(text: String) -> Result<(), String> {
    let path = calibration_path().ok_or("HOME not set")?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::write(&path, text).map_err(|e| e.to_string())
}
