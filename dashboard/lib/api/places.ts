import { raw, request } from "./client";

// ── Places service (map-contribution review queue) ─────────────────────────

export type PlaceCategory =
  | "organisation"
  | "building"
  | "landmark"
  | "construction"
  | "closed_road"
  | "sign"
  | "other";
export type PlaceStatus = "pending" | "approved" | "rejected";

export interface PlaceContributionAdmin {
  id: string;
  contributor_id: string;
  category: PlaceCategory;
  name: string;
  description: string | null;
  lat: number;
  lng: number;
  capture_lat: number;
  capture_lng: number;
  capture_distance_m: number;
  status: PlaceStatus;
  rejection_reason: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  points_awarded: number | null;
  created_at: string;
}

export const places = {
  queue: (status: PlaceStatus = "pending") =>
    request<{ items: PlaceContributionAdmin[] }>(
      `/v1/admin/places/contributions?status=${encodeURIComponent(status)}`,
    ).then((r) => r.items),

  detail: (id: string) => request<PlaceContributionAdmin>(`/v1/admin/places/contributions/${id}`),

  approve: (id: string) =>
    request<{ ok: boolean; points_awarded: number }>(`/v1/admin/places/contributions/${id}/approve`, {
      method: "POST",
    }),

  reject: (id: string, reason: string) =>
    request<{ ok: boolean }>(`/v1/admin/places/contributions/${id}/reject`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    }),

  async photoBlobUrl(id: string): Promise<string> {
    const res = await raw(`/v1/admin/places/contributions/${id}/photo`, {}, true);
    if (!res.ok) throw new Error("could not load photo");
    const blob = await res.blob();
    return URL.createObjectURL(blob);
  },
};
