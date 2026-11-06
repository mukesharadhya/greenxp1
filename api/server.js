import express from "express";
import cors from "cors";
import crypto from "crypto";
import { readFileSync } from "fs";
import pg from "pg";
import { CognitoJwtVerifier } from "aws-jwt-verify";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { createPresignedPost } from "@aws-sdk/s3-presigned-post";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import Anthropic from "@anthropic-ai/sdk";
import { createMailer, templates } from "./email.js";

// On AWS, secrets (Anthropic, Resend) come from Secrets Manager (APP_SECRET_ARN) and everything else from
// /etc/greenxp.env. Locally, put them all in the environment and set DATABASE_URL.
const sm = new SecretsManagerClient({});
const secretJson = async (id) => JSON.parse((await sm.send(new GetSecretValueCommand({ SecretId: id }))).SecretString);
const env = { ...process.env, ...(process.env.APP_SECRET_ARN ? await secretJson(process.env.APP_SECRET_ARN) : {}) };

const REQUIRED = ["COGNITO_USER_POOL_ID", "COGNITO_CLIENT_ID", "UPLOADS_BUCKET",
  ...(env.DATABASE_URL ? [] : ["DB_HOST", "DB_NAME", "DB_SECRET_ARN"])];
const missing = REQUIRED.filter((k) => !env[k]);
if (missing.length) { console.error("Missing settings: " + missing.join(", ")); process.exit(1); }

const { FRONTEND_URL, UPLOADS_BUCKET, PORT = 3000 } = env;

// Match PostgREST's JSON: numeric and bigint as numbers, dates as "YYYY-MM-DD" strings.
pg.types.setTypeParser(pg.types.builtins.NUMERIC, parseFloat);
pg.types.setTypeParser(pg.types.builtins.INT8, (v) => parseInt(v, 10));
pg.types.setTypeParser(pg.types.builtins.DATE, (v) => v);
const dbUser = env.DATABASE_URL ? null : await secretJson(env.DB_SECRET_ARN);
const pool = new pg.Pool(env.DATABASE_URL ? { connectionString: env.DATABASE_URL } : {
  host: env.DB_HOST, port: +(env.DB_PORT || 5432), database: env.DB_NAME, user: dbUser.username,
  // RDS rotates the password; each new connection reads the current one.
  password: async () => (await secretJson(env.DB_SECRET_ARN)).password,
  ssl: { ca: readFileSync(env.DB_CA_FILE || "/opt/greenxp/rds-ca.pem", "utf8") },
  max: 10, idleTimeoutMillis: 300000,
});
pool.on("error", (e) => console.error("database pool:", e.message));

const q = async (sql, params) => (await pool.query(sql, params)).rows;
const one = async (sql, params) => (await q(sql, params))[0] ?? null;
// Runs fn in one transaction. With uid, it runs as that signed-in user: the database's row-level security
// policies and auth.uid() apply, exactly as they did for the browser's own queries on Supabase.
async function tx(fn, uid) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    if (uid) {
      await c.query("set local role authenticated");
      await c.query("select set_config('request.jwt.claim.sub', $1, true)", [uid]);
    }
    const r = await fn(async (sql, params) => (await c.query(sql, params)).rows);
    await c.query("commit");
    return r;
  } catch (e) {
    await c.query("rollback").catch(() => {});
    throw e;
  } finally { c.release(); }
}
const asUser = (uid, fn) => tx(fn, uid);
// Database errors the user can act on (bad input, a rule in a function); anything else is a real failure.
const userError = (e) => {
  if (/^(22|23|P0)/.test(e.code || "")) return e.message;
  throw e;
};

const s3 = new S3Client({});
const verifier = CognitoJwtVerifier.create({ userPoolId: env.COGNITO_USER_POOL_ID, tokenUse: "id", clientId: env.COGNITO_CLIENT_ID });
// Optional: reading utility bills needs ANTHROPIC_API_KEY. Without it, students type the values themselves.
const anthropic = env.ANTHROPIC_API_KEY ? new Anthropic({ apiKey: env.ANTHROPIC_API_KEY }) : null;
// Optional: emails to students need RESEND_API_KEY. Without it, the app works the same but sends none.
const mailer = createMailer({ apiKey: env.RESEND_API_KEY, from: env.EMAIL_FROM || "GreenXP <noreply@greenxp.in>" });
const mail = templates(FRONTEND_URL || "https://greenxp.in");
const app = express();
if (FRONTEND_URL) app.use(cors({ origin: FRONTEND_URL }));
const isId = (s) => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
// Every async handler and middleware goes through wrap: in Express 4 an uncaught rejection would kill the process.
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch((e) => {
  console.error(e);
  if (!res.headersSent) res.status(500).json({ error: "Something went wrong. Please try again." });
});
const currentYear = (college) =>
  one("select id, start_date, end_date from public.academic_years where college_id = $1 and is_current limit 1", [college]);

// Uploaded files live in one bucket as <bucket>/<user id>/<random>.<ext>; the database stores the part after <bucket>/.
async function readUpload(bucket, path) {
  try {
    const o = await s3.send(new GetObjectCommand({ Bucket: UPLOADS_BUCKET, Key: `${bucket}/${path}` }));
    return Buffer.from(await o.Body.transformToByteArray());
  } catch (e) {
    if (e.name === "NoSuchKey") return null;
    throw e;
  }
}

