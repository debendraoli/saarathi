// Types shared across more than one API domain file.

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

export interface User {
  id: string;
  phone: string;
  full_name: string | null;
  role: UserRole;
  status: string;
  created_at: string;
  updated_at: string;
}

export interface TokenPair {
  access_token: string;
  refresh_token: string;
  user: User;
}
