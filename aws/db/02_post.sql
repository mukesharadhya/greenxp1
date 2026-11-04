-- Runs after the data is loaded: foreign keys, indexes, functions, the new-account trigger, row-level
-- security and grants, as exported from the Supabase database on 2026-10-29.

-- Foreign keys
alter table public.academic_years add constraint academic_years_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.activities add constraint activities_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.activity_submissions add constraint activity_submissions_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id);
alter table public.activity_submissions add constraint activity_submissions_event_token_id_fkey FOREIGN KEY (event_token_id) REFERENCES public.event_tokens(id);
alter table public.activity_submissions add constraint activity_submissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.activity_submissions add constraint activity_submissions_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES public.profiles(id);
alter table public.announcements add constraint announcements_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.announcements add constraint announcements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);
alter table public.audit_logs add constraint audit_logs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id);
alter table public.badges add constraint badges_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.certificate_rules add constraint certificate_rules_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.certificate_settings add constraint certificate_settings_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.certificates add constraint certificates_academic_year_id_fkey FOREIGN KEY (academic_year_id) REFERENCES public.academic_years(id);
alter table public.certificates add constraint certificates_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.challenge_participants add constraint challenge_participants_challenge_id_fkey FOREIGN KEY (challenge_id) REFERENCES public.challenges(id) ON DELETE CASCADE;
alter table public.challenge_participants add constraint challenge_participants_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.challenges add constraint challenges_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.challenges add constraint challenges_sponsor_id_fkey FOREIGN KEY (sponsor_id) REFERENCES public.sponsors(id);
alter table public.event_tokens add constraint event_tokens_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;
alter table public.fee_settings add constraint fee_settings_academic_year_id_fkey FOREIGN KEY (academic_year_id) REFERENCES public.academic_years(id) ON DELETE CASCADE;
alter table public.fee_settings add constraint fee_settings_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.flags add constraint flags_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.profiles(id);
alter table public.flags add constraint flags_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.footprint_logs add constraint footprint_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.lifestyle_surveys add constraint lifestyle_surveys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.memberships add constraint memberships_academic_year_id_fkey FOREIGN KEY (academic_year_id) REFERENCES public.academic_years(id);
alter table public.memberships add constraint memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.memberships add constraint memberships_waived_by_fkey FOREIGN KEY (waived_by) REFERENCES public.profiles(id);
alter table public.notifications add constraint notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.payments add constraint payments_academic_year_id_fkey FOREIGN KEY (academic_year_id) REFERENCES public.academic_years(id);
alter table public.payments add constraint payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.profiles add constraint profiles_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.profiles(id);
alter table public.profiles add constraint profiles_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id);
alter table public.profiles add constraint profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.reward_redemptions add constraint reward_redemptions_reward_id_fkey FOREIGN KEY (reward_id) REFERENCES public.rewards(id);
alter table public.reward_redemptions add constraint reward_redemptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.rewards add constraint rewards_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.rewards add constraint rewards_sponsor_id_fkey FOREIGN KEY (sponsor_id) REFERENCES public.sponsors(id);
alter table public.sponsors add constraint sponsors_college_id_fkey FOREIGN KEY (college_id) REFERENCES public.colleges(id) ON DELETE CASCADE;
alter table public.streaks add constraint streaks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.user_badges add constraint user_badges_badge_id_fkey FOREIGN KEY (badge_id) REFERENCES public.badges(id) ON DELETE CASCADE;
alter table public.user_badges add constraint user_badges_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
alter table public.xp_transactions add constraint xp_transactions_academic_year_id_fkey FOREIGN KEY (academic_year_id) REFERENCES public.academic_years(id);
alter table public.xp_transactions add constraint xp_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

