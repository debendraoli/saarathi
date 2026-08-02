"use client";

import { Camera, Check, RefreshCw } from "lucide-react";
import { useEffect, useRef, useState } from "react";

/** Live webcam capture that yields a JPEG File. Requests camera permission on
 *  mount; stops the stream on unmount or after a shot is taken. */
export function WebcamCapture({
  onCapture,
  filenameBase = "capture",
  facingMode = "user",
}: {
  onCapture: (file: File) => void;
  filenameBase?: string;
  facingMode?: "user" | "environment";
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [error, setError] = useState("");
  const [shot, setShot] = useState<string | null>(null);
  const [file, setFile] = useState<File | null>(null);

  useEffect(() => {
    let cancelled = false;
    const stop = () => {
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
    };
    async function start() {
      if (!navigator.mediaDevices?.getUserMedia) {
        setError("This browser has no camera access.");
        return;
      }
      try {
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode, width: { ideal: 1280 }, height: { ideal: 720 } },
          audio: false,
        });
        if (cancelled) {
          stream.getTracks().forEach((t) => t.stop());
          return;
        }
        streamRef.current = stream;
        if (videoRef.current) {
          videoRef.current.srcObject = stream;
          await videoRef.current.play().catch(() => {});
        }
      } catch (e) {
        setError((e as Error).message || "Camera permission denied.");
      }
    }
    if (!shot) start();
    return () => {
      cancelled = true;
      stop();
    };
  }, [shot, facingMode]);

  function capture() {
    const v = videoRef.current;
    if (!v) return;
    const canvas = document.createElement("canvas");
    canvas.width = v.videoWidth || 640;
    canvas.height = v.videoHeight || 480;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.drawImage(v, 0, 0, canvas.width, canvas.height);
    setShot(canvas.toDataURL("image/jpeg", 0.9));
    canvas.toBlob(
      (blob) => blob && setFile(new File([blob], `${filenameBase}.jpg`, { type: "image/jpeg" })),
      "image/jpeg",
      0.9,
    );
  }

  return (
    <div className="webcam">
      {error ? (
        <div className="error">{error}</div>
      ) : shot ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={shot} className="webcam-view" alt="capture preview" />
      ) : (
        <video ref={videoRef} className="webcam-view" playsInline muted />
      )}
      <div className="row" style={{ justifyContent: "center", marginTop: 10 }}>
        {!shot ? (
          <button className="btn primary" onClick={capture} disabled={!!error}>
            <Camera size={15} /> Capture
          </button>
        ) : (
          <>
            <button
              className="btn ghost"
              onClick={() => {
                setShot(null);
                setFile(null);
              }}
            >
              <RefreshCw size={15} /> Retake
            </button>
            <button className="btn primary" onClick={() => file && onCapture(file)} disabled={!file}>
              <Check size={15} /> Use photo
            </button>
          </>
        )}
      </div>
    </div>
  );
}
