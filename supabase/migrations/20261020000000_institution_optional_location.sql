-- Bulk uploads may leave city, state or pincode empty; the admin fills them in later with Edit.
-- Only the name is required. A pincode, when given, must still be 6 digits (the column's check enforces that too).
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

  insert into public.activities (college_id, name, description, category, xp_value, frequency_limit, frequency_period, verification_type, impact_factor, impact_unit, active)
  select cid, name, description, category, xp_value, frequency_limit, frequency_period, verification_type, impact_factor, impact_unit, active
  from public.activities where college_id = p_template;

  insert into public.certificate_rules (college_id, tier, min_xp)
  select cid, tier, min_xp from public.certificate_rules where college_id = p_template;

  insert into public.certificate_settings (college_id, template_config, signature_urls)
  select cid, template_config, '[]'::jsonb from public.certificate_settings where college_id = p_template;

  return cid;
end $function$;
