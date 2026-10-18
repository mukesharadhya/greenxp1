-- Baseline lifestyle questionnaire, answered once after sign-up (students can retake it).
-- answers: the raw choices; footprint: estimated kg CO2e per year per category, computed in the app.
create table public.lifestyle_surveys (
  user_id uuid primary key default auth.uid() references public.profiles(id) on delete cascade,
  answers jsonb not null check (jsonb_typeof(answers) = 'object'),
  footprint jsonb not null check (jsonb_typeof(footprint) = 'object'),
  total_kg numeric not null check (total_kg between 0 and 50000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.lifestyle_surveys enable row level security;
revoke all on public.lifestyle_surveys from anon;

create policy "read own or admin" on public.lifestyle_surveys for select to authenticated
  using (user_id = (select auth.uid()) or (private.is_admin() and private.same_college(user_id)));
create policy "insert own" on public.lifestyle_surveys for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "update own" on public.lifestyle_surveys for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- College-wide averages for the admin dashboard. Returns null for non-admins.
create or replace function public.lifestyle_summary()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select case when private.is_admin() then (
    select jsonb_build_object(
      'responses', count(*),
      'avg_total_kg', round(avg(s.total_kg)),
      'avg', jsonb_build_object(
        'Energy',    round(avg((s.footprint->>'Energy')::numeric)),
        'Transport', round(avg((s.footprint->>'Transport')::numeric)),
        'Food',      round(avg((s.footprint->>'Food')::numeric)),
        'Shopping',  round(avg((s.footprint->>'Shopping')::numeric)),
        'Water',     round(avg((s.footprint->>'Water')::numeric))))
    from public.lifestyle_surveys s join public.profiles p on p.id = s.user_id
    where p.college_id = private.my_college())
  end
$function$;

revoke execute on function public.lifestyle_summary() from public, anon;
grant execute on function public.lifestyle_summary() to authenticated;