app.use(express.json({ limit: "1mb" })); // room for bulk institution imports
app.get(["/health", "/api/health"], (_, res) => res.json({ ok: true }));
app.param("id", (req, res, next, id) => isId(id) ? next() : res.status(404).json({ error: "Not found" }));

// 0. Public: the sign-up page's institution list and counters, and certificate checks.
app.get("/api/public/colleges", wrap(async (req, res) => {
  res.json(await q("select id, name, city, state, pincode from public.colleges where active order by name"));
}));
app.get("/api/public/stats", wrap(async (req, res) => {
  res.json((await one("select public.public_stats() s")).s);
}));
app.get("/api/public/certificates/:code", wrap(async (req, res) => {
  res.json(await one("select * from public.verify_certificate($1)", [String(req.params.code).slice(0, 64)]));
}));

// Cognito proves who the user is; auth.users maps their Cognito account to their GreenXP id.
async function userFor(claims) {
  const u = await one("select id, email from auth.users where cognito_sub = $1", [claims.sub]);
  if (u) return u;
  // Accounts moved from Supabase are not linked to Cognito yet: the first sign-in with the same verified email claims it.
  if (claims.email_verified === true || claims.email_verified === "true") {
    const moved = await one("update auth.users set cognito_sub = $1 where cognito_sub is null and lower(email) = lower($2) returning id, email",
      [claims.sub, claims.email]);
    if (moved) return moved;
  }
  // First sign-in after signing up: add the account. The on_auth_user_created trigger then creates the profile.
  return one(`insert into auth.users (id, cognito_sub, email, raw_user_meta_data) values ($1, $2, $3, $4)
    on conflict (cognito_sub) do update set email = excluded.email returning id, email`,
    [claims.sub, claims.sub, claims.email, { full_name: claims.name || "", college_id: claims["custom:college_id"] || "" }]);
}
const auth = wrap(async (req, res, next) => {
  let claims;
  try { claims = await verifier.verify((req.headers.authorization || "").replace("Bearer ", "")); }
  catch { return res.status(401).json({ error: "Please sign in" }); }
  req.user = await userFor(claims);
  req.profile = await one("select * from public.profiles where id = $1", [req.user.id]);
  if (!req.profile) return res.status(403).json({ error: "Your profile is not set up yet" });
  next();
});
const admin = (req, res, next) =>
  ["admin", "super_admin"].includes(req.profile.role) ? next() : res.status(403).json({ error: "Admins only" });
// Students can pay and take part only after a college admin approves their account.
const approved = (req, res, next) =>
  req.profile.role !== "student" || req.profile.approval_status === "approved" ? next()
    : res.status(403).json({ error: "Your account is waiting for approval from your college admin" });

// 1. The signed-in student's own data. These run as the user, so row-level security applies.
app.get("/api/me", auth, wrap(async (req, res) => {
  const p = req.profile, y = p.college_id ? await currentYear(p.college_id) : null;
  const [survey, member] = await Promise.all([
    one("select * from public.lifestyle_surveys where user_id = $1", [p.id]),
    y ? one("select 1 from public.memberships where user_id = $1 and academic_year_id = $2 and status in ('active', 'waived') limit 1", [p.id, y.id]) : null,
  ]);
  res.json({ profile: p, survey, year: y, member: !!member });
}));

app.post("/api/me/profile", auth, wrap(async (req, res) => {
  const { usn, department, year, phone } = req.body;
  try {
    await asUser(req.profile.id, async (sql) => {
      await sql("update public.profiles set usn = $1, department = $2, year = $3, phone = $4 where id = auth.uid()",
        [String(usn || "").trim(), String(department || ""), Number(year) || null, String(phone || "")]);
      if (req.profile.approval_status === "rejected") await sql("select public.request_reapproval()");
    });
  } catch (e) {
    return res.status(400).json({ error: e.code === "23505" ? "That USN is already registered. Check it, or contact your college admin." : userError(e) });
  }
  res.json({ ok: true });
}));

app.put("/api/me/survey", auth, wrap(async (req, res) => {
  const { answers, footprint, total_kg } = req.body;
  try {
    const [row] = await asUser(req.profile.id, (sql) => sql(`insert into public.lifestyle_surveys (user_id, answers, footprint, total_kg, updated_at)
      values (auth.uid(), $1, $2, $3, now()) on conflict (user_id) do update
      set answers = excluded.answers, footprint = excluded.footprint, total_kg = excluded.total_kg, updated_at = now() returning *`,
      [answers, footprint, total_kg]));
    res.json(row);
  } catch (e) { res.status(400).json({ error: userError(e) }); }
}));

app.get("/api/me/xp", auth, wrap(async (req, res) => {
  const [s] = await asUser(req.profile.id, (sql) => sql("select * from public.my_xp_summary()"));
  res.json(s || { earned: 0, spendable: 0, year_earned: 0 });
}));

app.get("/api/me/certificates", auth, wrap(async (req, res) => {
  res.json(await asUser(req.profile.id, (sql) => sql("select * from public.certificates where user_id = auth.uid()")));
}));

// Active activities of the student's college, optionally only some categories (?categories=Energy,Food).
app.get("/api/activities", auth, wrap(async (req, res) => {
  const cats = req.query.categories ? String(req.query.categories).split(",") : null;
  res.json(await asUser(req.profile.id, (sql) =>
    sql("select * from public.activities where active and ($1::text[] is null or category = any($1)) order by category", [cats])));
}));

