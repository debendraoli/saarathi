// API client. All calls go through the API gateway (Traefik), which routes by
// path to the owning service — so one base URL covers every service.

const API_BASE = process.env.NEXT_PUBLIC_API_BASE ?? "http://localhost:8080";

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

// Parse the standard error envelope { error: { code, message } } → a display
// string. Apps should map `code` to a localized message; we fall back to message.
async function apiError(res: Response): Promise<string> {
  try {
    const body = await res.json();
    const err = body?.error;
    if (err && typeof err === "object") return err.message ?? err.code ?? `Request failed (${res.status})`;
    if (typeof err === "string") return err;
  } catch {
    /* ignore */
  }
  return `Request failed (${res.status})`;
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
    throw new Error(await apiError(res));
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

  // On-site KYC entry (staff onboards a walk-in driver).
  onboardDriver: (input: OnboardDriverInput) =>
    request<Driver>("/v1/admin/drivers/onboard", {
      method: "POST",
      body: JSON.stringify(input),
    }),

  async uploadDriverDocument(driverId: string, kind: string, file: File): Promise<DriverDocument> {
    const fd = new FormData();
    fd.append("kind", kind);
    fd.append("file", file);
    const res = await raw(`/v1/admin/drivers/${driverId}/documents`, { method: "POST", body: fd }, true);
    if (!res.ok) throw new Error(await apiError(res));
    return (await res.json()) as DriverDocument;
  },

  // ── Partnership / fleets (platform admin) ──────────────────────────────────
  adminListPartners: (status?: string) =>
    request<Partner[]>(`/v1/admin/partners${status ? `?status=${encodeURIComponent(status)}` : ""}`),
  adminCreatePartner: (body: NewPartner) =>
    request<Partner>("/v1/admin/partners", { method: "POST", body: JSON.stringify(body) }),
  adminPartnerDetail: (id: string) => request<PartnerDetail>(`/v1/admin/partners/${id}`),
  adminUpdatePartner: (id: string, body: Partial<{ status: string; commission_share: number; city: string; contact_email: string }>) =>
    request<Partner>(`/v1/admin/partners/${id}`, { method: "PUT", body: JSON.stringify(body) }),

  // ── Partner portal (member-scoped) ─────────────────────────────────────────
  partnerMemberships: () => request<Membership[]>("/v1/partner/memberships"),
  partnerMembers: (pid: string) => request<PartnerMemberRow[]>(`/v1/partner/${pid}/members`),
  partnerInviteMember: (pid: string, phone: string, role: string) =>
    request<PartnerMemberRow>(`/v1/partner/${pid}/members`, {
      method: "POST",
      body: JSON.stringify({ phone, role }),
    }),
  partnerSetMemberRole: (pid: string, uid: string, role: string) =>
    request<{ ok: boolean }>(`/v1/partner/${pid}/members/${uid}`, {
      method: "POST",
      body: JSON.stringify({ role }),
    }),
  partnerRemoveMember: (pid: string, uid: string) =>
    request<{ ok: boolean }>(`/v1/partner/${pid}/members/${uid}`, { method: "DELETE" }),
  partnerDrivers: (pid: string) => request<FleetDriver[]>(`/v1/partner/${pid}/drivers`),
  partnerAddDriver: (pid: string, body: AddFleetDriver) =>
    request<{ driver_user_id: string; status: string }>(`/v1/partner/${pid}/drivers`, {
      method: "POST",
      body: JSON.stringify(body),
    }),
  partnerSetDriverStatus: (pid: string, driverUserId: string, status: string) =>
    request<{ ok: boolean }>(`/v1/partner/${pid}/drivers/${driverUserId}`, {
      method: "POST",
      body: JSON.stringify({ status }),
    }),
  partnerRiders: (pid: string) => request<FleetRider[]>(`/v1/partner/${pid}/riders`),
  partnerAddRider: (pid: string, body: AddFleetRider) =>
    request<{ rider_user_id: string; status: string }>(`/v1/partner/${pid}/riders`, {
      method: "POST",
      body: JSON.stringify(body),
    }),
  partnerSetRiderStatus: (pid: string, riderUserId: string, status: string) =>
    request<{ ok: boolean }>(`/v1/partner/${pid}/riders/${riderUserId}`, {
      method: "POST",
      body: JSON.stringify({ status }),
    }),
};

export type PartnerType = "fleet" | "corporate" | "agent";
export type PartnerStatus = "pending" | "active" | "suspended" | "terminated";
export type PartnerRole = "owner" | "admin" | "manager" | "dispatcher" | "finance" | "support" | "viewer";

