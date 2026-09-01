//! Bridge to Margie's brain — the shared brain DAEMON (sidecar/src/server.ts),
//! reached over a unix socket at ~/.margie/brain.sock.
//!
//! The daemon is shared with the `margie` CLI: one conversation, one pending
//! confirmation, whoever asked gets the reply. This bridge connects on demand,
//! spawning the daemon (via the sidecar's own detaching launcher) when the
//! socket isn't there. On a broken pipe or timeout it only drops its
//! connection — it NEVER kills the daemon, which other clients may be using.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::UnixStream;
use tokio::process::Command;
use tokio::sync::oneshot;

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<String>>>>;

#[derive(serde::Serialize)]
struct BrainRequest<'a> {
    id: u64,
    text: &'a str,
    source: &'a str,
}

#[derive(serde::Deserialize)]
struct BrainResponse {
    id: Option<u64>,
    text: Option<String>,
    /// Progress ("tool"/"held") and broadcast ("notice") lines — the app takes
    /// spoken notices from the announce drop-box instead, so these are skipped.
    #[serde(default)]
    event: Option<String>,
}

pub struct Brain {
    writer: tokio::sync::Mutex<Option<OwnedWriteHalf>>,
    pending: Pending,
    counter: AtomicU64,
}

impl Default for Brain {
    fn default() -> Self {
        Brain {
            writer: tokio::sync::Mutex::new(None),
            pending: Arc::new(Mutex::new(HashMap::new())),
            counter: AtomicU64::new(1),
        }
    }
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

fn sock_path() -> PathBuf {
    home().join(".margie/brain.sock")
}

/// GUI apps launched from Finder don't inherit the shell PATH; probe the usual
/// Homebrew locations first (same pattern as stt.rs's whisper_server_bin).
fn node_bin() -> String {
    for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
        if Path::new(p).exists() {
            return p.to_string();
        }
    }
    "node".to_string()
}

/// Connect to the daemon, spawning it if the socket isn't answering.
async fn connect_daemon() -> Result<UnixStream, String> {
    let sock = sock_path();
    if let Ok(s) = UnixStream::connect(&sock).await {
        return Ok(s);
    }

    let sidecar = std::env::current_dir()
        .map_err(|e| e.to_string())?
        .join("../sidecar/dist/index.js");
    if !sidecar.exists() {
        return Err("Brain offline — build the sidecar with `npm run build` in sidecar/.".into());
    }

    // The launcher detaches its real child and exits immediately.
    let _ = Command::new(node_bin())
        .arg(&sidecar)
        .arg("--daemon")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map_err(|e| format!("failed to launch brain daemon: {e}"))?;

    for _ in 0..25 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        if let Ok(s) = UnixStream::connect(&sock).await {
            return Ok(s);
        }
    }
    Err("Brain daemon didn't come up, sir.".into())
}

/// Ensure a live connection. Holds the writer lock while (re)connecting.
async fn ensure_connected(brain: &Brain) -> Result<(), String> {
    let mut guard = brain.writer.lock().await;
    if guard.is_some() {
        return Ok(());
    }

    let stream = connect_daemon().await?;
    let (read_half, mut write_half) = stream.into_split();

    // Identify as the app so daemon notices go to the spoken announce channel.
    let _ = write_half
        .write_all(b"{\"op\":\"hello\",\"source\":\"app\"}\n")
        .await;

    let pending = brain.pending.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(read_half).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(resp) = serde_json::from_str::<BrainResponse>(&line) {
                if resp.event.is_some() {
                    continue; // progress/notice lines aren't replies
                }
                if let (Some(id), Some(text)) = (resp.id, resp.text) {
                    if let Some(tx) = pending.lock().unwrap().remove(&id) {
                        let _ = tx.send(text);
                    }
                }
            }
        }
        // Connection closed (daemon drained/restarted). Waiting callers time
        // out; the next request reconnects.
    });

    *guard = Some(write_half);
    Ok(())
}

#[tauri::command]
pub async fn ask_brain(
    brain: tauri::State<'_, Brain>,
    text: String,
    // Retained for API compatibility; context lives in the shared daemon now.
    resume: bool,
) -> Result<String, String> {
    let _ = resume;
    ensure_connected(&brain).await?;

    let id = brain.counter.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = oneshot::channel();
    brain.pending.lock().unwrap().insert(id, tx);

    let mut line = serde_json::to_string(&BrainRequest {
        id,
        text: &text,
        source: "app",
    })
    .map_err(|e| e.to_string())?;
    line.push('\n');

    {
        let mut guard = brain.writer.lock().await;
        let writer = guard.as_mut().ok_or("brain not connected")?;
        if writer.write_all(line.as_bytes()).await.is_err() || writer.flush().await.is_err() {
            *guard = None; // connection broke — reconnect on the next call
            brain.pending.lock().unwrap().remove(&id);
            return Err("Brain connection broke, sir — give it another go.".into());
        }
    }

    match tokio::time::timeout(Duration::from_secs(180), rx).await {
        Ok(Ok(reply)) => Ok(reply),
        _ => {
            brain.pending.lock().unwrap().remove(&id);
            // Drop only OUR connection; the shared daemon stays up for others.
            *brain.writer.lock().await = None;
            Err("Margie's brain took too long, sir — try that again.".into())
        }
    }
}
