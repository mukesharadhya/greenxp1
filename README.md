# GreenXP: live app (Render + Supabase)

- `api/`  Node/Express backend (Render web service)
- `web/`  Static front end (Render static site)
- Database: Supabase project `greenxp` (already set up with tables, security rules and starter data)

## Deploy
1. Push this folder to a new GitHub repository.
2. Apply the SQL in `supabase/migrations/` to the Supabase project (SQL editor or `supabase db push`). The API needs the `submit_activity` function from it.
3. In Render: New > Blueprint, pick the repo (it reads `render.yaml`) and create both services.
4. On `greenxp-api` set these environment variables (Environment tab). The API refuses to start until all of them are set:
   - `SUPABASE_SERVICE_ROLE_KEY`: Supabase dashboard > Project Settings > API (keep it secret)
   - `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`: Razorpay dashboard, test mode first
   - `RAZORPAY_WEBHOOK_SECRET`: a long random string (e.g. `openssl rand -hex 32`); use the same value when you add the webhook below
   - `FRONTEND_URL`: the URL of the `greenxp-web` static site, with no trailing slash
5. Edit `web/config.js`: set `API_URL` to the URL of `greenxp-api`, commit and push.
6. In Razorpay, add a webhook to `https://<your-api>/api/payments/webhook` for `payment.captured` and `order.paid`, using the same secret.
7. In Supabase > Authentication > URL Configuration, set the Site URL to your static site URL.
8. Make yourself an admin (SQL editor, after you sign up once):
   `update public.profiles set role = 'admin' where email = 'you@example.com';`

## Before real students use it
- Turn on leaked password protection (Supabase > Authentication > Providers > Email).
- Set the college email domain, the real fee (`fee_settings`) and academic year dates.
- Add rewards and sponsors, and event codes (`event_tokens`) for QR-style activities.
- Review the Terms, Privacy and Refund text with your college.
- Free Render web services sleep when idle; use a paid plan for always-on.