app.get("/api/fee", auth, wrap(async (req, res) => {
  const y = req.profile.college_id && await currentYear(req.profile.college_id);
  res.json(y ? await one("select amount, currency from public.fee_settings where college_id = $1 and academic_year_id = $2 and active",
    [req.profile.college_id, y.id]) : null);
}));

app.get("/api/leaderboard", auth, wrap(async (req, res) => {
  res.json(await asUser(req.profile.id, (sql) => sql("select * from public.get_leaderboard('all', 50)")));
}));

// Footprint logs: the last year of entries; students add and delete their own.
app.get("/api/footprint-logs", auth, wrap(async (req, res) => {
  res.json(await asUser(req.profile.id, (sql) => sql(`select * from public.footprint_logs where user_id = auth.uid()
    and period_end >= current_date - 364 order by period_start desc`)));
}));
app.post("/api/footprint-logs", auth, wrap(async (req, res) => {
  const { category, period_start, period_end, details, kg_co2e, bill_path } = req.body;
  try {
    await asUser(req.profile.id, (sql) => sql(`insert into public.footprint_logs (user_id, category, period_start, period_end, details, kg_co2e, bill_path)
      values (auth.uid(), $1, $2, $3, $4, $5, $6)`, [category, period_start, period_end, details, kg_co2e, bill_path || null]));
  } catch (e) { return res.status(400).json({ error: userError(e) }); }
  res.json({ ok: true });
}));
app.delete("/api/footprint-logs/:id", auth, wrap(async (req, res) => {
  await asUser(req.profile.id, (sql) => sql("delete from public.footprint_logs where id = $1", [req.params.id]));
  res.json({ ok: true });
}));

// Uploads go straight from the browser to S3 with a short-lived form the API signs. The API picks the file name
// (inside the student's own folder), and S3 enforces the type and the 10 MB limit.
const UPLOAD_TYPES = {
  proofs: { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "image/heif": "heif" },
  bills: { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "application/pdf": "pdf" },
  payments: { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp", "image/avif": "avif",
    "image/heic": "heic", "image/heif": "heif", "application/pdf": "pdf" },
};
app.post("/api/uploads", auth, approved, wrap(async (req, res) => {
  const { bucket, contentType } = req.body, ext = UPLOAD_TYPES[bucket]?.[contentType];
  if (!ext) return res.status(400).json({ error: bucket === "bills" ? "Please upload a JPG, PNG, WebP or PDF." :
    bucket === "payments" ? "Please upload an image (JPG, PNG, HEIC…) or a PDF." : "Please choose a JPG, PNG, WebP or HEIC photo." });
  const path = `${req.profile.id}/${crypto.randomUUID()}.${ext}`;
  const form = await createPresignedPost(s3, { Bucket: UPLOADS_BUCKET, Key: `${bucket}/${path}`, Expires: 300,
    Fields: { "Content-Type": contentType }, Conditions: [["content-length-range", 1, 10 * 1024 * 1024]] });
  res.json({ path, url: form.url, fields: form.fields });
}));

// 2. Payments: students pay the fee by UPI and send the transaction ID or a screenshot. Neither proves the money arrived,
// so membership starts only when the super admin, who can see the bank account, confirms it (/api/super/payments).
app.get("/api/payments/upi", auth, wrap(async (req, res) => {
  const y = req.profile.college_id && await currentYear(req.profile.college_id);
  res.json(y ? await one(`select status, upi_ref, review_note from public.payments where user_id = $1 and academic_year_id = $2
    and status in ('submitted', 'failed') order by created_at desc limit 1`, [req.profile.id, y.id]) : null);
}));

app.post("/api/payments/upi", auth, approved, wrap(async (req, res) => {
  const p = req.profile, y = p.college_id && await currentYear(p.college_id);
  if (!y) return res.status(400).json({ error: "No current academic year" });
  const m = await one("select status from public.memberships where user_id = $1 and academic_year_id = $2", [p.id, y.id]);
  if (m && ["active", "waived"].includes(m.status)) return res.status(400).json({ error: "You are already a member" });
  // The amount comes from the database, never from the browser.
  const fee = await one("select amount, currency from public.fee_settings where college_id = $1 and academic_year_id = $2 and active", [p.college_id, y.id]);
  if (!fee || !(fee.amount > 0)) return res.status(400).json({ error: "The fee for this year has not been set yet" });

  const ref = String(req.body.transactionId ?? "").replace(/\s/g, "").toUpperCase() || null, { proofPath } = req.body;
  if (!ref && !proofPath) return res.status(400).json({ error: "Enter the transaction ID or upload a screenshot" });
  if (ref && !/^[A-Z0-9]{8,35}$/.test(ref)) return res.status(400).json({ error: "That doesn't look like a transaction ID. It is usually 12 digits; check your UPI app." });
  if (proofPath) {
    if (typeof proofPath !== "string" || !proofPath.startsWith(p.id + "/") || proofPath.includes("..")) return res.status(400).json({ error: "Invalid screenshot" });
    if (!await readUpload("payments", proofPath)) return res.status(400).json({ error: "Screenshot upload not found. Please try again." });
  }
  try {
    await q(`insert into public.payments (user_id, academic_year_id, amount, currency, status, upi_ref, proof_path)
      values ($1, $2, $3, $4, 'submitted', $5, $6)`, [p.id, y.id, fee.amount, fee.currency, ref, proofPath || null]);
  } catch (e) {
    if (e.constraint === "payments_upi_ref_key") return res.status(400).json({ error: "That transaction ID has already been used" });
    if (e.constraint === "payments_one_submitted_key") return res.status(400).json({ error: "Your payment is already waiting to be checked" });
    return res.status(400).json({ error: userError(e) });
  }
  res.json({ ok: true });
}));

