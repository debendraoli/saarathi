"use client";

import { useEffect, useRef, useState } from "react";

/** Track a container's pixel width so charts render crisp (no viewBox distortion). */
function useWidth() {
  const ref = useRef<HTMLDivElement>(null);
  const [w, setW] = useState(560);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const cw = entries[0]?.contentRect.width;
      if (cw && cw > 0) setW(cw);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return { ref, w };
}

type Row = Record<string, number | string>;
type Series = { key: string; label: string; color: string };

/** Multi-series area+line chart with gridlines and an x-axis. */
export function LineChart({
  data,
  x,
  series,
  height = 190,
  fmt = (v) => String(Math.round(v)),
}: {
  data: Row[];
  x: string;
  series: Series[];
  height?: number;
  fmt?: (v: number) => string;
}) {
  const { ref, w } = useWidth();
  const padL = 46;
  const padR = 14;
  const padT = 14;
  const padB = 26;
  const iw = Math.max(10, w - padL - padR);
  const ih = height - padT - padB;
  const n = data.length;
  const vals = data.flatMap((d) => series.map((s) => Number(d[s.key]) || 0));
  const max = Math.max(1, ...vals);
  const xAt = (i: number) => padL + (n <= 1 ? iw / 2 : (i / (n - 1)) * iw);
  const yAt = (v: number) => padT + ih - (v / max) * ih;
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((t) => Math.round(max * t));
  const labelEvery = Math.ceil(n / 7);

  return (
    <div ref={ref} style={{ width: "100%" }}>
      {n === 0 ? (
        <div className="chart-empty" style={{ height }}>
          No data
        </div>
      ) : (
        <>
          <div className="chart-legend">
            {series.map((s) => (
              <span key={s.key} className="chart-legend-item">
                <i style={{ background: s.color }} /> {s.label}
              </span>
            ))}
          </div>
          <svg width={w} height={height} role="img">
            {ticks.map((t, i) => {
              const y = yAt(t);
              return (
                <g key={i}>
                  <line x1={padL} y1={y} x2={w - padR} y2={y} className="grid-line" />
                  <text x={padL - 8} y={y + 3} textAnchor="end" className="axis-label">
                    {fmt(t)}
                  </text>
                </g>
              );
            })}
            {series.map((s) => {
              const pts = data.map((d, i) => [xAt(i), yAt(Number(d[s.key]) || 0)] as const);
              const line = pts.map((p, i) => `${i ? "L" : "M"}${p[0]},${p[1]}`).join(" ");
              const area = `${line} L${xAt(n - 1)},${padT + ih} L${xAt(0)},${padT + ih} Z`;
              return (
                <g key={s.key}>
                  <path d={area} fill={s.color} opacity={0.1} />
                  <path d={line} fill="none" stroke={s.color} strokeWidth={2} />
                  {pts.map((p, i) => (
                    <circle key={i} cx={p[0]} cy={p[1]} r={2.4} fill={s.color} />
                  ))}
                </g>
              );
            })}
            {data.map((d, i) =>
              i % labelEvery === 0 || i === n - 1 ? (
                <text key={i} x={xAt(i)} y={height - 8} textAnchor="middle" className="axis-label">
                  {String(d[x]).slice(5)}
                </text>
              ) : null,
            )}
          </svg>
        </>
      )}
    </div>
  );
}

