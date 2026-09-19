-- ============================================================
-- The Board — auth schema v2 (individual accounts, roles, audit)
-- Run ONCE in the school's DEDICATED Supabase project's SQL Editor.
-- Safe to re-run: upgrades a v1 install in place.
-- Roles: admin (sees everything) | staff (never sees admin-authored evals)
-- v2 adds: active/pw_set account flags, the login_events audit trail,
-- and active-profile gating on EVERY data policy — a deactivated or
-- unprovisioned account gets nothing from the database itself.
-- ============================================================
create extension if not exists pgcrypto;

-- Who is who. One row per account; role + active drive every rule below.
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text not null,
  role text not null default 'staff' check (role in ('admin','staff')),
  active boolean not null default true,
  pw_set boolean not null default false
);
-- v1 -> v2 upgrades
alter table profiles add column if not exists active boolean not null default true;
alter table profiles add column if not exists pw_set boolean not null default false;

-- The shared board (players, grades, call logs) — one JSON document per key.
create table if not exists boards (
  key text primary key,
  value text not null,
  updated_at timestamptz default now()
);

-- Per-staffer evaluations live OUTSIDE the board document so the server can
-- filter them by role before they ever reach a browser.
create table if not exists evaluations (
  id uuid primary key default gen_random_uuid(),
  player_id text not null,
  author_id uuid not null references profiles(id) on delete cascade,
  author_name text not null,
  text text not null,
  updated_at_label text,
  updated_at timestamptz default now(),
  unique (player_id, author_id)
);

-- Login audit trail — who signed in, when. Admin-readable in 🔑 Access.
create table if not exists login_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete cascade,
  username text not null,
  name text not null,
  at timestamptz default now()
);

-- Kill the legacy OPEN policies in case the old schema.sql ever ran here:
drop policy if exists "board read"   on boards;
drop policy if exists "board insert" on boards;
drop policy if exists "board update" on boards;
-- Drop v1/v2 policies so re-running this file upgrades cleanly in place:
drop policy if exists "profiles read"         on profiles;
drop policy if exists "profiles admin update" on profiles;
drop policy if exists "boards read"           on boards;
drop policy if exists "boards insert"         on boards;
drop policy if exists "boards update"         on boards;
drop policy if exists "evals read"            on evaluations;
drop policy if exists "evals insert own"      on evaluations;
drop policy if exists "evals update own"      on evaluations;
drop policy if exists "evals delete own"      on evaluations;
drop policy if exists "login events insert"   on login_events;
drop policy if exists "login events admin read" on login_events;

alter table profiles     enable row level security;
alter table boards       enable row level security;
alter table evaluations  enable row level security;
alter table login_events enable row level security;

-- Helpers (security definer so policies can consult profiles without recursion)
create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and active) $$;

create or replace function public.is_active_profile() returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and active) $$;

create or replace function public.author_role(a uuid) returns text
language sql security definer stable set search_path = public as
$$ select role from profiles where id = a $$;

-- A signed-in user marks their own account as having a personal password.
create or replace function public.mark_pw_set() returns void
language sql security definer set search_path = public as
$$ update profiles set pw_set = true where id = auth.uid() $$;

-- profiles: active staff see the roster (names/roles); a deactivated account
-- can still read ONLY its own row (so the app can say WHY it was signed out);
-- only admins may change anyone.
create policy "profiles read" on profiles for select to authenticated
  using (is_active_profile() or id = auth.uid());
create policy "profiles admin update" on profiles for update to authenticated
  using (is_admin());

-- boards: only provisioned, ACTIVE accounts read or write the shared board.
create policy "boards read"   on boards for select to authenticated using (is_active_profile());
create policy "boards insert" on boards for insert to authenticated with check (is_active_profile());
create policy "boards update" on boards for update to authenticated using (is_active_profile());

-- evaluations — THE role rule: admins read every eval; staff read their own
-- and other staff's, but never an eval authored by an admin.
create policy "evals read" on evaluations for select to authenticated using (
  is_active_profile() and (is_admin() or author_id = auth.uid() or author_role(author_id) = 'staff')
);
create policy "evals insert own" on evaluations for insert to authenticated
  with check (author_id = auth.uid() and is_active_profile());
create policy "evals update own" on evaluations for update to authenticated
  using (is_active_profile() and (author_id = auth.uid() or is_admin()));
create policy "evals delete own" on evaluations for delete to authenticated
  using (is_active_profile() and (author_id = auth.uid() or is_admin()));

