-- Activity changes requested on 2026-10-21 (all institutions).
update public.activities set xp_value = 10 where name = 'Water Saver';
update public.activities set name = 'Clothes Donation', description = 'Upload a photo of the clothes you are donating.'
  where name = 'Clothes Reuse or Donation';
update public.activities set xp_value = 40 where name = 'Sustainability Event';
