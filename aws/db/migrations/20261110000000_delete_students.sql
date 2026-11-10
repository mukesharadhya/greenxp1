-- Admins can delete students. A deleted student is hidden from every admin list, leaderboard and count and can no
-- longer sign in, but their rows (payments, XP, submissions, certificates) stay for the records, so a deletion made by
-- mistake can be undone by clearing deleted_at. account_status 'suspended' also keeps them out of certificate issuing.
begin;

alter table public.profiles
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles (id) on delete set null;

-- The public counters on the log-in page leave deleted students out of "students" and "institutions".
create or replace function public.public_stats()
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'institutions',      (select count(distinct p.college_id) from public.profiles p where p.role = 'student' and p.college_id is not null and p.deleted_at is null),
    'students',          (select count(*) from public.profiles where role = 'student' and deleted_at is null),
    'activities_listed', (select count(distinct name) from public.activities where active),
    'activities',        (select count(*) from public.activity_submissions where verification_status = 'verified'),
    'co2e_saved_kg',     (select coalesce(sum(a.impact_factor), 0) from public.activity_submissions s
                          join public.activities a on a.id = s.activity_id where s.verification_status = 'verified'),
    'certificates',      (select count(*) from public.certificates where status = 'issued'));
$function$;

commit;
