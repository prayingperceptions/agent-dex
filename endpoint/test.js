// Local e2e test for the agent-dex HTTP endpoint.
// Boots server.js; exercises /health, /fee/rate, /launch (0.5%), /list, /trade, CORS.
import { spawn } from "node:child_process";

const PORT = 3499;
const BASE = `http://127.0.0.1:${PORT}`;
let pass = 0, fail = 0;
const check = (n, c, d) => { if (c) { pass++; console.log("PASS " + n); } else { fail++; console.log("FAIL " + n + " :: " + d); } };

const srv = spawn("node", ["server.js"], { env: { ...process.env, PORT: String(PORT) } });
await new Promise(r => setTimeout(r, 1200));

async function get(p) { const r = await fetch(BASE + p); return { status: r.status, json: await r.json() }; }
async function post(p, body) {
  const r = await fetch(BASE + p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  return { status: r.status, json: await r.json() };
}

try {
  const h = await get("/health");
  check("health ok", h.status === 200 && h.json.ok === true && h.json.service === "agent-dex");

  const fee = await get("/fee/rate");
  check("fee schedule disclosed", fee.status === 200 && fee.json.launch.percent === 0.5 && fee.json.listing.percent === 0.5 && fee.json.trade.percent === 0.05 && fee.json.protocolTo === "0x2091125bFE4259b2CfA889165Beb6290d0Df5DeA" && fee.json.disclosed === true);

  // launch 1,000,000 -> 0.5% = 5,000 to protocol, deployer 995,000
  const l = await post("/launch", { name: "Agent Token", symbol: "AGT", supply: 1000000 });
  check("launch: 0.5% fee computed", l.status === 200 && l.json.fee.wei === "5000" && l.json.deployer.wei === "995000", JSON.stringify(l.json));

  const tiny = await post("/launch", { name: "Micro", symbol: "MIC", supply: 1 });
  check("launch: underflow supply rejected", tiny.status === 400);

  // list seed 100,000 -> 0.5% = 500 listing fee, pool net 99,500
  const listR = await post("/list", { seedQuote: 100000 });
  check("list: 0.5% listing fee + pool seeded", listR.status === 200 && listR.json.pool.listingFee.wei === "500" && listR.json.pool.quoteSeed === "99500", JSON.stringify(listR.json));

  // trade 10,000 -> 0.05% = 5 trade fee
  const tr = await post("/trade", { quoteIn: 10000 });
  check("trade: 0.05% trade fee", tr.status === 200 && tr.json.fee.wei === "5", JSON.stringify(tr.json));

  const bad = await post("/launch", { name: "X", symbol: "Y" });
  check("launch: missing supply -> 400", bad.status === 400);

  const cors = await fetch(BASE + "/health", { headers: { Origin: "https://agentos-landing.vercel.app" } });
  check("CORS header present", (cors.headers.get("access-control-allow-origin") || "") === "*");

  const pre = await fetch(BASE + "/trade", { method: "OPTIONS", headers: { Origin: "https://agentos-landing.vercel.app", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type" } });
  check("CORS preflight OPTIONS 204", pre.status === 204 && pre.headers.get("access-control-allow-origin") === "*");
} catch (e) {
  fail++;
  console.log("EXC: " + e.message);
} finally {
  srv.kill();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);