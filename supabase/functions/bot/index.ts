// CUTLINE bot chat (Supabase Edge Function, Telegram webhook).
//   /start – welcome message with buttons: play, the news channel, the invite programme
//   /ref and the "invite programme" button – the player's own invite link and progress
//   "Support" – the player's next message (text, or a screenshot with a caption) becomes a ticket: one card in the
//              support chat with the player's name, username, id, a profile link (works without a username) and the
//              message itself, plus "Reply" and "Problem solved" buttons. Replies reach the player in the bot chat.
//   Owner (the support account): /stats – profit and totals, "withdraw profit", stop/resume payouts;
//              withdrawals above 40 TON, flagged or held ones arrive as cards with Approve / Reject.
// Telegram calls this function with a secret header; anything without it is ignored. Each update is handled once.
// POST ?tick=1 (called by the database) sends the owner the withdrawals that wait for a decision.
// GET ?setup=1 points the bot's webhook here (only when no other webhook is set) and sets the command menu.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const GAME_URL = "https://suspect147.github.io/cutline/";
const CHANNEL_URL = "https://t.me/cutline_channel";
const BOT = "cutline_game";
const SUPPORT_CHAT = 6169900632;       // the support account (it has to press /start in the bot once)
const ADMIN = SUPPORT_CHAT;            // the owner: statistics, profit, payouts
const FN = `${Deno.env.get("SUPABASE_URL")}/functions/v1`;

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const enc = (t: string) => new TextEncoder().encode(t);
const toHex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
async function hmac(key: Uint8Array, msg: Uint8Array) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, msg));
}
function sameStr(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
// the webhook secret is derived from a server secret, so it is never stored anywhere
const hookSecret = async () => toHex(await hmac(enc(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""), enc("cutline-bot-webhook"))).slice(0, 48);
const botToken = () => {
  const t = (Deno.env.get("TELEGRAM_BOT_TOKEN") || "").trim();
  if (!t) throw new Error("no_bot_token");
  return t;
};
async function tg(method: string, body: Record<string, unknown>) {
  const r = await fetch(`https://api.telegram.org/bot${botToken()}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(8000),
  });
  const j = await r.json();
  if (!j.ok) console.error("tg", method, j.description);
  return j;
}
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const num = (v: unknown) => String(Number(v));

/* ---------- texts ---------- */
type Lang = "ru" | "en";
// Russian only for players whose Telegram is in Russian, English for everyone else
const langOf = (code?: string): Lang => (/^ru\b/i.test(code || "") ? "ru" : "en");
const T = {
  ru: {
    welcome: (name: string) =>
      `Привет, ${esc(name)}! 👋\n\nСамое время залететь в <b>CUTLINE</b> и забрать весь пирог — общий банк раунда достаётся одному победителю. ` +
      `Так чего ты ждёшь? Стань победителем!`,
    play: "🎮 Играть", channel: "📢 Канал с новостями", refBtn: "👥 Реферальная программа", share: "📨 Отправить друзьям",
    supportBtn: "🛟 Поддержка",
    supportPrompt: "🛟 <b>Поддержка CUTLINE</b>\n\nОпишите проблему <b>одним сообщением</b>: что случилось и когда. " +
      "Скриншот можно прикрепить к этому же сообщению.\n\nОтвет придёт сюда, в этот чат. Передумали — нажмите /start.",
    supportSent: (n: number) => `✅ Обращение #${n} отправлено. Ответ придёт сюда, в этот чат.`,
    supportAnswer: (n: number) => `💬 <b>Ответ поддержки</b> · обращение #${n}`,
    supportLimited: "Слишком много обращений. Попробуйте снова через час.",
    supportSolved: (n: number) => `✅ Обращение #${n} закрыто: проблема решена. Если появятся вопросы — нажмите «Поддержка» в меню /start.`,
    shareText: "Залетай в CUTLINE — PvP-игру на TON!",
    noAccount: "Сначала открой игру кнопкой «Играть» — после первого входа здесь появится твоя личная ссылка для друзей.",
    off: "Реферальная программа сейчас на паузе. Следи за новостями в канале!",
    refMsg: (i: RefInfo) =>
      `<b>Реферальная программа</b>\n\nТвоя ссылка для друзей:\n${esc(i.link)}\n\n` +
      `Друг засчитывается, когда пополнит баланс от ${num(i.min_deposit)} TON и поставит в PvP от ${num(i.min_wager)} TON.\n\n` +
      `<b>Награды</b>\n` + i.ladder.map((s) => `${s.claimed ? "✅" : "▫️"} ${num(s.goal)} ${plural(Number(s.goal))} — ${num(s.reward)} TON`).join("\n") +
      `\n\nПриглашено: ${i.friends.total}, засчитано: <b>${i.friends.ok}</b>.\nНаграду забирай в игре, во вкладке «Задания».`,
  },
  en: {
    welcome: (name: string) =>
      `Hi, ${esc(name)}! 👋\n\nTime to jump into <b>CUTLINE</b> and take the whole pie: the entire round pot goes to one winner. ` +
      `So what are you waiting for? Become the winner!`,
    play: "🎮 Play", channel: "📢 News channel", refBtn: "👥 Invite friends", share: "📨 Send to friends",
    supportBtn: "🛟 Support",
    supportPrompt: "🛟 <b>CUTLINE support</b>\n\nDescribe the problem <b>in one message</b>: what happened and when. " +
      "You can attach a screenshot to the same message.\n\nThe answer will come here, in this chat. Changed your mind? Tap /start.",
    supportSent: (n: number) => `✅ Request #${n} sent. The answer will come here, in this chat.`,
    supportAnswer: (n: number) => `💬 <b>Support reply</b> · request #${n}`,
    supportLimited: "Too many requests. Please try again in an hour.",
    supportSolved: (n: number) => `✅ Request #${n} is closed: the problem is solved. If you have more questions, tap "Support" in the /start menu.`,
    shareText: "Join me in CUTLINE, a PvP game on TON!",
    noAccount: "Open the game with the \"Play\" button first: after your first visit your personal invite link will appear here.",
    off: "The invite programme is paused right now. Watch the channel for news!",
    refMsg: (i: RefInfo) =>
      `<b>Invite friends</b>\n\nYour link:\n${esc(i.link)}\n\n` +
      `A friend counts after depositing at least ${num(i.min_deposit)} TON and betting at least ${num(i.min_wager)} TON in PvP.\n\n` +
      `<b>Rewards</b>\n` + i.ladder.map((s) => `${s.claimed ? "✅" : "▫️"} ${num(s.goal)} friends — ${num(s.reward)} TON`).join("\n") +
      `\n\nInvited: ${i.friends.total}, counted: <b>${i.friends.ok}</b>.\nClaim rewards in the game, on the Tasks tab.`,
  },
};
function plural(n: number) {
  const a = n % 10, b = n % 100;
  if (a === 1 && b !== 11) return "друг";
  if (a >= 2 && a <= 4 && (b < 12 || b > 14)) return "друга";
  return "друзей";
}
type RefInfo = {
  enabled: boolean; account: boolean; link: string; min_deposit: number; min_wager: number;
  friends: { total: number; ok: number }; ladder: { goal: number; reward: number; claimed: boolean }[];
};

/* ---------- handlers ---------- */
// button colours (Bot API 9.4 "style"): success = green; buttons without a style keep the app's default look
const playBtn = (l: Lang) => ({ text: T[l].play, web_app: { url: GAME_URL }, style: "success" });
// someone came through a chat link with an invite (t.me/cutline_game?start=r_CODE): "Play" opens the game with the
// same invite, so the new player is bound to the inviter exactly as with a game link
const inviteBtn = (l: Lang, param: string) => ({ text: T[l].play, url: `https://t.me/${BOT}?startapp=${param}`, style: "success" });
async function sendStart(chatId: number, l: Lang, name: string, param = "") {
  await tg("sendMessage", {
    chat_id: chatId, text: T[l].welcome(name), parse_mode: "HTML", link_preview_options: { is_disabled: true },
    reply_markup: { inline_keyboard: [[param ? inviteBtn(l, param) : playBtn(l)], [{ text: T[l].channel, url: CHANNEL_URL }],
      [{ text: T[l].refBtn, callback_data: "ref", style: "success" }], [{ text: T[l].supportBtn, callback_data: "support" }]] },
  });
}
async function sendRef(chatId: number, tgId: number, l: Lang) {
  const { data, error } = await db.rpc("bot_ref_info", { p_tg_id: tgId });
  if (error) throw error;
  const i = data as RefInfo;
  if (!i || !i.enabled) {
    await tg("sendMessage", { chat_id: chatId, text: T[l].off, reply_markup: { inline_keyboard: [[{ text: T[l].channel, url: CHANNEL_URL }]] } });
    return;
  }
  if (!i.account) {
    await tg("sendMessage", { chat_id: chatId, text: T[l].noAccount, reply_markup: { inline_keyboard: [[playBtn(l)]] } });
    return;
  }
  const share = `https://t.me/share/url?url=${encodeURIComponent(i.link)}&text=${encodeURIComponent(T[l].shareText)}`;
  await tg("sendMessage", {
    chat_id: chatId, text: T[l].refMsg(i), parse_mode: "HTML", link_preview_options: { is_disabled: true },
    reply_markup: { inline_keyboard: [[{ text: T[l].share, url: share }], [playBtn(l)]] },
  });
}

/* ---------- support ---------- */
// what a message carries: its text (or caption) and whether it is a picture/file that can carry a caption
// deno-lint-ignore no-explicit-any
function body(m: any) {
  const media = !!(m.photo || m.video || m.document || m.animation || m.audio || m.voice);
  return { media, text: String(m.text || m.caption || ""), any: !!(m.text || media) };
}
const cut = (t: string, n: number) => (t.length > n ? t.slice(0, n - 1) + "…" : t);
async function openSupport(chatId: number, tgId: number, l: Lang) {
  const { error } = await db.rpc("support_open", { p_tg_id: tgId });
  if (error) throw error;
  await tg("sendMessage", { chat_id: chatId, text: T[l].supportPrompt, parse_mode: "HTML" });
}
const cardButtons = (id: number, tgId: number, withProfile: boolean) => {
  const rows: unknown[][] = [[{ text: "✍️ Ответить", callback_data: `sr:${id}` }, { text: "✅ Проблема решена", callback_data: `ss:${id}`, style: "success" }]];
  if (withProfile) rows.push([{ text: "👤 Открыть профиль", url: `tg://user?id=${tgId}` }]);
  return { inline_keyboard: rows };
};
// sends a message's content to `chatId` as one message: `head` + the text; a picture/file keeps the picture,
// with head + caption as its caption (Telegram allows 1024 characters there, 4096 in a text)
// deno-lint-ignore no-explicit-any
async function sendAs(chatId: number, m: any, head: string, markup?: unknown, replyTo?: number) {
  const b = body(m), extra: Record<string, unknown> = { parse_mode: "HTML" };
  if (markup) extra.reply_markup = markup;
  if (replyTo) extra.reply_parameters = { message_id: replyTo, allow_sending_without_reply: true };
  if (b.media) {
    const cap = head + (b.text ? "\n\n" + esc(cut(b.text, Math.max(0, 1000 - head.length))) : "");
    return await tg("copyMessage", { chat_id: chatId, from_chat_id: m.chat.id, message_id: m.message_id, caption: cap, ...extra });
  }
  return await tg("sendMessage", { chat_id: chatId, text: head + "\n\n" + esc(cut(b.text, 3800)), link_preview_options: { is_disabled: true }, ...extra });
}
// deno-lint-ignore no-explicit-any
async function newTicket(m: any, l: Lang) {
  const b = body(m);
  if (!b.any) return false;   // a sticker, a round video…: not a ticket (the support window stays open)
  const { data: st, error } = await db.rpc("support_take", { p_tg_id: m.from.id, p_group: m.media_group_id || null, p_lang: l });
  if (error) throw error;
  if (!st || st.state === "none") return false;
  if (st.state === "limited") { await tg("sendMessage", { chat_id: m.chat.id, text: T[l].supportLimited }); return true; }
  if (st.state === "album") {          // the other pictures of the same album go under the card
    let am = st.admin_msg;
    if (!am) { await new Promise((r) => setTimeout(r, 2000)); const { data: t } = await db.rpc("support_ticket", { p_ticket: st.id, p_admin_msg: null }); am = t && t.admin_msg; }
    await tg("copyMessage", { chat_id: SUPPORT_CHAT, from_chat_id: m.chat.id, message_id: m.message_id,
      ...(am ? { reply_parameters: { message_id: am, allow_sending_without_reply: true } } : {}) });
    return true;
  }
  const f = m.from, name = [f.first_name, f.last_name].filter(Boolean).join(" ") || "—";
  const head = `📨 <b>Обращение #${st.id}</b>\n\n` +
    `Имя: <a href="tg://user?id=${f.id}">${esc(name)}</a>\n` +
    `Юзернейм: ${f.username ? "@" + esc(f.username) : "нет"}\n` +
    `ID: <code>${f.id}</code>\n` +
    `Язык: ${l === "ru" ? "русский" : "английский"}` +
    (b.text ? "" : "\n\n(без текста)");
  // the profile button works through the id; if the player's privacy settings forbid it, the card goes without it
  let r = await sendAs(SUPPORT_CHAT, m, head, cardButtons(st.id, f.id, true));
  if (!r.ok) r = await sendAs(SUPPORT_CHAT, m, head, cardButtons(st.id, f.id, false));
  if (r.ok) await db.rpc("support_set_card", { p_ticket: st.id, p_admin_msg: r.result.message_id });
  await tg("sendMessage", { chat_id: m.chat.id, text: T[l].supportSent(st.id) });
  return true;
}
// the support account answers a ticket: by "Reply" + its next message, or by replying to the card
// deno-lint-ignore no-explicit-any
async function answerTicket(m: any, id: number) {
  const { data: t } = await db.rpc("support_ticket", { p_ticket: id, p_admin_msg: null });
  if (!t) return await tg("sendMessage", { chat_id: SUPPORT_CHAT, text: `Обращение #${id} не найдено.` });
  if (!body(m).any) return await tg("sendMessage", { chat_id: SUPPORT_CHAT, text: "Ответ должен быть текстом или картинкой/файлом с подписью." });
  const l: Lang = t.lang === "ru" ? "ru" : "en";
  const r = await sendAs(t.tg_id, m, T[l].supportAnswer(t.id));
  if (!r.ok) return await tg("sendMessage", { chat_id: SUPPORT_CHAT, text: `❌ Не удалось доставить ответ на #${t.id}: ${r.description || "ошибка Telegram"} (возможно, игрок заблокировал бота).` });
  await db.rpc("support_answered", { p_ticket: t.id });
  await tg("sendMessage", { chat_id: SUPPORT_CHAT, text: `✅ Ответ на обращение #${t.id} отправлен.`,
    reply_parameters: t.admin_msg ? { message_id: t.admin_msg, allow_sending_without_reply: true } : undefined });
}
// deno-lint-ignore no-explicit-any
async function onSupportButton(q: any) {
  const [kind, raw] = String(q.data).split(":"), id = Number(raw);
  if (kind === "sc") {
    await db.rpc("support_reply_cancel", { p_admin: SUPPORT_CHAT });
    return await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Отменено" });
  }
  if (!Number.isSafeInteger(id)) return await tg("answerCallbackQuery", { callback_query_id: q.id });
  if (kind === "sr") {
    await db.rpc("support_reply_set", { p_admin: SUPPORT_CHAT, p_ticket: id });
    await tg("answerCallbackQuery", { callback_query_id: q.id });
    return await tg("sendMessage", { chat_id: SUPPORT_CHAT,
      text: `✍️ Напишите ответ на обращение #${id} одним сообщением (можно картинку с подписью).\nИли просто ответьте (reply) на карточку обращения.`,
      reply_markup: { inline_keyboard: [[{ text: "Отмена", callback_data: "sc:0" }]] } });
  }
  if (kind === "ss") {
    const { data: t } = await db.rpc("support_solve", { p_ticket: id });
    if (!t) return await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Обращение не найдено" });
    if (!t.was_open) return await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Уже отмечено решённым" });
    await tg("answerCallbackQuery", { callback_query_id: q.id, text: "Отмечено решённым" });
    // the card keeps "Reply" (a follow-up is still possible) and shows that the ticket is solved
    await tg("editMessageReplyMarkup", { chat_id: SUPPORT_CHAT, message_id: q.message.message_id, reply_markup: { inline_keyboard: [
      [{ text: "✍️ Ответить", callback_data: `sr:${id}` }, { text: "✅ Решено", callback_data: `ss:${id}` }]] } });
    const l: Lang = t.lang === "ru" ? "ru" : "en";
    await tg("sendMessage", { chat_id: t.tg_id, text: T[l].supportSolved(t.id) });
  }
}

/* ---------- owner: statistics, profit, payouts ---------- */
const ton = (v: unknown) => {
  const n = Number(v) || 0;
  return (Math.round(n * 100) / 100).toLocaleString("ru-RU", { maximumFractionDigits: 2 });
};
async function houseWallet() {
  const { data } = await db.from("app_config").select("value").eq("key", "wallet").single();
  return (data && data.value) || {};
}
// the wallet's balance on chain, in nanoton (null when toncenter is unreachable)
async function chainNano(address: string) {
  try {
    const key = (Deno.env.get("TONCENTER_API_KEY") || "").trim();
    const r = await fetch(`https://toncenter.com/api/v2/getAddressBalance?address=${encodeURIComponent(address)}`,
      { headers: key ? { "X-API-Key": key } : {}, signal: AbortSignal.timeout(8000) });
    const j = await r.json();
    return j.ok ? BigInt(j.result) : null;
  } catch { return null; }
}
const kickGame = (action: string) => fetch(`${FN}/game`, { method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ action }), signal: AbortSignal.timeout(15000) }).catch(() => null);
// how much of the wallet is the owner's: the wallet minus the players' money minus the reserve
async function profitInfo() {
  await kickGame("deposits");          // fresh deposits first, so a just-arrived transfer is counted as the player's
  const w = await houseWallet();
  const { data: s, error } = await db.rpc("stats_summary");
  if (error) throw error;
  const nano = w.address ? await chainNano(String(w.address)) : null;
  const reserve = Number(w.owner_reserve ?? 1);
  const bal = nano === null ? null : Number(nano) / 1e9;
  const avail = bal === null ? null : Math.max(0, Math.floor((bal - Number(s.obligations) - reserve) * 100) / 100);
  return { s, w, nano, bal, reserve, avail, owner: String(w.owner_address || ""), paused: w.auto_payout === false };
}
async function sendStats(chatId: number, editId?: number) {
  const p = await profitInfo(), s = p.s, inc = s.income;
  const text = `📊 <b>Статистика CUTLINE</b>\n\n` +
    `<b>Чистая прибыль</b>: сегодня ${ton(s.profit.today)} · 7 дней ${ton(s.profit.week)} · всего <b>${ton(s.profit.total)} TON</b>\n` +
    `<i>комиссии раундов ${ton(inc.round_fees.total)} + комиссии выводов ${ton(inc.withdraw_fees.total)} − награды ${ton(inc.rewards.total)}</i>\n\n` +
    `👥 Игроки: ${s.players.total} (сегодня +${s.players.today}), играли сегодня ${s.players.active_today}, пополняли ${s.players.paying}\n` +
    `🎯 Раунды: сегодня ${s.rounds.today}, всего ${s.rounds.total} · поставлено сегодня ${ton(s.wagered.today)}, всего ${ton(s.wagered.total)} TON\n` +
    `⬇️ Пополнения: сегодня ${ton(s.deposits.today)}, всего ${ton(s.deposits.total)} TON\n` +
    `⬆️ Выводы игроков: сегодня ${ton(s.withdrawals.today)}, всего ${ton(s.withdrawals.paid_total)} TON` +
    (s.withdrawals.waiting_owner ? `\n🔔 Ждут вашего решения: <b>${s.withdrawals.waiting_owner}</b>` : "") +
    (s.deposits.unmatched ? `\n❓ Пополнений без кода: ${s.deposits.unmatched}` : "") + `\n\n` +
    `💰 Кошелёк: ${p.bal === null ? "не удалось узнать" : ton(p.bal) + " TON"} · деньги игроков ${ton(s.obligations)} · запас ${ton(p.reserve)}\n` +
    `Можно вывести прибыли: <b>${p.avail === null ? "—" : ton(p.avail) + " TON"}</b>\n` +
    `Выводы игрокам: ${p.paused ? "⛔ остановлены" : "✅ работают"}`;
  const rows: unknown[][] = [];
  if (p.avail !== null && p.avail >= 0.1) {
    rows.push([p.owner ? { text: `💸 Вывести прибыль (${ton(p.avail)} TON)`, callback_data: `po:${Math.round(p.avail * 100)}`, style: "success" }
                       : { text: "💸 Адрес для прибыли не задан", callback_data: "pa" }]);
  }
  rows.push([p.paused ? { text: "▶️ Включить выводы", callback_data: "resume", style: "success" } : { text: "⛔ Остановить выводы", callback_data: "stop", style: "danger" }]);
  rows.push([{ text: "🔄 Обновить", callback_data: "stats" }]);
  const body = { chat_id: chatId, text, parse_mode: "HTML", reply_markup: { inline_keyboard: rows } };
  if (editId) { const r = await tg("editMessageText", { ...body, message_id: editId }); if (r.ok) return; }
  await tg("sendMessage", body);
}
async function setPaused(paused: boolean) {
  const { error } = await db.rpc("admin_set_paused", { p_paused: paused });
  if (error) throw error;
  if (!paused) kickGame("payouts");
  await tg("sendMessage", { chat_id: ADMIN, parse_mode: "HTML", text: paused
    ? "⛔ <b>Выводы остановлены.</b> Заявки игроков принимаются и ждут. Включить: /resume"
    : "▶️ <b>Выводы снова работают.</b> Очередь пойдёт в течение минуты." });
}
const REASON: Record<string, string> = {
  review: "больше 40 TON — нужна ваша проверка",
  flagged: "баланс игрока не сходится с историей — проверьте",
  held: "автоматика поставила на удержание",
};
// deno-lint-ignore no-explicit-any
function wdCard(w: any) {
  const who = w.tg_id ? `<a href="tg://user?id=${w.tg_id}">${esc(String(w.name || "игрок"))}</a>` : "—";
  return `🔔 <b>Вывод #${w.id}</b> ждёт решения\nПричина: ${REASON[w.reason] || w.reason}` + (w.note ? ` (${esc(String(w.note))})` : "") + `\n\n` +
    `Игрок: ${who} · ${w.username ? "@" + esc(w.username) : "без юзернейма"} · ID <code>${w.tg_id || "—"}</code>\n` +
    `Сумма: <b>${ton(w.amount)} TON</b> (получит ${ton(w.payout)}, комиссия ${ton(w.fee)})\n` +
    `Адрес: <code>${esc(String(w.address))}</code>\n\n` +
    `История игрока: пополнил ${ton(w.deposited)} · поставил ${ton(w.wagered)} · выиграл ${ton(w.won)} · вывел раньше ${ton(w.withdrawn)}` +
    (w.audit_ok ? "" : "\n⚠️ Сверка баланса при заявке не прошла");
}
const wdButtons = (id: number) => ({ inline_keyboard: [[{ text: "✅ Одобрить", callback_data: `wa:${id}`, style: "success" }, { text: "❌ Отклонить", callback_data: `wr:${id}`, style: "danger" }]] });
async function notifyWithdrawals() {
  const { data: list, error } = await db.rpc("admin_wd_todo");
  if (error) throw error;
  for (const w of list || []) {
    const r = await tg("sendMessage", { chat_id: ADMIN, text: wdCard(w), parse_mode: "HTML", reply_markup: wdButtons(w.id) });
    if (r.ok) await db.rpc("admin_wd_mark", { p_id: w.id, p_reason: w.reason });
  }
  return (list || []).length;
}
// deno-lint-ignore no-explicit-any
async function onAdminButton(q: any) {
  const msgId = q.message.message_id, [kind, raw] = String(q.data).split(":"), id = Number(raw);
  const answer = (text?: string) => tg("answerCallbackQuery", { callback_query_id: q.id, ...(text ? { text } : {}) });
  const setButtons = (rows: unknown[][]) => tg("editMessageReplyMarkup", { chat_id: ADMIN, message_id: msgId, reply_markup: { inline_keyboard: rows } });
  const note = async (text: string) => {
    await setButtons([]);
    await tg("sendMessage", { chat_id: ADMIN, text, parse_mode: "HTML", reply_parameters: { message_id: msgId, allow_sending_without_reply: true } });
  };
  if (kind === "stats") { await answer(); return await sendStats(ADMIN, msgId); }
  if (kind === "stop" || kind === "resume") { await answer(); return await setPaused(kind === "stop"); }
  if (kind === "pa") {
    await answer();
    return await tg("sendMessage", { chat_id: ADMIN, parse_mode: "HTML", text: "Адрес для вывода прибыли задаётся один раз в Supabase → SQL Editor " +
      "(так его нельзя подменить, даже если кто-то получит доступ к вашему Telegram):\n\n<code>update public.app_config set value = value || " +
      "jsonb_build_object('owner_address', 'ВАШ_АДРЕС') where key = 'wallet';</code>" });
  }
  if (kind === "po") {           // step 1: show what will be sent and where
    const p = await profitInfo();
    if (!p.owner) { await answer("Адрес не задан"); return; }
    if (p.avail === null || p.avail < 0.1) { await answer("Сейчас нечего выводить"); return await sendStats(ADMIN, msgId); }
    await answer();
    return await tg("sendMessage", { chat_id: ADMIN, parse_mode: "HTML",
      text: `💸 Вывести <b>${ton(p.avail)} TON</b> прибыли на <code>${esc(p.owner)}</code>?\n\nДеньги игроков (${ton(p.s.obligations)} TON) и запас ${ton(p.reserve)} TON останутся в кошельке.`,
      reply_markup: { inline_keyboard: [[{ text: `Да, вывести ${ton(p.avail)} TON`, callback_data: `py:${Math.round(p.avail * 100)}`, style: "success" }, { text: "Отмена", callback_data: "pn" }]] } });
  }
  if (kind === "pn") { await answer("Отменено"); return await setButtons([]); }
  if (kind === "py") {           // step 2: the database checks everything again with a fresh wallet balance
    if (!Number.isSafeInteger(id) || id < 10) { await answer(); return; }
    await kickGame("deposits");
    const w = await houseWallet(), nano = w.address ? await chainNano(String(w.address)) : null;
    if (nano === null) { await answer("Не удалось узнать баланс кошелька, попробуйте позже"); return; }
    const { data: r, error } = await db.rpc("owner_payout_create", { p_amount: (id / 100).toFixed(2), p_chain_nano: nano.toString() });
    if (error) {
      const m = String(error.message || "");
      await answer(m.includes("owner_pending") ? "Предыдущий вывод прибыли ещё в пути" : m.includes("not_available") ? "Сумма больше доступной, обновите /stats" : "Не получилось: " + m);
      return await setButtons([]);
    }
    await answer("Отправляется");
    kickGame("payouts");
    return await note(`✅ Вывод прибыли #${r.id}: <b>${ton(r.amount)} TON</b> на <code>${esc(r.address)}</code> поставлен в очередь, придёт через минуту-две.`);
  }
  if (!Number.isSafeInteger(id)) return await answer();
  if (kind === "wa") { await answer(); return await setButtons([[{ text: `Да, одобрить #${id}`, callback_data: `wA:${id}`, style: "success" }, { text: "Назад", callback_data: `wb:${id}` }]]); }
  if (kind === "wr") { await answer(); return await setButtons([[{ text: `Да, отклонить #${id}`, callback_data: `wR:${id}`, style: "danger" }, { text: "Назад", callback_data: `wb:${id}` }]]); }
  if (kind === "wb") { await answer(); return await setButtons(wdButtons(id).inline_keyboard); }
  if (kind === "wA") {
    const { error } = await db.rpc("admin_wd_approve", { p_id: id });
    if (error) { await answer("Не получилось: " + error.message); return await setButtons([]); }
    await answer("Одобрено");
    kickGame("payouts");
    return await note(`✅ Вывод #${id} одобрен и отправляется.`);
  }
  if (kind === "wR") {
    const { data, error } = await db.rpc("admin_wd_reject", { p_id: id });
    if (error) { await answer("Не получилось: " + error.message); return await setButtons([]); }
    await answer("Отклонено");
    return await note(`❌ Вывод #${id} отклонён${String(data).includes("refunded") ? ", деньги вернулись игроку на баланс" : ""}.`);
  }
  await answer();
}