// 3. Submissions: membership, limits and event-code checks run in one locked database transaction (submit_activity),
// so parallel requests cannot get past the frequency limit.
app.post("/api/submissions", auth, approved, wrap(async (req, res) => {
  const p = req.profile, { activityId, proofPath, eventCode } = req.body;
  // Extra questions some activities ask (e.g. walk or cycle, and distance): every answer is required and checked here.
  const act = isId(activityId) ? await one("select inputs from public.activities where id = $1", [activityId]) : null;
  const details = {};
  for (const q of act?.inputs || []) {
    const v = req.body.details?.[q.key];
    if (q.type === "choice") {
      if (!q.options.includes(v)) return res.status(400).json({ error: `Please answer: ${q.label}` });
      details[q.key] = v;
    } else if (q.type === "number") {
      const n = Number(v);
      if (!Number.isFinite(n) || n < (q.min ?? 0) || n > (q.max ?? 1e6))
        return res.status(400).json({ error: `${q.label}: enter a number between ${q.min ?? 0} and ${q.max ?? 1e6}` });
      details[q.key] = Math.round(n * 100) / 100;
    }
  }
  let proofHash = null;
  if (proofPath) {
    // Students may only attach photos from their own folder; the hash is computed here because the browser's can't be trusted.
    if (typeof proofPath !== "string" || !proofPath.startsWith(p.id + "/") || proofPath.includes(".."))
      return res.status(400).json({ error: "Invalid photo" });
    const file = await readUpload("proofs", proofPath);
    if (!file) return res.status(400).json({ error: "Photo upload not found. Please try again." });
    proofHash = crypto.createHash("sha256").update(file).digest("hex");
  }
  let data;
  try {
    data = (await one("select public.submit_activity($1, $2, $3, $4, $5) r", [p.id, isId(activityId) ? activityId : null, proofPath || null,
      proofHash, eventCode == null ? null : String(eventCode)])).r;
  } catch (e) { return res.status(400).json({ error: userError(e) }); }
  if (Object.keys(details).length && data?.id) await q("update public.activity_submissions set details = $1 where id = $2", [details, data.id]);
  res.json(data);
}));

// 4. Rewards
app.post("/api/rewards/:id/redeem", auth, approved, wrap(async (req, res) => {
  try { await q("select public.redeem_reward($1, $2)", [req.user.id, req.params.id]); }
  catch (e) { return res.status(400).json({ error: userError(e) }); }
  res.json({ ok: true });
}));

// 5. Admin dashboard
// The super admin reviews new users of every college (a new college may have no admin yet); others only their own.
const reviewScope = (p) => p.role === "super_admin" ? null : p.college_id;

app.get("/api/admin/stats", auth, admin, wrap(async (req, res) => {
  res.json(await one(`select
    (select count(*) from public.profiles where ($2::uuid is null or college_id = $2) and role = 'student' and approval_status = 'pending') "usersPending",
    (select count(*) from public.payments where status = 'submitted') "paymentsPending",
    count(*) filter (where s.verification_status = 'pending') pending,
    count(*) filter (where s.verification_status = 'verified' and s.verified_by is not null and s.verified_at >= now() - interval '7 days') "approvedWeek",
    count(*) filter (where s.verification_status = 'rejected' and s.verified_at >= now() - interval '7 days') "rejectedWeek",
    (select count(*) from public.memberships m join public.profiles mp on mp.id = m.user_id where mp.college_id = $1 and m.status in ('active', 'waived')) members,
    (select count(*) from public.profiles where college_id = $1 and role = 'student') students
    from public.activity_submissions s join public.profiles st on st.id = s.user_id where st.college_id = $1`, [req.profile.college_id, reviewScope(req.profile)]));
}));

app.get("/api/admin/lifestyle-summary", auth, admin, wrap(async (req, res) => {
  const [r] = await asUser(req.profile.id, (sql) => sql("select public.lifestyle_summary() s"));
  res.json(r.s);
}));

