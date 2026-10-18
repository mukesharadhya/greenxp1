import express from "express";
import cors from "cors";
import crypto from "crypto";
import { createClient } from "@supabase/supabase-js";

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET,
  RAZORPAY_WEBHOOK_SECRET, FRONTEND_URL, PORT = 3000 } = process.env;
const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const app = express();
app.use(cors({ origin: FRONTEND_URL || false }));
const hmac = (secret, data) => crypto.createHmac("sha256", secret).update(data).digest("hex");
const same = (a, b) => a && b && a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
const currentYear = async (college) =>
  (await db.from("academic_years").select("id,start_date,end_date").eq("college_id", college).eq("is_current", true).maybeSingle()).data;

// Marks a payment paid and activates membership. Safe to call twice (webhook + browser verify).
async function markPaid(orderId, paymentId) {
  const { data: pay } = await db.from("payments").update({ status: "paid", gateway_payment_id: paymentId, paid_at: new Date().toISOString() })
    .eq("gateway_order_id", orderId).eq("status", "created").select().maybeSingle();
  if (!pay) return false;
  const { data: y } = await db.from("academic_years").select("start_date,end_date").eq("id", pay.academic_year_id).single();
  await db.from("memberships").upsert({ user_id: pay.user_id, academic_year_id: pay.academic_year_id, status: "active",
    start_date: y.start_date, end_date: y.end_date }, { onConflict: "user_id,academic_year_id" });
  return true;
}

// Razorpay webhook (needs the raw body, so it is registered before express.json)
app.post("/api/payments/webhook", express.raw({ type: "application/json" }), async (req, res) => {
  if (!same(hmac(RAZORPAY_WEBHOOK_SECRET || "", req.body), req.headers["x-razorpay-signature"])) return res.status(400).end();
  const ev = JSON.parse(req.body.toString());
  if (ev.event === "payment.captured" || ev.event === "order.paid") {
    const p = ev.payload.payment.entity; await markPaid(p.order_id, p.id);
  }
  res.json({ ok: true });
});

app.use(express.json());
app.get("/health", (_, res) => res.json({ ok: true }));

const auth = async (req, res, next) => {
  const token = (req.headers.authorization || "").replace("Bearer ", "");
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) return res.status(401).json({ error: "Please sign in" });
  req.user = data.user;
  req.profile = (await db.from("profiles").select("*").eq("id", data.user.id).single()).data;
  next();
};
const admin = (req, res, next) =>
  ["admin", "super_admin"].includes(req.profile?.role) ? next() : res.status(403).json({ error: "Admins only" });
const wrap = (fn) => (req, res) => fn(req, res).catch((e) => { console.error(e); res.status(500).json({ error: e.message }); });

// 1. Payments: the fee comes from the database, never from the browser
app.post("/api/payments/create-order", auth, wrap(async (req, res) => {
  const p = req.profile, y = await currentYear(p.college_id);
  if (!y) return res.status(400).json({ error: "No current academic year" });
  const { data: m } = await db.from("memberships").select("status").eq("user_id", p.id).eq("academic_year_id", y.id).maybeSingle();
  if (m && ["active", "waived"].includes(m.status)) return res.status(400).json({ error: "You are already a member" });
  const { data: fee } = await db.from("fee_settings").select("amount,currency").eq("college_id", p.college_id).eq("academic_year_id", y.id).eq("active", true).single();
  const r = await fetch("https://api.razorpay.com/v1/orders", { method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Basic " + Buffer.from(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`).toString("base64") },
    body: JSON.stringify({ amount: Math.round(fee.amount * 100), currency: fee.currency, receipt: "gxp_" + Date.now() }) });
  const o = await r.json();
  if (!r.ok) return res.status(502).json({ error: "Payment provider error" });
  await db.from("payments").insert({ user_id: p.id, academic_year_id: y.id, amount: fee.amount, currency: fee.currency, gateway_order_id: o.id });
  await db.from("memberships").upsert({ user_id: p.id, academic_year_id: y.id, status: "pending_payment" }, { onConflict: "user_id,academic_year_id", ignoreDuplicates: true });
  res.json({ orderId: o.id, amount: o.amount, currency: o.currency, keyId: RAZORPAY_KEY_ID });
}));