-- Indexes
CREATE UNIQUE INDEX colleges_name_unique ON public.colleges USING btree (lower(TRIM(BOTH FROM name)));
CREATE INDEX footprint_logs_user_period ON public.footprint_logs USING btree (user_id, period_end);
CREATE INDEX notifications_user_id_created_at_idx ON public.notifications USING btree (user_id, created_at DESC);
CREATE INDEX payments_user_id_idx ON public.payments USING btree (user_id);
CREATE INDEX certificates_user_id_idx ON public.certificates USING btree (user_id);
CREATE INDEX activity_submissions_verification_status_idx ON public.activity_submissions USING btree (verification_status);
CREATE INDEX activity_submissions_user_id_activity_id_submitted_at_idx ON public.activity_submissions USING btree (user_id, activity_id, submitted_at DESC);
CREATE INDEX reward_redemptions_user_id_idx ON public.reward_redemptions USING btree (user_id);
CREATE INDEX profiles_college_id_idx ON public.profiles USING btree (college_id);
CREATE INDEX activities_college_id_idx ON public.activities USING btree (college_id);
CREATE INDEX user_badges_user_id_idx ON public.user_badges USING btree (user_id);
CREATE INDEX memberships_user_id_idx ON public.memberships USING btree (user_id);
CREATE INDEX xp_transactions_user_id_created_at_idx ON public.xp_transactions USING btree (user_id, created_at DESC);
CREATE INDEX challenge_participants_user_id_idx ON public.challenge_participants USING btree (user_id);
CREATE INDEX activity_submissions_proof_hash_idx ON public.activity_submissions USING btree (proof_hash);

-- Helper functions used by the security rules
create schema if not exists private;

CREATE OR REPLACE FUNCTION private.my_college()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select college_id from public.profiles where id = auth.uid() $function$
;

CREATE OR REPLACE FUNCTION private.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select coalesce((select role in ('admin','super_admin') from public.profiles where id = auth.uid()), false) $function$
;

CREATE OR REPLACE FUNCTION private.my_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select role from public.profiles where id = auth.uid() $function$
;

