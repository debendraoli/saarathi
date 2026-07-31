// API client for the saarathi-auth service. Client-side only (uses localStorage).

const API_BASE = process.env.NEXT_PUBLIC_API_BASE ?? "http://localhost:8081";

const ACCESS_KEY = "saarathi.access";
const REFRESH_KEY = "saarathi.refresh";
const USER_KEY = "saarathi.user";

export type UserRole =
  | "rider"
  | "driver"
  | "super_admin"
  | "admin"
  | "dispatcher"
  | "finance"
  | "compliance"
  | "support"
  | "analyst";

export type KycStatus = "pending" | "under_review" | "approved" | "rejected";
export type DocumentStatus = "submitted" | "approved" | "rejected";
export type VehicleClass = "two_wheeler" | "four_wheeler";

export interface User {
  id: string;
  phone: string;
  full_name: string | null;
  role: UserRole;
  status: string;
  created_at: string;
  updated_at: string;
}

export interface DriverListItem {
  id: string;
  user_id: string;
  kyc_status: KycStatus;
  full_name: string | null;
  phone: string;
  license_number: string | null;
  created_at: string;
  reviewed_at: string | null;
}

export interface Driver {
  id: string;
  user_id: string;
  kyc_status: KycStatus;
  license_number: string | null;
  date_of_birth: string | null;
  address: string | null;
  rejection_reason: string | null;
  reviewed_at: string | null;
  approved_at: string | null;
  created_at: string;
}

export interface Vehicle {
  id: string;
  class: VehicleClass;
  make: string | null;
  model: string | null;
  year: number | null;
  plate_number: string;
  color: string | null;
}

export interface DriverDocument {
  id: string;
  kind: string;
  content_type: string | null;
  status: DocumentStatus;
  expires_at: string | null;
  rejection_reason: string | null;
  created_at: string;
}

export interface DriverDetail {
  driver: Driver;
  user: User;
  vehicle: Vehicle | null;
  documents: DriverDocument[];
}

// ── Token storage ────────────────────────────────────────────────────────────

export const auth = {
  get access() {
    return typeof window === "undefined" ? null : localStorage.getItem(ACCESS_KEY);
  },
  get refresh() {
    return typeof window === "undefined" ? null : localStorage.getItem(REFRESH_KEY);
  },
  get user(): User | null {
    if (typeof window === "undefined") return null;
    const raw = localStorage.getItem(USER_KEY);
    return raw ? (JSON.parse(raw) as User) : null;
  },
  set(access: string, refresh: string, user: User) {
    localStorage.setItem(ACCESS_KEY, access);
    localStorage.setItem(REFRESH_KEY, refresh);
    localStorage.setItem(USER_KEY, JSON.stringify(user));
  },
  clear() {
    localStorage.removeItem(ACCESS_KEY);
    localStorage.removeItem(REFRESH_KEY);
    localStorage.removeItem(USER_KEY);
  },
};

// ── Core request helper (with one refresh retry) ────────────────────────────

async function raw(path: string, init: RequestInit, withAuth: boolean): Promise<Response> {
  const headers = new Headers(init.headers);
  if (withAuth && auth.access) headers.set("Authorization", `Bearer ${auth.access}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  return fetch(`${API_BASE}${path}`, { ...init, headers });
}

async function request<T>(path: string, init: RequestInit = {}, withAuth = true): Promise<T> {
  let res = await raw(path, init, withAuth);

  if (res.status === 401 && withAuth && auth.refresh) {
    const refreshed = await raw(
      "/v1/auth/refresh",
      { method: "POST", body: JSON.stringify({ refresh_token: auth.refresh }) },
      false,
    );
    if (refreshed.ok) {
      const data = (await refreshed.json()) as TokenPair;
      auth.set(data.access_token, data.refresh_token, data.user);
      res = await raw(path, init, withAuth);
    }
  }

  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      if (body?.error) message = body.error;
    } catch {
      /* ignore */
    }
    throw new Error(message);
  }
  return (await res.json()) as T;
}

export interface TokenPair {
  access_token: string;
  refresh_token: string;
  user: User;
}

// ── Endpoints ────────────────────────────────────────────────────────────────

export const api = {
  requestOtp: (phone: string) =>
    request<{ sent: boolean; dev_code?: string }>(
      "/v1/auth/otp/request",
      { method: "POST", body: JSON.stringify({ phone }) },
      false,
    ),

  verifyOtp: (phone: string, code: string) =>
    request<TokenPair>(
      "/v1/auth/otp/verify",
      { method: "POST", body: JSON.stringify({ phone, code }) },
      false,
    ),

  listDrivers: (status: string) =>
    request<DriverListItem[]>(`/v1/admin/drivers?status=${encodeURIComponent(status)}`),

  driverDetail: (id: string) => request<DriverDetail>(`/v1/admin/drivers/${id}`),

  approveDriver: (id: string) =>
    request<{ ok: boolean }>(`/v1/admin/drivers/${id}/approve`, { method: "POST" }),

  rejectDriver: (id: string, reason: string) =>
    request<{ ok: boolean }>(`/v1/admin/drivers/${id}/reject`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    }),

  async documentBlobUrl(id: string): Promise<string> {
    const res = await raw(`/v1/admin/documents/${id}/content`, {}, true);
    if (!res.ok) throw new Error("could not load document");
    const blob = await res.blob();
    return URL.createObjectURL(blob);
  },
};

// ── Rides service (campaigns) ────────────────────────────────────────────────

const RIDES_BASE = process.env.NEXT_PUBLIC_RIDES_API_BASE ?? "http://localhost:8082";

export interface Campaign {
  id: string;
  code: string;
  title: string;
  audience: "rider" | "driver";
  kind: "percent" | "flat";
  value: string;
  min_fare: string;
  max_discount: string | null;
  city: string | null;
  vehicle_class: string | null;
  starts_at: string | null;
  ends_at: string | null;
  active: boolean;
  usage_limit: number | null;
  used_count: number;
  created_at: string;
}

export interface NewCampaign {
  code: string;
  title: string;
  audience: "rider" | "driver";
  kind: "percent" | "flat";
  value: number;
  min_fare?: number;
  max_discount?: number | null;
  vehicle_class?: string | null;
  usage_limit?: number | null;
}

async function ridesRequest<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (auth.access) headers.set("Authorization", `Bearer ${auth.access}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const res = await fetch(`${RIDES_BASE}${path}`, { ...init, headers });
  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      if (body?.error) message = body.error;
    } catch {
      /* ignore */
    }
    throw new Error(message);
  }
  return (await res.json()) as T;
}

export const rides = {
  listCampaigns: () => ridesRequest<Campaign[]>("/v1/admin/campaigns"),

  createCampaign: (c: NewCampaign) =>
    ridesRequest<Campaign>("/v1/admin/campaigns", { method: "POST", body: JSON.stringify(c) }),

  deactivateCampaign: (id: string) =>
    ridesRequest<{ ok: boolean }>(`/v1/admin/campaigns/${id}/deactivate`, { method: "POST" }),
};