// Add an activity to the admin's college; the super admin can add it to every college at once.
// Event-code and automatic activities aren't offered: nothing in the portal can run them yet.
const ACTIVITY_CATEGORIES = ["Campus", "Community", "Energy", "Food", "Recycling", "Reuse", "Transport", "Waste", "Water"];
app.post("/api/admin/activities", auth, admin, wrap(async (req, res) => {
  const name = String(req.body.name || "").trim(), description = String(req.body.description || "").trim();
  const { category, verification, period } = req.body, xp = Number(req.body.xp), limit = Number(req.body.limit);
  if (!name || name.length > 80) return res.status(400).json({ error: "Enter the activity's name (up to 80 characters)" });
  if (!description || description.length > 500) return res.status(400).json({ error: "Say what students should do (up to 500 characters)" });
  if (!ACTIVITY_CATEGORIES.includes(category)) return res.status(400).json({ error: "Choose a category" });
  if (!["photo_admin", "self"].includes(verification)) return res.status(400).json({ error: "Choose how it is checked" });
  if (!["day", "week", "month", "total"].includes(period)) return res.status(400).json({ error: "Choose how often it can be done" });
  if (!Number.isInteger(xp) || xp < 1 || xp > 100) return res.status(400).json({ error: "XP must be a whole number from 1 to 100" });
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) return res.status(400).json({ error: "The limit must be a whole number from 1 to 50" });
  const college = req.body.allColleges && req.profile.role === "super_admin" ? null : req.profile.college_id;
  const rows = await q(`insert into public.activities (college_id, name, description, category, xp_value, frequency_limit, frequency_period, verification_type)
    select c.id, $1::text, $2::text, $3::text, $4::int, $5::int, $6::text, $7::text from public.colleges c
    where ($8::uuid is null or c.id = $8) and not exists (select 1 from public.activities a
      where a.college_id = c.id and a.active and lower(trim(a.name)) = lower($1::text)) returning id`,
    [name, description, category, xp, limit, period, verification, college]);
  if (!rows.length) return res.status(400).json({ error: "An activity with this name already exists" });
  await audit(req.user.id, "create_activity", "activity", null, { name, colleges: rows.length });
  res.json({ added: rows.length });
}));

// New users: students of the admin's college by approval status, newest first.
app.get("/api/admin/users", auth, admin, wrap(async (req, res) => {
  const status = ["pending", "approved", "rejected"].includes(req.query.status) ? req.query.status : "pending";
  res.json(await q(`select u.id, u.email, u.full_name, u.usn, u.department, u.year, u.phone, u.created_at, u.approval_status,
      u.approval_note, u.approved_at, c.name college, case when u.approved_by is not null then json_build_object('full_name', r.full_name) end approver
    from public.profiles u left join public.profiles r on r.id = u.approved_by left join public.colleges c on c.id = u.college_id
    where ($1::uuid is null or u.college_id = $1) and u.role = 'student' and u.approval_status = $2
    order by ${status === "pending" ? "u.created_at" : "u.approved_at desc"} limit 200`, [reviewScope(req.profile), status]));
}));

app.post("/api/admin/users/review", auth, admin, wrap(async (req, res) => {
  const { ids, approve, reason } = req.body, waive = !!(approve && req.body.waive);
  if (!Array.isArray(ids) || !ids.length || ids.length > 200 || !ids.every(isId))
    return res.status(400).json({ error: "Choose between 1 and 200 users" });
  const note = approve ? null : String(reason || "Not approved by your college admin").slice(0, 500);
  const done = await tx(async (sql) => {
    const rows = await sql(`update public.profiles set approval_status = $2, approval_note = $3, approved_by = $4, approved_at = now()
      where id = any($1::uuid[]) and ($5::uuid is null or college_id = $5) and role = 'student' returning id, email, full_name`,
      [ids, approve ? "approved" : "rejected", note, req.user.id, reviewScope(req.profile)]);
    if (rows.length) await sql(`insert into public.audit_logs (actor_id, action, target_type, target_id, details)
      select $1, $2, 'profile', id::text, $3 from unnest($4::uuid[]) id`,
      [req.user.id, approve ? "approve_user" : "reject_user", { reason: note, fee_waived: waive }, rows.map((u) => u.id)]);
    // "Approve + free year": this year's membership without paying, e.g. for a demo session. A paid membership stays as it is.
    if (waive && rows.length) await sql(`insert into public.memberships (user_id, academic_year_id, status, start_date, end_date, waived_by, waiver_reason)
      select p.id, y.id, 'waived', y.start_date, y.end_date, $2, 'Fee waived by admin'
      from public.profiles p join public.academic_years y on y.college_id = p.college_id and y.is_current where p.id = any($1::uuid[])
      on conflict (user_id, academic_year_id) do update set status = 'waived', start_date = excluded.start_date, end_date = excluded.end_date,
        waived_by = excluded.waived_by, waiver_reason = excluded.waiver_reason where public.memberships.status <> 'active'`,
      [rows.map((u) => u.id), req.user.id]);
    return rows;
  });
  mailer.notify(() => done.map((u) => approve ? mail.accountApproved(u, waive) : mail.accountRejected(u, note)));
  res.json({ done: done.length, failed: ids.filter((id) => !done.some((u) => u.id === id)).map((id) => ({ id, error: "Not a student of your college" })) });
}));

