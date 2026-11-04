# GreenXP on AWS

Everything runs in **ap-south-1 (Mumbai)** from one CloudFormation stack, `greenxp` ([greenxp.yaml](greenxp.yaml)).

```
browser ──HTTPS──> greenxp.in (13.206.152.233, EC2 in a public subnet)
                     Caddy ──/*──────> /opt/greenxp/site (web/)
                       └────/api/*──> Node API on 127.0.0.1:3000 ──> RDS Postgres (private subnets)
browser ──> Cognito (sign-in)
browser ──> S3 uploads (signed forms from the API)
```

| Piece | What it is |
|---|---|
| Server | one `t4g.micro` (Amazon Linux 2023) with Elastic IP `13.206.152.233`; only ports 80/443 open, no SSH |
| HTTPS + site | Caddy (systemd service `caddy`) with automatic Let's Encrypt certificates, serving `web/` |
| API | `api/` on Node 22 (systemd service `greenxp`), listening on 127.0.0.1 only |
| Database | RDS PostgreSQL 17 `db.t4g.micro`, private, 7 days of backups, password managed by RDS in Secrets Manager |
| Sign-in | Cognito user pool (email + password, emailed codes for sign-up and password reset) |
| Files | S3 bucket `greenxp-uploads-<account>` with `proofs/` and `bills/` |
| Secrets | Secrets Manager `greenxp/app` (Razorpay, Anthropic, webhook secret) |

DNS: GoDaddy A record `greenxp.in` → `13.206.152.233`. The Elastic IP is allocated outside the stack
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

The API starts without Razorpay keys (payments show "not switched on yet") but needs them for payments. Set them in the
console (Secrets Manager > `greenxp/app` > Retrieve secret value > Edit), keeping `RAZORPAY_WEBHOOK_SECRET` as it is, then
run `.\aws\deploy.ps1 -Api` to restart the API.

| Key | Value |
|---|---|
| `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` | Razorpay dashboard |
| `RAZORPAY_WEBHOOK_SECRET` | generated; use the same value for the Razorpay webhook `https://<site>/api/payments/webhook` (`payment.captured`, `order.paid`) |
| `ANTHROPIC_API_KEY` | optional, turns on reading electricity bills |

## Database

Schema: [db/00_compat.sql](db/00_compat.sql) (stand-ins for Supabase's `auth.users`, `auth.uid()` and `authenticated` role),
[db/01_tables.sql](db/01_tables.sql), [db/02_post.sql](db/02_post.sql). The API runs each signed-in request as role
`authenticated` with the user's id, so the row-level security policies carried over from Supabase still apply.

Run SQL from your machine with Session Manager (no SSH or open ports needed):

```powershell
aws ssm start-session --target <ApiInstanceId> --profile Mukesh --region ap-south-1
sudo greenxp-psql
```

For a schema change, write the SQL in a new file under `db/migrations/`, try it with `greenxp-psql -f`, and commit it.

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
