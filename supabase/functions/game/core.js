/* CUTLINE core: deterministic game logic shared by the browser and the server (Supabase edge function).
   Same inputs → same field, same cuts, same winner. Plain script: exposes globalThis.CutlineCore. */
(function(){
'use strict';
function mulberry32(a){
  return function(){
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
/* string → 32-bit seed (xmur3); used to derive independent generators from the round seed */
function xmur3(str){
  let h = 1779033703 ^ str.length;
  for (let i = 0; i < str.length; i++){ h = Math.imul(h ^ str.charCodeAt(i), 3432918353); h = h << 13 | h >>> 19; }
  h = Math.imul(h ^ h >>> 16, 2246822507); h = Math.imul(h ^ h >>> 13, 3266489909);
  return (h ^= h >>> 16) >>> 0;
}
const layoutRngOf = seed => mulberry32(xmur3('layout:' + seed));
const cutRngOf = (seed, entropy) => mulberry32(xmur3('cuts:' + seed + ':' + entropy));
/* ---------- geometry (world = unit square, y down) ---------- */
function signedArea(p){
  let a = 0;
  for (let i = 0, j = p.length - 1; i < p.length; j = i++) a += p[j][0]*p[i][1] - p[i][0]*p[j][1];
  return a / 2;
}
function polyArea(p){ return p && p.length >= 3 ? Math.abs(signedArea(p)) : 0; }
function polyCentroid(p){
  let a = 0, cx = 0, cy = 0;
  for (let i = 0, j = p.length - 1; i < p.length; j = i++){
    const f = p[j][0]*p[i][1] - p[i][0]*p[j][1];
    a += f; cx += (p[j][0] + p[i][0]) * f; cy += (p[j][1] + p[i][1]) * f;
  }
  if (Math.abs(a) < 1e-30){
    let x = 0, y = 0; for (const q of p){ x += q[0]; y += q[1]; }
    return [x / p.length, y / p.length];
  }
  a *= 0.5;
  return [cx / (6 * a), cy / (6 * a)];
}
function clipPlane(p, nx, ny, d){ // keep nx*x + ny*y <= d
  const out = []; const n = p.length;
  for (let i = 0; i < n; i++){
    const A = p[i], B = p[(i + 1) % n];
    const da = nx*A[0] + ny*A[1] - d, db = nx*B[0] + ny*B[1] - d;
    if (da <= 0) out.push(A);
    if ((da <= 0) !== (db <= 0)){
      const t = da / (da - db);
      out.push([A[0] + (B[0] - A[0]) * t, A[1] + (B[1] - A[1]) * t]);
    }
  }
  return out;
}
/* intersection of two convex polygons: clip `subject` by every edge of `clip` */
function clipConvex(subject, clip){
  if (!subject || !clip || subject.length < 3 || clip.length < 3) return [];
  const sg = signedArea(clip) >= 0 ? 1 : -1;
  let q = subject;
  for (let i = 0; i < clip.length; i++){
    const a = clip[i], b = clip[(i + 1) % clip.length];
    const ex = b[0] - a[0], ey = b[1] - a[1];
    if (ex === 0 && ey === 0) continue;
    // keep the interior side: sg * cross(b - a, p - a) >= 0
    q = clipPlane(q, sg * ey, -sg * ex, sg * (ey * a[0] - ex * a[1]));
    if (q.length < 3) return [];
  }
  return q;
}
/* cut a convex polygon by a line with normal angle th so that the first part gets exactly fraction f of the area */
function splitByFraction(poly, th, f){
  if (!poly || poly.length < 3) return [[], []];
  if (f <= 0) return [[], poly];
  if (f >= 1) return [poly, []];
  const nx = Math.cos(th), ny = Math.sin(th);
  let lo = Infinity, hi = -Infinity;
  for (const q of poly){ const v = nx*q[0] + ny*q[1]; if (v < lo) lo = v; if (v > hi) hi = v; }
  const target = f * polyArea(poly);
  for (let i = 0; i < 44; i++){
    const mid = (lo + hi) / 2;
    if (polyArea(clipPlane(poly, nx, ny, mid)) < target) lo = mid; else hi = mid;
  }
  const d = (lo + hi) / 2;
  return [clipPlane(poly, nx, ny, d), clipPlane(poly, -nx, -ny, -d)];
}
function bbox(p){
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const q of p){ if (q[0] < x0) x0 = q[0]; if (q[0] > x1) x1 = q[0]; if (q[1] < y0) y0 = q[1]; if (q[1] > y1) y1 = q[1]; }
  return {x0, y0, x1, y1};
}
function bbSize(p){ const b = bbox(p); return Math.max(b.x1 - b.x0, b.y1 - b.y0); }
function inside(p, x, y){
  let sgn = 0;
  for (let i = 0; i < p.length; i++){
    const a = p[i], b = p[(i + 1) % p.length];
    const c = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
    if (c === 0) continue;
    const s = c > 0 ? 1 : -1;
    if (!sgn) sgn = s; else if (s !== sgn) return false;
  }
  return true;
}
function randomPointIn(p, rnd){
  const b = bbox(p);
  for (let k = 0; k < 60; k++){
    const x = b.x0 + rnd() * (b.x1 - b.x0), y = b.y0 + rnd() * (b.y1 - b.y0);
    if (inside(p, x, y)) return [x, y];
  }
  return polyCentroid(p);
}
const UNIT = [[0,0],[1,0],[1,1],[0,1]];

/* Territory layout: a binary tree of slanted cuts. Each node splits its polygon at angle th so the two
   sides get areas exactly proportional to their stakes. A new player is inserted by splitting an existing
   leaf with weight 0 and growing it, so the field morphs smoothly instead of reshuffling. */
function treeWeight(n, key){ return n.leaf ? Math.max(0, n.leaf[key]) : treeWeight(n.a, key) + treeWeight(n.b, key); }
function layoutTree(n, poly, key, out){
  if (n.leaf){ n.leaf[out] = poly; return; }
  const wa = treeWeight(n.a, key), wb = treeWeight(n.b, key), tot = wa + wb;
  const [pa, pb] = splitByFraction(poly, n.th, tot > 0 ? wa / tot : .5);
  layoutTree(n.a, pa, key, out); layoutTree(n.b, pb, key, out);
}
function leaves(n, acc){ acc = acc || []; if (!n) return acc; if (n.leaf) acc.push(n); else { leaves(n.a, acc); leaves(n.b, acc); } return acc; }
/* Deterministic insertion: depends only on the join order, the stakes at that moment and the round's layout
   generator (derived from the public seed hash), so anyone can rebuild the exact field later. */
function insertLeafInto(root, p, rng){
  if (!root) return {leaf: p};
  layoutTree(root, UNIT, 'stake', 'tpoly');
  // split one of the three biggest territories (weighted to the biggest): big stakes get carved into wedges
  const ls = leaves(root).map(l => ({l, a: polyArea(l.leaf.tpoly)})).sort((x, y) => (y.a - x.a) || (x.l.leaf.id < y.l.leaf.id ? -1 : 1));
  const top = ls.slice(0, 3);
  let u = rng() * top.reduce((s, x) => s + x.a + 1e-9, 0), host = top[0];
  for (const x of top){ u -= x.a + 1e-9; if (u <= 0){ host = x; break; } }
  const node = host.l, hp = node.leaf.tpoly && node.leaf.tpoly.length >= 3 ? node.leaf.tpoly : UNIT;
  const b = bbox(hp), wide = (b.x1 - b.x0) >= (b.y1 - b.y0);
  // mostly cut across the long side, but tilted; sometimes a free diagonal for corner wedges
  const r1 = rng(), r2 = rng(), r3 = rng();
  const th = r1 < .3 ? r2 * Math.PI : (wide ? 0 : Math.PI / 2) + (r2 - .5) * 1.3;
  const fresh = {leaf: p}, old = {leaf: node.leaf};
  delete node.leaf;
  if (r3 < .5){ node.a = fresh; node.b = old; } else { node.a = old; node.b = fresh; }
  node.th = th;
  return root;
}

/* ---------- modifiers ---------- */
const MODS = {
  classic: {name: 'Классика',    desc: 'Один прямой разрез за ход',                      w: 40,
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M5 19 19 5"/></svg>'},
  cross:   {name: 'Крест',       desc: 'Два разреза крест-накрест, устоит одна четверть', w: 15,
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M5 5l14 14M19 5 5 19"/></svg>'},
  double:  {name: 'Двойной нож', desc: 'Два параллельных лезвия, устоит одна из трёх полос', w: 15,
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M3 15 15 3M9 21 21 9"/></svg>'},
  circle:  {name: 'Круглый нож', desc: 'Вырубка кругом: устоит круг или всё вокруг него', w: 15,
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="12" cy="12" r="7.5"/></svg>'},
  shuffle: {name: 'Перетасовка', desc: 'После каждого разреза территории перемешиваются', w: 15,
    icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h3.5c4 0 5 10 9 10H20M17 14l3 3-3 3M4 17h3.5c1.6 0 2.7-1.6 3.6-3.5M14 8.6c.8-1 1.7-1.6 2.9-1.6H20M17 4l3 3-3 3"/></svg>'}
};
const MOD_KEYS = Object.keys(MODS);
/* the modifier is derived from the committed seed and the closing entropy, so it is announced only in preparation
   and nobody (operator included) could know it while bets were open */
function pickMod(seed, entropy){
  const u = mulberry32(xmur3('mod:' + seed + ':' + entropy))();
  let tot = 0; for (const k of MOD_KEYS) tot += MODS[k].w;
  let x = u * tot;
  for (const k of MOD_KEYS){ x -= MODS[k].w; if (x < 0) return k; }
  return 'classic';
}

/* ---------- regions: a convex polygon minus disjoint round holes ---------- */
const R = poly => ({poly, holes: []});
function circlePoly(c, r, n){
  n = n || 48; const out = [];
  for (let i = 0; i < n; i++){ const a = i / n * Math.PI * 2; out.push([c[0] + Math.cos(a) * r, c[1] + Math.sin(a) * r]); }
  return out;
}
function regionAreaWith(rg, T){          // area of (region ∩ convex T)
  const q = T ? clipConvex(rg.poly, T) : rg.poly;
  if (q.length < 3) return 0;
  let a = polyArea(q);
  for (const h of rg.holes){ const z = clipConvex(q, h.poly); if (z.length >= 3) a -= polyArea(z); }
  return Math.max(0, a);
}
const regionArea = rg => regionAreaWith(rg, null);
function insideRegion(rg, x, y){
  if (!inside(rg.poly, x, y)) return false;
  for (const h of rg.holes) if (inside(h.poly, x, y)) return false;
  return true;
}
function randomPointInRegion(rg, rnd){
  const b = bbox(rg.poly);
  for (let k = 0; k < 80; k++){
    const x = b.x0 + rnd() * (b.x1 - b.x0), y = b.y0 + rnd() * (b.y1 - b.y0);
    if (insideRegion(rg, x, y)) return [x, y];
  }
  return polyCentroid(rg.poly);
}
function cutRegion(rg, nx, ny, d){
  const poly = clipPlane(rg.poly, nx, ny, d);
  return {poly, holes: poly.length >= 3 ? rg.holes.filter(h => clipConvex(poly, h.poly).length >= 3) : []};
}

const SIGNS = [[1, 1], [1, -1], [-1, -1], [-1, 1]];
/* the parts a cut produces, rebuilt from its geometry alone (used by the server, the replay and the animation) */
function buildParts(rg, g){
  if (g.kind === 'circle'){
    const D = circlePoly(g.c, g.r);
    const swallowed = rg.holes.filter(h => Math.hypot(g.c[0] - h.c[0], g.c[1] - h.c[1]) + h.r <= g.r);
    const kept = rg.holes.filter(h => !swallowed.includes(h));
    return [{poly: clipConvex(rg.poly, D), holes: swallowed}, {poly: rg.poly, holes: kept.concat([{poly: D, c: g.c, r: g.r}])}];
  }
  const nx = Math.cos(g.th), ny = Math.sin(g.th);
  if (g.kind === 'cross'){
    const d = nx * g.px + ny * g.py, mx = -ny, my = nx, d2 = mx * g.px + my * g.py;
    return SIGNS.map(([a, b]) => cutRegion(cutRegion(rg, a * nx, a * ny, a * d), b * mx, b * my, b * d2));
  }
  if (g.kind === 'double') return [cutRegion(rg, nx, ny, g.lo), cutRegion(cutRegion(rg, -nx, -ny, -g.lo), nx, ny, g.hi), cutRegion(rg, -nx, -ny, -g.hi)];
  const d = nx * g.px + ny * g.py;
  return [cutRegion(rg, nx, ny, d), cutRegion(rg, -nx, -ny, -d)];
}
const geomOf = p => p.kind === 'circle' ? {kind: 'circle', c: p.c, r: p.r}
  : p.kind === 'double' ? {kind: 'double', th: p.th, px: p.px, py: p.py, lo: p.lo, hi: p.hi}
  : {kind: p.kind, th: p.th, px: p.px, py: p.py};
function withParts(rg, g){
  const parts = buildParts(rg, g);
  if (parts.some(q => q.poly.length < 3)) return null;
  return Object.assign({}, g, {parts, signs: g.kind === 'cross' ? SIGNS : undefined});
}
/* candidate cut of each kind */
function makeCandidate(rg, rng, mod, size){
  if (mod === 'circle' && rg.holes.length < 3){   // with many holes a straight cut tidies the piece up
    const c = randomPointInRegion(rg, rng);
    const target = .32 + rng() * .3;
    let r = Math.sqrt(target * regionArea(rg) / Math.PI);
    // an old hole may end up fully inside the new disc or fully outside it, never across its rim
    for (let pass = 0; pass < 6; pass++){
      let clean = true;
      for (const h of rg.holes){
        const dist = Math.hypot(c[0] - h.c[0], c[1] - h.c[1]);
        if (dist + h.r <= r || dist - h.r >= r) continue;
        clean = false;
        r = dist + h.r <= r * 1.4 ? (dist + h.r) * 1.002 : (dist - h.r) * .97;
      }
      if (clean) break;
      if (pass === 5) return null;
    }
    if (!(r > size * .04)) return null;
    return withParts(rg, {kind: 'circle', c, r});
  }
  const pt = randomPointInRegion(rg, rng), th = rng() * Math.PI;
  if (mod === 'cross') return withParts(rg, {kind: 'cross', th, px: pt[0], py: pt[1]});
  if (mod === 'double'){
    const nx = Math.cos(th), ny = Math.sin(th), d = nx * pt[0] + ny * pt[1];
    const gap = size * (.16 + rng() * .26) * (rng() < .5 ? -1 : 1);
    return withParts(rg, {kind: 'double', th, px: pt[0], py: pt[1], lo: Math.min(d, d + gap), hi: Math.max(d, d + gap)});
  }
  return withParts(rg, {kind: 'line', th, px: pt[0], py: pt[1]});
}
/* One step. The director may pick ANY cut for drama; fairness comes only from the keep-lottery at the end:
   each part survives with probability equal to its share of the area. */
function planStep(rg, alive, rng, mod){
  const A0 = regionArea(rg), size = bbSize(rg.poly);
  const ownersIn = part => { const s = new Set(); for (const p of alive) if (regionAreaWith(part, p.poly) / A0 > 1e-7) s.add(p.id); return s; };
  let best = null;
  for (let k = 0; k < 12; k++){
    const cand = makeCandidate(rg, rng, mod === 'shuffle' ? 'classic' : mod, size);
    if (!cand) continue;
    const fr = cand.parts.map(q => regionArea(q) / A0);
    if (fr.some(f => !(f > 1e-9))) continue;
    const cnt = new Map();
    cand.parts.map(ownersIn).forEach(st => st.forEach(id => cnt.set(id, (cnt.get(id) || 0) + 1)));
    let excl = 0; cnt.forEach(v => { if (v === 1) excl++; });
    const mn = Math.min(...fr), floor = cand.parts.length === 2 ? .12 : .05;
    const score = mn * (cand.parts.length === 2 ? 1 : 2.2) + .22 * Math.min(excl, 3) + (mn < floor ? -1 : 0) + rng() * .04;
    if (!best || score > best.score){ best = cand; best.fracs = fr; best.score = score; }
  }
  if (!best){ // safety net: a plain horizontal cut through the middle
    const c = randomPointInRegion(rg, rng);
    best = withParts(rg, {kind: 'line', th: Math.PI / 2, px: c[0], py: c[1]}) || {kind: 'line', th: Math.PI / 2, px: c[0], py: c[1], parts: [rg, R([])]};
    best.fracs = best.parts.map(q => regionArea(q) / A0);
  }
  const tot = best.fracs.reduce((a, b) => a + b, 0);
  let u = rng(), acc = 0; best.keep = best.parts.length - 1;
  for (let i = 0; i < best.parts.length; i++){ acc += best.fracs[i] / tot; if (u < acc){ best.keep = i; break; } }
  best.fracs = best.fracs.map(f => f / tot);
  return best;
}
/* Перетасовка: new territories inside the kept piece, each with exactly the area it had (chances unchanged) */
function shuffleLayout(poly, items, rng){
  const out = {};
  (function rec(pg, list){
    if (list.length === 1){ out[list[0].id] = pg; return; }
    const arr = list.slice();
    for (let i = arr.length - 1; i > 0; i--){ const j = Math.floor(rng() * (i + 1)); [arr[i], arr[j]] = [arr[j], arr[i]]; }
    const k = 1 + Math.floor(rng() * (arr.length - 1));
    const A = arr.slice(0, k), B = arr.slice(k);
    const wa = A.reduce((s, x) => s + x.w, 0), wb = B.reduce((s, x) => s + x.w, 0);
    const b = bbox(pg), wide = (b.x1 - b.x0) >= (b.y1 - b.y0);
    const th = (wide ? 0 : Math.PI / 2) + (rng() - .5) * 1.2;
    const [pa, pb] = splitByFraction(pg, th, wa / (wa + wb));
    rec(pa, A); rec(pb, B);
  })(poly, items);
  return out;
}
/* Pure replay of a round: same inputs → same cuts and same winner, in the game and in the verifier.
   Rule version v (stored in result.v):
     1 — after 26 cuts (or when only slivers are left) the winner is drawn by area;
     2 — at most 25 cuts: if several owners are still on the field after the 25th, the biggest territory wins
         (end: 'limit'); when only slivers are left besides one owner, that owner wins. */
const CUT_LIMIT = 25;
function simulateRound(parts0, rng, mod, v){
  v = v || 2;
  const polys = new Map(parts0.map(p => [p.id, p.poly]));
  const alive = new Set(parts0.map(p => p.id));
  let rg = R(UNIT), cuts = 0, winner = null, lottery = false, end = null;
  const steps = [];
  while (!winner){
    const plan = planStep(rg, [...alive].map(id => ({id, poly: polys.get(id)})), rng, mod);
    rg = plan.parts[plan.keep];
    cuts++;
    const A = regionArea(rg), ch = {};
    let sum = 0, bestId = null, bestF = -1;
    for (const id of [...alive]){
      const f = A > 0 ? regionAreaWith(rg, polys.get(id)) / A : 0;
      if (f > bestF){ bestF = f; bestId = id; }
      if (f < 1e-9) alive.delete(id); else { ch[id] = f; sum += f; }
    }
    if (!alive.size){ alive.add(bestId); ch[bestId] = 1; sum = 1; } // numeric safety net
    for (const k in ch) ch[k] /= sum;
    const ids = [...alive];
    if (ids.length === 1) winner = ids[0];
    else {
      const mx = Math.max(...ids.map(id => ch[id]));
      if (v >= 2 && (mx > 0.9995 || cuts >= CUT_LIMIT)){
        let best = ids[0];
        for (const id of ids) if (ch[id] > ch[best]) best = id;
        winner = best;
        if (mx > 0.9995 && cuts < CUT_LIMIT){ for (const id of ids) if (id !== winner){ alive.delete(id); delete ch[id]; } ch[winner] = 1; }
        else end = 'limit';                      // everyone keeps their share on screen; the verdict shows them
      } else if (v < 2 && (mx > 0.9995 || cuts >= 26)){
        // leftover slivers: settle by the same area lottery
        let u = rng(); winner = ids[ids.length - 1];
        for (const id of ids){ u -= ch[id]; if (u <= 0){ winner = id; break; } }
        lottery = true;
        for (const id of ids) if (id !== winner){ alive.delete(id); delete ch[id]; }
        ch[winner] = 1;
      }
    }
    let shuffled = null;
    if (!winner && mod === 'shuffle'){
      shuffled = shuffleLayout(rg.poly, ids.map(id => ({id, w: ch[id]})), rng);
      for (const id of ids) polys.set(id, shuffled[id]);
    }
    steps.push({plan, region: rg, chances: ch, winner, shuffled, end});
  }
  return {steps, winner, lottery, cuts, end};
}


/* ---------- shared helpers for server, client and verifier ---------- */
const r2 = v => Math.round(v * 100) / 100;
/* field from the public bet log: join order decides the cut tree, the layout generator comes from the public seed hash */
function buildField(bets, seedHash){
  const rng = layoutRngOf(seedHash), byId = new Map(), order = [];
  let root = null;
  for (const b of bets){
    let p = byId.get(b.user_id);
    if (!p){ p = {id: b.user_id, stake: 0}; byId.set(b.user_id, p); order.push(p); root = insertLeafInto(root, p, rng); }
    p.stake = r2(p.stake + Number(b.amount));
  }
  if (root) layoutTree(root, UNIT, 'stake', 'poly');
  return {root, players: order};
}
const STAGE_BASE = {intro: 900, aim: 950, lock: 200, split: 260, hold: 1050, fall: 800, cam: 650, shuffle: 1300, verdict: 3200};
/* stage length: slower for a duel, a little faster once a round gets long */
function stageMs(st, cutsDone, duel){
  let m = 1;
  if (duel && (st === 'aim' || st === 'hold')) m = 1.7;
  if (cutsDone > 4 && st !== 'intro' && st !== 'verdict') m *= Math.max(.6, 1 - .06 * (cutsDone - 4));
  return STAGE_BASE[st] * m;
}
/* the whole animation as a list of stages, so the server knows when the round ends and late viewers can seek */
function timeline(steps, nPlayers){
  const list = []; let t = 0;
  const push = (step, st, cutsDone, duel) => { const dur = stageMs(st, cutsDone, duel); list.push({step, st, dur, start: t}); t += dur; };
  push(0, 'intro', 0, false);
  steps.forEach((s, i) => {
    const alive = i === 0 ? nPlayers : Object.keys(steps[i - 1].chances).length, duel = alive === 2;
    for (const st of ['aim', 'lock', 'split', 'hold']) push(i, st, i, duel);
    for (const st of ['fall', 'cam']) push(i, st, i + 1, duel);
    if (!s.winner && s.shuffled) push(i, 'shuffle', i + 1, duel);
    if (s.end === 'limit') push(i, 'verdict', i + 1, false);
  });
  return {list, total: Math.ceil(t)};
}
/* server side: everything about a round, from public data + the secret seed + the closing entropy */
function computeRound(bets, seedHash, seed, entropy, forcedMod, v){
  v = v || 2;
  const {players} = buildField(bets, seedHash);
  const mod = forcedMod && MODS[forcedMod] ? forcedMod : pickMod(seed, entropy);
  const sim = simulateRound(players.map(p => ({id: p.id, poly: p.poly})), cutRngOf(seed, entropy), mod, v);
  const field = {}; for (const p of players) field[p.id] = p.poly;
  const steps = sim.steps.map(s => {
    const o = {g: geomOf(s.plan), keep: s.plan.keep, fracs: s.plan.fracs, chances: s.chances, winner: s.winner, shuffled: s.shuffled};
    if (s.end) o.end = s.end;
    return o;
  });
  const result = {v, field, order: players.map(p => p.id), steps};
  return {mod, modForced: !!(forcedMod && MODS[forcedMod]), winner: sim.winner, cuts: sim.cuts, lottery: sim.lottery, end: sim.end, result, anim: timeline(steps, players.length).total};
}
/* client side: turn the stored result back into regions for the animation */
function expandResult(result){
  let rg = R(UNIT);
  const steps = result.steps.map(s => {
    const plan = Object.assign({}, s.g, {parts: buildParts(rg, s.g), keep: s.keep, fracs: s.fracs, signs: s.g.kind === 'cross' ? SIGNS : undefined});
    rg = plan.parts[plan.keep];
    return {plan, region: rg, chances: s.chances, winner: s.winner, shuffled: s.shuffled, end: s.end || null};
  });
  return {steps};
}

globalThis.CutlineCore = {
  mulberry32, xmur3, layoutRngOf, cutRngOf, UNIT, R, r2,
  signedArea, polyArea, polyCentroid, clipPlane, clipConvex, splitByFraction, bbox, bbSize, inside, randomPointIn,
  treeWeight, layoutTree, leaves, insertLeafInto,
  MODS, MOD_KEYS, pickMod, circlePoly, regionAreaWith, regionArea, insideRegion, randomPointInRegion, cutRegion,
  SIGNS, buildParts, geomOf, makeCandidate, planStep, shuffleLayout, simulateRound,
  buildField, STAGE_BASE, stageMs, timeline, computeRound, expandResult, CUT_LIMIT
};
})();