app.get("/api/admin/submissions", auth, admin, wrap(async (req, res) => {
  const status = ["pending", "verified", "rejected"].includes(req.query.status) ? req.query.status : "pending";
  const data = await q(`select s.id, s.user_id, s.submitted_at, s.proof_path, s.proof_hash, s.verification_status, s.rejection_reason, s.verified_at, s.details,
      json_build_object('name', a.name, 'category', a.category, 'xp_value', a.xp_value, 'verification_type', a.verification_type) activities,
      json_build_object('id', st.id, 'full_name', st.full_name, 'usn', st.usn, 'department', st.department, 'year', st.year, 'college_id', st.college_id) student,
      case when rv.id is not null then json_build_object('full_name', rv.full_name) end reviewer
    from public.activity_submissions s
    join public.activities a on a.id = s.activity_id
    join public.profiles st on st.id = s.user_id
    left join public.profiles rv on rv.id = s.verified_by
    where s.verification_status = $1 and st.college_id = $2 ${status === "verified" ? "and s.verified_by is not null" : ""}
    order by ${status === "pending" ? "s.submitted_at" : "s.verified_at desc"} limit 100`, [status, req.profile.college_id]);

  await Promise.all(data.filter((s) => s.proof_path).map(async (s) => {
    s.proof_url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: UPLOADS_BUCKET, Key: `proofs/${s.proof_path}` }), { expiresIn: 600 });
  }));
  // Warnings for the reviewer: the same photo used in other submissions, and the student's review history.
  const hashes = [...new Set(data.map((s) => s.proof_hash).filter(Boolean))];
  if (hashes.length) {
    const others = await q("select id, user_id, proof_hash from public.activity_submissions where proof_hash = any($1)", [hashes]);
    for (const s of data) {
      const dup = others.filter((o) => o.proof_hash === s.proof_hash && o.id !== s.id);
      if (dup.length) s.duplicate = { count: dup.length, otherStudent: dup.some((o) => o.user_id !== s.student.id) };
    }
  }
  const studentIds = [...new Set(data.map((s) => s.student.id))];
  if (status === "pending" && studentIds.length) {
    const past = await q("select user_id, verification_status from public.activity_submissions where user_id = any($1::uuid[]) and verified_by is not null", [studentIds]);
    for (const s of data) {
      const mine = past.filter((p) => p.user_id === s.student.id);
      s.history = { approved: mine.filter((p) => p.verification_status === "verified").length, rejected: mine.filter((p) => p.verification_status === "rejected").length };
    }
  }
  for (const s of data) { delete s.proof_hash; delete s.proof_path; delete s.user_id; }
  res.json(data);
}));

// Approve or reject one or many submissions. Admins cannot review their own.
app.post("/api/admin/submissions/review", auth, admin, wrap(async (req, res) => {
  const { ids, approve, reason } = req.body;
  if (!Array.isArray(ids) || !ids.length || ids.length > 100 || !ids.every(isId))
    return res.status(400).json({ error: "Choose between 1 and 100 submissions" });
  const own = new Set((await q("select id from public.activity_submissions where id = any($1::uuid[]) and user_id = $2", [ids, req.user.id])).map((s) => s.id));
  const result = { done: 0, failed: [] }, reviewed = [];
  for (const id of ids) {
    if (own.has(id)) { result.failed.push({ id, error: "You can't review your own submission" }); continue; }
    try {
      await q("select public.review_submission($1, $2, $3, $4)", [id, req.user.id, !!approve, approve ? null : String(reason || "Rejected by admin").slice(0, 500)]);
      result.done++;
      reviewed.push(id);
    } catch (e) { result.failed.push({ id, error: userError(e) }); }
  }
  // Only rejections are emailed, one message per student: approvals show up as XP, and would use up the daily sending limit.
  if (!approve && reviewed.length) mailer.notify(async () => {
    const rows = await q(`select p.email, p.full_name, a.name activity, s.rejection_reason reason from public.activity_submissions s
      join public.activities a on a.id = s.activity_id join public.profiles p on p.id = s.user_id where s.id = any($1::uuid[])`, [reviewed]);
    const byStudent = new Map();
    for (const r of rows) byStudent.set(r.email, [...(byStudent.get(r.email) || []), r]);
    return [...byStudent.values()].map((items) => mail.submissionsRejected(items[0], items));
  });
  res.json(result);
}));
app.post("/api/admin/certificates/issue", auth, admin, wrap(async (req, res) => {
  const { t: since } = await one("select now() t");
  let issued;
  try { issued = (await one("select public.issue_certificates($1) n", [req.user.id])).n; }
  catch (e) { return res.status(400).json({ error: userError(e) }); }
  if (issued) mailer.notify(async () => (await q(`select p.email, p.full_name, c.tier, c.xp_earned, c.certificate_code from public.certificates c
    join public.profiles p on p.id = c.user_id where p.college_id = $1 and c.issued_at >= $2`, [req.profile.college_id, since]))
    .map((c) => mail.certificateIssued(c, c)));
  res.json({ issued });
}));

// Institutions (super admin only): list, add, switch on/off, and appoint each institution's admin.
const superAdmin = (req, res, next) =>
  req.profile.role === "super_admin" ? next() : res.status(403).json({ error: "Only the platform super admin can manage institutions" });
const audit = (actor, action, targetType, targetId, details) =>
  q("insert into public.audit_logs (actor_id, action, target_type, target_id, details) values ($1, $2, $3, $4, $5)",
    [actor, action, targetType, targetId ?? null, details]);
const createInstitution = (template, r) => one("select public.create_institution($1, $2, $3, $4, $5, $6) id",
  [template, String(r.name || ""), String(r.city || ""), String(r.state || ""), String(r.pincode || ""), Number(r.fee)]);

app.get("/api/super/institutions", auth, superAdmin, wrap(async (req, res) => {
  res.json(await q(`select c.id, c.name, c.city, c.state, c.pincode, c.active, c.created_at,
      count(p.id) filter (where p.role = 'student')::int students,
      count(p.id) filter (where p.role = 'student' and p.approval_status = 'pending')::int waiting,
      coalesce(array_agg(p.email order by p.email) filter (where p.role in ('admin', 'super_admin')), '{}') admins
    from public.colleges c left join public.profiles p on p.college_id = c.id group by c.id order by c.name`));
}));

