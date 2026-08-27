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
export type VehicleClass = "two_wheeler" | "three_wheeler" | "four_wheeler";

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
  service_types: string[];
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
  service_types: string[];
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

async function raw(
  path: string,
  init: RequestInit,
  withAuth: boolean,
  base: string = API_BASE,
): Promise<Response> {
  const headers = new Headers(init.headers);
  if (withAuth && auth.access) headers.set("Authorization", `Bearer ${auth.access}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  return fetch(`${base}${path}`, { ...init, headers });
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

async function request<T>(
  path: string,
  init: RequestInit = {},
  withAuth = true,
  base: string = API_BASE,
): Promise<T> {
  let res = await raw(path, init, withAuth, base);

  if (res.status === 401 && withAuth && auth.refresh) {
    // The refresh call itself always goes through the main gateway
    // (API_BASE), regardless of which base this request was for.
    const refreshed = await raw(
      "/v1/auth/refresh",
      { method: "POST", body: JSON.stringify({ refresh_token: auth.refresh }) },
      false,
    );
    if (refreshed.ok) {
      const data = (await refreshed.json()) as TokenPair;
      auth.set(data.access_token, data.refresh_token, data.user);
      res = await raw(path, init, withAuth, base);
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

  suspendDriver: (id: string) =>
    request<{ ok: boolean; status: string }>(`/v1/admin/drivers/${id}/suspend`, { method: "POST" }),

  reactivateDriver: (id: string) =>
    request<{ ok: boolean; status: string }>(`/v1/admin/drivers/${id}/reactivate`, { method: "POST" }),

  updateDriverServiceTypes: (id: string, serviceTypes: string[]) =>
    request<{ ok: boolean; service_types: string[] }>(`/v1/admin/drivers/${id}/service-types`, {
      method: "POST",
      body: JSON.stringify({ service_types: serviceTypes }),
    }),

  updateDriver: (
    id: string,
    fields: {
      full_name?: string;
      license_number?: string;
      date_of_birth?: string;
      address?: string;
      vehicle?: {
        make?: string;
        model?: string;
        year?: number;
        plate_number?: string;
        color?: string;
      };
    },
  ) =>
    request<Driver>(`/v1/admin/drivers/${id}`, {
      method: "PATCH",
      body: JSON.stringify(fields),
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
  adminUpdatePartner: (
    id: string,
    body: Partial<{
      status: string;
      commission_share: number;
      name: string;
      legal_name: string;
      partner_type: PartnerType;
      city: string;
      contact_phone: string;
      contact_email: string;
      pan_vat: string;
    }>,
  ) => request<Partner>(`/v1/admin/partners/${id}`, { method: "PUT", body: JSON.stringify(body) }),

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

  // Staff's own notification inbox — same per-user endpoint the rider/driver
  // app uses; a staff account is just a `users` row with a different role.
  notifications: () => request<{ unread: number; items: AppNotification[] }>("/v1/notifications"),
  markNotificationRead: (id: string) =>
    request<{ ok: boolean }>(`/v1/notifications/${id}/read`, { method: "POST" }),
  markAllNotificationsRead: () =>
    request<{ marked: number }>("/v1/notifications/read-all", { method: "POST" }),

  // ── Staff accounts (super_admin/admin only) ────────────────────────────────
  listStaff: () => request<User[]>("/v1/admin/staff"),
  createStaff: (body: { phone: string; full_name: string; role: StaffRole }) =>
    request<User>("/v1/admin/staff", { method: "POST", body: JSON.stringify(body) }),
  updateStaff: (id: string, body: Partial<{ role: StaffRole; full_name: string }>) =>
    request<User>(`/v1/admin/staff/${id}`, { method: "PATCH", body: JSON.stringify(body) }),
  deactivateStaff: (id: string) =>
    request<User>(`/v1/admin/staff/${id}/deactivate`, { method: "POST" }),
  reactivateStaff: (id: string) =>
    request<User>(`/v1/admin/staff/${id}/reactivate`, { method: "POST" }),
};

export type StaffRole = Exclude<UserRole, "rider" | "driver">;
export const STAFF_ROLES: StaffRole[] = [
  "super_admin",
  "admin",
  "dispatcher",
  "finance",
  "compliance",
  "support",
  "analyst",
];

export interface AppNotification {
  id: string;
  class: string;
  title: string;
  body: string | null;
  link: string | null;
  read_at: string | null;
  created_at: string;
}

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

export interface OwnedMerchant {
  id: string;
  name: string;
  vertical: string;
  is_open: boolean;
}

export interface PartnerDetail {
  partner: Partner;
  member_count: number;
  driver_count: number;
  drivers: FleetDriver[];
  merchants: OwnedMerchant[];
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
  address?: string | null;
  vehicle_class?: VehicleClass | null;
  plate_number?: string | null;
  model?: string | null;
  service_types?: string[];
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
  service_types?: string[];
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
  | { type: "rides_today"; count: number }
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

// Same refresh-and-retry behavior as the default `request()` — this used to
// be a separate hand-rolled fetch with no 401 retry, so anything routed
// through it (admin credit top-up, campaigns, credit plans, …) would hard-
// fail with "Request failed (401)" the moment the access token expired,
// even though the staff member was still logged in and every other page
// (backed by `request()`) kept working fine.
async function ridesRequest<T>(path: string, init: RequestInit = {}): Promise<T> {
  return request<T>(path, init, true, RIDES_BASE);
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
  tripRoute: (id: string) => ridesRequest<TripRoute>(`/v1/admin/trips/${id}/route`),

  // SOS
  listSos: () => ridesRequest<SosIncident[]>("/v1/admin/sos"),
  resolveSos: (id: string, note?: string) =>
    ridesRequest<{ resolved: boolean }>(`/v1/admin/sos/${id}/resolve`, {
      method: "POST",
      body: JSON.stringify({ note }),
    }),

  // Support chat
  listSupportThreads: () => ridesRequest<SupportThread[]>("/v1/admin/support/threads"),
  supportThreadMessages: (userId: string) =>
    ridesRequest<SupportMessage[]>(`/v1/admin/support/threads/${userId}/messages`),
  replySupportThread: (userId: string, body: string) =>
    ridesRequest<SupportMessage>(`/v1/admin/support/threads/${userId}/messages`, {
      method: "POST",
      body: JSON.stringify({ body }),
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
  cancellations: () => ridesRequest<CancellationRow[]>("/v1/admin/cancellations"),
  reviewCancellation: (id: string) =>
    ridesRequest<{ ok: boolean }>(`/v1/admin/cancellations/${id}/review`, { method: "POST" }),
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

  // Base per-km rates (maker-checker: any staff proposes, only super_admin approves)
  currentRates: () => ridesRequest<CurrentRate[]>("/v1/admin/rates"),
  listRateProposals: () => ridesRequest<RateProposal[]>("/v1/admin/rates/proposals"),
  proposeRate: (p: NewRateProposal) =>
    ridesRequest<RateProposal>("/v1/admin/rates/proposals", {
      method: "POST",
      body: JSON.stringify(p),
    }),
  approveRate: (id: string) =>
    ridesRequest<RateProposal>(`/v1/admin/rates/proposals/${id}/approve`, { method: "POST" }),
  rejectRate: (id: string, reason?: string) =>
    ridesRequest<RateProposal>(`/v1/admin/rates/proposals/${id}/reject`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    }),

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

  // Riders directory + per-driver analytics
  riders: (q?: string) =>
    ridesRequest<RiderRow[]>(`/v1/admin/riders${q ? `?q=${encodeURIComponent(q)}` : ""}`),
  riderDetail: (id: string) => ridesRequest<RiderDetail>(`/v1/admin/riders/${id}`),
  suspendRider: (id: string) =>
    ridesRequest<{ ok: boolean; status: string }>(`/v1/admin/riders/${id}/suspend`, { method: "POST" }),
  reactivateRider: (id: string) =>
    ridesRequest<{ ok: boolean; status: string }>(`/v1/admin/riders/${id}/reactivate`, { method: "POST" }),
  updateRider: (id: string, fields: { full_name?: string }) =>
    ridesRequest<{ ok: boolean }>(`/v1/admin/riders/${id}`, {
      method: "PATCH",
      body: JSON.stringify(fields),
    }),
  driverAnalytics: (userId: string) =>
    ridesRequest<DriverAnalytics>(`/v1/admin/driver-analytics/${userId}`),
  driverDirectory: (q?: string) =>
    ridesRequest<DriverDirectoryRow[]>(
      `/v1/admin/driver-directory${q ? `?q=${encodeURIComponent(q)}` : ""}`,
    ),

  // Staff-initiated credit top-up (bypasses the PSP) — rider or driver.
  // `planId` applies that plan's bonus on top of `amount` (validated
  // server-side against the plan's min/max range).
  adminTopup: (userId: string, kind: "rider" | "driver", amount: number, planId?: string) =>
    ridesRequest<{ ok: boolean; balance: string; credited: string; bonus: string }>(
      "/v1/admin/credits/topup",
      {
        method: "POST",
        headers: { "x-idempotency-key": crypto.randomUUID() },
        body: JSON.stringify({ user_id: userId, kind, amount, plan_id: planId }),
      },
    ),
};

export interface RiderRow {
  id: string;
  phone: string;
  full_name: string | null;
  status: string;
  created_at: string;
  total_rides: number;
  total_spend: string;
}

export interface RiderDetail {
  id: string;
  phone: string;
  full_name: string | null;
  status: string;
  created_at: string;
  total_rides: number;
  completed_rides: number;
  cancelled_rides: number;
  total_spend: string;
  avg_rating: number | null;
  rating_count: number;
  recent_trips: RideRow[];
}

export interface DriverDirectoryRow {
  driver_id: string;
  user_id: string;
  phone: string;
  full_name: string | null;
  kyc_status: string;
  created_at: string;
  total_trips: number;
  total_earnings: string;
}

export interface DriverAnalytics {
  user_id: string;
  total_trips: number;
  completed_trips: number;
  cancelled_trips: number;
  total_earnings: string;
  avg_rating: number | null;
  rating_count: number;
  recent_trips: RideRow[];
}

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

export interface CurrentRate {
  vehicle_class: string;
  per_km_rate: string;
  is_override: boolean;
}

export interface RateProposal {
  id: string;
  vehicle_class: string;
  per_km_rate: string;
  proposed_by: string;
  status: string;
  rejection_reason: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  created_at: string;
}

export interface NewRateProposal {
  vehicle_class: string;
  per_km_rate: number;
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
  accepted_at: string | null;
  completed_at: string | null;
}

export interface CancellationRow extends RideRow {
  reviewed: boolean;
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

export interface TripRoute {
  trip_id: string;
  status: string;
  origin_lat: number;
  origin_lng: number;
  dest_lat: number;
  dest_lng: number;
  breadcrumbs: { lat: number; lng: number; at: string }[];
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

export interface SupportThread {
  user_id: string;
  user_name: string | null;
  user_phone: string | null;
  last_message: string;
  last_at: string;
  unread: number;
  last_trip_id: string | null;
  last_order_id: string | null;
}

export interface SupportMessage {
  id: string;
  sender_role: "user" | "staff";
  body: string;
  trip_id: string | null;
  order_id: string | null;
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

// ── Places service (map-contribution review queue) ─────────────────────────

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
