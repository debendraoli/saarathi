"use client";

import { api, type Driver, type OnboardDriverInput, type VehicleClass } from "@/lib/api";
import Link from "next/link";
import { useState } from "react";

const DOC_KINDS = [
  "citizenship",
  "license",
  "bluebook",
  "vehicle_fitness",
  "insurance",
  "tax_clearance",
  "profile_photo",
  "vehicle_photo",
];

export default function OnboardDriverPage() {
  const [phone, setPhone] = useState("+977");
  const [fullName, setFullName] = useState("");
  const [license, setLicense] = useState("");
  const [address, setAddress] = useState("");
  const [vclass, setVclass] = useState<VehicleClass>("two_wheeler");
  const [plate, setPlate] = useState("");
  const [make, setMake] = useState("");
  const [model, setModel] = useState("");

  const [driver, setDriver] = useState<Driver | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [docKind, setDocKind] = useState(DOC_KINDS[0]);
  const [docFile, setDocFile] = useState<File | null>(null);
  const [uploaded, setUploaded] = useState<string[]>([]);
  const [uploadBusy, setUploadBusy] = useState(false);

  async function onboard() {
    setBusy(true);
    setError(null);
    try {
      const input: OnboardDriverInput = {
        phone: phone.trim(),
        full_name: fullName || null,
        license_number: license || null,
        address: address || null,
        vehicle: { class: vclass, plate_number: plate.trim(), make: make || null, model: model || null },
      };
      setDriver(await api.onboardDriver(input));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function upload() {
    if (!driver || !docFile) return;
    setUploadBusy(true);
    setError(null);
    try {
      const doc = await api.uploadDriverDocument(driver.id, docKind, docFile);
      setUploaded((u) => [...u, doc.kind]);
      setDocFile(null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setUploadBusy(false);
    }
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">On-site Driver KYC</h1>
        <p className="subtle">
          Capture a walk-in driver&apos;s details, then upload their documents. They land in the
          verification queue for a compliance decision.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>1. Driver &amp; vehicle</h3>
        <div className="grid-2">
          <div className="field">
            <label>Phone (E.164)</label>
            <input className="input" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="+9779800000000" disabled={!!driver} />
          </div>
          <div className="field">
            <label>Full name</label>
            <input className="input" value={fullName} onChange={(e) => setFullName(e.target.value)} disabled={!!driver} />
          </div>
          <div className="field">
            <label>License number</label>
            <input className="input" value={license} onChange={(e) => setLicense(e.target.value)} disabled={!!driver} />
          </div>
          <div className="field">
            <label>Address</label>
            <input className="input" value={address} onChange={(e) => setAddress(e.target.value)} disabled={!!driver} />
          </div>
          <div className="field">
            <label>Vehicle class</label>
            <select className="input" value={vclass} onChange={(e) => setVclass(e.target.value as VehicleClass)} disabled={!!driver}>
              <option value="two_wheeler">Two-wheeler</option>
              <option value="four_wheeler">Four-wheeler</option>
            </select>
          </div>
          <div className="field">
            <label>Plate number</label>
            <input className="input" value={plate} onChange={(e) => setPlate(e.target.value)} placeholder="BA-1-PA-1234" disabled={!!driver} />
          </div>
          <div className="field">
            <label>Make (optional)</label>
            <input className="input" value={make} onChange={(e) => setMake(e.target.value)} disabled={!!driver} />
          </div>
          <div className="field">
            <label>Model (optional)</label>
            <input className="input" value={model} onChange={(e) => setModel(e.target.value)} disabled={!!driver} />
          </div>
        </div>
        {!driver ? (
          <button className="btn primary" disabled={busy || !plate.trim()} onClick={onboard}>
            {busy ? "Saving…" : "Create driver"}
          </button>
        ) : (
          <div className="row">
            <span className="badge under_review">created · under review</span>
            <Link className="btn ghost" href={`/drivers/${driver.id}`}>
              Open in verification
            </Link>
          </div>
        )}
      </div>

      {driver && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>2. Upload documents</h3>
          <div className="grid-2">
            <div className="field">
              <label>Document type</label>
              <select className="input" value={docKind} onChange={(e) => setDocKind(e.target.value)}>
                {DOC_KINDS.map((k) => (
                  <option key={k} value={k}>
                    {k}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <label>File</label>
              <input
                className="input"
                type="file"
                onChange={(e) => setDocFile(e.target.files?.[0] ?? null)}
              />
            </div>
          </div>
          <button className="btn primary" disabled={uploadBusy || !docFile} onClick={upload}>
            {uploadBusy ? "Uploading…" : "Upload document"}
          </button>
          {uploaded.length > 0 && (
            <p className="subtle" style={{ marginTop: 12 }}>
              Uploaded: {uploaded.join(", ")}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
