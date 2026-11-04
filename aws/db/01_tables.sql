-- GreenXP tables with their primary keys, unique and check constraints, exported from the Supabase database
-- on 2026-10-29. Foreign keys, indexes, functions and security rules are in 02_post.sql, which runs after the
-- data is loaded.
create table public.academic_years (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  label text not null,
  start_date date not null,
  end_date date not null,
  is_current boolean default false not null
);
create table public.activities (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  name text not null,
  description text,
  category text not null,
  xp_value integer not null,
  frequency_limit integer default 1 not null,
  frequency_period text default 'day'::text not null,
  verification_type text default 'photo'::text not null,
  impact_factor numeric(8,3) default 0 not null,
  impact_unit text default 'kg CO2e'::text,
  active boolean default true not null,
  inputs jsonb default '[]'::jsonb not null
);
create table public.activity_submissions (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  activity_id uuid not null,
  submitted_at timestamp with time zone default now() not null,
  proof_path text,
  proof_hash text,
  event_token_id uuid,
  verification_status text default 'pending'::text not null,
  rejection_reason text,
  verified_by uuid,
  verified_at timestamp with time zone,
  details jsonb
);
create table public.announcements (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  title text not null,
  body text,
  created_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.audit_logs (
  id uuid default gen_random_uuid() not null,
  actor_id uuid,
  action text not null,
  target_type text,
  target_id text,
  details jsonb,
  created_at timestamp with time zone default now() not null
);
create table public.badges (
  id uuid default gen_random_uuid() not null,
  college_id uuid,
  name text not null,
  description text,
  icon text,
  requirement_type text not null,
  requirement_value integer default 1 not null,
  tier text
);
create table public.certificate_rules (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  tier text not null,
  min_xp integer not null
);
create table public.certificate_settings (
  college_id uuid not null,
  template_config jsonb default '{}'::jsonb not null,
  signature_urls jsonb default '[]'::jsonb not null,
  logo_url text
);
create table public.certificates (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  academic_year_id uuid not null,
  tier text not null,
  xp_earned integer not null,
  activities_count integer default 0 not null,
  badges_count integer default 0 not null,
  estimated_co2e numeric(10,2) default 0 not null,
  certificate_code text default upper(encode(gen_random_bytes(6), 'hex'::text)) not null,
  pdf_url text,
  status text default 'issued'::text not null,
  issued_at timestamp with time zone default now() not null,
  revoked_at timestamp with time zone,
  revoked_reason text
);
create table public.challenge_participants (
  challenge_id uuid not null,
  user_id uuid not null,
  progress integer default 0 not null,
  status text default 'joined'::text not null,
  joined_at timestamp with time zone default now() not null
);
create table public.challenges (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  sponsor_id uuid,
  name text not null,
  description text,
  start_date date not null,
  end_date date not null,
  xp_reward integer default 0 not null,
  max_participants integer,
  goal_categories text[] default '{}'::text[] not null,
  goal_count integer default 5 not null,
  active boolean default true not null
);
create table public.colleges (
  id uuid default gen_random_uuid() not null,
  name text not null,
  city text,
  state text,
  logo_url text,
  email_domain text,
  payment_provider text default 'razorpay'::text not null,
  active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  pincode text
);
create table public.event_tokens (
  id uuid default gen_random_uuid() not null,
  activity_id uuid not null,
  secret text not null,
  valid_from timestamp with time zone not null,
  valid_to timestamp with time zone not null
);
create table public.fee_settings (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  academic_year_id uuid not null,
  amount numeric(10,2) not null,
  currency text default 'INR'::text not null,
  active boolean default true not null
);
create table public.flags (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  reason text not null,
  status text default 'open'::text not null,
  reviewed_by uuid,
  created_at timestamp with time zone default now() not null
);
create table public.footprint_logs (
  id uuid default gen_random_uuid() not null,
  user_id uuid default auth.uid() not null,
  category text not null,
  period_start date not null,
  period_end date not null,
  details jsonb not null,
  kg_co2e numeric not null,
  bill_path text,
  created_at timestamp with time zone default now() not null
);
create table public.lifestyle_surveys (
  user_id uuid default auth.uid() not null,
  answers jsonb not null,
  footprint jsonb not null,
  total_kg numeric not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table public.memberships (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  academic_year_id uuid not null,
  status text default 'pending_payment'::text not null,
  start_date date,
  end_date date,
  waived_by uuid,
  waiver_reason text
);
create table public.notifications (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  type text not null,
  title text not null,
  message text,
  read_status boolean default false not null,
  created_at timestamp with time zone default now() not null
);
create table public.payments (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  academic_year_id uuid not null,
  amount numeric(10,2) not null,
  currency text default 'INR'::text not null,
  gateway_order_id text,
  gateway_payment_id text,
  status text default 'created'::text not null,
  receipt_url text,
  paid_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table public.profiles (
  id uuid not null,
  college_id uuid,
  full_name text,
  email text,
  phone text,
  usn text,
  department text,
  year smallint,
  semester smallint,
  section text,
  username text,
  instagram_url text,
  linkedin_url text,
  portfolio_url text,
  interests text[] default '{}'::text[] not null,
  motivation text[] default '{}'::text[] not null,
  notification_preferences jsonb default '{}'::jsonb not null,
  leaderboard_visibility boolean default true not null,
  role text default 'student'::text not null,
  account_status text default 'normal'::text not null,
  is_demo boolean default false not null,
  created_at timestamp with time zone default now() not null,
  approval_status text default 'pending'::text not null,
  approval_note text,
  approved_by uuid,
  approved_at timestamp with time zone
);
create table public.reward_redemptions (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  reward_id uuid not null,
  xp_spent integer not null,
  voucher_code text,
  status text default 'pending'::text not null,
  redeemed_at timestamp with time zone default now() not null
);
create table public.rewards (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  sponsor_id uuid,
  name text not null,
  description text,
  xp_required integer not null,
  quantity integer default 0 not null,
  active boolean default true not null
);
create table public.sponsors (
  id uuid default gen_random_uuid() not null,
  college_id uuid not null,
  company_name text not null,
  logo_url text,
  contact text,
  campaign_details text
);
create table public.streaks (
  user_id uuid not null,
  current_streak integer default 0 not null,
  longest_streak integer default 0 not null,
  last_activity_date date,
  shields_remaining integer default 3 not null
);
create table public.user_badges (
  user_id uuid not null,
  badge_id uuid not null,
  earned_at timestamp with time zone default now() not null
);
create table public.xp_transactions (
  id uuid default gen_random_uuid() not null,
  user_id uuid not null,
  academic_year_id uuid,
  amount integer not null,
  source text not null,
  reference_id uuid,
  created_at timestamp with time zone default now() not null
);

alter table public.academic_years add constraint academic_years_pkey PRIMARY KEY (id);
alter table public.activities add constraint activities_pkey PRIMARY KEY (id);
alter table public.activity_submissions add constraint activity_submissions_pkey PRIMARY KEY (id);
alter table public.announcements add constraint announcements_pkey PRIMARY KEY (id);
alter table public.audit_logs add constraint audit_logs_pkey PRIMARY KEY (id);
alter table public.badges add constraint badges_pkey PRIMARY KEY (id);
alter table public.certificate_rules add constraint certificate_rules_pkey PRIMARY KEY (id);
alter table public.certificate_settings add constraint certificate_settings_pkey PRIMARY KEY (college_id);
alter table public.certificates add constraint certificates_pkey PRIMARY KEY (id);
alter table public.challenge_participants add constraint challenge_participants_pkey PRIMARY KEY (challenge_id, user_id);
alter table public.challenges add constraint challenges_pkey PRIMARY KEY (id);
alter table public.colleges add constraint colleges_pkey PRIMARY KEY (id);
alter table public.event_tokens add constraint event_tokens_pkey PRIMARY KEY (id);
alter table public.fee_settings add constraint fee_settings_pkey PRIMARY KEY (id);
alter table public.flags add constraint flags_pkey PRIMARY KEY (id);
alter table public.footprint_logs add constraint footprint_logs_pkey PRIMARY KEY (id);
alter table public.lifestyle_surveys add constraint lifestyle_surveys_pkey PRIMARY KEY (user_id);
alter table public.memberships add constraint memberships_pkey PRIMARY KEY (id);
alter table public.notifications add constraint notifications_pkey PRIMARY KEY (id);
alter table public.payments add constraint payments_pkey PRIMARY KEY (id);
alter table public.profiles add constraint profiles_pkey PRIMARY KEY (id);
alter table public.reward_redemptions add constraint reward_redemptions_pkey PRIMARY KEY (id);
alter table public.rewards add constraint rewards_pkey PRIMARY KEY (id);
alter table public.sponsors add constraint sponsors_pkey PRIMARY KEY (id);
alter table public.streaks add constraint streaks_pkey PRIMARY KEY (user_id);
alter table public.user_badges add constraint user_badges_pkey PRIMARY KEY (user_id, badge_id);
alter table public.xp_transactions add constraint xp_transactions_pkey PRIMARY KEY (id);
alter table public.academic_years add constraint academic_years_college_id_label_key UNIQUE (college_id, label);
alter table public.certificate_rules add constraint certificate_rules_college_id_tier_key UNIQUE (college_id, tier);
alter table public.certificates add constraint certificates_certificate_code_key UNIQUE (certificate_code);
alter table public.certificates add constraint certificates_user_id_academic_year_id_key UNIQUE (user_id, academic_year_id);
alter table public.fee_settings add constraint fee_settings_college_id_academic_year_id_key UNIQUE (college_id, academic_year_id);
alter table public.memberships add constraint memberships_user_id_academic_year_id_key UNIQUE (user_id, academic_year_id);
alter table public.payments add constraint payments_gateway_order_id_key UNIQUE (gateway_order_id);
alter table public.payments add constraint payments_gateway_payment_id_key UNIQUE (gateway_payment_id);
alter table public.profiles add constraint profiles_college_id_usn_key UNIQUE (college_id, usn);
alter table public.activities add constraint activities_frequency_period_check CHECK ((frequency_period = ANY (ARRAY['day'::text, 'week'::text, 'month'::text, 'event'::text, 'total'::text])));
alter table public.activities add constraint activities_inputs_check CHECK ((jsonb_typeof(inputs) = 'array'::text));
alter table public.activities add constraint activities_verification_type_check CHECK ((verification_type = ANY (ARRAY['self'::text, 'photo'::text, 'qr_event'::text, 'photo_admin'::text, 'automatic'::text])));
alter table public.activities add constraint activities_xp_value_check CHECK ((xp_value >= 0));
alter table public.activity_submissions add constraint activity_submissions_details_check CHECK (((details IS NULL) OR (jsonb_typeof(details) = 'object'::text)));
alter table public.activity_submissions add constraint activity_submissions_verification_status_check CHECK ((verification_status = ANY (ARRAY['pending'::text, 'verified'::text, 'rejected'::text])));
alter table public.certificates add constraint certificates_status_check CHECK ((status = ANY (ARRAY['issued'::text, 'revoked'::text])));
alter table public.challenge_participants add constraint challenge_participants_status_check CHECK ((status = ANY (ARRAY['joined'::text, 'completed'::text])));
alter table public.colleges add constraint colleges_pincode_check CHECK ((pincode ~ '^[1-9][0-9]{5}$'::text));
alter table public.fee_settings add constraint fee_settings_amount_check CHECK ((amount >= (0)::numeric));
alter table public.flags add constraint flags_status_check CHECK ((status = ANY (ARRAY['open'::text, 'reviewed'::text, 'dismissed'::text])));
alter table public.footprint_logs add constraint footprint_logs_category_check CHECK ((category = ANY (ARRAY['transport'::text, 'electricity'::text, 'cooking'::text, 'food'::text, 'shopping'::text, 'waste'::text])));
alter table public.footprint_logs add constraint footprint_logs_check CHECK ((period_end >= period_start));
alter table public.footprint_logs add constraint footprint_logs_check1 CHECK (((bill_path IS NULL) OR (bill_path ~~ ((user_id)::text || '/%'::text))));
alter table public.footprint_logs add constraint footprint_logs_details_check CHECK ((jsonb_typeof(details) = 'object'::text));
alter table public.footprint_logs add constraint footprint_logs_kg_co2e_check CHECK (((kg_co2e >= (0)::numeric) AND (kg_co2e <= (100000)::numeric)));
alter table public.lifestyle_surveys add constraint lifestyle_surveys_answers_check CHECK ((jsonb_typeof(answers) = 'object'::text));
alter table public.lifestyle_surveys add constraint lifestyle_surveys_footprint_check CHECK ((jsonb_typeof(footprint) = 'object'::text));
alter table public.lifestyle_surveys add constraint lifestyle_surveys_total_kg_check CHECK (((total_kg >= (0)::numeric) AND (total_kg <= (50000)::numeric)));
alter table public.memberships add constraint memberships_status_check CHECK ((status = ANY (ARRAY['pending_payment'::text, 'active'::text, 'expired'::text, 'waived'::text])));
alter table public.payments add constraint payments_status_check CHECK ((status = ANY (ARRAY['created'::text, 'paid'::text, 'failed'::text, 'refunded'::text])));
alter table public.profiles add constraint profiles_account_status_check CHECK ((account_status = ANY (ARRAY['normal'::text, 'suspicious'::text, 'under_review'::text, 'suspended'::text])));
alter table public.profiles add constraint profiles_approval_status_check CHECK ((approval_status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text])));
alter table public.profiles add constraint profiles_role_check CHECK ((role = ANY (ARRAY['student'::text, 'admin'::text, 'super_admin'::text, 'sponsor'::text])));
alter table public.reward_redemptions add constraint reward_redemptions_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'fulfilled'::text, 'cancelled'::text])));
alter table public.rewards add constraint rewards_quantity_check CHECK ((quantity >= 0));
alter table public.rewards add constraint rewards_xp_required_check CHECK ((xp_required >= 0));
alter table public.xp_transactions add constraint xp_transactions_source_check CHECK ((source = ANY (ARRAY['activity'::text, 'challenge'::text, 'bonus'::text, 'redemption'::text, 'reversal'::text])));
