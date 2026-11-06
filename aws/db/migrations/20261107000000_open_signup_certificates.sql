-- Students no longer wait for approval, can add an institution that isn't listed, and get a GreenXP registration ID.
-- Certificates need at least 200 XP. The super admin covers institutions that have no admin of their own.
begin;

-- Email verification is now enough. Only a blocked ('rejected') account stays out.
alter table public.profiles alter column approval_status set default 'approved';
update public.profiles set approval_status = 'approved' where approval_status = 'pending';

create sequence public.registration_id_seq;
alter table public.profiles add column registration_id text not null
  default 'GXP' || lpad(nextval('public.registration_id_seq')::text, 6, '0');
alter table public.profiles add constraint profiles_registration_id_key unique (registration_id);

-- website: optional. added_by: the student who typed it in; such institutions stay off the public list until switched on.
alter table public.colleges add column website text, add column added_by uuid references public.profiles (id) on delete set null;

create or replace function public.review_submission(p_id uuid, p_admin uuid, p_approve boolean, p_reason text)
 returns text
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare s record; a record; yid uuid; adm record;
begin
  select * into adm from public.profiles where id = p_admin and role in ('admin','super_admin');
  if not found then raise exception 'not an admin'; end if;
  select sub.*, p.college_id student_college into s from public.activity_submissions sub join public.profiles p on p.id = sub.user_id
    where sub.id = p_id and sub.verification_status = 'pending' and (adm.role = 'super_admin' or p.college_id = adm.college_id) for update of sub;
  if not found then raise exception 'submission not found or already reviewed'; end if;
  update public.activity_submissions set verification_status = case when p_approve then 'verified' else 'rejected' end,
    rejection_reason = case when p_approve then null else p_reason end, verified_by = p_admin, verified_at = now() where id = p_id;
  if p_approve then
    select * into a from public.activities where id = s.activity_id;
    select id into yid from public.academic_years where college_id = s.student_college and is_current limit 1;
    insert into public.xp_transactions (user_id, academic_year_id, amount, source, reference_id) values (s.user_id, yid, a.xp_value, 'activity', p_id);
  end if;
  insert into public.audit_logs (actor_id, action, target_type, target_id, details)
    values (p_admin, case when p_approve then 'approve_submission' else 'reject_submission' end, 'submission', p_id::text, jsonb_build_object('reason', p_reason));
  return case when p_approve then 'verified' else 'rejected' end;
end $function$;

-- 200 XP is the minimum everywhere. At exactly 200 a student whose college starts its tiers higher still gets the lowest tier.
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
    select p.id uid, p.college_id cid, y.id yid, coalesce(sum(t.amount) filter (where t.source <> 'redemption' and t.academic_year_id = y.id),0) xp
    from public.profiles p
    join public.academic_years y on y.college_id = p.college_id and y.is_current
    join public.memberships m on m.user_id = p.id and m.academic_year_id = y.id and m.status in ('active','waived')
    left join public.xp_transactions t on t.user_id = p.id
    where (adm.role = 'super_admin' or p.college_id = adm.college_id) and p.account_status = 'normal' and p.role = 'student'
    group by p.id, p.college_id, y.id),
  tiered as (
    select x.uid, x.yid, x.xp, coalesce(
      (select r.tier from public.certificate_rules r where r.college_id = x.cid and r.min_xp <= x.xp order by r.min_xp desc limit 1),
      (select r.tier from public.certificate_rules r where r.college_id = x.cid order by r.min_xp limit 1)) tier
    from x where x.xp >= 200)
  insert into public.certificates (user_id, academic_year_id, tier, xp_earned, activities_count, badges_count, estimated_co2e)
  select t.uid, t.yid, t.tier, t.xp,
    (select count(*) from public.xp_transactions xt
       join public.activity_submissions s on s.id = xt.reference_id and s.verification_status = 'verified'
       where xt.user_id = t.uid and xt.source = 'activity' and xt.academic_year_id = t.yid),
    (select count(*) from public.user_badges b where b.user_id = t.uid),
    coalesce((select sum(a.impact_factor) from public.xp_transactions xt
       join public.activity_submissions s on s.id = xt.reference_id and s.verification_status = 'verified'
       join public.activities a on a.id = s.activity_id
       where xt.user_id = t.uid and xt.source = 'activity' and xt.academic_year_id = t.yid),0)
  from tiered t where t.tier is not null
  on conflict (user_id, academic_year_id) do nothing;
  get diagnostics n = row_count;
  insert into public.audit_logs (actor_id, action, target_type, details) values (p_admin, 'issue_certificates', 'certificate', jsonb_build_object('issued', n));
  return n;
end $function$;

commit;
