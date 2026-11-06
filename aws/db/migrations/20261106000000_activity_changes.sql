-- Removed at the admin's request. Where a student has already submitted it, the row is hidden instead,
-- so their submission and XP stay intact.
begin;

delete from public.activities a
where a.name = 'Home Energy Saver'
  and not exists (select 1 from public.activity_submissions s where s.activity_id = a.id);

update public.activities set active = false where name = 'Home Energy Saver';

insert into public.activities (college_id, name, description, category, xp_value, frequency_limit, frequency_period, verification_type)
select c.id, 'Conduct Sustainability Awareness Program',
  'Run a sustainability awareness session, talk or campaign for your class, college or community, and upload a photo of it.',
  'Campus', 50, 1, 'month', 'photo_admin'
from public.colleges c
where not exists (select 1 from public.activities a where a.college_id = c.id and a.name = 'Conduct Sustainability Awareness Program');

commit;
