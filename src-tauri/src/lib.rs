mod brain;

use tauri::{LogicalSize, Manager};

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
        .invoke_handler(tauri::generate_handler![set_form, brain::ask_brain])
        .setup(|app| {
            // Keep a handle around for future subsystems (tray, shortcuts, PTY pool).
            let _window = app.get_webview_window("main");
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
