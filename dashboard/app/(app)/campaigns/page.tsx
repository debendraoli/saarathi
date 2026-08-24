"use client";

import { Modal } from "@/components/Modal";
import { Pagination, SearchInput, usePaged } from "@/components/Toolbar";
import { rides, type Campaign, type CampaignRule, type NewCampaign } from "@/lib/api";
import { Plus } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

const EMPTY: NewCampaign = {
  code: "",
  title: "",
  audience: "rider",
  kind: "percent",
  value: 10,
  min_fare: 0,
  max_discount: null,
  vehicle_class: null,
  usage_limit: null,
};

type RuleType = CampaignRule["type"];

function defaultRule(type: RuleType): CampaignRule {
  switch (type) {
    case "new_user":
      return { type, within_days: 30, max_prior_rides: 0 };
    case "min_rides":
      return { type, count: 10 };
    case "max_rides":
      return { type, count: 5 };
    case "rides_today":
      return { type, count: 5 };
    case "time_of_day":
      return { type, start_minute: 17 * 60, end_minute: 20 * 60, days_mask: 127 };
    case "min_fare":
      return { type, amount: 100 };
    case "max_per_user":
      return { type, count: 1 };
  }
}

const RULE_LABELS: Record<RuleType, string> = {
  new_user: "New user",
  min_rides: "Min rides (≥ n)",
  max_rides: "Max rides (≤ n)",
  rides_today: "Rides today (≥ n) — daily goal",
  time_of_day: "Time of day",
  min_fare: "Min fare",
  max_per_user: "Max per user",
};

function hhmm(min: number): string {
  const h = Math.floor(min / 60) % 24;
  return `${String(h).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`;
}
function toMin(v: string): number {
  const [h, m] = v.split(":").map(Number);
  return (h || 0) * 60 + (m || 0);
}

