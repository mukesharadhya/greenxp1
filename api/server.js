import express from "express";
import cors from "cors";
import crypto from "crypto";
import { createClient } from "@supabase/supabase-js";

// Refuse to start without every secret: an empty webhook secret would let anyone forge "payment captured" events.
const REQUIRED = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET", "RAZORPAY_WEBHOOK_SECRET", "FRONTEND_URL"];
const missing = REQUIRED.filter((k) => !process.env[k]);
if (missing.length) { console.error("Missing environment variables: " + missing.join(", ")); process.exit(1); }

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET,
  RAZORPAY_WEBHOOK_SECRET, FRONTEND_URL, PORT = 3000 } = process.env;
const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const app = express();
app.use(cors({ origin: FRONTEND_URL }));
const hmac = (secret, data) => crypto.createHmac("sha256", secret).update(data).digest("hex");
// Compares bytes, not string lengths, so odd input (non-ASCII, arrays) returns false instead of throwing.
const same = (a, b) => {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};
// Unwraps a Supabase result and throws on error, so failed writes are never silently ignored.
const must = ({ data, error }) => { if (error) throw error; return data; };
// Every async handler and middleware goes through wrap: in Express 4 an uncaught rejection would kill the process.
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch((e) => {
  console.error(e);
  if (!res.headersSent) res.status(500).json({ error: "Something went wrong. Please try again." });
});
const currentYear = async (college) =>
  must(await db.from("academic_years").select("id,start_date,end_date").eq("college_id", college).eq("is_current", true).maybeSingle());

// Marks a payment paid and activates membership. Safe to call twice (webhook + browser verify).
async function markPaid(orderId, paymentId) {
  const pay = must(await db.from("payments").update({ status: "paid", gateway_payment_id: paymentId, paid_at: new Date().toISOString() })
    .eq("gateway_order_id", orderId).eq("status", "created").select().maybeSingle());
  if (!pay) return false;
  const y = must(await db.from("academic_years").select("start_date,end_date").eq("id", pay.academic_year_id).single());
  must(await db.from("memberships").upsert({ user_id: pay.user_id, academic_year_id: pay.academic_year_id, status: "active",
    start_date: y.start_date, end_date: y.end_date }, { onConflict: "user_id,academic_year_id" }));
  return true;
}

// Razorpay webhook (needs the raw body, so it is registered before express.json)
app.post("/api/payments/webhook", express.raw({ type: "application/json" }), wrap(async (req, res) => {
  if (!same(hmac(RAZORPAY_WEBHOOK_SECRET, req.body), req.headers["x-razorpay-signature"])) return res.status(400).end();
  const ev = JSON.parse(req.body.toString());
  const p = ev.payload?.payment?.entity;
  if ((ev.event === "payment.captured" || ev.event === "order.paid") && p) await markPaid(p.order_id, p.id);
  res.json({ ok: true });
}));

app.use(express.json());
app.get("/health", (_, res) => res.json({ ok: true }));

const auth = wrap(async (req, res, next) => {
  const token = (req.headers.authorization || "").replace("Bearer ", "");
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) return res.status(401).json({ error: "Please sign in" });
  req.user = data.user;
  req.profile = must(await db.from("profiles").select("*").eq("id", data.user.id).maybeSingle());
  if (!req.profile) return res.status(403).json({ error: "Your profile is not set up yet" });
  next();
});
const admin = (req, res, next) =>
  ["admin", "super_admin"].includes(req.profile.role) ? next() : res.status(403).json({ error: "Admins only" });

