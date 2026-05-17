/**
 * Shared types for TapKar AI backend.
 *
 * IMPORTANT: These are data shapes only. NO business logic lives in this file
 * or anywhere else in /tools. All decision-making happens in agents.
 */

// ─── Geo ───────────────────────────────────────────────────────────────────

export interface LatLng {
  lat: number;
  lng: number;
}

export interface Location extends LatLng {
  label: string;
  neighborhood?: string;
}

// ─── Taxonomy ──────────────────────────────────────────────────────────────

export type Language = 'en' | 'ur' | 'roman_ur' | 'mixed';
export type Urgency = 'emergency' | 'high' | 'normal' | 'low';

export interface CategoryNames {
  en: string[];
  ur: string[];
  roman_ur: string[];
}

export interface RankingWeights {
  distance?: number;
  rating?: number;
  availability?: number;
  price?: number;
  completed_jobs?: number;
}

export interface Category {
  id: string;
  tier: 1 | 2 | 3;
  names: CategoryNames;
  places_type: string | null;
  places_keywords: string[];
  ranking_weights: RankingWeights;
  urgency_default: Urgency;
  typical_price_range_pkr: [number, number];
  specializations: string[];
  ux_label: { en: string; ur: string };
  emoji: string;
}

export interface Taxonomy {
  version: string;
  city: string;
  currency: string;
  default_ranking_weights: RankingWeights;
  categories: Category[];
  neighborhoods_karachi: Array<{ name: string; ur: string; lat: number; lng: number }>;
}

// ─── Providers ─────────────────────────────────────────────────────────────

export type AvailabilityRange = string; // "HH:MM-HH:MM"
export type WeeklyAvailability = Record<
  'monday' | 'tuesday' | 'wednesday' | 'thursday' | 'friday' | 'saturday' | 'sunday',
  AvailabilityRange[]
>;

export interface Provider {
  id: string;
  name: string;
  category: string;
  specializations: string[];
  neighborhood: string;
  lat: number;
  lng: number;
  service_radius_km: number;
  rating: number;
  review_count: number;
  jobs_completed: number;
  years_experience: number;
  languages: Language[];
  price_range_pkr: [number, number];
  availability: WeeklyAvailability;
  phone: string;
  verified: boolean;
  tags: string[];
}

export interface ProviderCandidate extends Provider {
  distance_km?: number;
  availability_at_request?: 'available' | 'busy' | string;
  source: 'mock' | 'firestore' | 'places_api';
}

// ─── Intent ────────────────────────────────────────────────────────────────

export type Preference =
  | 'quality_priority'
  | 'price_priority'
  | 'speed_priority'
  | 'trust_priority'
  | 'female_provider_required';

export interface Intent {
  service: {
    category_id: string | null;
    free_text: string;
    specializations: string[] | null;
  };
  location: Location | { use_user_default: true };
  time: {
    iso: string;
    approximate: boolean;
    user_phrase: string;
  } | null;
  urgency: Urgency;
  preferences: Preference[];
  language: Language;
  ambiguities: string[];
}

// ─── Bookings ──────────────────────────────────────────────────────────────

export type BookingStatus =
  | 'requested'
  | 'matched'
  | 'confirmed'
  | 'reminded'
  | 'in_progress'
  | 'completed'
  | 'cancelled'
  | 'no_show';

export interface Booking {
  id: string;
  user_id: string;
  provider_id: string;
  service_category_id: string;
  specializations?: string[];
  time_iso: string;
  location: Location;
  status: BookingStatus;
  language: Language;
  estimated_price_pkr: [number, number];
  notes?: string;
  created_at: string;
  confirmed_at?: string;
  completed_at?: string;
}

export interface Receipt {
  booking_id: string;
  url: string;
  summary: string;
  generated_at: string;
}

// ─── Trace log ─────────────────────────────────────────────────────────────

export type AgentName =
  | 'orchestrator'
  | 'intent'
  | 'discovery'
  | 'ranking'
  | 'booking'
  | 'followup';

export interface ToolCall {
  name: string;
  input: unknown;
  output: unknown;
  ms: number;
  ts: string;
}

export interface TraceStep {
  agent: AgentName;
  reasoning: string;
  tools_called: ToolCall[];
  output: unknown;
  ms: number;
  ts: string;
}

export interface Trace {
  run_id: string;
  user_id: string;
  user_input: string;
  started_at: string;
  ended_at: string | null;
  status: 'running' | 'complete' | 'failed';
  steps: TraceStep[];
  result?: {
    booking_id?: string;
    status: string;
  };
}

// ─── Scheduled jobs ────────────────────────────────────────────────────────

export type JobType = 'reminder' | 'status_check' | 'survey';
export type JobStatus = 'pending' | 'fired' | 'cancelled';

export interface ScheduledJob {
  id: string;
  booking_id: string;
  type: JobType;
  fire_at_iso: string;
  purpose: string;
  language: Language;
  message_preview: string;
  status: JobStatus;
  fired_at?: string;
}

// ─── User ──────────────────────────────────────────────────────────────────

export interface User {
  id: string;
  name?: string;
  phone?: string;
  default_location?: Location;
  language_preference?: Language;
}