// deno-lint-ignore no-explicit-any
async function onUpdate(u: any) {
  // Telegram may deliver the same update again (e.g. after a slow answer): handle each one once
  if (Number.isSafeInteger(u.update_id)) {
    const { data: seen, error } = await db.rpc("bot_seen", { p_update_id: u.update_id });
    if (!error && seen === true) return;
  }
  if (u.message && u.message.chat && u.message.chat.type === "private" && u.message.from) {
    const m = u.message, l = langOf(m.from.language_code);
    const words = String(m.text || "").trim().split(/\s+/), cmd = words[0].split("@")[0].toLowerCase();
    if (cmd === "/ref") return await sendRef(m.chat.id, m.from.id, l);
    if (cmd === "/support") return await openSupport(m.chat.id, m.from.id, l);
    if (m.chat.id === ADMIN && m.from.id === ADMIN) {
      if (cmd === "/stats") return await sendStats(ADMIN);
      if (cmd === "/stop") return await setPaused(true);
      if (cmd === "/resume") return await setPaused(false);
    }
    if (m.chat.id === SUPPORT_CHAT && cmd !== "/start") {
      // the support account: a reply to a ticket card, or the message after "Reply"
      const r = m.reply_to_message;
      if (r && r.from && r.from.is_bot) {
        const { data: t } = await db.rpc("support_ticket", { p_ticket: null, p_admin_msg: r.message_id });
        if (t) return await answerTicket(m, t.id);
      }
      const { data: pending } = await db.rpc("support_reply_take", { p_admin: SUPPORT_CHAT });
      if (pending) return await answerTicket(m, Number(pending));
    }
    if (cmd === "/start") {
      await db.rpc("support_close", { p_tg_id: m.from.id });
      if (m.chat.id === SUPPORT_CHAT) await db.rpc("support_reply_cancel", { p_admin: SUPPORT_CHAT });
      // the "Support" button inside the game opens t.me/cutline_game?start=support
      if (words[1] === "support") return await openSupport(m.chat.id, m.from.id, l);
    } else if (await newTicket(m, l)) return;
    const param = cmd === "/start" && /^r_[A-Za-z0-9]{6,16}$/.test(words[1] || "") ? words[1] : "";
    // /start and anything else typed in the chat: the welcome menu
    const name = [m.from.first_name, m.from.last_name].filter(Boolean).join(" ") || (l === "ru" ? "игрок" : "player");
    return await sendStart(m.chat.id, l, name, param);
  }
  if (u.callback_query && u.callback_query.from) {
    const q = u.callback_query, l = langOf(q.from.language_code);
    // owner buttons: only the owner, only in the owner's chat with the bot
    if (/^(stats|stop|resume|pa|pn|po:\d+|py:\d+|w[arbARB]:\d+)$/.test(String(q.data || ""))) {
      if (q.from.id === ADMIN && q.message && q.message.chat && q.message.chat.id === ADMIN) return await onAdminButton(q);
      return await tg("answerCallbackQuery", { callback_query_id: q.id });
    }
    // ticket buttons: only the support account, only in its chat with the bot
    if (/^(sr|ss|sc):/.test(String(q.data || ""))) {
      if (q.from.id === SUPPORT_CHAT && q.message && q.message.chat && q.message.chat.id === SUPPORT_CHAT) return await onSupportButton(q);
      return await tg("answerCallbackQuery", { callback_query_id: q.id });
    }
    await tg("answerCallbackQuery", { callback_query_id: q.id });
    if (!q.message || !q.message.chat || q.message.chat.type !== "private") return;
    if (q.data === "ref") await sendRef(q.message.chat.id, q.from.id, l);
    if (q.data === "support") await openSupport(q.message.chat.id, q.from.id, l);
  }
}

