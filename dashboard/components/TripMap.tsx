"use client";

import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { MapContainer, TileLayer, Marker, Polyline, useMap } from "react-leaflet";
import { useEffect } from "react";

// Plain colored dots via divIcon rather than Leaflet's default pin images —
// those reference relative paths Next.js's bundler won't resolve, and this
// avoids an external CDN dependency for something this simple.
function dot(color: string, size = 16): L.DivIcon {
  return L.divIcon({
    html: `<span style="display:block;width:${size}px;height:${size}px;border-radius:50%;background:${color};border:2px solid #0a0c11;box-shadow:0 0 0 1px ${color}66;"></span>`,
    className: "",
    iconSize: [size, size],
    iconAnchor: [size / 2, size / 2],
  });
}
const startIcon = dot("#2ecc71");
const endIcon = dot("#f0616d");
const liveIcon = dot("#5aa2ff", 18);

export interface LatLng {
  lat: number;
  lng: number;
}

/** Re-fits the view whenever the set of points to show changes. */
function FitBounds({ points }: { points: LatLng[] }) {
  const map = useMap();
  useEffect(() => {
    if (points.length === 0) return;
    if (points.length === 1) {
      map.setView([points[0].lat, points[0].lng], 15);
      return;
    }
    map.fitBounds(
      points.map((p) => [p.lat, p.lng] as [number, number]),
      { padding: [32, 32] },
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(points)]);
  return null;
}

/**
 * Start → breadcrumb trail → end on an OSM basemap. Used for both a
 * completed trip's full historical path and a live trip's current position
 * (pass a single-point `breadcrumbs` and no `dest` for the latter).
 */
export function TripMap({
  origin,
  dest,
  breadcrumbs = [],
  live,
  heightPx = 360,
}: {
  origin: LatLng;
  dest?: LatLng;
  breadcrumbs?: LatLng[];
  live?: LatLng | null;
  heightPx?: number;
}) {
  const trail = breadcrumbs.length > 0 ? breadcrumbs : dest ? [origin, dest] : [origin];
  const allPoints = [origin, ...(dest ? [dest] : []), ...breadcrumbs, ...(live ? [live] : [])];

  return (
    <div style={{ height: heightPx, borderRadius: 12, overflow: "hidden" }}>
      <MapContainer
        center={[origin.lat, origin.lng]}
        zoom={14}
        style={{ height: "100%", width: "100%", background: "#121620" }}
        scrollWheelZoom
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {trail.length > 1 && (
          <Polyline
            positions={trail.map((p) => [p.lat, p.lng] as [number, number])}
            pathOptions={{ color: "#f5a623", weight: 4, opacity: 0.85 }}
          />
        )}
        <Marker position={[origin.lat, origin.lng]} icon={startIcon} />
        {dest && <Marker position={[dest.lat, dest.lng]} icon={endIcon} />}
        {live && <Marker position={[live.lat, live.lng]} icon={liveIcon} />}
        <FitBounds points={allPoints} />
      </MapContainer>
    </div>
  );
}
