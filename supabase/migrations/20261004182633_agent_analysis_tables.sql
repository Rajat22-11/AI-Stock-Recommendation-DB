
create table if not exists signal_exclusions (
  signal_id bigint primary key references signals(id),
  batch text not null,
  reason text not null,
  created_at timestamptz not null default now()
);
create table if not exists signal_rationale (
  signal_id bigint primary key references signals(id),
  run_id bigint references runs(id),
  thesis text not null,
  catalyst text,
  risks text,
  invalidation text,
  alternatives text,
  data_gaps text,
  confidence smallint check (confidence between 1 and 5),
  created_at timestamptz not null default now()
);
create table if not exists trade_reviews (
  id bigserial primary key,
  signal_id bigint not null references signals(id),
  symbol text not null,
  run_id bigint references runs(id),
  tag text not null check (tag in ('good_call','winner','valid_stop','whipsaw_tight_stop','gap_through_stop',
        'missed_runner','avoided_loser','bad_entry','rule_violation','data_gap','removed_fresh_start','other')),
  lesson text,
  author text not null default 'agent' check (author in ('agent','rajat')),
  created_at timestamptz not null default now()
);
create index if not exists trade_reviews_signal_idx on trade_reviews(signal_id);
alter table signal_exclusions enable row level security;
alter table signal_rationale enable row level security;
alter table trade_reviews enable row level security;
create policy signal_exclusions_read on signal_exclusions for select using (true);
create policy signal_rationale_read on signal_rationale for select using (true);
create policy trade_reviews_read on trade_reviews for select using (true);
revoke insert, update, delete, truncate on signal_exclusions, signal_rationale, trade_reviews from anon, authenticated;
grant select on signal_exclusions, signal_rationale, trade_reviews to anon, authenticated;
;