CREATE OR REPLACE FUNCTION private.same_college(uid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select coalesce((select college_id = private.my_college() from public.profiles where id = uid), false) $function$
;

CREATE OR REPLACE FUNCTION private.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.profiles (id, email, full_name, college_id)
  values (new.id, new.email, new.raw_user_meta_data->>'full_name', nullif(new.raw_user_meta_data->>'college_id','')::uuid);
  return new;
end $function$
;

create trigger on_auth_user_created after insert on auth.users for each row execute function private.handle_new_user();

-- App functions
CREATE OR REPLACE FUNCTION public.create_institution(p_template uuid, p_name text, p_city text, p_state text, p_pincode text, p_fee numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare cid uuid; ty record; yid uuid;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Institution name is required'; end if;
  if coalesce(trim(p_pincode), '') <> '' and trim(p_pincode) !~ '^[1-9][0-9]{5}$' then raise exception 'Pincode must be 6 digits'; end if;
  if p_fee is null or p_fee < 0 then raise exception 'Fee must be zero or more'; end if;
  if exists (select 1 from public.colleges where lower(trim(name)) = lower(trim(p_name))) then
    raise exception 'An institution with this name already exists';
  end if;

  insert into public.colleges (name, city, state, pincode)
  values (trim(p_name), nullif(trim(p_city), ''), nullif(trim(p_state), ''), nullif(trim(p_pincode), ''))
  returning id into cid;

  select * into ty from public.academic_years where college_id = p_template and is_current limit 1;
  if found then
    insert into public.academic_years (college_id, label, start_date, end_date, is_current)
    values (cid, ty.label, ty.start_date, ty.end_date, true) returning id into yid;
    insert into public.fee_settings (college_id, academic_year_id, amount, currency, active)
    values (cid, yid, p_fee, coalesce((select currency from public.fee_settings where college_id = p_template and academic_year_id = ty.id limit 1), 'INR'), true);
  end if;

  insert into public.activities (college_id, name, description, category, xp_value, frequency_limit, frequency_period, verification_type, impact_factor, impact_unit, active, inputs)
  select cid, name, description, category, xp_value, frequency_limit, frequency_period, verification_type, impact_factor, impact_unit, active, inputs
  from public.activities where college_id = p_template;

  insert into public.certificate_rules (college_id, tier, min_xp)
  select cid, tier, min_xp from public.certificate_rules where college_id = p_template;

  insert into public.certificate_settings (college_id, template_config, signature_urls)
  select cid, template_config, '[]'::jsonb from public.certificate_settings where college_id = p_template;

  return cid;
end $function$
;

CREATE OR REPLACE FUNCTION public.get_leaderboard(p_period text DEFAULT 'all'::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(rank bigint, display_name text, department text, xp bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select rank() over (order by x.xp desc), coalesce(p.username, p.full_name), p.department, x.xp
  from (select t.user_id, coalesce(sum(t.amount) filter (where t.source <> 'redemption'), 0) as xp
        from public.xp_transactions t
        where p_period = 'all'
           or (p_period = 'week' and t.created_at > now() - interval '7 days')
           or (p_period = 'month' and t.created_at > now() - interval '30 days')
        group by t.user_id) x
  join public.profiles p on p.id = x.user_id
  where p.leaderboard_visibility and p.account_status <> 'suspended' and p.college_id = private.my_college()
  order by x.xp desc limit least(p_limit, 200)
$function$
;

CREATE OR REPLACE FUNCTION public.issue_certificates(p_admin uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.lifestyle_summary()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.my_xp_summary()
 RETURNS TABLE(earned bigint, spendable bigint, year_earned bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(sum(amount) filter (where source <> 'redemption'), 0),
         coalesce(sum(amount), 0),
         coalesce(sum(amount) filter (where source <> 'redemption'
            and academic_year_id in (select id from public.academic_years where is_current)), 0)
  from public.xp_transactions where user_id = auth.uid()
$function$
;

CREATE OR REPLACE FUNCTION public.public_stats()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'institutions',      (select count(distinct p.college_id) from public.profiles p where p.role = 'student' and p.college_id is not null),
    'students',          (select count(*) from public.profiles where role = 'student'),
    'activities_listed', (select count(distinct name) from public.activities where active),
    'activities',        (select count(*) from public.activity_submissions where verification_status = 'verified'),
    'co2e_saved_kg',     (select coalesce(sum(a.impact_factor), 0) from public.activity_submissions s
                          join public.activities a on a.id = s.activity_id where s.verification_status = 'verified'),
    'certificates',      (select count(*) from public.certificates where status = 'issued'));
$function$
;

CREATE OR REPLACE FUNCTION public.redeem_reward(p_user uuid, p_reward uuid, p_min_earned integer DEFAULT 500)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.request_reapproval()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update public.profiles set approval_status = 'pending', approval_note = null
  where id = auth.uid() and approval_status = 'rejected';
$function$
;

CREATE OR REPLACE FUNCTION public.review_submission(p_id uuid, p_admin uuid, p_approve boolean, p_reason text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s record; a record; yid uuid; adm record;
begin
  select * into adm from public.profiles where id = p_admin and role in ('admin','super_admin');
  if not found then raise exception 'not an admin'; end if;
  select sub.* into s from public.activity_submissions sub join public.profiles p on p.id = sub.user_id
    where sub.id = p_id and sub.verification_status = 'pending' and p.college_id = adm.college_id for update of sub;
  if not found then raise exception 'submission not found or already reviewed'; end if;
  update public.activity_submissions set verification_status = case when p_approve then 'verified' else 'rejected' end,
    rejection_reason = case when p_approve then null else p_reason end, verified_by = p_admin, verified_at = now() where id = p_id;
  if p_approve then
    select * into a from public.activities where id = s.activity_id;
    select id into yid from public.academic_years where college_id = adm.college_id and is_current limit 1;
    insert into public.xp_transactions (user_id, academic_year_id, amount, source, reference_id) values (s.user_id, yid, a.xp_value, 'activity', p_id);
  end if;
  insert into public.audit_logs (actor_id, action, target_type, target_id, details)
    values (p_admin, case when p_approve then 'approve_submission' else 'reject_submission' end, 'submission', p_id::text, jsonb_build_object('reason', p_reason));
  return case when p_approve then 'verified' else 'rejected' end;
end $function$
;

CREATE OR REPLACE FUNCTION public.submit_activity(p_user uuid, p_activity uuid, p_proof_path text, p_proof_hash text, p_event_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  return jsonb_build_object('id', sid, 'status', case when auto then 'verified' else 'pending' end, 'xp', case when auto then a.xp_value else 0 end);
end $function$
;

CREATE OR REPLACE FUNCTION public.verify_certificate(p_code text)
 RETURNS TABLE(status text, student_name text, tier text, academic_year text, college text, issued_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.status, p.full_name, c.tier, y.label, col.name, c.issued_at
  from public.certificates c
  join public.profiles p on p.id = c.user_id
  join public.academic_years y on y.id = c.academic_year_id
  left join public.colleges col on col.id = p.college_id
  where c.certificate_code = upper(trim(p_code))
$function$
;

-- Row-level security: applies when the API runs a request as role "authenticated".
alter table public.academic_years enable row level security;
alter table public.activities enable row level security;
alter table public.activity_submissions enable row level security;
alter table public.announcements enable row level security;
alter table public.audit_logs enable row level security;
alter table public.badges enable row level security;
alter table public.certificate_rules enable row level security;
alter table public.certificate_settings enable row level security;
alter table public.certificates enable row level security;
alter table public.challenge_participants enable row level security;
alter table public.challenges enable row level security;
alter table public.colleges enable row level security;
alter table public.event_tokens enable row level security;
alter table public.fee_settings enable row level security;
alter table public.flags enable row level security;
alter table public.footprint_logs enable row level security;
alter table public.lifestyle_surveys enable row level security;
alter table public.memberships enable row level security;
alter table public.notifications enable row level security;
alter table public.payments enable row level security;
alter table public.profiles enable row level security;
alter table public.reward_redemptions enable row level security;
alter table public.rewards enable row level security;
alter table public.sponsors enable row level security;
alter table public.streaks enable row level security;
alter table public.user_badges enable row level security;
alter table public.xp_transactions enable row level security;

create policy "admin manage" on public.academic_years as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read own college" on public.academic_years as PERMISSIVE for SELECT to authenticated using ((college_id = private.my_college()));
create policy "admin manage" on public.activities as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read own college" on public.activities as PERMISSIVE for SELECT to authenticated using ((college_id = private.my_college()));
create policy "admin update submissions" on public.activity_submissions as PERMISSIVE for UPDATE to authenticated using ((private.is_admin() AND private.same_college(user_id))) with check ((private.is_admin() AND private.same_college(user_id)));
create policy "read own or admin" on public.activity_submissions as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "admin manage" on public.announcements as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read own college" on public.announcements as PERMISSIVE for SELECT to authenticated using ((college_id = private.my_college()));
create policy "admin read audit" on public.audit_logs as PERMISSIVE for SELECT to authenticated using (private.is_admin());
create policy "admin manage badges" on public.badges as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read badges" on public.badges as PERMISSIVE for SELECT to authenticated using (((college_id IS NULL) OR (college_id = private.my_college())));
create policy "admin manage" on public.certificate_rules as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read own college" on public.certificate_rules as PERMISSIVE for SELECT to authenticated using ((college_id = private.my_college()));
create policy "admin manage" on public.certificate_settings as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "admin update certificates" on public.certificates as PERMISSIVE for UPDATE to authenticated using ((private.is_admin() AND private.same_college(user_id))) with check ((private.is_admin() AND private.same_college(user_id)));
create policy "read own or admin" on public.certificates as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "read own" on public.challenge_participants as PERMISSIVE for SELECT to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "admin manage" on public.challenges as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read own college" on public.challenges as PERMISSIVE for SELECT to authenticated using ((college_id = private.my_college()));
create policy "admin update college" on public.colleges as PERMISSIVE for UPDATE to authenticated using ((private.is_admin() AND (id = private.my_college()))) with check ((private.is_admin() AND (id = private.my_college())));
create policy "public read colleges" on public.colleges as PERMISSIVE for SELECT to anon,authenticated using (active);
create policy "admin manage event tokens" on public.event_tokens as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (EXISTS ( SELECT 1
   FROM public.activities a
  WHERE ((a.id = event_tokens.activity_id) AND (a.college_id = private.my_college())))))) with check ((private.is_admin() AND (EXISTS ( SELECT 1
   FROM public.activities a
  WHERE ((a.id = event_tokens.activity_id) AND (a.college_id = private.my_college()))))));
create policy "admin manage" on public.fee_settings as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "public read active fee" on public.fee_settings as PERMISSIVE for SELECT to anon,authenticated using (active);
create policy "admin manage flags" on public.flags as PERMISSIVE for UPDATE to authenticated using ((private.is_admin() AND private.same_college(user_id))) with check ((private.is_admin() AND private.same_college(user_id)));
create policy "read own or admin" on public.flags as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "delete own" on public.footprint_logs as PERMISSIVE for DELETE to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "insert own" on public.footprint_logs as PERMISSIVE for INSERT to authenticated with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "read own or admin" on public.footprint_logs as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "update own" on public.footprint_logs as PERMISSIVE for UPDATE to authenticated using ((user_id = ( SELECT auth.uid() AS uid))) with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "insert own" on public.lifestyle_surveys as PERMISSIVE for INSERT to authenticated with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "read own or admin" on public.lifestyle_surveys as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "update own" on public.lifestyle_surveys as PERMISSIVE for UPDATE to authenticated using ((user_id = ( SELECT auth.uid() AS uid))) with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "admin update memberships" on public.memberships as PERMISSIVE for UPDATE to authenticated using ((private.is_admin() AND private.same_college(user_id))) with check ((private.is_admin() AND private.same_college(user_id)));
create policy "read own or admin" on public.memberships as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "read own notifications" on public.notifications as PERMISSIVE for SELECT to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "update own notifications" on public.notifications as PERMISSIVE for UPDATE to authenticated using ((user_id = ( SELECT auth.uid() AS uid))) with check ((user_id = ( SELECT auth.uid() AS uid)));
create policy "read own or admin" on public.payments as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "read own profile" on public.profiles as PERMISSIVE for SELECT to authenticated using (((id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND (college_id = private.my_college()))));
create policy "update own profile" on public.profiles as PERMISSIVE for UPDATE to authenticated using ((id = ( SELECT auth.uid() AS uid))) with check ((id = ( SELECT auth.uid() AS uid)));
create policy "read own or admin" on public.reward_redemptions as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));
create policy "admin manage" on public.rewards as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read own college" on public.rewards as PERMISSIVE for SELECT to authenticated using ((college_id = private.my_college()));
create policy "admin manage" on public.sponsors as PERMISSIVE for ALL to authenticated using ((private.is_admin() AND (college_id = private.my_college()))) with check ((private.is_admin() AND (college_id = private.my_college())));
create policy "read own" on public.streaks as PERMISSIVE for SELECT to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "read own" on public.user_badges as PERMISSIVE for SELECT to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "read own or admin" on public.xp_transactions as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) OR (private.is_admin() AND private.same_college(user_id))));

-- Grants for the "authenticated" role. As on Supabase, profiles and notifications allow updates only to the
-- columns a user may change; row-level security decides which rows.
grant usage on schema public, private to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke insert, update, delete on public.profiles from authenticated;
grant update (department, full_name, instagram_url, interests, leaderboard_visibility, linkedin_url, motivation,
  notification_preferences, phone, portfolio_url, section, semester, username, usn, year) on public.profiles to authenticated;
revoke update on public.notifications from authenticated;
grant update (read_status) on public.notifications to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;

-- Functions: only the ones a signed-in user may call directly; the rest are called by the API as the owner.
revoke execute on all functions in schema public, private from public;
grant execute on all functions in schema private to authenticated;
grant execute on function public.my_xp_summary(), public.get_leaderboard(text, integer), public.lifestyle_summary(),
  public.request_reapproval(), public.public_stats(), public.verify_certificate(text) to authenticated;