/** Vertical bar chart from labelled values. */
export function BarChart({
  data,
  height = 190,
  color = "var(--color-brand)",
  fmt = (v) => String(Math.round(v)),
}: {
  data: { label: string; value: number }[];
  height?: number;
  color?: string;
  fmt?: (v: number) => string;
}) {
  const { ref, w } = useWidth();
  const padL = 46;
  const padR = 14;
  const padT = 14;
  const padB = 26;
  const iw = Math.max(10, w - padL - padR);
  const ih = height - padT - padB;
  const max = Math.max(1, ...data.map((d) => d.value));
  const bw = data.length ? (iw / data.length) * 0.62 : 0;
  const ticks = [0, 0.5, 1].map((t) => Math.round(max * t));

  return (
    <div ref={ref} style={{ width: "100%" }}>
      {data.length === 0 ? (
        <div className="chart-empty" style={{ height }}>
          No data
        </div>
      ) : (
        <svg width={w} height={height} role="img">
          {ticks.map((t, i) => {
            const y = padT + ih - (t / max) * ih;
            return (
              <g key={i}>
                <line x1={padL} y1={y} x2={w - padR} y2={y} className="grid-line" />
                <text x={padL - 8} y={y + 3} textAnchor="end" className="axis-label">
                  {fmt(t)}
                </text>
              </g>
            );
          })}
          {data.map((d, i) => {
            const cx = padL + (i + 0.5) * (iw / data.length);
            const h = (d.value / max) * ih;
            return (
              <g key={i}>
                <rect
                  x={cx - bw / 2}
                  y={padT + ih - h}
                  width={bw}
                  height={h}
                  rx={4}
                  fill={color}
                />
                <text x={cx} y={height - 8} textAnchor="middle" className="axis-label">
                  {d.label}
                </text>
              </g>
            );
          })}
        </svg>
      )}
    </div>
  );
}

/** Donut chart with a centred label. */
export function Donut({
  segments,
  size = 148,
  thickness = 18,
  centerLabel,
  centerSub,
}: {
  segments: { label: string; value: number; color: string }[];
  size?: number;
  thickness?: number;
  centerLabel?: string;
  centerSub?: string;
}) {
  const total = segments.reduce((a, s) => a + s.value, 0) || 1;
  const r = (size - thickness) / 2;
  const c = size / 2;
  const circ = 2 * Math.PI * r;
  let acc = 0;

  return (
    <div className="donut">
      <svg width={size} height={size} role="img">
        <circle cx={c} cy={c} r={r} fill="none" stroke="var(--color-surface-2)" strokeWidth={thickness} />
        {segments.map((s, i) => {
          const frac = s.value / total;
          const dash = frac * circ;
          const el = (
            <circle
              key={i}
              cx={c}
              cy={c}
              r={r}
              fill="none"
              stroke={s.color}
              strokeWidth={thickness}
              strokeDasharray={`${dash} ${circ - dash}`}
              strokeDashoffset={-acc * circ}
              transform={`rotate(-90 ${c} ${c})`}
              strokeLinecap="butt"
            />
          );
          acc += frac;
          return el;
        })}
      </svg>
      {(centerLabel || centerSub) && (
        <div className="donut-center">
          {centerLabel && <div className="donut-value">{centerLabel}</div>}
          {centerSub && <div className="donut-sub subtle">{centerSub}</div>}
        </div>
      )}
    </div>
  );
}

/** Tiny inline trend line. */
export function Sparkline({
  data,
  color = "var(--color-brand)",
  width = 90,
  height = 28,
}: {
  data: number[];
  color?: string;
  width?: number;
  height?: number;
}) {
  if (data.length < 2) return <svg width={width} height={height} />;
  const max = Math.max(...data);
  const min = Math.min(...data);
  const span = max - min || 1;
  const pts = data.map((v, i) => {
    const x = (i / (data.length - 1)) * width;
    const y = height - 2 - ((v - min) / span) * (height - 4);
    return `${x},${y}`;
  });
  return (
    <svg width={width} height={height} role="img">
      <polyline points={pts.join(" ")} fill="none" stroke={color} strokeWidth={1.6} />
    </svg>
  );
}

/** A KPI tile: label, big value, optional delta + sparkline. */
export function Kpi({
  label,
  value,
  hint,
  spark,
  sparkColor,
  icon,
}: {
  label: string;
  value: string;
  hint?: string;
  spark?: number[];
  sparkColor?: string;
  icon?: React.ReactNode;
}) {
  return (
    <div className="kpi">
      <div className="kpi-top">
        <span className="kpi-label">{label}</span>
        {icon && <span className="kpi-icon">{icon}</span>}
      </div>
      <div className="kpi-value">{value}</div>
      <div className="kpi-foot">
        {hint && <span className="subtle text-[12px]">{hint}</span>}
        {spark && spark.length > 1 && <Sparkline data={spark} color={sparkColor} />}
      </div>
    </div>
  );
}
