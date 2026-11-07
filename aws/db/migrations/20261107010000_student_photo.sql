-- Students can upload a passport-size photo (S3 photos/). Their LinkedIn link uses the existing linkedin_url column.
alter table public.profiles add column photo_path text;
