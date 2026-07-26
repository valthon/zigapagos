export interface ResolvedState {
  flags: Record<string, boolean>;
  experiments: Record<string, string>;
}

export interface ContactRequest {
  name: string;
  email: string;
  message: string;
  recaptchaToken: string;
}

export interface ContactResponse {
  ok: boolean;
  errors?: string[];
}

export interface ClubAuthRequest {
  email: string;
  password: string;
  recaptchaToken: string;
}

export interface ClubSession {
  token: string;
  expiresAt: string;
  member?: Record<string, string>;
}

export const CONTRACT_VERSION = "2026-06-27.1";