-- login_events: any active account records its own logins; admins read them.
create policy "login events insert" on login_events for insert to authenticated
  with check (user_id = auth.uid() and is_active_profile());
create policy "login events admin read" on login_events for select to authenticated
  using (is_admin());

-- ============================================================
-- Table privileges. RLS (above) gates ROWS; these gate the tables
-- themselves. New Supabase projects grant API roles nothing by default.
-- anon deliberately gets NOTHING: without a session the API cannot even
-- see these tables — deny-by-default, enforced twice.
-- ============================================================
grant usage on schema public to authenticated, service_role;
grant select, insert, update on public.profiles     to authenticated, service_role;
grant select, insert, update on public.boards       to authenticated, service_role;
grant select, insert, update, delete on public.evaluations to authenticated, service_role;
grant select, insert on public.login_events         to authenticated, service_role;
grant execute on function public.is_admin()            to authenticated;
grant execute on function public.is_active_profile()   to authenticated;
grant execute on function public.author_role(uuid)     to authenticated;
grant execute on function public.mark_pw_set()         to authenticated;

-- ============================================================
-- v3: assignments, notifications, push (identical to schema-assignments.sql)
-- ============================================================
alter table profiles add column if not exists can_assign boolean not null default false;

create table if not exists assignments (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  notes text not null default '',
  assignee_id uuid not null references profiles(id) on delete cascade,
  assignee_name text not null,
  assigner_id uuid not null references profiles(id) on delete cascade,
  assigner_name text not null,
  due_date date not null,
  status text not null default 'open' check (status in ('open','done')),
  done_at timestamptz,
  done_note text not null default '',
  -- what the task is about: linked recruit ids (board players) and/or a team's
  -- depth chart slug; kind drives auto-progress ("contact" counts call logs)
  kind text not null default 'general' check (kind in ('general','contact','evaluate')),
  player_ids jsonb not null default '[]'::jsonb,
  player_names jsonb not null default '[]'::jsonb,
  team_slug text,
  team_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- reminder bookkeeping (the daily job sets these so nobody is pinged twice)
  due_notified_on date,
  overdue_notified_on date
);
create index if not exists assignments_assignee_idx on assignments (assignee_id, status, due_date);
create index if not exists assignments_assigner_idx on assignments (assigner_id, status, due_date);

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  kind text not null check (kind in ('assigned','due','overdue','done','digest')),
  title text not null,
  body text not null default '',
  assignment_id uuid references assignments(id) on delete cascade,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on notifications (user_id, read, created_at desc);

create table if not exists push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  device text not null default '',
  created_at timestamptz not null default now(),
  last_ok_at timestamptz,
  failures int not null default 0
);
create index if not exists push_subscriptions_user_idx on push_subscriptions (user_id);

-- helpers
create or replace function public.can_assign() returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and active and (role = 'admin' or can_assign)) $$;

-- keep updated_at honest
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists assignments_touch on assignments;
create trigger assignments_touch before update on assignments
  for each row execute function public.touch_updated_at();

-- drop + recreate policies so re-running upgrades in place
drop policy if exists "assignments read"        on assignments;
drop policy if exists "assignments insert"      on assignments;
drop policy if exists "assignments update"      on assignments;
drop policy if exists "assignments delete"      on assignments;
drop policy if exists "notifications read own"  on notifications;
drop policy if exists "notifications insert"    on notifications;
drop policy if exists "notifications update own" on notifications;
drop policy if exists "push own"                on push_subscriptions;

alter table assignments        enable row level security;
alter table notifications      enable row level security;
alter table push_subscriptions enable row level security;

-- assignments: you see what you were given and what you handed out; admins
-- see the whole staff's work. Only assigners create; the assignee (or the
-- assigner / an admin) closes it; only the assigner or an admin deletes.
create policy "assignments read" on assignments for select to authenticated using (
  is_active_profile() and (assignee_id = auth.uid() or assigner_id = auth.uid() or is_admin())
);
create policy "assignments insert" on assignments for insert to authenticated with check (
  can_assign() and assigner_id = auth.uid()
);
create policy "assignments update" on assignments for update to authenticated using (
  is_active_profile() and (assignee_id = auth.uid() or assigner_id = auth.uid() or is_admin())
);
create policy "assignments delete" on assignments for delete to authenticated using (
  is_active_profile() and (assigner_id = auth.uid() or is_admin())
);

