-- Activity logging for the carbon footprint dashboard.
-- details: the raw inputs (vehicle, kWh, meals...); kg_co2e: emissions for the period, computed in the app.
create table public.footprint_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  category text not null check (category in ('transport','electricity','cooking','food','shopping','waste')),
  period_start date not null,
  period_end date not null,
  details jsonb not null check (jsonb_typeof(details) = 'object'),
  kg_co2e numeric not null check (kg_co2e between 0 and 100000),
  bill_path text,
  created_at timestamptz not null default now(),
  check (period_end >= period_start),
  check (bill_path is null or bill_path like user_id::text || '/%')
);
create index footprint_logs_user_period on public.footprint_logs (user_id, period_end);

alter table public.footprint_logs enable row level security;
revoke all on public.footprint_logs from anon;

create policy "read own or admin" on public.footprint_logs for select to authenticated
  using (user_id = (select auth.uid()) or (private.is_admin() and private.same_college(user_id)));
create policy "insert own" on public.footprint_logs for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "update own" on public.footprint_logs for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "delete own" on public.footprint_logs for delete to authenticated
  using (user_id = (select auth.uid()));

-- Utility bills: private, each student only reaches their own folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bills', 'bills', false, 10485760, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy "upload own bill" on storage.objects for insert to authenticated
  with check (bucket_id = 'bills' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "read own bill" on storage.objects for select to authenticated
  using (bucket_id = 'bills' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "delete own bill" on storage.objects for delete to authenticated
  using (bucket_id = 'bills' and (storage.foldername(name))[1] = (select auth.uid())::text);
