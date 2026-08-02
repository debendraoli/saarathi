"use client";

import { Modal } from "@/components/Modal";
import { WebcamCapture } from "@/components/Webcam";
import { api, type Driver, type OnboardDriverInput, type VehicleClass } from "@/lib/api";
import { Camera, Check } from "lucide-react";
import Link from "next/link";
import { useState } from "react";

const DOC_KINDS = [
  "profile_photo",
  "citizenship_front",
  "citizenship_back",
  "citizenship",
  "license",
  "bluebook",
  "vehicle_fitness",
  "insurance",
  "tax_clearance",
  "vehicle_photo",
];

const KIND_LABELS: Record<string, string> = {
  profile_photo: "Profile photo (driver / rider)",
  citizenship_front: "Citizenship — front",
  citizenship_back: "Citizenship — back",
  citizenship: "Citizenship (single page)",
  license: "Driving license",
  bluebook: "Vehicle bluebook",
  vehicle_fitness: "Vehicle fitness",
  insurance: "Insurance",
  tax_clearance: "Tax clearance",
  vehicle_photo: "Vehicle photo",
};

// Kinds that make sense to capture live on a webcam during a walk-in.
const CAMERA_FACING: Record<string, "user" | "environment"> = {
  profile_photo: "user",
};

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
  const [camOpen, setCamOpen] = useState(false);

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
    await uploadFile(docFile);
    setDocFile(null);
  }

  async function uploadFile(file: File) {
    if (!driver) return;
    setUploadBusy(true);
    setError(null);
    try {
      const doc = await api.uploadDriverDocument(driver.id, docKind, file);
      setUploaded((u) => [...u.filter((k) => k !== doc.kind), doc.kind]);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setUploadBusy(false);
    }
  }

  async function onCapture(file: File) {
    setCamOpen(false);
    await uploadFile(file);
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
          <h3 style={{ marginTop: 0 }}>2. Documents &amp; photos</h3>
          <p className="subtle" style={{ marginTop: 0 }}>
            Capture a live photo with the webcam or upload a file. Citizenship needs both the front
            and back page.
          </p>
          <div className="grid-2">
            <div className="field">
              <label>Document type</label>
              <select className="input" value={docKind} onChange={(e) => setDocKind(e.target.value)}>
                {DOC_KINDS.map((k) => (
                  <option key={k} value={k}>
                    {KIND_LABELS[k] ?? k}
                    {uploaded.includes(k) ? " ✓" : ""}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <label>Upload a file</label>
              <input
                className="input"
                type="file"
                accept="image/*,application/pdf"
                onChange={(e) => setDocFile(e.target.files?.[0] ?? null)}
              />
            </div>
          </div>
          <div className="row" style={{ flexWrap: "wrap" }}>
            <button className="btn primary" disabled={uploadBusy || !docFile} onClick={upload}>
              {uploadBusy ? "Uploading…" : "Upload file"}
            </button>
            <button className="btn ghost" disabled={uploadBusy} onClick={() => setCamOpen(true)}>
              <Camera size={15} /> Capture with camera
            </button>
          </div>
          {uploaded.length > 0 && (
            <div className="stack" style={{ gap: 6, marginTop: 14 }}>
              {uploaded.map((k) => (
                <div key={k} className="row" style={{ gap: 8 }}>
                  <Check size={15} color="var(--color-green)" />
                  <span className="text-[13px]">{KIND_LABELS[k] ?? k}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      <Modal
        open={camOpen}
        onClose={() => setCamOpen(false)}
        title={`Capture · ${KIND_LABELS[docKind] ?? docKind}`}
      >
        {camOpen && (
          <WebcamCapture
            key={docKind}
            onCapture={onCapture}
            filenameBase={docKind}
            facingMode={CAMERA_FACING[docKind] ?? "environment"}
          />
        )}
      </Modal>
    </div>
  );
}