app.post("/api/super/institutions", auth, superAdmin, wrap(async (req, res) => {
  let id;
  try { ({ id } = await createInstitution(req.profile.college_id, req.body)); }
  catch (e) { return res.status(400).json({ error: userError(e) }); }
  await audit(req.user.id, "create_institution", "college", id, { name: req.body.name });
  res.json({ id });
}));

// Bulk import from a spreadsheet (already parsed and checked in the browser). Each row is created on its own,
// so one bad row doesn't stop the rest; the result says what happened to every row.
app.post("/api/super/institutions/bulk", auth, superAdmin, wrap(async (req, res) => {
  const rows = req.body.rows;
  if (!Array.isArray(rows) || !rows.length || rows.length > 500) return res.status(400).json({ error: "Upload between 1 and 500 institutions at a time" });
  const results = [];
  for (const r of rows) {
    try { results.push({ ok: true, id: (await createInstitution(req.profile.college_id, r)).id }); }
    catch (e) { results.push({ ok: false, error: userError(e) }); }
  }
  const created = results.filter((r) => r.ok).length;
  await audit(req.user.id, "bulk_import_institutions", "college", null, { submitted: rows.length, created });
  res.json({ created, results });
}));

// Edit an institution's name and location.
app.post("/api/super/institutions/:id", auth, superAdmin, wrap(async (req, res) => {
  const f = Object.fromEntries(["name", "city", "state", "pincode"].map((k) => [k, String(req.body[k] || "").trim()]));
  if (!f.name || !f.city || !f.state) return res.status(400).json({ error: "Name, city and state are required" });
  if (!/^[1-9][0-9]{5}$/.test(f.pincode)) return res.status(400).json({ error: "Pincode must be 6 digits" });
  try { await q("update public.colleges set name = $2, city = $3, state = $4, pincode = $5 where id = $1", [req.params.id, f.name, f.city, f.state, f.pincode]); }
  catch (e) { return res.status(400).json({ error: e.code === "23505" ? "An institution with this name already exists" : userError(e) }); }
  await audit(req.user.id, "edit_institution", "college", req.params.id, f);
  res.json({ ok: true });
}));

app.post("/api/super/institutions/:id/active", auth, superAdmin, wrap(async (req, res) => {
  if (req.params.id === req.profile.college_id && !req.body.active) return res.status(400).json({ error: "You can't switch off your own institution" });
  await q("update public.colleges set active = $2 where id = $1", [req.params.id, !!req.body.active]);
  res.json({ ok: true });
}));

// Delete an institution nobody has signed up at (a mistake, test or duplicate). Its setup rows are removed
// by ON DELETE CASCADE; anything with student data is refused, and switching it off is suggested instead.
app.post("/api/super/institutions/:id/delete", auth, superAdmin, wrap(async (req, res) => {
  if (req.params.id === req.profile.college_id) return res.status(400).json({ error: "You can't delete your own institution" });
  const c = await one("select id, name, (select count(*) from public.profiles where college_id = $1) accounts from public.colleges where id = $1", [req.params.id]);
  if (!c) return res.status(404).json({ error: "Institution not found" });
  if (c.accounts) return res.status(400).json({ error: `${c.name} has ${c.accounts} account${c.accounts > 1 ? "s" : ""}, so it can't be deleted. Switch it off instead to hide it from sign-up.` });
  try { await q("delete from public.colleges where id = $1", [c.id]); }
  catch (e) { return res.status(400).json({ error: e.code === "23503" ? `${c.name} still has student records, so it can't be deleted. Switch it off instead.` : userError(e) }); }
  await audit(req.user.id, "delete_institution", "college", c.id, { name: c.name });
  res.json({ ok: true });
}));

app.post("/api/super/institutions/:id/admin", auth, superAdmin, wrap(async (req, res) => {
  const email = String(req.body.email || "").trim().toLowerCase();
  const p = await one("select id, college_id, role from public.profiles where lower(email) = $1", [email]);
  if (!p) return res.status(404).json({ error: "No account with that email. Ask them to sign up first, choosing this institution." });
  if (p.college_id !== req.params.id) return res.status(400).json({ error: "That person signed up at a different institution" });
  if (p.role === "super_admin") return res.status(400).json({ error: "That person is already the super admin" });
  await q("update public.profiles set role = 'admin', approval_status = 'approved', approved_by = $2, approved_at = now() where id = $1", [p.id, req.user.id]);
  await audit(req.user.id, "make_admin", "profile", p.id, { email });
  res.json({ ok: true });
}));

// UPI payments (super admin only): the fee goes to one account, so only its owner can tell whether the money arrived.
app.get("/api/super/payments", auth, superAdmin, wrap(async (req, res) => {
  const v = req.query.status, status = v === "paid" ? "paid" : v === "rejected" ? "failed" : "submitted";
  const rows = await q(`select y.id, y.amount, y.currency, y.upi_ref, y.proof_path, y.review_note, y.created_at, y.reviewed_at, c.name college,
      json_build_object('full_name', st.full_name, 'usn', st.usn, 'email', st.email) student
    from public.payments y join public.profiles st on st.id = y.user_id left join public.colleges c on c.id = st.college_id
    where y.status = $1 and (y.upi_ref is not null or y.proof_path is not null)
    order by ${status === "submitted" ? "y.created_at" : "y.reviewed_at desc"} limit 200`, [status]);
  await Promise.all(rows.filter((r) => r.proof_path).map(async (r) => {
    r.proof_url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: UPLOADS_BUCKET, Key: `payments/${r.proof_path}` }), { expiresIn: 600 });
    r.proof_ext = r.proof_path.split(".").pop(); // PDFs and HEIC photos can't be shown as an image, so the page links to them
  }));
  for (const r of rows) delete r.proof_path;
  res.json(rows);
}));

