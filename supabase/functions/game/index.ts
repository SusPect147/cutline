// CUTLINE game server (Supabase Edge Function).
// Runs with the service role. Players can ask it to:
//   tg       – sign in with the Telegram Mini App launch data (signature checked with the bot token)
//   status   – is the bot token configured (returns the bot's username only)
//   advance  – settle any round whose betting has closed, in both rooms (idempotent; anyone may trigger it)
//   deposits – scan the house wallet for incoming Gram and credit them (idempotent; anyone may trigger it)
//   admin    – test tools for ForFun and on-chain re-checks of deposits, only with the admin code
// The round itself is computed from public data (bets, seed hash) + the secret seed + fresh entropy,
// using exactly the same core.js the browser uses to replay and verify it.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import "./core.js";

// deno-lint-ignore no-explicit-any
const C = (globalThis as any).CutlineCore;
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const hex = (n: number) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (x) => x.toString(16).padStart(2, "0")).join("");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  try {
    switch (body.action) {
      case "tg": return json(await tgLogin(body));
      case "status": return json(await status());
      case "advance": return json(await advance());
      case "deposits": return json(await scanDeposits());
      case "admin": return json(await admin(body));
      default: return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});

/* ---------- Telegram sign-in ---------- */
const enc = (t: string) => new TextEncoder().encode(t);
async function hmac(key: Uint8Array, msg: Uint8Array) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, msg));
}
const toHex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
function sameHex(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const botToken = () => {
  const t = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!t) throw new Error("no_bot_token");
  return t.trim();
};
const tgApi = async (method: string, params: Record<string, string | number>) => {
  const q = new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)]));
  const r = await fetch(`https://api.telegram.org/bot${botToken()}/${method}?${q}`, { signal: AbortSignal.timeout(5000) });
  const j = await r.json();
  if (!j.ok) throw new Error("tg_api_" + method);
  return j.result;
};

// https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
async function checkInitData(initData: string) {
  if (!initData || initData.length > 8192) throw new Error("tg_required");
  const params = new URLSearchParams(initData);
  const hash = params.get("hash") || "";
  params.delete("hash");
  const dcs = [...params.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([k, v]) => `${k}=${v}`).join("\n");
  const secret = await hmac(enc("WebAppData"), enc(botToken()));
  const sig = toHex(await hmac(secret, enc(dcs)));
  if (!sameHex(sig, hash.toLowerCase())) throw new Error("tg_bad_sign");
  const age = Date.now() / 1000 - Number(params.get("auth_date") || 0);
  if (!(age < 86400)) throw new Error("tg_expired");
  const user = JSON.parse(params.get("user") || "null");
  if (!user || !Number.isSafeInteger(user.id)) throw new Error("tg_no_user");
  return user as { id: number; first_name?: string; last_name?: string; username?: string; photo_url?: string };
}

// copies the player's current Telegram photo into our storage; returns null when nothing changed
async function fetchAvatar(tgId: number, knownUid: string | null) {
  const res = await tgApi("getUserProfilePhotos", { user_id: tgId, limit: 1 });
  const sizes = res.photos && res.photos[0];
  if (!sizes || !sizes.length) return { url: null, uid: null };
  const pick = sizes.find((s: { width: number }) => s.width >= 160) || sizes[sizes.length - 1];
  if (pick.file_unique_id === knownUid) return null;
  const file = await tgApi("getFile", { file_id: pick.file_id });
  const img = await fetch(`https://api.telegram.org/file/bot${botToken()}/${file.file_path}`, { signal: AbortSignal.timeout(5000) });
  if (!img.ok) throw new Error("tg_photo_download");
  const bytes = new Uint8Array(await img.arrayBuffer());
  if (bytes.length > 1048576) throw new Error("tg_photo_too_big");
  const path = `${tgId}/${pick.file_unique_id}.jpg`;
  const { error } = await db.storage.from("avatars").upload(path, bytes, { contentType: "image/jpeg", upsert: true, cacheControl: "31536000" });
  if (error) throw error;
  return { url: db.storage.from("avatars").getPublicUrl(path).data.publicUrl, uid: pick.file_unique_id as string };
}