export interface Partner {
  id: string;
  name: string;
  legal_name: string | null;
  type: PartnerType;
  status: PartnerStatus;
  city: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  pan_vat: string | null;
  commission_share: string;
  created_at: string;
}

export interface PartnerDetail {
  partner: Partner;
  member_count: number;
  driver_count: number;
}

export interface NewPartner {
  name: string;
  owner_phone: string;
  legal_name?: string | null;
  partner_type?: PartnerType;
  city?: string | null;
  contact_email?: string | null;
  pan_vat?: string | null;
  commission_share?: number;
}

export interface Membership {
  partner_id: string;
  name: string;
  role: PartnerRole;
  status: PartnerStatus;
}

export interface PartnerMemberRow {
  user_id: string;
  phone: string;
  full_name: string | null;
  role: PartnerRole;
  created_at: string;
}

export interface FleetDriver {
  driver_user_id: string;
  phone: string;
  full_name: string | null;
  status: string;
  kyc_status: string | null;
  joined_at: string;
}

export interface AddFleetDriver {
  phone: string;
  full_name?: string | null;
  license_number?: string | null;
  vehicle_class?: VehicleClass | null;
  plate_number?: string | null;
}

export interface FleetRider {
  rider_user_id: string;
  phone: string;
  full_name: string | null;
  status: string;
  monthly_cap: string | null;
  joined_at: string;
}

export interface AddFleetRider {
  phone: string;
  full_name?: string | null;
  monthly_cap?: number | null;
}

export interface OnboardDriverInput {
  phone: string;
  full_name?: string | null;
  license_number?: string | null;
  date_of_birth?: string | null;
  address?: string | null;
  vehicle: {
    class: VehicleClass;
    make?: string | null;
    model?: string | null;
    year?: number | null;
    plate_number: string;
    color?: string | null;
  };
}

// ── Rides service (campaigns) ────────────────────────────────────────────────

// Same gateway; kept as a separate constant for call-site clarity.
const RIDES_BASE = process.env.NEXT_PUBLIC_RIDES_API_BASE ?? API_BASE;

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
  rules: CampaignRule[];
  created_at: string;
}

// Dynamic campaign eligibility rules (ANDed). Mirrors rides::rules::CampaignRule.
export type CampaignRule =
  | { type: "new_user"; within_days?: number | null; max_prior_rides?: number | null }
  | { type: "min_rides"; count: number }
  | { type: "max_rides"; count: number }
  | { type: "time_of_day"; start_minute: number; end_minute: number; days_mask?: number }
  | { type: "min_fare"; amount: number }
  | { type: "max_per_user"; count: number };

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
  starts_at?: string | null;
  ends_at?: string | null;
  rules?: CampaignRule[];
}

