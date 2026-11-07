-- Students can upload a passport-size photo (S3 photos/). Their LinkedIn link uses the existing linkedin_url column.
alter table public.profiles add column if not exists photo_path text;
