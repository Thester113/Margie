//! Streaming speech-to-text via ElevenLabs Scribe v2 Realtime (WebSocket).
//!
//! The webview can't set the `xi-api-key` header on a WebSocket, so the socket
//! lives here in Rust (and the key never lands in a URL). The frontend streams
//! 16 kHz PCM16 audio via `stt_stream_feed`; we forward each chunk as an
//! `input_audio_chunk` message and emit transcript events back to the webview:
//!   - `stt-partial`   interim text (use for live wake-word detection)
//!   - `stt-committed` VAD-committed text = end of turn (the command)
//!   - `stt-error` / `stt-closed`

use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use std::fs;
use tauri::{AppHandle, Emitter, State};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, tungstenite::Message,
};

/// Audio sender into the live WS writer task; `None` when no stream is open.
pub struct SttStream(pub Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>);

impl Default for SttStream {
    fn default() -> Self {
        SttStream(Mutex::new(None))
    }
}

#[derive(serde::Serialize, Clone)]
struct SttEvent {
    text: String,
}

fn elevenlabs_key() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let raw = fs::read_to_string(format!("{home}/.margie/config.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    v.get("elevenlabs_api_key")?.as_str().map(|s| s.to_string())
}

/// Open the ElevenLabs realtime STT socket. Idempotent: a no-op if already open.
#[tauri::command]
pub async fn stt_stream_start(app: AppHandle, state: State<'_, SttStream>) -> Result<(), String> {
    if state.0.lock().await.is_some() {
        return Ok(());
    }
    let key = elevenlabs_key().ok_or("no elevenlabs_api_key in ~/.margie/config.json")?;
    let url = "wss://api.elevenlabs.io/v1/speech-to-text/realtime\
               ?model_id=scribe_v2_realtime&audio_format=pcm_16000\
               &commit_strategy=vad&vad_silence_threshold_secs=0.45";
    let mut req = url
        .into_client_request()
        .map_err(|e| format!("bad ws request: {e}"))?;
    req.headers_mut().insert(
        "xi-api-key",
        key.parse().map_err(|_| "bad api key header".to_string())?,
    );
    let (ws, _resp) = connect_async(req)
        .await
        .map_err(|e| format!("EL STT connect failed: {e}"))?;
    let (mut write, mut read) = ws.split();

    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    *state.0.lock().await = Some(tx);

    // Writer: forward PCM chunks as input_audio_chunk messages.
    tauri::async_runtime::spawn(async move {
        while let Some(bytes) = rx.recv().await {
            let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
            let msg = serde_json::json!({
                "message_type": "input_audio_chunk",
                "audio_base_64": b64,
                "sample_rate": 16000
            })
            .to_string();
            if write.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
        let _ = write.close().await;
    });

    // Reader: emit transcript events to the webview.
    tauri::async_runtime::spawn(async move {
        while let Some(Ok(msg)) = read.next().await {
            if let Message::Text(t) = msg {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(t.as_str()) {
                    let mt = v.get("message_type").and_then(|x| x.as_str()).unwrap_or("");
                    let text = v
                        .get("text")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string();
                    match mt {
                        "partial_transcript" => {
                            let _ = app.emit("stt-partial", SttEvent { text });
                        }
                        "committed_transcript"
                        | "committed_transcript_with_timestamps"
                        | "final_transcript"
                        | "final_transcript_with_timestamps" => {
                            let _ = app.emit("stt-committed", SttEvent { text });
                        }
                        "auth_error" | "error" | "quota_exceeded" | "rate_limited" => {
                            let _ = app.emit("stt-error", SttEvent { text: t.to_string() });
                        }
                        _ => {}
                    }
                }
            }
        }
        let _ = app.emit("stt-closed", SttEvent { text: String::new() });
    });

    Ok(())
}

/// Feed one chunk of 16 kHz PCM16 (little-endian) audio into the open stream.
#[tauri::command]
pub async fn stt_stream_feed(state: State<'_, SttStream>, bytes: Vec<u8>) -> Result<(), String> {
    if let Some(tx) = state.0.lock().await.as_ref() {
        let _ = tx.send(bytes);
    }
    Ok(())
}

/// Close the stream (dropping the sender ends the writer, which closes the WS).
#[tauri::command]
pub async fn stt_stream_stop(state: State<'_, SttStream>) -> Result<(), String> {
    *state.0.lock().await = None;
    Ok(())
}
