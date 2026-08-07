import { useCallback, useEffect, useRef, useState } from "react";

export type VoiceStatus = "idle" | "listening" | "thinking" | "speaking";

/**
 * Margie's voice pipeline (v0).
 *
 * - TTS: browser speechSynthesis as a stand-in until cloud TTS
 *   (ElevenLabs/OpenAI) is wired through the sidecar.
 * - STT: microphone capture with a live level meter. Transcription is a
 *   TODO — audio will be streamed to whisper.cpp on the Rust side, with a
 *   local wake word ("Margie") gating it.
 */
export function useVoice() {
  const [status, setStatus] = useState<VoiceStatus>("idle");
  const [micLevel, setMicLevel] = useState(0);
  const streamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const rafRef = useRef<number>(0);

  const speak = useCallback((text: string) => {
    return new Promise<void>((resolve) => {
      const utterance = new SpeechSynthesisUtterance(text);
      const voice = speechSynthesis
        .getVoices()
        .find((v) => v.name.includes("Samantha"));
      if (voice) utterance.voice = voice;
      utterance.onstart = () => setStatus("speaking");
      utterance.onend = () => {
        setStatus("idle");
        resolve();
      };
      speechSynthesis.speak(utterance);
    });
  }, []);

  const startListening = useCallback(async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    streamRef.current = stream;
    const ctx = new AudioContext();
    audioCtxRef.current = ctx;
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 256;
    ctx.createMediaStreamSource(stream).connect(analyser);
    const data = new Uint8Array(analyser.frequencyBinCount);

    setStatus("listening");
    const tick = () => {
      analyser.getByteFrequencyData(data);
      const avg = data.reduce((a, b) => a + b, 0) / data.length;
      setMicLevel(avg / 255);
      rafRef.current = requestAnimationFrame(tick);
    };
    tick();
    // TODO: stream PCM frames to Rust for wake-word + whisper.cpp STT.
  }, []);

  const stopListening = useCallback(() => {
    cancelAnimationFrame(rafRef.current);
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    audioCtxRef.current?.close();
    audioCtxRef.current = null;
    setMicLevel(0);
    setStatus("idle");
  }, []);

  useEffect(() => stopListening, [stopListening]);

  return { status, setStatus, micLevel, speak, startListening, stopListening };
}
