//! Bridge to Margie's brain — the Node sidecar running the Claude Agent SDK.
//!
//! v0: the sidecar is spawned per request (`node sidecar/dist/index.js`),
//! receives one JSON request on stdin, and prints one JSON response on
//! stdout. Later this becomes a long-lived process with a streaming
//! protocol and PTY-managed `claude` CLI sessions.

use std::io::Write;
use std::process::{Command, Stdio};

#[derive(serde::Serialize)]
struct BrainRequest<'a> {
    r#type: &'a str,
    text: &'a str,
}

#[derive(serde::Deserialize)]
struct BrainResponse {
    text: String,
}

#[tauri::command]
pub async fn ask_brain(text: String) -> Result<String, String> {
    let sidecar = std::env::current_dir()
        .map_err(|e| e.to_string())?
        .join("../sidecar/dist/index.js");

    if !sidecar.exists() {
        // Sidecar not built yet — echo so the UI loop is testable end to end.
        return Ok(format!(
            "(brain offline — build the sidecar with `npm run build` in sidecar/) You said: {text}"
        ));
    }

    let mut child = Command::new("node")
        .arg(&sidecar)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("failed to spawn sidecar: {e}"))?;

    let request = serde_json::to_vec(&BrainRequest {
        r#type: "user_text",
        text: &text,
    })
    .map_err(|e| e.to_string())?;

    child
        .stdin
        .take()
        .ok_or("no stdin on sidecar")?
        .write_all(&request)
        .map_err(|e| e.to_string())?;

    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("sidecar exited with {}", output.status));
    }

    let response: BrainResponse =
        serde_json::from_slice(&output.stdout).map_err(|e| format!("bad sidecar reply: {e}"))?;
    Ok(response.text)
}
