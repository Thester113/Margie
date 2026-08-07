import { useCallback, useEffect, useRef, useState } from "react";

/**
 * Camera access so Margie can see Tom. v0 shows a live preview in the
 * panel; later, frames are periodically snapshotted and sent to the brain
 * for vision (presence detection, "what am I holding", etc.).
 */
export function useCamera() {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [active, setActive] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const start = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { width: 640, height: 480 },
      });
      streamRef.current = stream;
      if (videoRef.current) {
        videoRef.current.srcObject = stream;
        await videoRef.current.play();
      }
      setActive(true);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  const stop = useCallback(() => {
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    setActive(false);
  }, []);

  /** Grab the current frame as a JPEG data URL, for sending to the brain. */
  const snapshot = useCallback((): string | null => {
    const video = videoRef.current;
    if (!video || !streamRef.current) return null;
    const canvas = document.createElement("canvas");
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    canvas.getContext("2d")?.drawImage(video, 0, 0);
    return canvas.toDataURL("image/jpeg", 0.8);
  }, []);

  useEffect(() => stop, [stop]);

  return { videoRef, active, error, start, stop, snapshot };
}
