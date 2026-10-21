-- Activities can ask extra questions on submission (e.g. walk or cycle, and distance), stored with the submission.
-- activities.inputs: [{key, label, type: "choice"|"number", options?, min?, max?}]; activity_submissions.details: the answers.
alter table public.activities add column inputs jsonb not null default '[]'::jsonb check (jsonb_typeof(inputs) = 'array');
alter table public.activity_submissions add column details jsonb check (details is null or jsonb_typeof(details) = 'object');

update public.activities set
  inputs = '[{"key":"mode","label":"How did you travel?","type":"choice","options":["Walk","Cycle"]},
             {"key":"km","label":"Distance covered (km)","type":"number","min":0.1,"max":100}]'::jsonb,
  description = 'Choose walk or cycle, enter the distance you covered, and upload a photo of your trip to college.'
where name = 'Walk or Cycle to College';

-- submit_activity: unchanged, except it also returns the new submission id (the API then saves the answers on it).
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
  return jsonb_build_object('id', sid, 'status', case when auto then 'verified' else 'pending' end, 'xp', case when auto then a.xp_value else 0 end);
end $function$;

-- create_institution: unchanged, except new institutions also copy each activity's questions.
create or replace function public.create_institution(p_template uuid, p_name text, p_city text, p_state text, p_pincode text, p_fee numeric)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
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
end $function$;