async function tgLogin(body: Record<string, unknown>) {
  let u;
  try { u = await checkInitData(String(body.initData || "")); }
  catch (e) { return { error: e instanceof Error ? e.message : "tg_bad_sign" }; }

  // one Telegram account = one game account
  const email = `tg${u.id}@tg.cutline.app`;
  const { data: known } = await db.rpc("tg_lookup", { p_tg_id: u.id });
  if (!known) {
    const { error } = await db.auth.admin.createUser({ email, email_confirm: true, app_metadata: { tg_id: u.id } });
    if (error && !/already|exists|registered/i.test(error.message)) throw error;
  }
  const { data: link, error: e1 } = await db.auth.admin.generateLink({ type: "magiclink", email });
  if (e1) throw e1;
  // a fresh client per request, so the service-role client never picks up a player session
  const pub = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: v, error: e2 } = await pub.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "magiclink" });
  if (e2 || !v.session) throw e2 || new Error("tg_session");

  // name and picture come from Telegram, checked above; the client cannot change them
  const name = [u.first_name, u.last_name].filter(Boolean).join(" ") || u.username || "Player";
  let avatar: string | null = null, photoUid: string | null = null;
  try {
    const a = await fetchAvatar(u.id, known?.photo_uid || null);
    if (a) { avatar = a.url; photoUid = a.uid; }
    else avatar = known?.avatar_url || null;
  } catch (e) { console.error("avatar", e); avatar = known?.avatar_url || null; }
  if (!avatar) avatar = u.photo_url || `https://api.dicebear.com/9.x/thumbs/svg?seed=tg${u.id}`;

  const { data: w, error: e3 } = await db.rpc("tg_login_profile", {
    p_user: v.session.user.id, p_tg_id: u.id, p_name: name, p_avatar: avatar, p_photo_uid: photoUid,
    p_username: u.username || null,
  });
  if (e3) throw e3;
  return {
    access_token: v.session.access_token, refresh_token: v.session.refresh_token,
    user_id: v.session.user.id, name: w.name, username: w.username, avatar_url: w.avatar_url,
    balance: w.balance, fun_balance: w.fun_balance, last_faucet_round: w.last_faucet_round,
  };
}

async function status() {
  try { const me = await tgApi("getMe", {}); return { ok: true, bot: me.username }; }
  catch (e) { return { ok: false, error: e instanceof Error ? e.message : String(e) }; }
}

async function advance() {
  const out: Record<string, unknown> = {};
  for (const room of ["real", "fun"]) out[room] = await advanceRoom(room).catch((e) => ({ ok: false, error: String(e && e.message || e) }));
  return out;
}

async function advanceRoom(room: string) {
  const { data: r, error } = await db.from("rounds").select("id,status,seed_hash,bets_close_at")
    .eq("status", "betting").eq("room", room).order("id", { ascending: false }).limit(1).maybeSingle();
  if (error) throw error;
  if (!r || !r.bets_close_at || Date.parse(r.bets_close_at) > Date.now() + 750) return { ok: false, reason: "not_due" };
  const { data: sec, error: e1 } = await db.rpc("get_round_secret", { p_round: r.id });
  if (e1) throw e1;
  const { data: bets, error: e2 } = await db.from("bets").select("id,user_id,amount").eq("round_id", r.id).order("id");
  if (e2) throw e2;
  if (!bets || new Set(bets.map((b) => b.user_id)).size < 2) return { ok: false, reason: "not_enough_players" };
  const entropy = hex(12); // created only now, after bets are closed
  const out = C.computeRound(bets, r.seed_hash, sec.seed, entropy, sec.forced_mod);
  const { data: st, error: e3 } = await db.rpc("settle_round", {
    p_round: r.id, p_entropy: entropy, p_mod: out.mod, p_mod_forced: out.modForced, p_winner: out.winner,
    p_cuts: out.cuts, p_result: out.result, p_anim_ms: out.anim,
  });
  if (e3) throw e3;
  return st;
}

