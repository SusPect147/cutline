// CUTLINE game server (Supabase Edge Function).
// Runs with the service role. Players can ask it to:
//   guest   – create a guest account (no e-mail needed)
//   advance – settle the current round once betting has closed (idempotent; anyone may trigger it)
//   admin   – test tools, only with the admin code
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
      case "guest": return json(await guest());
      case "advance": return json(await advance());
      case "admin": return json(await admin(body));
      default: return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});

async function guest() {
  const email = `g-${hex(8)}@guest.cutline.app`;
  const password = hex(24);
  const { error } = await db.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { guest: true } });
  if (error) throw error;
  return { email, password };
}

async function advance() {
  const { data: r, error } = await db.from("rounds").select("id,status,seed_hash,bets_close_at")
    .eq("status", "betting").order("id", { ascending: false }).limit(1).maybeSingle();
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
    const { data: open } = await db.from("rounds").select("id").eq("status", "betting").order("id", { ascending: false }).limit(1).maybeSingle();
    const { data: inRound } = open ? await db.from("bets").select("user_id").eq("round_id", open.id) : { data: [] };
    const taken = new Set((inRound || []).map((b) => b.user_id));
    const free = (bots || []).map((b) => b.id).filter((id) => !taken.has(id)).sort(() => Math.random() - 0.5).slice(0, n);
    for (const id of free) {
      const amt = BOT_STAKES[Math.floor(Math.random() * BOT_STAKES.length)];
      const { error: e } = await db.rpc("admin_bot_bet", { p_bot: id, p_amount: amt });
      if (e) throw e;
    }
  } else if (op === "skip") {
    const { error: e } = await db.rpc("admin_skip");
    if (e) throw e;
    await advance().catch(() => null);
  }
  const { data: sec } = await db.rpc("get_round_secret", { p_round: 0 });
  const { data: timing } = await db.from("app_config").select("value").eq("key", "timing").maybeSingle();
  return { ok: true, next_mod: sec?.forced_mod || null, fast: !!timing?.value?.fast };
}
