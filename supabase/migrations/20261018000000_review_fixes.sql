-- Fixes from the 2026-10-18 code review. Apply before deploying the matching api/server.js.

-- 1. Activity submissions in one transaction. A per-user, per-activity advisory lock serialises
--    parallel requests, so the frequency limit cannot be beaten by sending many at once.
create or replace function public.submit_activity(p_user uuid, p_activity uuid, p_proof_path text, p_proof_hash text, p_event_code text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare prof record; a record; yid uuid; tok uuid; since timestamptz; n int; auto boolean; sid uuid;
begin
  select * into prof from public.profiles where id = p_user;
  if not found then raise exception 'Profile not found'; end if;
  if prof.account_status = 'suspended' then raise exception 'Account suspended'; end if;
  select id into yid from public.academic_years where college_id = prof.college_id and is_current limit 1;
  if yid is null then raise exception 'No current academic year'; end if;
  if not exists (select 1 from public.memberships m where m.user_id = p_user and m.academic_year_id = yid and m.status in ('active','waived')) then
    raise exception 'Activate your membership first';
  end if;
  select * into a from public.activities where id = p_activity and college_id = prof.college_id and active;
  if not found then raise exception 'Activity not found'; end if;
  if a.verification_type = 'automatic' then raise exception 'This activity is tracked automatically'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user::text || ':' || p_activity::text, 0));

  if a.verification_type = 'qr_event' then
    select t.id into tok from public.event_tokens t
      where t.activity_id = a.id and t.secret = coalesce(p_event_code, '') and now() between t.valid_from and t.valid_to limit 1;
    if tok is null then raise exception 'That event code is not valid right now'; end if;
  end if;
  if a.verification_type in ('photo','photo_admin') and p_proof_path is null then raise exception 'A photo is required'; end if;

  -- 'event' limits count per event code; 'total' counts all time.
  since := case a.frequency_period when 'day' then now() - interval '1 day'
                                   when 'week' then now() - interval '7 days'
                                   when 'month' then now() - interval '30 days' end;
  select count(*) into n from public.activity_submissions s
    where s.user_id = p_user and s.activity_id = a.id and s.verification_status <> 'rejected'
      and (since is null or s.submitted_at >= since)
      and (a.frequency_period <> 'event' or tok is null or s.event_token_id = tok);
  if n >= a.frequency_limit then raise exception 'Limit reached: % per %', a.frequency_limit, a.frequency_period; end if;

  if p_proof_hash is not null and exists (select 1 from public.activity_submissions s where s.proof_hash = p_proof_hash) then
    insert into public.flags (user_id, reason) values (p_user, 'Duplicate proof photo for ' || a.name);
  end if;

  auto := a.verification_type = 'self';
  insert into public.activity_submissions (user_id, activity_id, proof_path, proof_hash, event_token_id, verification_status, verified_at)
    values (p_user, a.id, p_proof_path, p_proof_hash, tok, case when auto then 'verified' else 'pending' end, case when auto then now() end)
    returning id into sid;
  if auto then
    insert into public.xp_transactions (user_id, academic_year_id, amount, source, reference_id) values (p_user, yid, a.xp_value, 'activity', sid);
  end if;
  return jsonb_build_object('status', case when auto then 'verified' else 'pending' end, 'xp', case when auto then a.xp_value else 0 end);
end $function$;

revoke execute on function public.submit_activity(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.submit_activity(uuid, uuid, text, text, text) to service_role;

-- 2. Rewards: lock the student's profile row so parallel redemptions cannot overspend XP,
--    only allow rewards from the student's own college, and block suspended accounts.
create or replace function public.redeem_reward(p_user uuid, p_reward uuid, p_min_earned integer default 500)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare prof record; r record; earned bigint; spendable bigint; rid uuid; yid uuid;
begin
  select * into prof from public.profiles where id = p_user for update;
  if not found then raise exception 'profile not found'; end if;
  if prof.account_status = 'suspended' then raise exception 'account suspended'; end if;
  select * into r from public.rewards where id = p_reward and active and college_id = prof.college_id for update;
  if not found or r.quantity < 1 then raise exception 'reward unavailable'; end if;
  select coalesce(sum(amount) filter (where source <> 'redemption'),0), coalesce(sum(amount),0) into earned, spendable
    from public.xp_transactions where user_id = p_user;
  if earned < p_min_earned then raise exception 'earn % XP before your first redemption', p_min_earned; end if;
  if spendable < r.xp_required then raise exception 'not enough spendable XP'; end if;
  select id into yid from public.academic_years where college_id = r.college_id and is_current limit 1;
  insert into public.reward_redemptions (user_id, reward_id, xp_spent) values (p_user, p_reward, r.xp_required) returning id into rid;
  insert into public.xp_transactions (user_id, academic_year_id, amount, source, reference_id) values (p_user, yid, -r.xp_required, 'redemption', rid);
  update public.rewards set quantity = quantity - 1 where id = p_reward;
  return rid;
end $function$;

-- 3. Certificates: activity count and CO2e now cover only the current academic year
--    (via the year's activity XP transactions), matching the XP figure.
create or replace function public.issue_certificates(p_admin uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare adm record; yid uuid; n int;
begin
  select * into adm from public.profiles where id = p_admin and role in ('admin','super_admin');
  if not found then raise exception 'not an admin'; end if;
  select id into yid from public.academic_years where college_id = adm.college_id and is_current limit 1;
  if yid is null then raise exception 'no current academic year'; end if;
  with x as (
    select p.id uid, coalesce(sum(t.amount) filter (where t.source <> 'redemption' and t.academic_year_id = yid),0) xp
    from public.profiles p
    join public.memberships m on m.user_id = p.id and m.academic_year_id = yid and m.status in ('active','waived')
    left join public.xp_transactions t on t.user_id = p.id
    where p.college_id = adm.college_id and p.account_status = 'normal' and p.role = 'student' group by p.id),
  tiered as (
    select x.uid, x.xp, (select r.tier from public.certificate_rules r where r.college_id = adm.college_id and r.min_xp <= x.xp order by r.min_xp desc limit 1) tier from x)
  insert into public.certificates (user_id, academic_year_id, tier, xp_earned, activities_count, badges_count, estimated_co2e)
  select t.uid, yid, t.tier, t.xp,
    (select count(*) from public.xp_transactions xt
       join public.activity_submissions s on s.id = xt.reference_id and s.verification_status = 'verified'
       where xt.user_id = t.uid and xt.source = 'activity' and xt.academic_year_id = yid),
    (select count(*) from public.user_badges b where b.user_id = t.uid),
    coalesce((select sum(a.impact_factor) from public.xp_transactions xt
       join public.activity_submissions s on s.id = xt.reference_id and s.verification_status = 'verified'
       join public.activities a on a.id = s.activity_id
       where xt.user_id = t.uid and xt.source = 'activity' and xt.academic_year_id = yid),0)
  from tiered t where t.tier is not null
  on conflict (user_id, academic_year_id) do nothing;
  get diagnostics n = row_count;
  insert into public.audit_logs (actor_id, action, target_type, details) values (p_admin, 'issue_certificates', 'certificate', jsonb_build_object('issued', n));
  return n;
end $function$;

-- 4. Proof photos: images only, max 10 MB.
update storage.buckets set file_size_limit = 10485760, allowed_mime_types = array['image/*'] where id = 'proofs';
