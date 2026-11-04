# GreenXP: live app (AWS)

- `api/`  Node/Express backend
- `web/`  Static front end
- `aws/`  CloudFormation template, database schema and deploy script: see [aws/README.md](aws/README.md)
- `supabase/migrations/`  history from when the app ran on Supabase; the current schema is in `aws/db/`

## Deploy
```powershell
.\aws\deploy.ps1
```
Details, secrets and day-to-day operations are in [aws/README.md](aws/README.md).

Make yourself an admin after signing up once (`sudo greenxp-psql` on the API server, see aws/README.md):
`update public.profiles set role = 'admin' where email = 'you@example.com';`

## Before real students use it
- Connect Amazon SES to Cognito: Cognito's own email sender allows only 50 emails a day.
- Set the college email domain, the real fee (`fee_settings`) and academic year dates.
- Add rewards and sponsors, and event codes (`event_tokens`) for QR-style activities.
- Review the Terms, Privacy and Refund text with your college.
