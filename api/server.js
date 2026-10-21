import express from "express";
import cors from "cors";
import crypto from "crypto";
import { createClient } from "@supabase/supabase-js";
import Anthropic from "@anthropic-ai/sdk";

// Refuse to start without every secret: an empty webhook secret would let anyone forge "payment captured" events.
const REQUIRED = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET", "RAZORPAY_WEBHOOK_SECRET", "FRONTEND_URL"];
const missing = REQUIRED.filter((k) => !process.env[k]);
if (missing.length) { console.error("Missing environment variables: " + missing.join(", ")); process.exit(1); }

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET,
  RAZORPAY_WEBHOOK_SECRET, FRONTEND_URL, PORT = 3000 } = process.env;
const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
// Optional: reading utility bills needs ANTHROPIC_API_KEY. Without it, students type the values themselves.
const anthropic = process.env.ANTHROPIC_API_KEY ? new Anthropic() : null;
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

app.use(express.json({ limit: "1mb" })); // room for bulk institution imports
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
// Students can pay and take part only after a college admin approves their account.
const approved = (req, res, next) =>
  req.profile.role !== "student" || req.profile.approval_status === "approved" ? next()
    : res.status(403).json({ error: "Your account is waiting for approval from your college admin" });

// 1. Payments: the fee comes from the database, never from the browser
app.post("/api/payments/create-order", auth, approved, wrap(async (req, res) => {
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

// Which payment methods the Razorpay account has switched on, so the pay screen only offers ones that work.
// Uses Razorpay's public methods lookup (key id only); cached for 10 minutes.
let methodsCache = { at: 0, data: null };
app.get("/api/payments/methods", wrap(async (req, res) => {
  if (Date.now() - methodsCache.at > 6e5) {
    const r = await fetch(`https://api.razorpay.com/v1/methods?key_id=${encodeURIComponent(RAZORPAY_KEY_ID)}`);
    const m = r.ok ? await r.json() : null;
    methodsCache = { at: Date.now(), data: m && { upi: !!m.upi, card: !!m.card, netbanking: !!(m.netbanking && Object.keys(m.netbanking).length), wallet: !!(m.wallet && Object.values(m.wallet).some(Boolean)) } };
  }
  res.json(methodsCache.data || { upi: true, card: true, netbanking: true, wallet: true }); // unknown: don't block anything
}));

app.post("/api/payments/verify", auth, wrap(async (req, res) => {
  const { razorpay_order_id: o, razorpay_payment_id: p, razorpay_signature: s } = req.body;
  if (!same(hmac(RAZORPAY_KEY_SECRET, `${o}|${p}`), s)) return res.status(400).json({ error: "Invalid payment signature" });
  await markPaid(o, p);
  res.json({ ok: true });
}));

// 2. Submissions: membership, limits and event-code checks run in one locked database transaction (submit_activity),
// so parallel requests cannot get past the frequency limit.
app.post("/api/submissions", auth, approved, wrap(async (req, res) => {
  const p = req.profile, { activityId, proofPath, eventCode } = req.body;
  // Extra questions some activities ask (e.g. walk or cycle, and distance): every answer is required and checked here.
  const act = typeof activityId === "string" && /^[0-9a-f-]{36}$/i.test(activityId)
    ? must(await db.from("activities").select("inputs").eq("id", activityId).maybeSingle()) : null;
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
    const { data: file, error } = await db.storage.from("proofs").download(proofPath);
    if (error) return res.status(400).json({ error: "Photo upload not found. Please try again." });
    proofHash = crypto.createHash("sha256").update(Buffer.from(await file.arrayBuffer())).digest("hex");
  }
  const { data, error } = await db.rpc("submit_activity", { p_user: p.id, p_activity: activityId, p_proof_path: proofPath || null,
    p_proof_hash: proofHash, p_event_code: eventCode == null ? null : String(eventCode) });
  if (error) return res.status(400).json({ error: error.message });
  if (Object.keys(details).length && data?.id) must(await db.from("activity_submissions").update({ details }).eq("id", data.id));
  res.json(data);
}));

// 3. Rewards
app.post("/api/rewards/:id/redeem", auth, approved, wrap(async (req, res) => {
  const { error } = await db.rpc("redeem_reward", { p_user: req.user.id, p_reward: req.params.id });
  if (error) return res.status(400).json({ error: error.message });
  res.json({ ok: true });
}));

// 4. Admin dashboard. Submissions reference profiles twice (student and reviewer), so each embed names its foreign key.
const SUB_COLS = "id,submitted_at,proof_path,proof_hash,verification_status,rejection_reason,verified_at,details," +
  "activities(name,category,xp_value,verification_type)," +
  "student:profiles!activity_submissions_user_id_fkey!inner(id,full_name,usn,department,year,college_id)," +
  "reviewer:profiles!activity_submissions_verified_by_fkey(full_name)";
const countOf = async (q) => { const { count, error } = await q; if (error) throw error; return count || 0; };

app.get("/api/admin/stats", auth, admin, wrap(async (req, res) => {
  const college = req.profile.college_id, weekAgo = new Date(Date.now() - 7 * 864e5).toISOString();
  const subs = () => db.from("activity_submissions").select("id,student:profiles!activity_submissions_user_id_fkey!inner(college_id)", { count: "exact", head: true })
    .eq("student.college_id", college);
  const [usersPending, pending, approvedWeek, rejectedWeek, members, students] = await Promise.all([
    countOf(db.from("profiles").select("id", { count: "exact", head: true }).eq("college_id", college).eq("role", "student").eq("approval_status", "pending")),
    countOf(subs().eq("verification_status", "pending")),
    countOf(subs().eq("verification_status", "verified").not("verified_by", "is", null).gte("verified_at", weekAgo)),
    countOf(subs().eq("verification_status", "rejected").gte("verified_at", weekAgo)),
    countOf(db.from("memberships").select("id,p:profiles!memberships_user_id_fkey!inner(college_id)", { count: "exact", head: true })
      .eq("p.college_id", college).in("status", ["active", "waived"])),
    countOf(db.from("profiles").select("id", { count: "exact", head: true }).eq("college_id", college).eq("role", "student")),
  ]);
  res.json({ usersPending, pending, approvedWeek, rejectedWeek, members, students });
}));

// New users: students of the admin's college by approval status, newest first.
app.get("/api/admin/users", auth, admin, wrap(async (req, res) => {
  const status = ["pending", "approved", "rejected"].includes(req.query.status) ? req.query.status : "pending";
  const data = must(await db.from("profiles")
    .select("id,email,full_name,usn,department,year,phone,created_at,approval_status,approval_note,approved_at,approved_by")
    .eq("college_id", req.profile.college_id).eq("role", "student").eq("approval_status", status)
    .order(status === "pending" ? "created_at" : "approved_at", { ascending: status === "pending" }).limit(200)) || [];
  // Reviewer names come from a second lookup: the API can't embed profiles into itself.
  const reviewerIds = [...new Set(data.map((u) => u.approved_by).filter(Boolean))];
  if (reviewerIds.length) {
    const names = new Map(must(await db.from("profiles").select("id,full_name").in("id", reviewerIds)).map((r) => [r.id, r.full_name]));
    for (const u of data) if (u.approved_by) u.approver = { full_name: names.get(u.approved_by) };
  }
  for (const u of data) delete u.approved_by;
  res.json(data);
}));

app.post("/api/admin/users/review", auth, admin, wrap(async (req, res) => {
  const { ids, approve, reason } = req.body;
  if (!Array.isArray(ids) || !ids.length || ids.length > 200 || !ids.every((id) => /^[0-9a-f-]{36}$/i.test(id)))
    return res.status(400).json({ error: "Choose between 1 and 200 users" });
  const note = approve ? null : String(reason || "Not approved by your college admin").slice(0, 500);
  const done = must(await db.from("profiles")
    .update({ approval_status: approve ? "approved" : "rejected", approval_note: note, approved_by: req.user.id, approved_at: new Date().toISOString() })
    .in("id", ids).eq("college_id", req.profile.college_id).eq("role", "student").select("id"));
  if (done.length) must(await db.from("audit_logs").insert(done.map((u) => ({ actor_id: req.user.id, action: approve ? "approve_user" : "reject_user",
    target_type: "profile", target_id: u.id, details: { reason: note } }))));
  res.json({ done: done.length, failed: ids.filter((id) => !done.some((u) => u.id === id)).map((id) => ({ id, error: "Not a student of your college" })) });
}));

app.get("/api/admin/submissions", auth, admin, wrap(async (req, res) => {
  const status = ["pending", "verified", "rejected"].includes(req.query.status) ? req.query.status : "pending";
  let q = db.from("activity_submissions").select(SUB_COLS).eq("verification_status", status).eq("student.college_id", req.profile.college_id);
  if (status === "verified") q = q.not("verified_by", "is", null); // admin-approved only, not instant activities
  q = status === "pending" ? q.order("submitted_at") : q.order("verified_at", { ascending: false });
  const data = must(await q.limit(100)) || [];

  const paths = data.filter((s) => s.proof_path).map((s) => s.proof_path);
  if (paths.length) {
    const urls = new Map(must(await db.storage.from("proofs").createSignedUrls(paths, 600)).map((u) => [u.path, u.signedUrl]));
    for (const s of data) if (s.proof_path) s.proof_url = urls.get(s.proof_path);
  }
  // Warnings for the reviewer: the same photo used in other submissions, and the student's review history.
  const hashes = [...new Set(data.map((s) => s.proof_hash).filter(Boolean))];
  if (hashes.length) {
    const others = must(await db.from("activity_submissions").select("id,user_id,proof_hash").in("proof_hash", hashes));
    for (const s of data) {
      const dup = others.filter((o) => o.proof_hash === s.proof_hash && o.id !== s.id);
      if (dup.length) s.duplicate = { count: dup.length, otherStudent: dup.some((o) => o.user_id !== s.student.id) };
    }
  }
  const studentIds = [...new Set(data.map((s) => s.student.id))];
  if (status === "pending" && studentIds.length) {
    const past = must(await db.from("activity_submissions").select("user_id,verification_status").in("user_id", studentIds)
      .not("verified_by", "is", null));
    for (const s of data) {
      const mine = past.filter((p) => p.user_id === s.student.id);
      s.history = { approved: mine.filter((p) => p.verification_status === "verified").length, rejected: mine.filter((p) => p.verification_status === "rejected").length };
    }
  }
  for (const s of data) { delete s.proof_hash; delete s.proof_path; }
  res.json(data);
}));

// Approve or reject one or many submissions. Admins cannot review their own.
app.post("/api/admin/submissions/review", auth, admin, wrap(async (req, res) => {
  const { ids, approve, reason } = req.body;
  if (!Array.isArray(ids) || !ids.length || ids.length > 100 || !ids.every((id) => /^[0-9a-f-]{36}$/i.test(id)))
    return res.status(400).json({ error: "Choose between 1 and 100 submissions" });
  const own = new Set(must(await db.from("activity_submissions").select("id").in("id", ids).eq("user_id", req.user.id)).map((s) => s.id));
  const result = { done: 0, failed: [] };
  for (const id of ids) {
    if (own.has(id)) { result.failed.push({ id, error: "You can't review your own submission" }); continue; }
    const { error } = await db.rpc("review_submission", { p_id: id, p_admin: req.user.id, p_approve: !!approve,
      p_reason: approve ? null : String(reason || "Rejected by admin").slice(0, 500) });
    error ? result.failed.push({ id, error: error.message }) : result.done++;
  }
  res.json(result);
}));
app.post("/api/admin/certificates/issue", auth, admin, wrap(async (req, res) => {
  const { data, error } = await db.rpc("issue_certificates", { p_admin: req.user.id });
  if (error) return res.status(400).json({ error: error.message });
  res.json({ issued: data });
}));

// Institutions (super admin only): list, add, switch on/off, and appoint each institution's admin.
const superAdmin = (req, res, next) =>
  req.profile.role === "super_admin" ? next() : res.status(403).json({ error: "Only the platform super admin can manage institutions" });

app.get("/api/super/institutions", auth, superAdmin, wrap(async (req, res) => {
  const colleges = must(await db.from("colleges").select("id,name,city,state,pincode,active,created_at").order("name"));
  const people = must(await db.from("profiles").select("college_id,role,approval_status,email"));
  res.json(colleges.map((c) => {
    const mine = people.filter((p) => p.college_id === c.id);
    return { ...c, students: mine.filter((p) => p.role === "student").length,
      waiting: mine.filter((p) => p.role === "student" && p.approval_status === "pending").length,
      admins: mine.filter((p) => ["admin", "super_admin"].includes(p.role)).map((p) => p.email) };
  }));
}));

app.post("/api/super/institutions", auth, superAdmin, wrap(async (req, res) => {
  const { name, city, state, pincode, fee } = req.body;
  const { data, error } = await db.rpc("create_institution", { p_template: req.profile.college_id, p_name: String(name || ""),
    p_city: String(city || ""), p_state: String(state || ""), p_pincode: String(pincode || ""), p_fee: Number(fee) });
  if (error) return res.status(400).json({ error: error.message });
  must(await db.from("audit_logs").insert({ actor_id: req.user.id, action: "create_institution", target_type: "college", target_id: data, details: { name } }));
  res.json({ id: data });
}));

// Bulk import from a spreadsheet (already parsed and checked in the browser). Each row is created on its own,
// so one bad row doesn't stop the rest; the result says what happened to every row.
app.post("/api/super/institutions/bulk", auth, superAdmin, wrap(async (req, res) => {
  const rows = req.body.rows;
  if (!Array.isArray(rows) || !rows.length || rows.length > 500) return res.status(400).json({ error: "Upload between 1 and 500 institutions at a time" });
  const results = [];
  for (const r of rows) {
    const { data, error } = await db.rpc("create_institution", { p_template: req.profile.college_id, p_name: String(r.name || ""),
      p_city: String(r.city || ""), p_state: String(r.state || ""), p_pincode: String(r.pincode || ""), p_fee: Number(r.fee) });
    results.push(error ? { ok: false, error: error.message } : { ok: true, id: data });
  }
  const created = results.filter((r) => r.ok).length;
  must(await db.from("audit_logs").insert({ actor_id: req.user.id, action: "bulk_import_institutions", target_type: "college",
    details: { submitted: rows.length, created } }));
  res.json({ created, results });
}));

// Edit an institution's name and location.
app.post("/api/super/institutions/:id", auth, superAdmin, wrap(async (req, res) => {
  const f = Object.fromEntries(["name", "city", "state", "pincode"].map((k) => [k, String(req.body[k] || "").trim()]));
  if (!f.name || !f.city || !f.state) return res.status(400).json({ error: "Name, city and state are required" });
  if (!/^[1-9][0-9]{5}$/.test(f.pincode)) return res.status(400).json({ error: "Pincode must be 6 digits" });
  const { error } = await db.from("colleges").update(f).eq("id", req.params.id);
  if (error) return res.status(400).json({ error: error.code === "23505" ? "An institution with this name already exists" : error.message });
  must(await db.from("audit_logs").insert({ actor_id: req.user.id, action: "edit_institution", target_type: "college", target_id: req.params.id, details: f }));
  res.json({ ok: true });
}));

app.post("/api/super/institutions/:id/active", auth, superAdmin, wrap(async (req, res) => {
  if (req.params.id === req.profile.college_id && !req.body.active) return res.status(400).json({ error: "You can't switch off your own institution" });
  must(await db.from("colleges").update({ active: !!req.body.active }).eq("id", req.params.id));
  res.json({ ok: true });
}));

// Delete an institution nobody has signed up at (a mistake, test or duplicate). Its setup rows are removed
// by ON DELETE CASCADE; anything with student data is refused, and switching it off is suggested instead.
app.post("/api/super/institutions/:id/delete", auth, superAdmin, wrap(async (req, res) => {
  if (req.params.id === req.profile.college_id) return res.status(400).json({ error: "You can't delete your own institution" });
  const c = must(await db.from("colleges").select("id,name").eq("id", req.params.id).maybeSingle());
  if (!c) return res.status(404).json({ error: "Institution not found" });
  const accounts = await countOf(db.from("profiles").select("id", { count: "exact", head: true }).eq("college_id", c.id));
  if (accounts) return res.status(400).json({ error: `${c.name} has ${accounts} account${accounts > 1 ? "s" : ""}, so it can't be deleted. Switch it off instead to hide it from sign-up.` });
  const { error } = await db.from("colleges").delete().eq("id", c.id);
  if (error) return res.status(400).json({ error: error.code === "23503" ? `${c.name} still has student records, so it can't be deleted. Switch it off instead.` : error.message });
  must(await db.from("audit_logs").insert({ actor_id: req.user.id, action: "delete_institution", target_type: "college", target_id: c.id, details: { name: c.name } }));
  res.json({ ok: true });
}));

app.post("/api/super/institutions/:id/admin", auth, superAdmin, wrap(async (req, res) => {
  const email = String(req.body.email || "").trim().toLowerCase();
  const p = must(await db.from("profiles").select("id,college_id,role").eq("email", email).maybeSingle());
  if (!p) return res.status(404).json({ error: "No account with that email. Ask them to sign up first, choosing this institution." });
  if (p.college_id !== req.params.id) return res.status(400).json({ error: "That person signed up at a different institution" });
  if (p.role === "super_admin") return res.status(400).json({ error: "That person is already the super admin" });
  must(await db.from("profiles").update({ role: "admin", approval_status: "approved", approved_by: req.user.id, approved_at: new Date().toISOString() }).eq("id", p.id));
  must(await db.from("audit_logs").insert({ actor_id: req.user.id, action: "make_admin", target_type: "profile", target_id: p.id, details: { email } }));
  res.json({ ok: true });
}));

// 5. Utility bills: read units and the billing period from an uploaded bill; the student checks and corrects them before saving.
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

  const { data: file, error } = await db.storage.from("bills").download(path);
  if (error) return res.status(400).json({ error: "Bill upload not found. Please try again." });
  const type = MEDIA[path.split(".").pop().toLowerCase()];
  if (!type) return res.status(400).json({ error: "Upload a JPG, PNG, WebP or PDF bill." });
  const data = Buffer.from(await file.arrayBuffer()).toString("base64");
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

app.listen(PORT, () => console.log("GreenXP API on " + PORT));
