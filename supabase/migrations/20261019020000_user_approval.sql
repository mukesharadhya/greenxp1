-- New students must be approved by a college admin before they can pay and use the app.
-- Students cannot change these columns themselves: profile updates are limited by column grants.
alter table public.profiles
  add column approval_status text not null default 'pending' check (approval_status in ('pending', 'approved', 'rejected')),
  add column approval_note text,
  add column approved_by uuid references public.profiles(id),
  add column approved_at timestamptz;

-- Existing admins and students who already paid stay approved; everyone else is reviewed like a new sign-up.
update public.profiles p set approval_status = 'approved', approved_at = now()
where p.role <> 'student'
   or exists (select 1 from public.memberships m where m.user_id = p.id and m.status in ('active', 'waived'));

-- A rejected student who has fixed their details asks to be reviewed again.
create or replace function public.request_reapproval()
returns void
language sql
security definer
set search_path to ''
as $function$
  update public.profiles set approval_status = 'pending', approval_note = null
  where id = auth.uid() and approval_status = 'rejected';
$function$;
revoke execute on function public.request_reapproval() from public, anon;
grant execute on function public.request_reapproval() to authenticated;
