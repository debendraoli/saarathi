import { apiError, raw, request } from "./client";
import type { TokenPair, User, UserRole } from "./types";

export type KycStatus = "pending" | "under_review" | "approved" | "rejected";
export type DocumentStatus = "submitted" | "approved" | "rejected";
export type VehicleClass = "two_wheeler" | "three_wheeler" | "four_wheeler";

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