export default function CampaignsPage() {
  const [rows, setRows] = useState<Campaign[]>([]);
  const [form, setForm] = useState<NewCampaign>(EMPTY);
  const [rules, setRules] = useState<CampaignRule[]>([]);
  const [startsAt, setStartsAt] = useState("");
  const [endsAt, setEndsAt] = useState("");
  const [ruleToAdd, setRuleToAdd] = useState<RuleType>("new_user");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  const [query, setQuery] = useState("");

  function addRule() {
    setRules((r) => [...r, defaultRule(ruleToAdd)]);
  }
  function removeRule(i: number) {
    setRules((r) => r.filter((_, idx) => idx !== i));
  }
  function patchRule(i: number, patch: Partial<CampaignRule>) {
    setRules((r) => r.map((rule, idx) => (idx === i ? ({ ...rule, ...patch } as CampaignRule) : rule)));
  }

  async function load() {
    setError(null);
    try {
      setRows(await rides.listCampaigns());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function create() {
    setBusy(true);
    setError(null);
    try {
      await rides.createCampaign({
        ...form,
        value: Number(form.value),
        min_fare: form.min_fare ? Number(form.min_fare) : 0,
        max_discount: form.max_discount ? Number(form.max_discount) : null,
        usage_limit: form.usage_limit ? Number(form.usage_limit) : null,
        vehicle_class: form.vehicle_class || null,
        starts_at: startsAt ? new Date(startsAt).toISOString() : null,
        ends_at: endsAt ? new Date(endsAt).toISOString() : null,
        rules,
      });
      setForm(EMPTY);
      setRules([]);
      setStartsAt("");
      setEndsAt("");
      setShowAdd(false);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function deactivate(id: string) {
    try {
      await rides.deactivateCampaign(id);
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  function set<K extends keyof NewCampaign>(key: K, value: NewCampaign[K]) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((c) => [c.code, c.title].some((v) => v.toLowerCase().includes(q)));
  }, [rows, query]);

  const { page, setPage, pageCount, total, slice } = usePaged(filtered, 12);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Campaigns &amp; Offers</h1>
        <p className="subtle">
          Rider discounts and driver bonuses. Promos are platform-funded — the driver&apos;s payout is
          never reduced.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="toolbar">
        <div />
        <div className="toolbar-actions">
          <SearchInput value={query} onChange={setQuery} placeholder="Code, title…" />
          <button className="btn primary" onClick={() => setShowAdd(true)}>
            <Plus size={15} /> Add campaign
          </button>
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Code</th>
              <th>Title</th>
              <th>Audience</th>
              <th>Benefit</th>
              <th>Used</th>
              <th>Rules</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {slice.map((c) => (
              <tr key={c.id}>
                <td>
                  <b>{c.code}</b>
                </td>
                <td>{c.title}</td>
                <td>{c.audience}</td>
                <td>
                  {c.kind === "percent" ? `${c.value}%` : `NPR ${c.value}`}
                  {c.max_discount ? ` (max ${c.max_discount})` : ""}
                </td>
                <td className="subtle">
                  {c.used_count}
                  {c.usage_limit ? ` / ${c.usage_limit}` : ""}
                </td>
                <td className="subtle">
                  {c.rules && c.rules.length > 0
                    ? c.rules.map((r) => RULE_LABELS[r.type]).join(", ")
                    : "—"}
                </td>
                <td>
                  <span className={`badge ${c.active ? "approved" : "rejected"}`}>
                    {c.active ? "active" : "inactive"}
                  </span>
                </td>
                <td style={{ textAlign: "right" }}>
                  {c.active && (
                    <button className="btn ghost" onClick={() => deactivate(c.id)}>
                      Deactivate
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr>
                <td colSpan={8} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  No campaigns yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />

      <Modal
        open={showAdd}
        onClose={() => setShowAdd(false)}
        title="New campaign"
        wide
        footer={
          <>
            <button className="btn ghost" onClick={() => setShowAdd(false)}>Cancel</button>
            <button className="btn primary" disabled={busy} onClick={create}>
              {busy ? "Creating…" : "Create campaign"}
            </button>
          </>
        }
      >
        <div className="grid-2">
          <div className="field">
            <label>Code</label>
            <input
              className="input"
              value={form.code}
              onChange={(e) => set("code", e.target.value.toUpperCase())}
              placeholder="DASHAIN25"
            />
          </div>
          <div className="field">
            <label>Title</label>
            <input
              className="input"
              value={form.title}
              onChange={(e) => set("title", e.target.value)}
              placeholder="Dashain festival offer"
            />
          </div>
          <div className="field">
            <label>Audience</label>
            <select
              className="input"
              value={form.audience}
              onChange={(e) => set("audience", e.target.value as NewCampaign["audience"])}
            >
              <option value="rider">Rider discount</option>
              <option value="driver">Driver bonus</option>
            </select>
          </div>
          <div className="field">
            <label>Type</label>
            <select
              className="input"
              value={form.kind}
              onChange={(e) => set("kind", e.target.value as NewCampaign["kind"])}
            >
              <option value="percent">Percent (%)</option>
              <option value="flat">Flat (NPR)</option>
            </select>
          </div>
          <div className="field">
            <label>Value {form.kind === "percent" ? "(%)" : "(NPR)"}</label>
            <input
              className="input"
              type="number"
              value={form.value}
              onChange={(e) => set("value", Number(e.target.value))}
            />
          </div>
          <div className="field">
            <label>Max discount (NPR, optional)</label>
            <input
              className="input"
              type="number"
              value={form.max_discount ?? ""}
              onChange={(e) => set("max_discount", e.target.value ? Number(e.target.value) : null)}
              placeholder="e.g. 50"
            />
          </div>
          <div className="field">
            <label>Min fare (NPR)</label>
            <input
              className="input"
              type="number"
              value={form.min_fare ?? 0}
              onChange={(e) => set("min_fare", Number(e.target.value))}
            />
          </div>
          <div className="field">
            <label>Usage limit (optional)</label>
            <input
              className="input"
              type="number"
              value={form.usage_limit ?? ""}
              onChange={(e) => set("usage_limit", e.target.value ? Number(e.target.value) : null)}
              placeholder="unlimited"
            />
          </div>
          <div className="field">
            <label>Vehicle class (optional)</label>
            <select
              className="input"
              value={form.vehicle_class ?? ""}
              onChange={(e) => set("vehicle_class", e.target.value || null)}
            >
              <option value="">Any</option>
              <option value="two_wheeler">Two-wheeler</option>
              <option value="four_wheeler">Four-wheeler</option>
            </select>
          </div>
          <div className="field">
            <label>Starts at (optional)</label>
            <input
              className="input"
              type="datetime-local"
              value={startsAt}
              onChange={(e) => setStartsAt(e.target.value)}
            />
          </div>
          <div className="field">
            <label>Ends at (optional)</label>
            <input
              className="input"
              type="datetime-local"
              value={endsAt}
              onChange={(e) => setEndsAt(e.target.value)}
            />
          </div>
        </div>

        <div className="field" style={{ marginTop: 8 }}>
          <label>Eligibility rules (all must match)</label>
          <div className="row" style={{ marginBottom: 10 }}>
            <select
              className="input"
              style={{ maxWidth: 220 }}
              value={ruleToAdd}
              onChange={(e) => setRuleToAdd(e.target.value as RuleType)}
            >
              {(Object.keys(RULE_LABELS) as RuleType[]).map((t) => (
                <option key={t} value={t}>
                  {RULE_LABELS[t]}
                </option>
              ))}
            </select>
            <button type="button" className="btn ghost" onClick={addRule}>
              + Add rule
            </button>
          </div>
          {rules.length === 0 && <p className="subtle">No rules — offer applies to everyone.</p>}
          {rules.map((rule, i) => (
            <div key={i} className="row" style={{ marginBottom: 8, flexWrap: "wrap" }}>
              <span className="badge under_review">{RULE_LABELS[rule.type]}</span>
              {rule.type === "new_user" && (
                <>
                  <input
                    className="input"
                    style={{ maxWidth: 150 }}
                    type="number"
                    placeholder="within days"
                    value={rule.within_days ?? ""}
                    onChange={(e) =>
                      patchRule(i, { within_days: e.target.value ? Number(e.target.value) : null })
                    }
                  />
                  <input
                    className="input"
                    style={{ maxWidth: 160 }}
                    type="number"
                    placeholder="max prior rides"
                    value={rule.max_prior_rides ?? ""}
                    onChange={(e) =>
                      patchRule(i, {
                        max_prior_rides: e.target.value ? Number(e.target.value) : null,
                      })
                    }
                  />
                </>
              )}
              {(rule.type === "min_rides" ||
                rule.type === "max_rides" ||
                rule.type === "max_per_user" ||
                rule.type === "rides_today") && (
                <input
                  className="input"
                  style={{ maxWidth: 140 }}
                  type="number"
                  placeholder="count"
                  value={rule.count}
                  onChange={(e) => patchRule(i, { count: Number(e.target.value) })}
                />
              )}
              {rule.type === "min_fare" && (
                <input
                  className="input"
                  style={{ maxWidth: 140 }}
                  type="number"
                  placeholder="NPR"
                  value={rule.amount}
                  onChange={(e) => patchRule(i, { amount: Number(e.target.value) })}
                />
              )}
              {rule.type === "time_of_day" && (
                <>
                  <input
                    className="input"
                    style={{ maxWidth: 130 }}
                    type="time"
                    value={hhmm(rule.start_minute)}
                    onChange={(e) => patchRule(i, { start_minute: toMin(e.target.value) })}
                  />
                  <input
                    className="input"
                    style={{ maxWidth: 130 }}
                    type="time"
                    value={hhmm(rule.end_minute)}
                    onChange={(e) => patchRule(i, { end_minute: toMin(e.target.value) })}
                  />
                </>
              )}
              <button type="button" className="btn ghost" onClick={() => removeRule(i)}>
                Remove
              </button>
            </div>
          ))}
        </div>
      </Modal>
    </div>
  );
}
