
-- ============ CONFIG / VERSIONS / RUNS ============
create table public.config (
  key text primary key,
  value jsonb not null,
  description text,
  updated_at timestamptz not null default now()
);

create table public.skill_versions (
  version text primary key,            -- 'YYYY-MM-DD-<sha256[:8] of SKILL.md>'
  effective_from date not null,
  sha256 text,
  summary text,
  created_at timestamptz not null default now()
);

create table public.runs (
  id bigint generated always as identity primary key,
  run_type text not null check (run_type in ('weekly_scan','midweek_checkin','adhoc','backfill','processing')),
  trigger_id text,
  session_id text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  data_as_of date,
  model text,
  skill_version text references public.skill_versions(version),
  status text not null default 'running' check (status in ('running','succeeded','partial','failed')),
  data_calls jsonb,
  summary text,
  report_ref text,
  notes text
);

-- ============ SIGNALS (immutable input: every call I make) ============
create table public.signals (
  id bigint generated always as identity primary key,
  run_id bigint references public.runs(id),
  created_at timestamptz not null default now(),
  symbol text not null,
  exchange text not null default 'NSE',
  signal_date date not null,
  source text not null check (source in ('weekly_scan','midweek_checkin','adhoc','backfill')),
  verdict text not null check (verdict in ('ENTRY','ENTRY_REDUCED','WAIT','WAIT_ALERT','NO_GO','TRIM','ADD','HOLD','REDUCE','EXIT')),
  provisional boolean not null default false,
  setup text check (setup in ('A_base','B_flag','holding','other')),
  stage int check (stage between 1 and 4),
  why_grade text check (why_grade in ('A','B','C','D')),
  why_text text,
  signal_close numeric,
  pivot numeric,
  alert_trigger numeric,
  entry_low numeric,
  entry_high numeric,
  stop numeric,
  stop_basis text check (stop_basis in ('structural','cap8','higher_low','sma','other')),
  trim_price numeric,
  size_pct numeric,
  risk_pct numeric,
  vol_mult numeric,
  req_vol_mult numeric,
  req_vol_abs bigint,
  sma13 numeric,
  sma13_rising boolean,
  dist_sma_pct numeric,
  correction_pct numeric,
  base_range_pct numeric,
  close_loc numeric,
  liquidity_tier text not null default 'liquid' check (liquidity_tier in ('liquid','thin')),
  priority_rank int,
  window_start date,
  window_end date,
  skill_version text references public.skill_versions(version),
  retro_seeded boolean not null default false,
  supersedes bigint references public.signals(id),
  notes text,
  raw jsonb
);
create index signals_symbol_date_idx on public.signals(symbol, signal_date);
create index signals_verdict_idx on public.signals(verdict);
create index signals_run_idx on public.signals(run_id);
create index signals_supersedes_idx on public.signals(supersedes);

create or replace function public.block_signal_mutation() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('tracker.allow_signal_edit', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception 'signals are append-only: insert a new row with supersedes = % instead', old.id;
end $$;
create trigger signals_append_only before update or delete on public.signals
  for each row execute function public.block_signal_mutation();

-- ============ PRICES (daily bars fetched by runs) ============
create table public.price_bars (
  symbol text not null,
  bar_date date not null,
  open numeric not null, high numeric not null, low numeric not null, close numeric not null,
  volume bigint,
  source text,
  inserted_at timestamptz not null default now(),
  primary key (symbol, bar_date)
);

-- ============ DERIVED LEDGER (rebuilt by process_ledger, never hand-edited) ============
create table public.positions (
  id bigint generated always as identity primary key,
  signal_id bigint not null unique references public.signals(id),
  symbol text not null,
  status text not null default 'pending' check (status in ('pending','open','closed','expired','skipped')),
  planned_size_pct numeric not null,
  cost_pct numeric not null,
  entry_low numeric, entry_high numeric,
  window_start date, window_end date,
  stop_initial numeric,
  fill_date date, fill_price numeric,
  qty_initial int, qty_open int not null default 0,
  avg_cost numeric,
  gross_bought numeric not null default 0,
  stop_at_fill numeric, stop_current numeric,
  trim_price numeric, trimmed boolean not null default false,
  exit_date date, exit_price numeric, exit_reason text,
  realized_pnl numeric not null default 0,
  costs numeric not null default 0
);
create index positions_symbol_idx on public.positions(symbol);

create table public.events (
  id bigint generated always as identity primary key,
  position_id bigint references public.positions(id) on delete cascade,
  signal_id bigint references public.signals(id),
  trigger_signal_id bigint references public.signals(id),
  symbol text not null,
  event_date date not null,
  event_type text not null check (event_type in ('fill','add','trim','reduce','stop_raise','stop_hit','exit','expire','skip')),
  price numeric, qty int,
  pnl numeric not null default 0,
  cost numeric not null default 0,
  rule text,
  created_at timestamptz not null default now()
);
create index events_position_idx on public.events(position_id);
create index events_date_idx on public.events(event_date);
create index events_trigger_sig_idx on public.events(trigger_signal_id);
create index events_signal_idx on public.events(signal_id);

create table public.marks (
  position_id bigint references public.positions(id) on delete cascade,
  mark_date date not null,
  symbol text not null,
  close numeric, qty_open int, cost_basis numeric, market_value numeric,
  unrealized_pnl numeric, unrealized_pct numeric, realized_to_date numeric,
  stop_current numeric, dist_to_stop_pct numeric,
  primary key (position_id, mark_date)
);
create index marks_date_idx on public.marks(mark_date);

-- ============ REVIEWS (my learning log; skill changes stay proposals) ============
create table public.reviews (
  id bigint generated always as identity primary key,
  run_id bigint references public.runs(id),
  review_date date not null,
  period text not null check (period in ('weekly','monthly','quarterly','adhoc')),
  stats jsonb,
  observations text,
  lessons text,
  proposed_change text,
  proposal_status text not null default 'none' check (proposal_status in ('none','proposed','approved','rejected','applied')),
  created_at timestamptz not null default now()
);
create index reviews_run_idx on public.reviews(run_id);
create index runs_skill_idx on public.runs(skill_version);
create index signals_skill_idx on public.signals(skill_version);

-- ============ RLS: UI (anon/publishable key) is read-only; writes only via MCP/postgres ============
do $$ declare t text; begin
  foreach t in array array['config','skill_versions','runs','signals','price_bars','positions','events','marks','reviews'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t||'_read', t);
  end loop;
end $$;
;