/* ---------- deposits: Gram sent to the house wallet with the player's code as the comment ---------- */
// A transfer is credited only if two independent indexers (toncenter and tonapi) agree on every detail:
// it is a finished, non-aborted, non-bounced incoming internal transfer to the house wallet, with this exact
// value, sender and comment. The database then credits each transaction hash at most once.
function crc16(d: Uint8Array) {
  let c = 0;
  for (const x of d) { c ^= x << 8; for (let i = 0; i < 8; i++) c = (c & 0x8000) ? ((c << 1) ^ 0x1021) & 0xffff : (c << 1) & 0xffff; }
  return c;
}
function rawAddress(friendly: string) {
  const b = Uint8Array.from(atob(friendly.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0));
  if (b.length !== 36 || crc16(b.subarray(0, 34)) !== ((b[34] << 8) | b[35])) throw new Error("bad_house_address");
  const wc = b[1] === 0xff ? -1 : b[1];
  return `${wc}:${toHex(b.subarray(2, 34))}`;
}
let houseCache: string | null = null, sinceCache = 0;
async function houseRaw() {
  if (houseCache) return houseCache;
  const { data, error } = await db.from("app_config").select("value").eq("key", "wallet").single();
  if (error) throw error;
  houseCache = rawAddress(String(data.value.address)).toLowerCase();
  sinceCache = Number(data.value.since) || 0;              // transfers before deposits were switched on never count
  return houseCache;
}
const low = (a: unknown) => String(a || "").toLowerCase();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// deno-lint-ignore no-explicit-any
function incoming(tx: any, house: string) {
  const m = tx && tx.in_msg, d = (tx && tx.description) || {};
  if (low(tx.account) !== house || !m || !m.source || low(m.destination) !== house) return null;   // internal transfer to us
  if (!(Number(tx.now) >= sinceCache) || !sinceCache) return null;
  if (d.type !== "ord" || d.aborted !== false) return null;
  if (!d.compute_ph || d.compute_ph.skipped || d.compute_ph.success !== true) return null;
  if (m.bounced === true) return null;
  let nano: bigint;
  try { nano = BigInt(m.value); } catch { return null; }
  if (nano <= 0n) return null;
  const dec = m.message_content && m.message_content.decoded;
  const comment = dec && dec.type === "text_comment" ? String(dec.comment || "") : "";
  if (!/^\s*CUT[0-9A-F]{8}\s*$/i.test(comment) && nano < 10000000n) return null;               // dust / spam
  return { hash: String(tx.hash), lt: String(tx.lt), sender: low(m.source), nano, comment, time: Number(tx.now) };
}

// second opinion from another indexer: every field has to match
async function confirmed(t: NonNullable<ReturnType<typeof incoming>>, house: string) {
  const hex = toHex(Uint8Array.from(atob(t.hash), (ch) => ch.charCodeAt(0)));
  const r = await fetch(`https://tonapi.io/v2/blockchain/transactions/${hex}`, { signal: AbortSignal.timeout(8000) });
  if (!r.ok) return false;
  const j = await r.json();
  const m = j.in_msg || {};
  const text = m.decoded_body && typeof m.decoded_body.text === "string" ? m.decoded_body.text : "";
  return j.success === true && j.aborted === false && j.in_progress !== true &&
    low(j.account && j.account.address) === house && low(m.destination && m.destination.address) === house &&
    low(m.source && m.source.address) === t.sender && m.bounced !== true &&
    String(m.value) === t.nano.toString() && String(j.lt) === t.lt && text === t.comment;
}

