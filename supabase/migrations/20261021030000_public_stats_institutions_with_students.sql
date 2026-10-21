-- Login page: "Institutions registered" counts only institutions with at least one registered student,
-- not every institution the admin has added. Totals only; callable without logging in.
create or replace function public.public_stats()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  select jsonb_build_object(
    'institutions',      (select count(distinct p.college_id) from public.profiles p where p.role = 'student' and p.college_id is not null),
    'students',          (select count(*) from public.profiles where role = 'student'),
    'activities_listed', (select count(distinct name) from public.activities where active),
    'activities',        (select count(*) from public.activity_submissions where verification_status = 'verified'),
    'co2e_saved_kg',     (select coalesce(sum(a.impact_factor), 0) from public.activity_submissions s
                          join public.activities a on a.id = s.activity_id where s.verification_status = 'verified'),
    'certificates',      (select count(*) from public.certificates where status = 'issued'));
$function$;