async function setup(selfUrl: string) {
  const { data: ok } = await db.rpc("rate_hit", { p_key: "botsetup", p_max: 3, p_secs: 60 });
  if (ok === false) return { error: "rate_limited" };
  const info = await tg("getWebhookInfo", {});
  const cur = (info.result && info.result.url) || "";
  if (cur && cur !== selfUrl) return { ok: false, error: "other_webhook_set", url: cur };
  const set = await tg("setWebhook", {
    url: selfUrl, secret_token: await hookSecret(), allowed_updates: ["message", "callback_query"], drop_pending_updates: false,
  });
  await tg("setMyCommands", { commands: [{ command: "start", description: "Главное меню" }, { command: "ref", description: "Реферальная программа" }, { command: "support", description: "Поддержка" }], language_code: "ru" });
  await tg("setMyCommands", { commands: [{ command: "start", description: "Main menu" }, { command: "ref", description: "Invite friends" }, { command: "support", description: "Support" }] });
  // the owner also sees the owner commands in the menu
  await tg("setMyCommands", { scope: { type: "chat", chat_id: ADMIN }, language_code: "ru", commands: [{ command: "stats", description: "Статистика и прибыль" },
    { command: "stop", description: "Остановить выводы" }, { command: "resume", description: "Включить выводы" },
    { command: "start", description: "Главное меню" }, { command: "support", description: "Поддержка" }] });
  return { ok: !!set.ok, url: selfUrl };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "GET" && url.searchParams.get("setup") === "1") {
    const self = `${Deno.env.get("SUPABASE_URL")}/functions/v1/bot`;
    try { return Response.json(await setup(self)); } catch (e) { return Response.json({ error: String(e) }, { status: 500 }); }
  }
  if (req.method !== "POST") return new Response("ok");
  // the database asks the bot to tell the owner about withdrawals that wait for a decision (it sends only to the owner)
  if (url.searchParams.get("tick") === "1") {
    const { data: ok } = await db.rpc("rate_hit", { p_key: "bottick", p_max: 30, p_secs: 60 });
    if (ok === false) return new Response("busy", { status: 429 });
    try { return Response.json({ sent: await notifyWithdrawals() }); } catch (e) { console.error("tick", e); return new Response("error", { status: 500 }); }
  }
  if (!sameStr(req.headers.get("x-telegram-bot-api-secret-token") || "", await hookSecret())) return new Response("forbidden", { status: 403 });
  try { await onUpdate(await req.json()); } catch (e) { console.error(e); }
  return new Response("ok");     // always 200, so Telegram does not resend the same update forever
});
