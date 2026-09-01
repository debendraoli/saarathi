import { auth } from "./auth";
import { API_BASE, apiError } from "./client";

// ── Merchant service (marketplace admin) ────────────────────────────────────

const MERCHANT_BASE = process.env.NEXT_PUBLIC_MERCHANT_API_BASE ?? API_BASE;

async function merchantRequest<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (auth.access) headers.set("Authorization", `Bearer ${auth.access}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const res = await fetch(`${MERCHANT_BASE}${path}`, { ...init, headers });
  if (!res.ok) throw new Error(await apiError(res));
  return (await res.json()) as T;
}

export interface MerchantRow {
  id: string;
  name: string;
  vertical: string;
  address: string | null;
  phone: string | null;
  lat: number;
  lng: number;
  prep_mins: number;
  is_open: boolean;
  rating: string;
  image_key: string | null;
  status: "pending" | "approved" | "rejected";
  rejection_reason: string | null;
}

export interface NewMerchant {
  name: string;
  vertical: string;
  lat: number;
  lng: number;
  address?: string | null;
  phone?: string | null;
  owner_user_id?: string | null;
  prep_mins?: number;
}

export interface MerchantMenuItem {
  id: string;
  merchant_id: string;
  name: string;
  description: string | null;
  category: string | null;
  price: string;
  is_available: boolean;
  image_key: string | null;
}

export interface MerchantOrderRow {
  id: string;
  customer_id: string;
  merchant_id: string;
  merchant_name: string;
  status: string;
  subtotal: string;
  delivery_fee: string;
  total: string;
  payment_method: string;
  delivery_lat: number | null;
  delivery_lng: number | null;
  trip_id: string | null;
  created_at: string;
}

export interface ZonePoint {
  lat: number;
  lng: number;
}

export interface MerchantZone {
  merchant_id: string;
  points: ZonePoint[];
  cell_count: number;
}

export const merchant = {
  // Staff sees every merchant, regardless of vertical or open/closed state.
  list: () => merchantRequest<MerchantRow[]>("/v1/merchant/merchants"),

  create: (m: NewMerchant) =>
    merchantRequest<{ id: string; owner_user_id: string }>("/v1/admin/merchants", {
      method: "POST",
      body: JSON.stringify(m),
    }),

  // Pending applications by default; pass "all" for every store regardless
  // of review state (mirrors listDrivers' status param).
  queue: (status: "pending" | "all" = "pending") =>
    merchantRequest<MerchantRow[]>(`/v1/admin/merchants/queue?status=${status}`),

  approve: (id: string) =>
    merchantRequest<{ ok: boolean }>(`/v1/admin/merchants/${id}/approve`, { method: "POST" }),

  reject: (id: string, reason: string) =>
    merchantRequest<{ ok: boolean }>(`/v1/admin/merchants/${id}/reject`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    }),

  update: (
    id: string,
    fields: { name?: string; address?: string; phone?: string; prep_mins?: number; vertical?: string },
  ) =>
    merchantRequest<{ ok: boolean }>(`/v1/admin/merchants/${id}`, {
      method: "PATCH",
      body: JSON.stringify(fields),
    }),

  menu: (id: string) => merchantRequest<MerchantMenuItem[]>(`/v1/merchant/merchants/${id}/menu`),

  // No merchant-scoped filter on the backend — staff gets every order; filter client-side.
  orders: () => merchantRequest<MerchantOrderRow[]>("/v1/merchant/orders"),

  setOpen: (merchantId: string, isOpen: boolean) =>
    merchantRequest<{ ok: boolean; is_open: boolean }>("/v1/merchant/open", {
      method: "POST",
      body: JSON.stringify({ merchant_id: merchantId, is_open: isOpen }),
    }),

  zone: (id: string) => merchantRequest<MerchantZone>(`/v1/merchant/zone/${id}`),

  setZone: (id: string, points: ZonePoint[]) =>
    merchantRequest<{ ok: boolean; cell_count: number }>(`/v1/merchant/zone/${id}`, {
      method: "PUT",
      body: JSON.stringify({ points }),
    }),
};
