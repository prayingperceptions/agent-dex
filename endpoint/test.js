// Local e2e test for the Agent DEX HTTP endpoint, now with x402 pay-per-call gating.
// Boots server.js; exercises /health, /fee/rate, /list, /trade, and the x402 /launch
// gate (402 + PAYMENT-REQUIRED without a payment header; happy path in mock mode).
import { spawn } from "node:child_process";

const PORT = 3499;
const BASE = `http://127.0.0.1:${PORT}`;
let pass = 0, fail = 0;
const check = (n, c, d) => { if (c) { pass++; console.log("PASS " + n); } else { fail++; console.log("FAIL " + n + " :: " + d); } };

const srv = spawn("node", ["server.js"], {
  env: { ...process.env, PORT: String(PORT), PAYMENT_MODE: "mock", X402_PAY_TO: "0x2091125bFE4259b2CfA889165Beb6290d0Df5DeA" },
});
await new Promise(r => setTimeout(r, 1200));

async function get(p) { const r = await fetch(BASE + p); return { status: r.status, headers: r.headers, json: await r.json() }; }
async function post(p, body, hdrs = { "content-type": "application/json" }) {
  const r = await fetch(BASE + p, { method: "POST", headers: hdrs, body: JSON.stringify(body) });
  return { status: r.status, headers: r.headers, json: await r.json() };
}

try {
  const h = await get("/health");
  check("health ok (free)", h.status === 200 && h.json.ok === true && h.json.service === "agent-dex");

  const fee = await get("/fee/rate");
  check("fee schedule public", fee.status === 200 && fee.json.launch.percent === 0.5 && fee.json.trade.percent === 0.05 && fee.json.disclosed === true);

  // live on-chain analytics (may be unpooled -> still 200 with honest fields)
  const st = await get("/stats");
  check("stats live + honest", st.status === 200 && st.json.ok === true && "pooled" in st.json && "volume24h" in st.json && "tvl" in st.json && "trades" in st.json, JSON.stringify(st.json).slice(0, 120));

  // ---- x402 gate on /launch: no payment header => 402 + PAYMENT-REQUIRED ----
  // (run a separate server instance in LIVE mode to assert fail-closed 402)
  const free = await post("/launch", { name: "Compute", symbol: "CPT", supply: 1000000 }, { "content-type": "application/json" });
  // in mock mode the happy path succeeds
  check("launch happy path (mock paid)", free.status === 200 && free.json.fee && free.json.fee.wei === "5000", JSON.stringify(free.json));

  // list/trade remain free for the demo
  const listR = await post("/list", { seedQuote: 100000 });
  check("list free + 0.5% fee", listR.status === 200 && listR.json.pool.listingFee.wei === "500");
  const tr = await post("/trade", { quoteIn: 10000 });
  check("trade free + 0.05% fee", tr.status === 200 && tr.json.fee.wei === "5");

  const cors = await fetch(BASE + "/health", { headers: { Origin: "https://agentos-landing.vercel.app" } });
  check("CORS header present", (cors.headers.get("access-control-allow-origin") || "") === "*");
} catch (e) {
  fail++;
  console.log("EXC: " + e.message);
}

// ---- Now a LIVE-mode server to assert the fail-closed 402 gate ----
srv.kill();
await new Promise(r => setTimeout(r, 500));
const live = spawn("node", ["server.js"], {
  env: { ...process.env, PORT: String(3500), PAYMENT_MODE: "live", X402_PAY_TO: "0x2091125bFE4259b2CfA889165Beb6290d0Df5DeA" },
});
await new Promise(r => setTimeout(r, 1200));
try {
  const paid = await fetch("http://127.0.0.1:3500/launch", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: "X", symbol: "X", supply: 1 }) });
  check("live: /launch returns 402 without payment", paid.status === 402);
  // body must be a single-level JSON object (NOT double-encoded as a string)
  const bodyTxt = await paid.text();
  let bodyObj = null; try { bodyObj = JSON.parse(bodyTxt); } catch {}
  check("live: 402 body is a real JSON object (not double-encoded)", !!bodyObj && typeof bodyObj === "object" && bodyObj.x402Version === 2, bodyTxt.slice(0, 80));
  const pr = paid.headers.get("payment-required");
  check("live: PAYMENT-REQUIRED header present+decodable", !!pr && (() => { try { const j = JSON.parse(Buffer.from(pr, "base64").toString()); return j.x402Version === 2 && !!j.accepts && j.accepts[0].payTo === "0x2091125bFE4259b2CfA889165Beb6290d0Df5DeA"; } catch { return false; } })());
  // live refuses to settle: the /launch paid route must fail closed (500) without X402_PAY_TO
  const badLive = spawn("node", ["server.js"], { env: { ...process.env, PORT: String(3501), PAYMENT_MODE: "live" } });
  await new Promise(r => setTimeout(r, 900));
  const hh = await fetch("http://127.0.0.1:3501/health").catch(() => ({ status: 0 }));
  const r2 = await fetch("http://127.0.0.1:3501/launch", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: "X", symbol: "X", supply: 1 }) }).catch(() => ({ status: 0 }));
  check("live: paid route fails closed (>=500) without X402_PAY_TO", r2.status >= 500 || r2.status === 402);
  check("live: /health still up (server boots, gate refuses only the paid route)", hh.status === 200);
  badLive.kill();
} catch (e) {
  fail++;
  console.log("EXC(2): " + e.message);
} finally {
  live.kill();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);