async function scanDeposits() {
  const { data: slot, error: e0 } = await db.rpc("scan_slot", { p_gap_ms: 4000 });
  if (e0) throw e0;
  if (!slot) return { ok: true, waited: true };                    // someone scanned a moment ago
  const house = await houseRaw();
  const key = Deno.env.get("TONCENTER_API_KEY");
  const res: Record<string, number> = {};
  let stop = false;
  for (let page = 0; page < 2 && !stop; page++) {
    if (page && !key) await sleep(1100);                           // public rate limit: 1 request per second
    const url = `https://toncenter.com/api/v3/transactions?account=${house}&limit=50&offset=${page * 50}&sort=desc`;
    const r = await fetch(url, { headers: key ? { "X-API-Key": key } : {}, signal: AbortSignal.timeout(8000) });
    if (!r.ok) return { ok: false, error: "chain_unavailable" };
    const txs = (await r.json()).transactions || [];
    for (const tx of txs) {
      const t = incoming(tx, house);
      if (!t) continue;
      const { data: known } = await db.rpc("deposit_known", { p_hash: t.hash });
      if (known) { stop = true; continue; }
      if (!(await confirmed(t, house).catch(() => false))) { res.unconfirmed = (res.unconfirmed || 0) + 1; continue; }
      const { data: st, error } = await db.rpc("credit_deposit", {
        p_hash: t.hash, p_lt: Number(t.lt), p_sender: t.sender, p_nano: t.nano.toString(),
        p_comment: t.comment, p_time: new Date(t.time * 1000).toISOString(),
      });
      if (error) throw error;
      res[String(st)] = (res[String(st)] || 0) + 1;
    }
    if (txs.length < 50) break;
  }
  return { ok: true, ...res };
}

const BOT_STAKES = [0.1, 0.2, 0.5, 1, 2, 3, 5, 10, 20];
async function admin(body: Record<string, unknown>) {
  const code = String(body.code || "");
  const { data: ok, error } = await db.rpc("admin_check", { p_code: code });
  if (error) throw error;
  if (!ok) return { ok: false, error: "bad_code" };
  const op = String(body.op || "state");
  if (op === "set_mod") {
    const mod = body.mod && C.MODS[String(body.mod)] ? String(body.mod) : null;
    const { error: e } = await db.rpc("admin_set", { p_key: "next_mod", p_value: mod });
    if (e) throw e;
  } else if (op === "set_fast") {
    const { error: e } = await db.rpc("admin_timing", { p_fast: !!body.fast });
    if (e) throw e;
  } else if (op === "bots") {
    const n = Math.max(1, Math.min(12, Number(body.count) || 1));
    const { data: bots } = await db.from("profiles").select("id").eq("is_bot", true);
    const { data: open } = await db.from("rounds").select("id").eq("status", "betting").eq("room", "fun").order("id", { ascending: false }).limit(1).maybeSingle();
    const { data: inRound } = open ? await db.from("bets").select("user_id").eq("round_id", open.id) : { data: [] };
    const taken = new Set((inRound || []).map((b) => b.user_id));
    const free = (bots || []).map((b) => b.id).filter((id) => !taken.has(id)).sort(() => Math.random() - 0.5).slice(0, n);
    for (const id of free) {
      const amt = BOT_STAKES[Math.floor(Math.random() * BOT_STAKES.length)];
      const { error: e } = await db.rpc("admin_bot_bet", { p_bot: id, p_amount: amt });
      if (e) throw e;
    }
  } else if (op === "recheck") {
    // re-verify deposits on chain before paying a withdrawal out
    const hashes = (Array.isArray(body.hashes) ? body.hashes : []).slice(0, 40).map(String);
    const house = await houseRaw();
    const out: Record<string, boolean> = {};
    for (const h of hashes) {
      const hex = toHex(Uint8Array.from(atob(h), (ch) => ch.charCodeAt(0)));
      const r = await fetch(`https://tonapi.io/v2/blockchain/transactions/${hex}`, { signal: AbortSignal.timeout(8000) }).catch(() => null);
      const j = r && r.ok ? await r.json() : null;
      out[h] = !!j && j.success === true && j.aborted === false && low(j.account && j.account.address) === house &&
        low(j.in_msg && j.in_msg.destination && j.in_msg.destination.address) === house && j.in_msg.bounced !== true;
      if (hashes.length > 1) await sleep(350);
    }
    return { ok: true, recheck: out };
  } else if (op === "skip") {
    const { error: e } = await db.rpc("admin_skip");
    if (e) throw e;
    await advance().catch(() => null);
  }
  const { data: sec } = await db.rpc("get_round_secret", { p_round: 0 });
  const { data: timing } = await db.from("app_config").select("value").eq("key", "timing").maybeSingle();
  return { ok: true, next_mod: sec?.forced_mod || null, fast: !!timing?.value?.fast };
}
