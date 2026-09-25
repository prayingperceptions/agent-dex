// stats.js — CoinGecko-style on-chain analytics for Agent DEX (read-only).
// Queries the live Base mainnet venue (AgentDEX + its DemoAMM pool) via eth_call
// JSON-RPC using exact 4-byte selectors; returns price, TVL, volume, trades, liquidity.
const RPC = 'https://mainnet.base.org';
const DEX = '0xB1a77D1CEBb2BdF7A1Dd12758992BfC1408de996';
const COMPUTE = '0xad3dc01fE083dEF0F3e7DE0F2164865494eB0322';
const PROTOCOL = '0x2091125bFE4259b2CfA889165Beb6290d0Df5DeA';

// exact 4-byte selectors (from `cast sig`)
const SEL = {
  listings: '65d96c82',
  reserveQuote: '93778609',
  reserveToken: 'f4325d67',
  totalVolumeQuote: 'bbe402de',
  totalVolumeToken: 'b9337840',
  totalTrades: 'e275c997',
  lastTradeTimestamp: '19f18dee',
  price: 'a035b1fe',
};

function addrArg(a) { return '0'.repeat(24) + a.slice(2).toLowerCase(); }

async function ethCall(to, sel, data = '') {
  const r = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to, data: '0x' + sel + data }, 'latest'] }),
  }).then((x) => x.json());
  return r.result; // '0x…' or undefined on revert
}

const b256 = (hex) => BigInt(hex).toString();
const addr = (hex) => '0x' + (hex || '0'.repeat(64)).slice(24);
const isZero = (hex) => BigInt(hex || '0') <= 0n;

export async function poolStats() {
  // DEX.listings(compute) => struct (token, amm, deployer, quote, active) = 5 x 32B words
  const lres = await ethCall(DEX, SEL.listings, addrArg(COMPUTE));
  const h = String(lres || '0x').replace(/^0x/, '');
  const word = (i) => h.slice(i * 64, (i + 1) * 64);
  const active = BigInt(word(4) || '0') > 0n;
  const ammRaw = word(1) || '';
  const amm = (active && BigInt(ammRaw) > 0n) ? addr(ammRaw) : null;

  if (!active || !amm) {
    return {
      ok: true, token: COMPUTE, dex: DEX, pooled: false, amm: null,
      note: 'Compute launched but not yet pooled — run /list (USDC quote) to open liquidity',
      volume24h: '0', tvl: '0', trades: '0', price: '0',
      protocolTo: PROTOCOL, updatedAt: new Date().toISOString(),
    };
  }

  const view = async (sel) => b256(await ethCall(amm, sel) || '0x0');
  const rq = await view(SEL.reserveQuote);
  const rt = await view(SEL.reserveToken);
  const volumeQuote = await view(SEL.totalVolumeQuote);
  const volumeToken = await view(SEL.totalVolumeToken);
  const trades = await view(SEL.totalTrades);
  const lastTrade = await view(SEL.lastTradeTimestamp);
  const price = await view(SEL.price);

  return {
    ok: true, token: COMPUTE, dex: DEX, amm, pooled: true,
    price: { perTokenQuoteScale18: price, note: 'constant-product quote/token ×1e18' },
    tvl: rq,
    liquidity: { reserveQuote: rq, reserveToken: rt },
    volume24h: volumeQuote,
    volumeAllTime: volumeQuote,
    trades,
    lastTradeTimestamp: lastTrade,
    protocolTo: PROTOCOL,
    updatedAt: new Date().toISOString(),
  };
}