-- notifications: strictly your own inbox. Any active staffer may write a
-- notification addressed to someone (that's how "assigned" and "done" land
-- in the right inbox); reading and marking read is owner-only.
create policy "notifications read own" on notifications for select to authenticated
  using (user_id = auth.uid() and is_active_profile());
create policy "notifications insert" on notifications for insert to authenticated
  with check (is_active_profile());
create policy "notifications update own" on notifications for update to authenticated
  using (user_id = auth.uid() and is_active_profile());

-- push subscriptions: each device row belongs to the signed-in user only.
-- The notify Edge Function reads them with the service role.
create policy "push own" on push_subscriptions for all to authenticated
  using (user_id = auth.uid() and is_active_profile())
  with check (user_id = auth.uid() and is_active_profile());

grant select, insert, update, delete on public.assignments        to authenticated, service_role;
grant select, insert, update         on public.notifications      to authenticated, service_role;
grant select, insert, update, delete on public.push_subscriptions to authenticated, service_role;
grant execute on function public.can_assign() to authenticated;

-- ============================================================
-- DAILY 7 AM REMINDERS (after the `notify` Edge Function is deployed):
-- paste this in the SQL Editor, replacing <PROJECT-REF> (the id in the
-- project URL) and <JOB-SECRET> (the same value you set as the function's
-- JOB_SECRET). The job runs EVERY HOUR; the function itself only acts at
-- REMINDER_HOUR in SCHOOL_TZ, so daylight saving never moves the 7 AM ping.
--
-- create extension if not exists pg_cron;
-- create extension if not exists pg_net;
-- select cron.unschedule('board-reminders') where exists (select 1 from cron.job where jobname = 'board-reminders');
-- select cron.schedule('board-reminders', '5 * * * *',
--   $$ select net.http_post(
--        url := 'https://<PROJECT-REF>.supabase.co/functions/v1/notify',
--        headers := '{"Content-Type":"application/json","x-job-secret":"<JOB-SECRET>"}'::jsonb,
--        body := '{"job":"daily"}'::jsonb) $$);
-- ============================================================

-- ============================================================
-- v4: player universe + aliases (identical to schema-universe.sql)
-- ============================================================
create table if not exists universe (
  pid text primary key,
  name text not null,
  first_name text not null default '',
  last_name text not null default '',
  hs text not null default '',
  hometown text not null default '',
  state text not null default '',
  class_year int,
  pos text not null default '',
  height text not null default '',
  weight text not null default '',
  stars int,
  rating numeric,
  links jsonb not null default '{}'::jsonb,
  source text not null default '',
  kind text not null default 'recruit' check (kind in ('recruit','college')),
  current_team text,
  team_history jsonb not null default '[]'::jsonb,
  weak boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists universe_name_idx on universe (lower(name));
create index if not exists universe_last_idx on universe (lower(last_name));
create index if not exists universe_team_idx on universe (current_team);
create index if not exists universe_class_idx on universe (class_year, pos);

create table if not exists player_aliases (
  from_pid text primary key,
  to_pid text not null,
  by_name text not null default '',
  at timestamptz not null default now()
);
create index if not exists player_aliases_to_idx on player_aliases (to_pid);

drop trigger if exists universe_touch on universe;
create trigger universe_touch before update on universe
  for each row execute function public.touch_updated_at();

drop policy if exists "universe read"    on universe;
drop policy if exists "universe insert"  on universe;
drop policy if exists "universe update"  on universe;
drop policy if exists "universe delete"  on universe;
drop policy if exists "aliases read"     on player_aliases;
drop policy if exists "aliases admin write" on player_aliases;

alter table universe       enable row level security;
alter table player_aliases enable row level security;

-- any active staffer reads and adds to the universe (Add Prospect creates a
-- row); only admins delete. Merges (aliases) are admin-only.
create policy "universe read"   on universe for select to authenticated using (is_active_profile());
create policy "universe insert" on universe for insert to authenticated with check (is_active_profile());
create policy "universe update" on universe for update to authenticated using (is_active_profile());
create policy "universe delete" on universe for delete to authenticated using (is_admin());
create policy "aliases read" on player_aliases for select to authenticated using (is_active_profile());
create policy "aliases admin write" on player_aliases for all to authenticated using (is_admin()) with check (is_admin());

grant select, insert, update, delete on public.universe       to authenticated, service_role;
grant select, insert, update, delete on public.player_aliases to authenticated, service_role;
