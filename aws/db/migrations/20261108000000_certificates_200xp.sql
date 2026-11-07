-- Certificates need at least 200 XP in the academic year (was 400). One certificate per student per academic year.
-- The standard tiers move to match the star scale (200 / 300 / 400 / 500 / 700 XP, and 1000+ With Distinction):
-- Participation 200, Achievement 400, Excellence 700, Distinction 1000 (were 100 / 500 / 1000 / 2500).
-- Only these four standard tier names are changed; any tier an institution named differently is left alone.
begin;

update public.certificate_rules set min_xp = case tier when 'Participation' then 200 when 'Achievement' then 400
  when 'Excellence' then 700 when 'Distinction' then 1000 end
where tier in ('Participation', 'Achievement', 'Excellence', 'Distinction');

create or replace function public.issue_certificates(p_admin uuid)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare adm record; n int;
begin
  select * into adm from public.profiles where id = p_admin and role in ('admin','super_admin');
  if not found then raise exception 'not an admin'; end if;
  with x as (
    select p.id uid, p.college_id cid, p.year study_year, y.id yid, coalesce(sum(t.amount) filter (where t.source <> 'redemption' and t.academic_year_id = y.id),0) xp
    from public.profiles p
    join public.academic_years y on y.college_id = p.college_id and y.is_current
    join public.memberships m on m.user_id = p.id and m.academic_year_id = y.id and m.status in ('active','waived')
    left join public.xp_transactions t on t.user_id = p.id
    where (adm.role = 'super_admin' or p.college_id = adm.college_id) and p.account_status = 'normal' and p.role = 'student'
    group by p.id, p.college_id, p.year, y.id),
  tiered as (
    select x.uid, x.yid, x.xp, x.study_year, coalesce(
      (select r.tier from public.certificate_rules r where r.college_id = x.cid and r.min_xp <= x.xp order by r.min_xp desc limit 1),
      (select r.tier from public.certificate_rules r where r.college_id = x.cid order by r.min_xp limit 1)) tier
    from x where x.xp >= 200)
  insert into public.certificates (user_id, academic_year_id, tier, xp_earned, activities_count, badges_count, estimated_co2e, study_year)
  select t.uid, t.yid, t.tier, t.xp,
    (select count(*) from public.xp_transactions xt
       join public.activity_submissions s on s.id = xt.reference_id and s.verification_status = 'verified'
       where xt.user_id = t.uid and xt.source = 'activity' and xt.academic_year_id = t.yid),
    (select count(*) from public.user_badges b where b.user_id = t.uid),
    coalesce((select sum(a.impact_factor) from public.xp_transactions xt
       join public.activity_submissions s on s.id = xt.reference_id and s.verification_status = 'verified'
       join public.activities a on a.id = s.activity_id
       where xt.user_id = t.uid and xt.source = 'activity' and xt.academic_year_id = t.yid),0),
    t.study_year
  from tiered t where t.tier is not null
  on conflict (user_id, academic_year_id) do nothing;
  get diagnostics n = row_count;
  insert into public.audit_logs (actor_id, action, target_type, details) values (p_admin, 'issue_certificates', 'certificate', jsonb_build_object('issued', n));
  return n;
end $function$;

commit;