// 1. Payments: the fee comes from the database, never from the browser
app.post("/api/payments/create-order", auth, wrap(async (req, res) => {
  const p = req.profile, y = await currentYear(p.college_id);
  if (!y) return res.status(400).json({ error: "No current academic year" });
  const m = must(await db.from("memberships").select("status").eq("user_id", p.id).eq("academic_year_id", y.id).maybeSingle());
  if (m && ["active", "waived"].includes(m.status)) return res.status(400).json({ error: "You are already a member" });
  const fee = must(await db.from("fee_settings").select("amount,currency").eq("college_id", p.college_id).eq("academic_year_id", y.id).eq("active", true).maybeSingle());
  if (!fee) return res.status(400).json({ error: "The fee for this year has not been set yet" });
  const paise = Math.round(fee.amount * 100);

  // Reuse an unpaid order for the same fee, so pressing Pay twice cannot lead to paying twice.
  const open = must(await db.from("payments").select("gateway_order_id,amount,currency").eq("user_id", p.id).eq("academic_year_id", y.id)
    .eq("status", "created").order("created_at", { ascending: false }).limit(1).maybeSingle());
  if (open && Math.round(open.amount * 100) === paise && open.currency === fee.currency)
    return res.json({ orderId: open.gateway_order_id, amount: paise, currency: fee.currency, keyId: RAZORPAY_KEY_ID });

  const r = await fetch("https://api.razorpay.com/v1/orders", { method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Basic " + Buffer.from(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`).toString("base64") },
    body: JSON.stringify({ amount: paise, currency: fee.currency, receipt: "gxp_" + Date.now() }) });
  const o = await r.json();
  if (!r.ok) return res.status(502).json({ error: "Payment provider error" });
  // If this insert fails we throw before the browser gets the order, so nobody can pay for an order we did not record.
  must(await db.from("payments").insert({ user_id: p.id, academic_year_id: y.id, amount: fee.amount, currency: fee.currency, gateway_order_id: o.id }));
  must(await db.from("memberships").upsert({ user_id: p.id, academic_year_id: y.id, status: "pending_payment" }, { onConflict: "user_id,academic_year_id", ignoreDuplicates: true }));
  res.json({ orderId: o.id, amount: o.amount, currency: o.currency, keyId: RAZORPAY_KEY_ID });
}));

app.post("/api/payments/verify", auth, wrap(async (req, res) => {
  const { razorpay_order_id: o, razorpay_payment_id: p, razorpay_signature: s } = req.body;
  if (!same(hmac(RAZORPAY_KEY_SECRET, `${o}|${p}`), s)) return res.status(400).json({ error: "Invalid payment signature" });
  await markPaid(o, p);
  res.json({ ok: true });
}));

// 2. Submissions: membership, limits and event-code checks run in one locked database transaction (submit_activity),
// so parallel requests cannot get past the frequency limit.
app.post("/api/submissions", auth, wrap(async (req, res) => {
  const p = req.profile, { activityId, proofPath, eventCode } = req.body;
  let proofHash = null;
  if (proofPath) {
    // Students may only attach photos from their own folder; the hash is computed here because the browser's can't be trusted.
    if (typeof proofPath !== "string" || !proofPath.startsWith(p.id + "/") || proofPath.includes(".."))
      return res.status(400).json({ error: "Invalid photo" });
    const { data: file, error } = await db.storage.from("proofs").download(proofPath);
    if (error) return res.status(400).json({ error: "Photo upload not found. Please try again." });
    proofHash = crypto.createHash("sha256").update(Buffer.from(await file.arrayBuffer())).digest("hex");
  }
  const { data, error } = await db.rpc("submit_activity", { p_user: p.id, p_activity: activityId, p_proof_path: proofPath || null,
    p_proof_hash: proofHash, p_event_code: eventCode == null ? null : String(eventCode) });
  if (error) return res.status(400).json({ error: error.message });
  res.json(data);
}));

// 3. Rewards
app.post("/api/rewards/:id/redeem", auth, wrap(async (req, res) => {
  const { error } = await db.rpc("redeem_reward", { p_user: req.user.id, p_reward: req.params.id });
  if (error) return res.status(400).json({ error: error.message });
  res.json({ ok: true });
}));

// 4. Admin
app.get("/api/admin/submissions", auth, admin, wrap(async (req, res) => {
  const data = must(await db.from("activity_submissions").select("id,submitted_at,proof_path,activities(name,xp_value),profiles!inner(full_name,usn,college_id)")
    .eq("verification_status", "pending").eq("profiles.college_id", req.profile.college_id).order("submitted_at").limit(100)) || [];
  const paths = data.filter((s) => s.proof_path).map((s) => s.proof_path);
  if (paths.length) {
    const urls = new Map(must(await db.storage.from("proofs").createSignedUrls(paths, 600)).map((u) => [u.path, u.signedUrl]));
    for (const s of data) if (s.proof_path) s.proof_url = urls.get(s.proof_path);
  }
  res.json(data);
}));
app.post("/api/admin/submissions/:id/review", auth, admin, wrap(async (req, res) => {
  const { error } = await db.rpc("review_submission", { p_id: req.params.id, p_admin: req.user.id, p_approve: !!req.body.approve, p_reason: req.body.reason || null });
  if (error) return res.status(400).json({ error: error.message });
  res.json({ ok: true });
}));
app.post("/api/admin/certificates/issue", auth, admin, wrap(async (req, res) => {
  const { data, error } = await db.rpc("issue_certificates", { p_admin: req.user.id });
  if (error) return res.status(400).json({ error: error.message });
  res.json({ issued: data });
}));

app.listen(PORT, () => console.log("GreenXP API on " + PORT));
