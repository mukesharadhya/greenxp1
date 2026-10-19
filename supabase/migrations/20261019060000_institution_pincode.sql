-- Institutions get a pincode, so students can find theirs by state, city and pincode at sign-up.
alter table public.colleges add column pincode text check (pincode ~ '^[1-9][0-9]{5}$');

-- create_institution now takes the pincode too.
drop function public.create_institution(uuid, text, text, text, numeric);
create or replace function public.create_institution(p_template uuid, p_name text, p_city text, p_state text, p_pincode text, p_fee numeric)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare cid uuid; ty record; yid uuid;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Institution name is required'; end if;
  if coalesce(trim(p_city), '') = '' or coalesce(trim(p_state), '') = '' then raise exception 'City and state are required'; end if;
  if coalesce(trim(p_pincode), '') !~ '^[1-9][0-9]{5}$' then raise exception 'Pincode must be 6 digits'; end if;
  if p_fee is null or p_fee < 0 then raise exception 'Fee must be zero or more'; end if;
  if exists (select 1 from public.colleges where lower(trim(name)) = lower(trim(p_name))) then
    raise exception 'An institution with this name already exists';
  end if;

  insert into public.colleges (name, city, state, pincode) values (trim(p_name), trim(p_city), trim(p_state), trim(p_pincode))
  returning id into cid;

  select * into ty from public.academic_years where college_id = p_template and is_current limit 1;
  if found then
    insert into public.academic_years (college_id, label, start_date, end_date, is_current)
    values (cid, ty.label, ty.start_date, ty.end_date, true) returning id into yid;
    insert into public.fee_settings (college_id, academic_year_id, amount, currency, active)
    values (cid, yid, p_fee, coalesce((select currency from public.fee_settings where college_id = p_template and academic_year_id = ty.id limit 1), 'INR'), true);
  end if;

  insert into public.activities (college_id, name, description, category, xp_value, frequency_limit, frequency_period, verification_type, impact_factor, impact_unit, active)
  select cid, name, description, category, xp_value, frequency_limit, frequency_period, verification_type, impact_factor, impact_unit, active
  from public.activities where college_id = p_template;

  insert into public.certificate_rules (college_id, tier, min_xp)
  select cid, tier, min_xp from public.certificate_rules where college_id = p_template;

  insert into public.certificate_settings (college_id, template_config, signature_urls)
  select cid, template_config, '[]'::jsonb from public.certificate_settings where college_id = p_template;

  return cid;
end $function$;

revoke execute on function public.create_institution(uuid, text, text, text, text, numeric) from public, anon, authenticated;
grant execute on function public.create_institution(uuid, text, text, text, text, numeric) to service_role;
