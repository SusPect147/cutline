// CUTLINE statistics for the owner's local page (Supabase Edge Function).
// Answers only with the right key in the "x-stats-key" header (the database keeps just its SHA-256).
// Returns totals only: no names, Telegram ids, usernames, wallet addresses or transaction hashes.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-stats-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const sha256 = async (t: string) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(t))), (x) => x.toString(16).padStart(2, "0")).join("");

async function walletNano(address: string) {
  try {
    const key = (Deno.env.get("TONCENTER_API_KEY") || "").trim();
    const r = await fetch(`https://toncenter.com/api/v2/getAddressBalance?address=${encodeURIComponent(address)}`,
      { headers: key ? { "X-API-Key": key } : {}, signal: AbortSignal.timeout(8000) });
    const j = await r.json();
    return j.ok ? Number(BigInt(j.result)) / 1e9 : null;
  } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  // a few tries a minute per address, so the key cannot be guessed by brute force
  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "?";
  const { data: okRate } = await db.rpc("rate_hit", { p_key: `stats:${ip}`, p_max: 20, p_secs: 60 });
  if (okRate === false) return json({ error: "rate_limited" }, 429);
  const key = req.headers.get("x-stats-key") || "";
  if (key.length < 32 || key.length > 200) return json({ error: "forbidden" }, 403);
  const { data: ok } = await db.rpc("stats_key_ok", { p_hash: await sha256(key) });
  if (ok !== true) return json({ error: "forbidden" }, 403);
  try {
    const { data: s, error } = await db.rpc("stats_summary");
    if (error) throw error;
    const { data: cfg } = await db.from("app_config").select("value").eq("key", "wallet").single();
    const w = (cfg && cfg.value) || {};
    const bal = w.address ? await walletNano(String(w.address)) : null;
    const reserve = Number(w.owner_reserve ?? 1);
    return json({ ...s, wallet: { balance: bal, reserve,
      available_profit: bal === null ? null : Math.max(0, Math.floor((bal - Number(s.obligations) - reserve) * 100) / 100) } });
  } catch (e) {
    console.error(e);
    return json({ error: "server_error" }, 500);
  }
});
