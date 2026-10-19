-- Totals for the login page counters. Returns aggregate numbers only, so visitors who aren't logged in may call it.
create or replace function public.public_stats()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'institutions', (select count(*) from public.colleges where active),
    'students',     (select count(*) from public.profiles where role = 'student'),
    'activities',   (select count(*) from public.activity_submissions where verification_status = 'verified'),
    'co2e_saved_kg', (select coalesce(sum(a.impact_factor), 0) from public.activity_submissions s
                      join public.activities a on a.id = s.activity_id where s.verification_status = 'verified'));
$function$;
revoke execute on function public.public_stats() from public;
grant execute on function public.public_stats() to anon, authenticated;
