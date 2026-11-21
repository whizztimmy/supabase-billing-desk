export type Tone = 'red' | 'amber' | 'green' | 'blue' | 'gray';

export interface QueueTicket {
  id: number; org_id: string; org_name: string; plan: string; requester_name: string;
  category: string; severity: 'Low' | 'Normal' | 'High' | 'Urgent'; subject: string; created_at: string;
  topic: string; first_response_due: string; hours_waiting: number;
  sla_state: 'overdue' | 'due soon' | 'on track';
  playbook: string; diagnosis: string; escalate_to: string | null;
}

export interface Evidence { label: string; value: string }

export interface Finding {
  playbook: string; title: string; rank: number; cause: string; evidence: Evidence[];
  next_step: string; escalate_to: string | null; doc_url: string | null; reply: string | null;
}

export interface TicketContext {
  ticket_id: number; subject: string; body: string; category: string; severity: QueueTicket['severity'];
  created_at: string; topic: string; requester_name: string;
  org_id: string; org_name: string; plan: string; spend_cap: boolean; country: string;
  tax_id: string | null; restriction_status: string | null; credit_balance: number;
  invoice_id: number | null; invoice_number: string | null;
  card_brand: string | null; card_last4: string | null; card_country: string | null;
  card_expires: string | null; card_expired: boolean | null;
  project_count: number; paused_projects: number;
}

export interface Project { id: number; name: string; compute_size: string; status: string; pause_reason: string | null }

export interface InvoiceOverview {
  id: number; org_id: string; org_name: string; number: string; status: string; status_label: string;
  usage_period_start: string; usage_period_end: string; usage_plan: string; fee_plan: string; spend_cap: boolean;
  issued_at: string; due_at: string; paid_at: string | null; total: number; days_overdue: number | null;
  failed_attempts: number; succeeded_attempts: number; last_decline_code: string | null; open_dispute: boolean;
}

export interface InvoiceLine {
  line_no: number; kind: string; project: string | null; name: string;
  quantity: number | null; unit: string | null; included: number | null; billable: number | null;
  unit_price: number | null; amount: number | null; explanation: string;
  expected_amount?: number | null; matches?: boolean;
}

export interface PaymentAttempt { id: number; attempted_at: string; status: string; decline_code: string | null; amount: number }
export interface Dispute { id: number; opened_at: string; reason: string; status: string; amount: number; evidence_due_by: string | null }
export interface PlaybookSource { id: string; title: string; applies_when: string; doc_url: string | null; sort: number; sql: string }
export interface PlaybookStat { playbook: string; title: string; tickets: number; share_pct: number | null; escalated: number; median_first_response_min: number | null }
export interface WeeklyCount { week_start: string; playbook: string; tickets: number }
export interface SpendSignal { org_id: string; name: string; plan: string; age_days: number; lifetime_paid: number; monthly_run_rate: number; largest_size: string }
export interface Setting { key: string; value: string; kind: 'demo' | 'documented' | 'assumed'; note: string }
export interface Plan { id: string; name: string; monthly_fee: number; spend_cap_available: boolean; sort: number }
export interface ComputeSize { id: string; name: string; hourly_price: number; sort: number }
export interface UsageMetric { id: string; line_name: string; unit: string; scope: 'org' | 'project'; free_quota: number | null; paid_quota: number; sort: number; source_url: string }
export interface Addon { id: string; line_name: string; hourly_price: number; sort: number }