async function ridesRequest<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (auth.access) headers.set("Authorization", `Bearer ${auth.access}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const res = await fetch(`${RIDES_BASE}${path}`, { ...init, headers });
  if (!res.ok) {
    throw new Error(await apiError(res));
  }
  return (await res.json()) as T;
}

export const rides = {
  listCampaigns: () => ridesRequest<Campaign[]>("/v1/admin/campaigns"),

  createCampaign: (c: NewCampaign) =>
    ridesRequest<Campaign>("/v1/admin/campaigns", { method: "POST", body: JSON.stringify(c) }),

  deactivateCampaign: (id: string) =>
    ridesRequest<{ ok: boolean }>(`/v1/admin/campaigns/${id}/deactivate`, { method: "POST" }),

  // Live tracking
  activeTrips: () => ridesRequest<ActiveTrip[]>("/v1/admin/trips/active"),
  tripLocation: (id: string) => ridesRequest<TripLocation>(`/v1/rides/${id}/location`),

  // SOS
  listSos: () => ridesRequest<SosIncident[]>("/v1/admin/sos"),
  resolveSos: (id: string, note?: string) =>
    ridesRequest<{ resolved: boolean }>(`/v1/admin/sos/${id}/resolve`, {
      method: "POST",
      body: JSON.stringify({ note }),
    }),

  // Reports
  listReports: () => ridesRequest<Report[]>("/v1/admin/reports"),
  resolveReport: (id: string, status: string, resolution?: string) =>
    ridesRequest<{ ok: boolean }>(`/v1/admin/reports/${id}/resolve`, {
      method: "POST",
      body: JSON.stringify({ status, resolution }),
    }),

  // Finance
  listLedger: () => ridesRequest<LedgerEntry[]>("/v1/admin/ledger"),
  verifyLedger: () => ridesRequest<{ chain_intact: boolean }>("/v1/admin/ledger/verify"),
  listPayouts: () => ridesRequest<Payout[]>("/v1/admin/payouts"),

  // Credit plans (maker-checker)
  listCreditPlans: () => ridesRequest<CreditPlan[]>("/v1/admin/credit-plans"),
  createCreditPlan: (p: NewCreditPlan) =>
    ridesRequest<CreditPlan>("/v1/admin/credit-plans", { method: "POST", body: JSON.stringify(p) }),
  approveCreditPlan: (id: string) =>
    ridesRequest<{ status: string }>(`/v1/admin/credit-plans/${id}/approve`, { method: "POST" }),
  rejectCreditPlan: (id: string, note?: string) =>
    ridesRequest<{ status: string }>(`/v1/admin/credit-plans/${id}/reject`, {
      method: "POST",
      body: JSON.stringify({ note }),
    }),

  // Ops insights
  adminRides: (status?: string) =>
    ridesRequest<RideRow[]>(`/v1/admin/rides${status ? `?status=${encodeURIComponent(status)}` : ""}`),
  cancellations: () => ridesRequest<RideRow[]>("/v1/admin/cancellations"),
  leaderboard: (role: string, by: string) =>
    ridesRequest<LeaderRow[]>(`/v1/admin/leaderboard?role=${role}&by=${by}`),

  // Feature flags (circuit breakers)
  listFlags: () => ridesRequest<FeatureFlag[]>("/v1/admin/flags"),
  setFlag: (key: string, enabled: boolean, description?: string) =>
    ridesRequest<FeatureFlag>(`/v1/admin/flags/${encodeURIComponent(key)}`, {
      method: "PUT",
      body: JSON.stringify({ enabled, description }),
    }),

  // Surge windows
  listSurge: () => ridesRequest<SurgeWindow[]>("/v1/admin/surge"),
  createSurge: (w: NewSurgeWindow) =>
    ridesRequest<SurgeWindow>("/v1/admin/surge", { method: "POST", body: JSON.stringify(w) }),
  deactivateSurge: (id: string) =>
    ridesRequest<{ ok: boolean }>(`/v1/admin/surge/${id}/deactivate`, { method: "POST" }),

  // Platform analytics
  analyticsOverview: () => ridesRequest<AnalyticsOverview>("/v1/admin/analytics/overview"),
  analyticsTimeseries: (days = 14) =>
    ridesRequest<{ days: number; series: TimeseriesPoint[] }>(
      `/v1/admin/analytics/timeseries?days=${days}`,
    ),

  // Fleet analytics (partner-scoped)
  partnerAnalytics: (pid: string) => ridesRequest<FleetAnalytics>(`/v1/partner/${pid}/analytics`),

  // Fleet money (partner-scoped)
  partnerWallet: (pid: string) => ridesRequest<PartnerWallet>(`/v1/partner/${pid}/wallet`),
  partnerLedger: (pid: string) => ridesRequest<PartnerLedgerRow[]>(`/v1/partner/${pid}/ledger`),
  partnerVerifyLedger: (pid: string) =>
    ridesRequest<{ chain_intact: boolean }>(`/v1/partner/${pid}/ledger/verify`),
  partnerTopup: (pid: string, amount: number) =>
    ridesRequest<{ reference: string }>(`/v1/partner/${pid}/wallet/topup`, {
      method: "POST",
      body: JSON.stringify({ amount }),
    }),
  partnerConfirmTopup: (pid: string, reference: string) =>
    ridesRequest<{ confirmed: boolean; balance: string }>(`/v1/partner/${pid}/wallet/topup/confirm`, {
      method: "POST",
      body: JSON.stringify({ reference }),
    }),
  partnerRequestPayout: (pid: string, amount?: number) =>
    ridesRequest<{ amount: string; balance: string }>(`/v1/partner/${pid}/payouts`, {
      method: "POST",
      body: JSON.stringify(amount ? { amount } : {}),
    }),
  partnerCampaigns: (pid: string) => ridesRequest<FleetCampaign[]>(`/v1/partner/${pid}/campaigns`),
  partnerCreateCampaign: (pid: string, body: NewFleetCampaign) =>
    ridesRequest<FleetCampaign>(`/v1/partner/${pid}/campaigns`, {
      method: "POST",
      body: JSON.stringify(body),
    }),
  partnerDeactivateCampaign: (pid: string, id: string) =>
    ridesRequest<{ ok: boolean }>(`/v1/partner/${pid}/campaigns/${id}/deactivate`, { method: "POST" }),
};

export interface FleetAnalytics {
  active_drivers: number;
  trips: { total: number; completed: number; cancelled: number };
  money: { gmv: string; driver_earnings: string; currency: string };
  leaderboard: { driver_id: string; name: string | null; trips: number; earnings: string }[];
}

export interface PartnerWallet {
  balance: string;
  lifetime_share: string;
  currency: string;
}

export interface PartnerLedgerRow {
  kind: string;
  amount: string;
  balance_after: string;
  trip_id: string | null;
  created_at: string;
}

export interface FleetCampaign {
  id: string;
  code: string;
  title: string;
  kind: "percent" | "flat";
  value: string;
  max_discount: string | null;
  active: boolean;
  used_count: number;
  created_at: string;
}

export interface NewFleetCampaign {
  code: string;
  title: string;
  kind: "percent" | "flat";
  value: number;
  max_discount?: number | null;
  min_fare?: number;
}

export interface FeatureFlag {
  key: string;
  enabled: boolean;
  description: string | null;
  updated_by: string | null;
  updated_at: string;
}

export interface SurgeWindow {
  id: string;
  label: string;
  start_minute: number;
  end_minute: number;
  multiplier: string;
  days_mask: number;
  vehicle_class: string | null;
  city: string | null;
  active: boolean;
  created_at: string;
}

export interface NewSurgeWindow {
  label: string;
  start_minute: number;
  end_minute: number;
  multiplier: number;
  days_mask?: number;
  vehicle_class?: string | null;
  city?: string | null;
}

export interface AnalyticsOverview {
  trips: {
    total: number;
    completed: number;
    cancelled: number;
    active: number;
    completed_today: number;
    completion_rate: number;
    cancellation_rate: number;
  };
  money: {
    gmv: string;
    commission_earned: string;
    accident_fund_levied: string;
    driver_payouts: string;
    currency: string;
  };
  tax: {
    vat_rate: string;
    vat_on_commission: string;
    tds_withheld: string;
    currency: string;
  };
  supply: { drivers_total: number; drivers_approved: number; drivers_online: number };
  demand: { users_total: number; riders: number; signups_7d: number };
}

export interface TimeseriesPoint {
  day: string;
  requested: number;
  completed: number;
  gmv: string;
}

export interface CreditPlan {
  id: string;
  name: string;
  min_amount: string;
  max_amount: string;
  bonus_percent: string;
  status: string;
  review_note: string | null;
  created_at: string;
}

export interface NewCreditPlan {
  name: string;
  min_amount: number;
  max_amount: number;
  bonus_percent?: number;
}

export interface RideRow {
  id: string;
  rider_id: string;
  rider_name: string | null;
  driver_id: string | null;
  driver_name: string | null;
  status: string;
  final_fare: string;
  payment_method: string;
  cancel_reason: string | null;
  cancelled_by_role: string | null;
  driver_stars: number | null;
  created_at: string;
}

export interface LeaderRow {
  user_id: string;
  name: string | null;
  phone: string;
  value: number;
}

export interface ActiveTrip {
  id: string;
  rider_id: string;
  driver_id: string | null;
  status: string;
  origin_lat: number;
  origin_lng: number;
  dest_lat: number;
  dest_lng: number;
  final_fare: string;
}

export interface TripLocation {
  lat: number | null;
  lng: number | null;
  heading: number | null;
  speed: number | null;
  at: number | null;
  by: string | null;
}

export interface SosIncident {
  id: string;
  user_id: string;
  trip_id: string | null;
  lat: number | null;
  lng: number | null;
  status: string;
  note: string | null;
  created_at: string;
}

export interface Report {
  id: string;
  reporter_id: string;
  subject_id: string | null;
  trip_id: string | null;
  category: string;
  severity: string;
  detail: string | null;
  status: string;
  resolution: string | null;
  created_at: string;
}

export interface LedgerEntry {
  seq: number;
  trip_id: string;
  driver_id: string | null;
  gross: string;
  commission: string;
  accident_fund: string;
  driver_payout: string;
  payment_method: string;
  entry_hash: string;
  report_status: string;
  created_at: string;
}

export interface Payout {
  id: string;
  driver_id: string;
  amount: string;
  tds_amount: string;
  net_amount: string | null;
  status: string;
  reference: string | null;
  created_at: string;
}
