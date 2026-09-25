// server.js — Agent DEX HTTP endpoint (zero-dependency Node).
// Thin wrapper over the agent-dex venue logic for the live demo + agent callers:
//   GET  /health        -> status
//   GET  /              -> endpoints list
//   GET  /fee/rate      -> launch/list/trade fee rates (disclosed)
//   POST /launch        -> {name,symbol,supply} -> fee breakdown (0.5% -> protocol) + deploy params
//   POST /list          -> {seedQuote} -> 0.5% listing fee, pool seeded (liquidity)
//   POST /trade         -> {quoteIn}   -> buy: quote->token via pool, trade fee to protocol
// CORS: Access-Control-Allow-Origin:* for the live browser demo.
import http from 'node:http';

const PORT = parseInt(process.env.PORT || '8794', 10);

const PROTOCOL_TO = '0x2091125bFE4259b2CfA889165Beb6290d0Df5DeA';
const BPS = { launch: 50, listing: 50, trade: 5 }; // 0.5% / 0.5% / 0.05%
const BPS_NUM = { launch: 50n, listing: 50n, trade: 5n };

function send(res, status, obj, addHeaders = {}) {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'content-type',
    ...addHeaders
  });
  res.end(JSON.stringify(obj, null, 2));
}

async function readBody(req) {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  if (!raw.trim()) return {};
  try { return JSON.parse(raw); } catch { return { __invalid: true }; }
}

const feeFor = (wei, bps) => (wei * bps) / 10000n;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const method = req.method;
  const path = url.pathname.replace(/\/+$/, '') || '/';

  try {
    if (method === 'OPTIONS') return send(res, 204, {}, {});

    if (method === 'GET' && path === '/health') {
      return send(res, 200, { ok: true, service: 'agent-dex', version: '0.1.0', chain: 'base' });
    }
    if (method === 'GET' && path === '/') {
      return send(res, 200, { service: 'agent-dex', endpoints: ['/health', '/fee/rate', '/launch', '/list', '/trade'] });
    }

    // disclosed fee schedule — transparency first
    if (method === 'GET' && path === '/fee/rate') {
      return send(res, 200, {
        launch: { basisPoints: 50, percent: 0.5, note: '0.5% of supply minted to protocol at launch' },
        listing: { basisPoints: 50, percent: 0.5, note: '0.5% of seed quote to protocol' },
        trade: { basisPoints: 5, percent: 0.05, note: 'per-swap, to protocol' },
        protocolTo: PROTOCOL_TO,
        disclosed: true
      });
    }

    // launch: compute the 0.5% mint + the auto-pooling liquidity plan
    if (method === 'POST' && path === '/launch') {
      const body = await readBody(req);
      if (body.__invalid) return send(res, 400, { error: 'invalid JSON body' });
      const name = String(body.name || '').trim(), symbol = String(body.symbol || '').trim();
      const supply = body.supply;
      if (!name || !symbol) return send(res, 400, { error: 'body requires { name, symbol }' });
      if (typeof supply !== 'number' || !Number.isFinite(supply) || supply <= 0) return send(res, 400, { error: 'supply must be a positive number' });
      const supplyWei = BigInt(Math.floor(supply));
      const launchFee = feeFor(supplyWei, BPS_NUM.launch);
      if (launchFee <= 0n) return send(res, 400, { error: `supply ${supplyWei} underflows 0.5% fee to 0; raise supply` });
      return send(res, 200, {
        ok: true,
        token: { name, symbol, totalSupply: supplyWei.toString() },
        fee: { basisPoints: 50, percent: 0.5, to: PROTOCOL_TO, wei: launchFee.toString() },
        deployer: { wei: (supplyWei - launchFee).toString() },
        liquidity: { note: 'launch auto-pools via Agent DEX; see /list to seed', seedQuoteMin: '0' },
        note: '0.5% minted on-chain at launch; token becomes tradable when pooled.'
      });
    }

    // list: open liquidity; 0.5% listing fee from the seed quote
    if (method === 'POST' && path === '/list') {
      const body = await readBody(req);
      if (body.__invalid) return send(res, 400, { error: 'invalid JSON body' });
      const seedQuote = body.seedQuote;
      if (typeof seedQuote !== 'number' || !Number.isFinite(seedQuote) || seedQuote <= 0) return send(res, 400, { error: 'seedQuote must be a positive number' });
      const seedWei = BigInt(Math.floor(seedQuote));
      const listingFee = feeFor(seedWei, BPS_NUM.listing);
      const netSeed = seedWei - listingFee;
      if (listingFee <= 0n) return send(res, 400, { error: 'seedQuote too small; 0.5% listing fee underflows to 0' });
      return send(res, 200, {
        ok: true,
        pool: { seeded: true, quoteSeed: netSeed.toString(), listingFee: { basisPoints: 50, percent: 0.5, to: PROTOCOL_TO, wei: listingFee.toString() } },
        note: 'Token becomes tradable now that the pool has liquidity; receipt = LP position.'
      });
    }

    // trade: buy with quote through the pooled venue, trade fee to protocol
    if (method === 'POST' && path === '/trade') {
      const body = await readBody(req);
      if (body.__invalid) return send(res, 400, { error: 'invalid JSON body' });
      const quoteIn = body.quoteIn;
      if (typeof quoteIn !== 'number' || !Number.isFinite(quoteIn) || quoteIn <= 0) return send(res, 400, { error: 'quoteIn must be a positive number' });
      const qwei = BigInt(Math.floor(quoteIn));
      const tradeFee = feeFor(qwei, BPS_NUM.trade);
      return send(res, 200, {
        ok: true,
        quote: { in: qwei.toString() },
        fee: { basisPoints: 5, percent: 0.05, to: PROTOCOL_TO, wei: tradeFee.toString() },
        note: 'swap: quote -> token through the pooled venue; 0.05% trade fee to protocol.'
      });
    }

    return send(res, 404, { error: 'not found', endpoints: ['/health', '/fee/rate', '/launch', '/list', '/trade'] });
  } catch (err) {
    send(res, 500, { error: 'internal_error', detail: String(err && err.message || err) });
  }
});

server.listen(PORT, () => console.log(`agent-dex listening on :${PORT}`));