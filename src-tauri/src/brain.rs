//! Bridge to Margie's brain — a long-lived Node sidecar running the Claude
//! Agent SDK as one warm streaming session.
//!
//! The sidecar is spawned once and kept alive; requests and responses are
//! newline-delimited JSON correlated by a monotonic id. A background task
//! reads the sidecar's stdout and routes each response to the awaiting
//! caller. If the pipe breaks or a turn times out, the process is dropped so
//! the next request respawns a fresh brain.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdin, Command};
use tokio::sync::oneshot;

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<String>>>>;

#[derive(serde::Serialize)]
struct BrainRequest<'a> {
    id: u64,
    text: &'a str,
}

#[derive(serde::Deserialize)]
struct BrainResponse {
    id: u64,
    text: String,
}

pub struct Brain {
    stdin: tokio::sync::Mutex<Option<ChildStdin>>,
    pending: Pending,
    counter: AtomicU64,
}

impl Default for Brain {
    fn default() -> Self {
        Brain {
            stdin: tokio::sync::Mutex::new(None),
            pending: Arc::new(Mutex::new(HashMap::new())),
            counter: AtomicU64::new(1),
        }
    }
}

/// Spawn the sidecar if it isn't running. Holds the stdin lock while starting.
async fn ensure_started(brain: &Brain) -> Result<(), String> {
    let mut guard = brain.stdin.lock().await;
    if guard.is_some() {
        return Ok(());
    }

    let sidecar = std::env::current_dir()
        .map_err(|e| e.to_string())?
        .join("../sidecar/dist/index.js");
    if !sidecar.exists() {
        return Err(
            "Brain offline — build the sidecar with `npm run build` in sidecar/.".into(),
        );
    }

    let mut child = Command::new("node")
        .arg(&sidecar)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .map_err(|e| format!("failed to spawn brain: {e}"))?;

    let stdin = child.stdin.take().ok_or("no stdin on brain")?;
    let stdout = child.stdout.take().ok_or("no stdout on brain")?;
    let pending = brain.pending.clone();

    // Route each response line to its awaiting caller.
    tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(resp) = serde_json::from_str::<BrainResponse>(&line) {
                if let Some(tx) = pending.lock().unwrap().remove(&resp.id) {
                    let _ = tx.send(resp.text);
                }
            }
        }
        // stdout closed → the brain exited. Waiting callers will time out and
        // the next request will respawn it.
    });

    // Keep the child alive for the app's lifetime by leaking the handle; the
    // sidecar exits on its own when our stdin closes at app shutdown.
    std::mem::forget(child);

    *guard = Some(stdin);
    Ok(())
}

#[tauri::command]
pub async fn ask_brain(
    brain: tauri::State<'_, Brain>,
    text: String,
    // Retained for API compatibility; context is now automatic in the warm
    // session, so no explicit resume is needed.
    resume: bool,
) -> Result<String, String> {
    let _ = resume;
    ensure_started(&brain).await?;

    let id = brain.counter.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = oneshot::channel();
    brain.pending.lock().unwrap().insert(id, tx);

    let mut line = serde_json::to_string(&BrainRequest { id, text: &text })
        .map_err(|e| e.to_string())?;
    line.push('\n');

    {
        let mut guard = brain.stdin.lock().await;
        let stdin = guard.as_mut().ok_or("brain not running")?;
        if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
            *guard = None; // pipe broke — force a respawn next call
            brain.pending.lock().unwrap().remove(&id);
            return Err("Brain pipe broke, sir — give it another go.".into());
        }
    }

    match tokio::time::timeout(Duration::from_secs(180), rx).await {
        Ok(Ok(reply)) => Ok(reply),
        _ => {
            brain.pending.lock().unwrap().remove(&id);
            // Drop the process so a wedged brain gets respawned next time.
            *brain.stdin.lock().await = None;
            Err("Margie's brain took too long and was reset.".into())
        }
    }
}
