// Emails to students, sent through Resend. Sign-up codes and password resets are not here: Cognito sends those.

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const firstName = (u) => String(u.full_name || "").trim().split(/\s+/)[0] || "there";
const money = (amount, currency) => new Intl.NumberFormat("en-IN", { style: "currency", currency }).format(amount);

// Builds one message. lines are plain text (escaped here, so names and admins' reasons can't inject HTML);
// the button is the site, since every email asks the student to sign in or just tells them something happened.
function message(to, subject, lines, site, button) {
  const paragraphs = lines.map((l) => `<p style="margin:0 0 14px;line-height:1.5">${esc(l)}</p>`).join("");
  const action = button ? `<p style="margin:22px 0 6px"><a href="${esc(site)}" style="background:#15803d;color:#fff;padding:11px 20px;border-radius:8px;text-decoration:none;font-weight:600">${esc(button)}</a></p>` : "";
  return {
    to: [to], subject,
    html: `<div style="font-family:Arial,Helvetica,sans-serif;color:#1f2937;font-size:15px;max-width:520px;margin:0 auto;padding:20px">` +
      `<p style="margin:0 0 18px;font-size:18px;font-weight:700;color:#15803d">GreenXP</p>${paragraphs}${action}</div>`,
    text: [...lines, ...(button ? [`${button}: ${site}`] : [])].join("\n\n"),
  };
}

export const templates = (site) => ({
  accountApproved: (u, feeWaived) => message(u.email, "Your GreenXP account is approved", [
    `Hi ${firstName(u)},`,
    feeWaived ? "Your college admin has approved your account and waived this year's membership fee. You can start logging activities now."
      : "Your college admin has approved your account. Sign in to pay your membership fee and start logging activities.",
  ], site, "Open GreenXP"),
  accountRejected: (u, reason) => message(u.email, "Your GreenXP account wasn't approved", [
    `Hi ${firstName(u)},`,
    "Your college admin didn't approve your account.",
    `Reason: ${reason}`,
    "If something in your details was wrong, sign in and correct them to ask for another review.",
  ], site, "Open GreenXP"),
  paymentReceipt: (u, pay) => message(u.email, "Your GreenXP membership receipt", [
    `Hi ${firstName(u)},`,
    `We've confirmed your payment of ${money(pay.amount, pay.currency)}, and your membership for this academic year is active.`,
    ...(pay.upi_ref ? [`UPI transaction ID: ${pay.upi_ref}`] : []),
  ], site, "Open GreenXP"),
  paymentRejected: (u, reason) => message(u.email, "We couldn't confirm your GreenXP payment", [
    `Hi ${firstName(u)},`,
    "We couldn't confirm your membership payment.",
    `Reason: ${reason}`,
    "If you did pay, sign in and send the correct transaction ID or a clear screenshot.",
  ], site, "Open GreenXP"),
  submissionsRejected: (u, items) => message(u.email,
    items.length > 1 ? `${items.length} of your GreenXP activities weren't approved` : "Your GreenXP activity wasn't approved", [
      `Hi ${firstName(u)},`,
      "Your college admin didn't approve the following:",
      ...items.map((i) => `${i.activity}: ${i.reason}`),
    ], site, "Open GreenXP"),
  certificateIssued: (u, cert) => message(u.email, "Your GreenXP certificate is ready", [
    `Hi ${firstName(u)},`,
    `Well done! You've earned a ${cert.tier} certificate with ${cert.xp_earned} XP this year.`,
    `Certificate code: ${cert.certificate_code}`,
  ], site, "View your certificate"),
});

// Without an API key, nothing is sent and the rest of the app works as usual.
export function createMailer({ apiKey, from }) {
  // Sends up to 100 messages per request (Resend's batch limit). Throws if Resend refuses.
  async function send(messages) {
    for (let i = 0; i < messages.length; i += 100) {
      const r = await fetch("https://api.resend.com/emails/batch", {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify(messages.slice(i, i + 100).map((m) => ({ from, ...m }))),
        signal: AbortSignal.timeout(15000),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${(await r.text()).slice(0, 300)}`);
    }
  }
  // For use after the work is committed: runs in the background, and a failed email is logged, never passed to the user.
  const notify = (build) => {
    if (!apiKey) return;
    Promise.resolve().then(build).then((list) => list.length ? send(list) : null)
      .catch((e) => console.error("email not sent:", e.message));
  };
  return { send, notify };
}
