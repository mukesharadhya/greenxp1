-- Students now pay by UPI to a fixed ID and send the transaction ID or a screenshot; the super admin confirms it.
-- 'submitted' = waiting for that check. A rejected claim becomes 'failed', and the student can send a new one.
begin;

alter table public.payments drop constraint payments_status_check;
alter table public.payments add constraint payments_status_check
  check (status = any (array['created', 'submitted', 'paid', 'failed', 'refunded']));

alter table public.payments
  add column upi_ref text,
  add column proof_path text,
  add column review_note text,
  add column reviewed_by uuid references public.profiles (id),
  add column reviewed_at timestamptz;

-- One transaction can't pay for two students. A rejected claim frees its ID, e.g. if the money simply hadn't arrived yet.
create unique index payments_upi_ref_key on public.payments (upper(upi_ref)) where status in ('submitted', 'paid');
-- One claim waiting at a time, so pressing Submit twice can't queue two.
create unique index payments_one_submitted_key on public.payments (user_id, academic_year_id) where status = 'submitted';

commit;
