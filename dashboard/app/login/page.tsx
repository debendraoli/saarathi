"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { api, auth } from "@/lib/api";

export default function LoginPage() {
  const router = useRouter();
  const [phone, setPhone] = useState("+9779800000000");
  const [code, setCode] = useState("");
  const [stage, setStage] = useState<"phone" | "code">("phone");
  const [devCode, setDevCode] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function sendOtp() {
    setError(null);
    setBusy(true);
    try {
      const res = await api.requestOtp(phone.trim());
      setDevCode(res.dev_code ?? null);
      if (res.dev_code) setCode(res.dev_code);
      setStage("code");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function verify() {
    setError(null);
    setBusy(true);
    try {
      const res = await api.verifyOtp(phone.trim(), code.trim());
      if (!isStaff(res.user.role)) {
        auth.clear();
        setError("This account is not a staff account.");
        return;
      }
      auth.set(res.access_token, res.refresh_token, res.user);
      router.replace("/drivers");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="auth-wrap">
      <div className="card auth-card">
        <div className="brand" style={{ paddingLeft: 0 }}>
          <span className="dot" /> Saarathi Ops
        </div>
        <p className="subtle" style={{ marginTop: -8 }}>
          Staff sign-in
        </p>

        {error && <div className="error">{error}</div>}

        {stage === "phone" ? (
          <>
            <div className="field">
              <label>Phone number</label>
              <input
                className="input"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder="+9779800000000"
                onKeyDown={(e) => e.key === "Enter" && sendOtp()}
              />
            </div>
            <button className="btn primary" style={{ width: "100%" }} disabled={busy} onClick={sendOtp}>
              {busy ? "Sending…" : "Send code"}
            </button>
          </>
        ) : (
          <>
            {devCode && <div className="notice">Dev mode code: <b>{devCode}</b></div>}
            <div className="field">
              <label>Verification code</label>
              <input
                className="input"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="123456"
                onKeyDown={(e) => e.key === "Enter" && verify()}
              />
            </div>
            <button className="btn primary" style={{ width: "100%" }} disabled={busy} onClick={verify}>
              {busy ? "Verifying…" : "Verify & sign in"}
            </button>
            <button
              className="btn ghost"
              style={{ width: "100%", marginTop: 8 }}
              onClick={() => setStage("phone")}
            >
              Use a different number
            </button>
          </>
        )}
      </div>
    </div>
  );
}

function isStaff(role: string): boolean {
  return !["rider", "driver"].includes(role);
}