app.post("/api/payments/verify", auth, wrap(async (req, res) => {
  const { razorpay_order_id: o, razorpay_payment_id: p, razorpay_signature: s } = req.body;
  if (!same(hmac(RAZORPAY_KEY_SECRET, `${o}|${p}`), s)) return res.status(400).json({ error: "Invalid payment signature" });
  await markPaid(o, p);
  res.json({ ok: true });
}));

// 2. Submissions: membership, limits, proof and event-code checks all happen here
app.post("/api/submissions", auth, wrap(async (req, res) => {
  const p = req.profile, { activityId, proofPath, proofHash, eventCode } = req.body;
  if (p.account_status === "suspended") return res.status(403).json({ error: "Account suspended" });
  const y = await currentYear(p.college_id);
  const { data: m } = await db.from("memberships").select("status").eq("user_id", p.id).eq("academic_year_id", y.id).maybeSingle();
  if (!m || !["active", "waived"].includes(m.status)) return res.status(402).json({ error: "Activate your membership first" });
  const { data: a } = await db.from("activities").select("*").eq("id", activityId).eq("college_id", p.college_id).eq("active", true).maybeSingle();
  if (!a) return res.status(404).json({ error: "Activity not found" });
  const days = { day: 1, week: 7, month: 30 }[a.frequency_period];
  let q = db.from("activity_submissions").select("id", { count: "exact", head: true }).eq("user_id", p.id).eq("activity_id", a.id).neq("verification_status", "rejected");
  if (days) q = q.gte("submitted_at", new Date(Date.now() - days * 864e5).toISOString());
  const { count } = await q;
  if (count >= a.frequency_limit) return res.status(429).json({ error: `Limit reached: ${a.frequency_limit} per ${a.frequency_period}` });
  let tokenId = null;
  if (a.verification_type === "qr_event") {
    const { data: t } = await db.from("event_tokens").select("id").eq("activity_id", a.id).eq("secret", String(eventCode || ""))
      .lte("valid_from", new Date().toISOString()).gte("valid_to", new Date().toISOString()).maybeSingle();
    if (!t) return res.status(400).json({ error: "That event code is not valid right now" });
    tokenId = t.id;
  }
  if (["photo", "photo_admin"].includes(a.verification_type) && !proofPath) return res.status(400).json({ error: "A photo is required" });
  if (proofHash) {
    const { count: dup } = await db.from("activity_submissions").select("id", { count: "exact", head: true }).eq("proof_hash", proofHash);
    if (dup > 0) await db.from("flags").insert({ user_id: p.id, reason: "Duplicate proof photo for " + a.name });
  }
  const auto = a.verification_type === "self";
  const { data: s } = await db.from("activity_submissions").insert({ user_id: p.id, activity_id: a.id, proof_path: proofPath || null,
    proof_hash: proofHash || null, event_token_id: tokenId, verification_status: auto ? "verified" : "pending",
    verified_at: auto ? new Date().toISOString() : null }).select().single();
  if (auto) await db.from("xp_transactions").insert({ user_id: p.id, academic_year_id: y.id, amount: a.xp_value, source: "activity", reference_id: s.id });
  res.json({ status: s.verification_status, xp: auto ? a.xp_value : 0 });
}));

// 3. Rewards
app.post("/api/rewards/:id/redeem", auth, wrap(async (req, res) => {
  const { error } = await db.rpc("redeem_reward", { p_user: req.user.id, p_reward: req.params.id });
  if (error) return res.status(400).json({ error: error.message });
  res.json({ ok: true });
}));

// 4. Admin
app.get("/api/admin/submissions", auth, admin, wrap(async (req, res) => {
  const { data } = await db.from("activity_submissions").select("id,submitted_at,proof_path,activities(name,xp_value),profiles!inner(full_name,usn,college_id)")
    .eq("verification_status", "pending").eq("profiles.college_id", req.profile.college_id).order("submitted_at").limit(100);
  for (const s of data || []) if (s.proof_path) s.proof_url = (await db.storage.from("proofs").createSignedUrl(s.proof_path, 600)).data?.signedUrl;
  res.json(data || []);
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
