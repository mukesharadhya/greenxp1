#!/bin/bash
# One-off copy of GreenXP from Supabase to RDS. Runs on the API server (aws/deploy.ps1 -Migrate sends it there).
# Reads from the app secret: SUPABASE_DB_URL (the Session pooler connection string), and optionally
# SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY to copy uploaded photos and bills.
# Refuses to run if RDS already has the GreenXP tables, so it can never overwrite live data.
set -euo pipefail
cd "$(dirname "$0")"
source /etc/greenxp.env
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text --region "$AWS_REGION"; }
APP=$(secret "$APP_SECRET_ARN"); DB=$(secret "$DB_SECRET_ARN")
SRC=$(jq -r '.SUPABASE_DB_URL // empty' <<<"$APP")
[ -n "$SRC" ] || { echo "Add SUPABASE_DB_URL to the app secret first (see aws/README.md)."; exit 1; }
TGT="host=$DB_HOST dbname=$DB_NAME user=$(jq -r .username <<<"$DB") sslmode=verify-full sslrootcert=/opt/greenxp/rds-ca.pem"
DBPW=$(jq -r .password <<<"$DB")
target() { PGPASSWORD="$DBPW" psql "$TGT" -v ON_ERROR_STOP=1 -q "$@"; }
source_db() { psql "$SRC" -v ON_ERROR_STOP=1 -q "$@"; }

if [ "$(target -tAc "select to_regclass('public.profiles') is not null")" = t ]; then
  echo "RDS already has the GreenXP tables; stopping so nothing is overwritten."; exit 1
fi

echo "== Schema"
target -f 00_compat.sql -f 01_tables.sql

echo "== Data (one transaction)"
{
  echo "begin;"
  echo "copy auth.users (id, email, raw_user_meta_data, created_at) from stdin;"
  source_db -tA -c "copy (select id, email, coalesce(raw_user_meta_data, '{}'::jsonb), created_at from auth.users) to stdout"
  echo '\.'
  pg_dump "$SRC" --data-only --schema=public --no-owner --no-privileges
  echo "commit;"
} | target

echo "== Keys, functions, security rules"
target -f 02_post.sql

echo "== Uploaded files"
SB_URL=$(jq -r '.SUPABASE_URL // empty' <<<"$APP"); SB_KEY=$(jq -r '.SUPABASE_SERVICE_ROLE_KEY // empty' <<<"$APP")
if [ -n "$SB_URL" ] && [ -n "$SB_KEY" ]; then
  auth=(-H "apikey: $SB_KEY")
  [[ $SB_KEY == eyJ* ]] && auth+=(-H "Authorization: Bearer $SB_KEY") # legacy JWT keys also go in Authorization
  source_db -tA -F $'\t' -c "select bucket_id, name, coalesce(metadata->>'mimetype', 'application/octet-stream') from storage.objects where bucket_id in ('proofs', 'bills')" |
  while IFS=$'\t' read -r bucket name type; do
    # One failed file shouldn't stop the rest; the list at the end shows what to copy by hand.
    if curl -fsS "${auth[@]}" "$SB_URL/storage/v1/object/$bucket/$name" -o /tmp/object &&
       aws s3 cp /tmp/object "s3://$UPLOADS_BUCKET/$bucket/$name" --content-type "$type" --region "$AWS_REGION" --quiet; then
      echo "copied $bucket/$name"
    else
      echo "FAILED $bucket/$name (is SUPABASE_SERVICE_ROLE_KEY the secret key, sb_secret_...?)"
    fi
  done
else
  echo "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not in the app secret; skipped."
fi

echo "== Row counts (table supabase rds)"
for t in $(target -tAc "select tablename from pg_tables where schemaname = 'public' order by 1") ; do
  echo "$t $(source_db -tAc "select count(*) from public.$t") $(target -tAc "select count(*) from public.$t")"
done
echo "auth.users $(source_db -tAc "select count(*) from auth.users") $(target -tAc "select count(*) from auth.users")"
