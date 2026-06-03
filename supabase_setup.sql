-- ============================================================
-- INKWELL — Supabase Database Setup
-- Run this entire file in: Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- 1. USERS (extends Supabase auth.users)
create table if not exists public.profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  username text unique not null,
  display_name text not null,
  created_at timestamptz default now()
);

-- 2. PROJECTS
create table if not exists public.projects (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  name text not null,
  word_goal integer default 80000,
  color text default '#8b6914',
  archived boolean default false,
  created_at timestamptz default now()
);

-- 3. SESSIONS (the core writing log)
create table if not exists public.sessions (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  project_id uuid references public.projects(id) on delete set null,
  stage text not null check (stage in ('plan', 'flow', 'edit')),
  word_count integer not null,           -- flow: positive; edit: positive or negative delta
  note text,
  timer_total_seconds integer,
  timer_run_seconds integer,
  timer_paused_seconds integer,
  logged_at timestamptz default now()
);

-- 4. ACHIEVEMENTS
create table if not exists public.achievements (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  achievement_key text not null,
  unlocked_at timestamptz default now(),
  unique(user_id, achievement_key)
);

-- ============================================================
-- ROW LEVEL SECURITY — users can only see/edit their own data
-- ============================================================
alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.sessions enable row level security;
alter table public.achievements enable row level security;

-- Profiles: readable by all authenticated users (so you can see your friend's stats),
-- but only editable by the owner
create policy "Profiles are viewable by authenticated users"
  on public.profiles for select using (auth.role() = 'authenticated');

create policy "Users can insert their own profile"
  on public.profiles for insert with check (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update using (auth.uid() = id);

-- Projects: only owner can see/edit
create policy "Users can manage their own projects"
  on public.projects for all using (auth.uid() = user_id);

-- Sessions: owner can write; authenticated users can read (for leaderboard)
create policy "Users can manage their own sessions"
  on public.sessions for all using (auth.uid() = user_id);

create policy "Authenticated users can view all sessions"
  on public.sessions for select using (auth.role() = 'authenticated');

-- Achievements: owner can write; authenticated users can read
create policy "Users can manage their own achievements"
  on public.achievements for all using (auth.uid() = user_id);

create policy "Authenticated users can view all achievements"
  on public.achievements for select using (auth.role() = 'authenticated');

-- ============================================================
-- HELPER VIEWS (make leaderboard queries easy)
-- ============================================================

-- Yearly stats per user
create or replace view public.yearly_stats as
select
  p.id as user_id,
  p.display_name,
  p.username,
  extract(year from s.logged_at) as year,
  sum(case when s.stage = 'flow' and s.word_count > 0 then s.word_count else 0 end) as flow_words,
  sum(case when s.stage = 'plan' and s.word_count > 0 then s.word_count else 0 end) as plan_words,
  count(distinct case when s.stage = 'edit' then s.id end) as edit_sessions,
  count(distinct case when s.stage = 'plan' then s.id end) as plan_sessions,
  count(distinct date(s.logged_at)) as active_days
from public.profiles p
left join public.sessions s on s.user_id = p.id
group by p.id, p.display_name, p.username, extract(year from s.logged_at);

-- ============================================================
-- AUTO-CREATE PROFILE ON SIGNUP
-- ============================================================
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$ language plpgsql security definer;

create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ============================================================
-- DONE. You should see 4 tables in your Table Editor:
-- profiles, projects, sessions, achievements
-- ============================================================
