# GreenXP on AWS

Everything runs in **ap-south-1 (Mumbai)** from one CloudFormation stack, `greenxp` ([greenxp.yaml](greenxp.yaml)).

```
browser â”€â”€HTTPSâ”€â”€> greenxp.in (13.206.152.233, EC2 in a public subnet)
                     Caddy â”€â”€/*â”€â”€â”€â”€â”€â”€> /opt/greenxp/site (web/)
                       â””â”€â”€â”€â”€/api/*â”€â”€> Node API on 127.0.0.1:3000 â”€â”€> RDS Postgres (private subnets)
browser â”€â”€> Cognito (sign-in)
browser â”€â”€> S3 uploads (signed forms from the API)
```

| Piece | What it is |
|---|---|
| Server | one `t4g.micro` (Amazon Linux 2023) with Elastic IP `13.206.152.233`; only ports 80/443 open, no SSH |
| HTTPS + site | Caddy (systemd service `caddy`) with automatic Let's Encrypt certificates, serving `web/` |
| API | `api/` on Node 22 (systemd service `greenxp`), listening on 127.0.0.1 only |
| Database | RDS PostgreSQL 17 `db.t4g.micro`, private, 7 days of backups, password managed by RDS in Secrets Manager |
| Sign-in | Cognito user pool (email + password, emailed codes for sign-up and password reset) |
| Files | S3 bucket `greenxp-uploads-<account>` with `proofs/` and `bills/` |
| Secrets | Secrets Manager `greenxp/app` (Anthropic, Resend) |

DNS: GoDaddy A record `greenxp.in` â†’ `13.206.152.233`. The Elastic IP is allocated outside the stack
(`eipalloc-044fc879cc73b5b99`, passed in by deploy.ps1), so it survives server replacement and stack rebuilds.

Rough cost: about USD 25/month (RDS ~15, server ~6, IPv4 address ~4, storage/Secrets ~1).

## Deploy

Needs the AWS CLI with the `Mukesh` profile.

```powershell
.\aws\deploy.ps1          # infrastructure, API and site
.\aws\deploy.ps1 -Api     # after changing api/
.\aws\deploy.ps1 -Web     # after changing web/
```

`-Api` uploads `api/` to the artifacts bucket and runs `greenxp-deploy` on the server through SSM; it fails if `/health` doesn't answer.
`-Web` writes `config.js` from the stack outputs, uploads `web/` and installs it on the server with `greenxp-deploy-site`.

## Secrets

Set these with `.\aws\set-secrets.ps1`, then run `.\aws\deploy.ps1 -Api` to restart the API. The API starts without them.

| Key | Value |
|---|---|
| `ANTHROPIC_API_KEY` | optional, turns on reading electricity bills |
| `RESEND_API_KEY` | optional, turns on emails to students (see below) |
| `EMAIL_FROM` | optional sender, default `GreenXP <noreply@greenxp.in>`; must be on a domain verified in Resend |

## Payments

Students pay the fee by UPI to the ID and QR code on the pay screen (`UPI_ID` and `upi-qr.jpeg` in [web/](../web/)), then send
the transaction ID or a screenshot (S3 `payments/`). Their membership starts when the super admin confirms it in
Admin portal > Payments. Check each one against the bank account: the details a student sends prove nothing on their own.

## Students and institutions

Verifying their email is all a student needs; admins can block an account under Admin portal > Students. A student whose
institution isn't listed adds it after their first sign-in. It gets a copy of the main college's year, activities and rules at
â‚¹199, stays off the public sign-up list, and shows "added by a student" under Institutions until the super admin switches it on.
The super admin reviews activities and issues certificates for every institution, since these may have no admin of their own.

Admin portal > Students lists every registered student with a Download list button. **Approve** only marks a student's details as
checked (status New or Approved); it never blocks them. Students can upload a photo (JPG or PNG, zoomed and positioned in the browser, saved as a 600x600 JPG; S3 `photos/`) and a LinkedIn link,
both optional, when registering or from Edit profile on Home.
**Delete** (per row, or Delete selected) removes a student from every admin list, leaderboard and count and stops them signing in. Their payments, XP and certificates stay in the database (profiles.deleted_at / deleted_by, account_status suspended); to undo a mistake, set deleted_at back to null and account_status to normal.

## Certificates

Students need at least 200 XP for the academic year, and get at most one certificate per academic year. Stars: 1 for 200-299 XP, 2 for 300-399, 3 for 400-499, 4 for 500-699, 5 for 700+; 1000+ XP is awarded "With Distinction" (Green Champion). Standard tiers: Participation 200, Achievement 400, Excellence 700, Distinction 1000 XP. Admin portal has a Certificate template card for a background image and signature
(S3 `certificates/`) and the signatory's name and title. A college without its own uses the super admin's. The site draws each
certificate from the student's record and prints it to PDF from the browser; the signature is an image, not a cryptographic one.

## Email

Enquiries from the Help form go to `greenxpglobal@gmail.com`, limited to 5 per visitor and 30 in all each day.

[api/email.js](../api/email.js) sends these through Resend from `greenxp.in`: account blocked or fee waived, payment confirmed
or rejected, activities rejected (one email per student per review) and certificate issued. Emails go out after the change is saved, and
a failed send only logs `email not sent:` in the API's log. Resend's free plan allows 100 emails a day and 3,000 a month, so
issuing certificates to a large college at once needs a paid plan.

Sign-up codes and password resets still come from Cognito, not Resend.

## Database

Schema: [db/00_compat.sql](db/00_compat.sql) (stand-ins for Supabase's `auth.users`, `auth.uid()` and `authenticated` role),
[db/01_tables.sql](db/01_tables.sql), [db/02_post.sql](db/02_post.sql). The API runs each signed-in request as role
`authenticated` with the user's id, so the row-level security policies carried over from Supabase still apply.

Run SQL from your machine with Session Manager (no SSH or open ports needed):

```powershell
aws ssm start-session --target <ApiInstanceId> --profile Mukesh --region ap-south-1
sudo greenxp-psql
```

For a schema change, write the SQL in a new file under `db/migrations/`, run it with `.\aws\deploy.ps1 -Sql <file>`, and commit it.

Logs: `sudo journalctl -u greenxp -f` on the server; Postgres logs in CloudWatch.

## Moving from Supabase (one-off)

1. Put the Supabase settings into the `greenxp/app` secret: `SUPABASE_DB_URL` (Supabase > Connect > **Session pooler**
   string, with the database password), and for uploaded photos `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
2. `.\aws\deploy.ps1 -Migrate`. It loads the schema and all data into RDS in one go, copies the files to S3, and prints row
   counts for both sides. It refuses to run if RDS already has the tables.
3. Existing users already have Cognito accounts (created without a password). They choose **Forgot password?** on the
   login page; on their first sign-in the API links them to their old account by their verified email.
4. Delete the `SUPABASE_*` keys from the secret afterwards. Remove the `Supabase pooler` egress rule from
   `ApiSecurityGroup` in `greenxp.yaml` and redeploy.

## Notes

- Cognito sends emails from its own address, limited to 50 a day. Before many students sign up, connect Amazon SES
  (`EmailConfiguration` in the template).
- A new Amazon Linux image replaces both instances on the next `-Infra` deploy; the API instance reinstalls the latest
  bundle on boot, so expect a few minutes of downtime.
- The database, buckets, user pool and app secret are kept if the stack is deleted (`Retain`/`Snapshot`), and the database
  and user pool have deletion protection.
