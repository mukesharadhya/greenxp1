-- One-line instructions shown when a student taps an activity on the Earn page (all institutions).
-- Reusable Bottle, Reusable Shopping Bag and Zero Food Waste now need a photo (admin-approved); Energy Saver stays instant.
update public.activities set verification_type = 'photo'
where name in ('Reusable Bottle', 'Reusable Shopping Bag', 'Zero Food Waste');

update public.activities a set description = d.text
from (values
  ('Campus Cleanup',            'Join a campus cleanup drive and enter the event code your coordinator shares.'),
  ('Campus Gardening',          'Take part in a campus gardening session and enter the event code shared there.'),
  ('Plant a Tree',              'Upload a photo of you planting or caring for a tree or plant.'),
  ('Sustainability Event',      'Attend a sustainability talk or event and enter the event code shown there.'),
  ('7-Day Green Challenge',     'Complete at least one approved activity every day for 7 days; XP is added automatically.'),
  ('Bring a Friend',            'Invite a friend; when they join, pay and complete their first activity, you get XP automatically.'),
  ('Energy Saver',              'Switch off lights, fans and chargers you aren''t using today, then tap Mark as done.'),
  ('Home Energy Saver',         'Upload a photo of an energy-saving step at home, like switched-off appliances or an LED bulb.'),
  ('Zero Food Waste',           'Upload a photo of your empty plate after finishing your meal.'),
  ('E-Waste Recycling',         'Hand in old electronics at an e-waste drive and enter the event code given there.'),
  ('Book or Notes Exchange',    'Upload a photo of the books or notes you are sharing or reusing.'),
  ('Clothes Reuse or Donation', 'Upload a photo of the clothes you are donating or reusing.'),
  ('Green Commute',             'Upload a photo of your bus or metro ticket, or your carpool, on the way to college.'),
  ('Public Transport Day',      'Upload a photo of your bus, metro or train ticket or pass for today.'),
  ('Walk or Cycle to College',  'Upload a photo of you walking or cycling to college.'),
  ('Weekend Cycling',           'Upload a photo from your weekend cycle ride.'),
  ('Reusable Bottle',           'Upload a picture of the reusable bottle you are carrying today.'),
  ('Reusable Shopping Bag',     'Upload a picture of your reusable bag when you go shopping.'),
  ('Waste Segregation',         'Upload a photo of your waste sorted into wet, dry and recyclable bins.'),
  ('Water Saver',               'Upload a photo of a water-saving step, like a fixed leak or a bucket bath.')
) as d(name, text)
where a.name = d.name;