app.post("/api/super/payments/review", auth, superAdmin, wrap(async (req, res) => {
  const { ids, reason } = req.body, approve = !!req.body.approve;
  if (!Array.isArray(ids) || !ids.length || ids.length > 100 || !ids.every(isId))
    return res.status(400).json({ error: "Choose between 1 and 100 payments" });
  const note = approve ? null : String(reason || "We couldn't find this payment in our account").slice(0, 500);
  const done = await tx(async (sql) => {
    const rows = await sql(`update public.payments set status = $2, paid_at = case when $3::boolean then now() end, review_note = $4,
      reviewed_by = $5, reviewed_at = now() where id = any($1::uuid[]) and status = 'submitted' returning id`,
      [ids, approve ? "paid" : "failed", approve, note, req.user.id]);
    const confirmed = rows.map((r) => r.id);
    if (confirmed.length) await sql(`insert into public.audit_logs (actor_id, action, target_type, target_id, details)
      select $1, $2, 'payment', id::text, $3 from unnest($4::uuid[]) id`,
      [req.user.id, approve ? "confirm_payment" : "reject_payment", { reason: note }, confirmed]);
    if (approve && confirmed.length) await sql(`insert into public.memberships (user_id, academic_year_id, status, start_date, end_date)
      select p.user_id, y.id, 'active', y.start_date, y.end_date from public.payments p join public.academic_years y on y.id = p.academic_year_id
      where p.id = any($1::uuid[])
      on conflict (user_id, academic_year_id) do update set status = 'active', start_date = excluded.start_date, end_date = excluded.end_date`, [confirmed]);
    return confirmed;
  });
  if (done.length) mailer.notify(async () => (await q(`select s.email, s.full_name, p.amount, p.currency, p.upi_ref from public.payments p
    join public.profiles s on s.id = p.user_id where p.id = any($1::uuid[])`, [done]))
    .map((r) => approve ? mail.paymentReceipt(r, r) : mail.paymentRejected(r, note)));
  res.json({ done: done.length, failed: ids.filter((id) => !done.includes(id)).map((id) => ({ id, error: "Already reviewed" })) });
}));

// 6. Utility bills: read units and the billing period from an uploaded bill; the student checks and corrects them before saving.
const num = { anyOf: [{ type: "number" }, { type: "null" }] }, date = { anyOf: [{ type: "string", format: "date" }, { type: "null" }] };
const BILL_SCHEMA = {
  type: "object",
  properties: { kwh: num, period_start: date, period_end: date, amount_inr: num },
  required: ["kwh", "period_start", "period_end", "amount_inr"],
  additionalProperties: false,
};
const BILL_PROMPT = "This is a household electricity bill, probably from India. Extract: kwh = electricity units consumed in this " +
  "billing period (not the meter readings themselves, and not the sanctioned load); period_start and period_end = the billing " +
  "period as YYYY-MM-DD (if only a reading date and the number of days are shown, work out the start date); amount_inr = the " +
  "total amount payable. Use null for anything that is not on the bill or that you cannot read clearly.";
const MEDIA = { pdf: "application/pdf", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp" };
const billReads = new Map(); // user id -> { day, n }: a simple cap on paid model calls per student per day

app.post("/api/bills/extract", auth, approved, wrap(async (req, res) => {
  if (!anthropic) return res.status(501).json({ error: "Automatic bill reading isn't switched on yet. Please type the values from your bill." });
  const { path } = req.body;
  if (typeof path !== "string" || !path.startsWith(req.profile.id + "/") || path.includes(".."))
    return res.status(400).json({ error: "Invalid file" });
  const today = new Date().toISOString().slice(0, 10), used = billReads.get(req.profile.id);
  const n = used?.day === today ? used.n : 0;
  if (n >= 10) return res.status(429).json({ error: "You've reached today's limit for reading bills. Please type the values." });
  billReads.set(req.profile.id, { day: today, n: n + 1 });

  const file = await readUpload("bills", path);
  if (!file) return res.status(400).json({ error: "Bill upload not found. Please try again." });
  const type = MEDIA[path.split(".").pop().toLowerCase()];
  if (!type) return res.status(400).json({ error: "Upload a JPG, PNG, WebP or PDF bill." });
  const data = file.toString("base64");
  const media = type === "application/pdf"
    ? { type: "document", source: { type: "base64", media_type: type, data } }
    : { type: "image", source: { type: "base64", media_type: type, data } };

  const r = await anthropic.beta.messages.create({
    model: "claude-opus-5-5",
    max_tokens: 16000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: { type: "json_schema", schema: BILL_SCHEMA } },
    messages: [{ role: "user", content: [media, { type: "text", text: BILL_PROMPT }] }],
  });
  const text = r.content.find((b) => b.type === "text")?.text;
  if (r.stop_reason !== "end_turn" || !text) return res.status(422).json({ error: "We couldn't read this bill. Please type the values." });
  res.json(JSON.parse(text));
}));

// On the server HOST is 127.0.0.1, so the API is reachable only through Caddy.
app.listen(PORT, env.HOST || "0.0.0.0", () => console.log("GreenXP API on " + PORT));
