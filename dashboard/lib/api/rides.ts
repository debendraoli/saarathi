import { API_BASE, request } from "./client";

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
