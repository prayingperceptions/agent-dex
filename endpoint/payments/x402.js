// payments/x402.js — Agent DEX x402 pay-per-call gating (v2 protocol).
// Reuses the proven token-risk patterns: 402 + PAYMENT-REQUIRED header, v2 payload,
// fail-closed (unset PAYMENT_MODE => live), explicit X402_PAY_TO required in live,
// and the official Bazaar discovery extension block so agents can FIND the DEX.
const USDC_BASE_DECIMALS = 6;
const USDC_BASE_MAINNET = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

// dev-only fallback; live mode refuses without an explicit X402_PAY_TO
const DEFAULT_PAY_TO = '0x2091125bFE4259b2CfA889165Beb6290d0Df5DeA';

function cfg(env) {
  const mode = env.PAYMENT_MODE || env.X402_MODE || 'live'; // FAIL-CLOSED: unset => 402
  const payTo = env.X402_PAY_TO;
  if (mode === 'live' && !payTo) {
    throw new Error('X402_PAY_TO env is required when PAYMENT_MODE=live (fail-closed: never settle to a default)');
  }
  return {
    mode,
    priceUsdc: env.PRICE_USDC || env.X402_PRICE_USDC || '0.005',
    payTo: payTo || DEFAULT_PAY_TO,
    facilitatorUrl: env.X402_FACILITATOR_URL || 'https://api.cdp.coinbase.com/platform/v2/x402',
    network: env.X402_NETWORK || 'eip155:8453', // Base mainnet
    asset: env.X402_ASSET || USDC_BASE_MAINNET,
  };
}

const atomic = (usdc) => String(Math.round(parseFloat(usdc) * 10 ** USDC_BASE_DECIMALS));

// Bazaar-discovery shape: resource is a URL STRING; extensions.bazaar = { info, schema }.
export function paymentRequirements(resourceUrl, env) {
  const c = cfg(env);
  return {
    x402Version: 2,
    error: 'Payment required',
    resource: resourceUrl,
    description: 'Pay-per-call agent-native token exchange on Base mainnet over x402. Launch a token (1% deployer / 0.5% protocol / 0.5% lottery / 98% float), list it into pooled USDC or ETH liquidity, and trade with identity/permission/safety gates. Fee schedule disclosed at /fee/rate. $0.005 USDC/call, no signup, no API key.',
    mimeType: 'application/json',
    extensions: {
      bazaar: {
        info: {
          input: {
            type: 'http',
            method: 'POST',
            queryParams: {}, // POST body carries { name, symbol, supply } for /launch
          },
          output: {
            type: 'json',
            example: {
              ok: true,
              token: { name: 'Compute', symbol: 'CPT', totalSupply: '1000000', address: '0x…' },
              fee: { basisPoints: 50, percent: 0.5, to: '0x2091…' },
            },
          },
        },
        schema: {
          $schema: 'https://json-schema.org/draft/2020-12/schema',
          type: 'object',
          properties: { input: { type: 'object' }, output: { type: 'object' } },
          required: ['input'],
        },
      },
    },
    accepts: [
      {
        scheme: 'exact',
        network: c.network,
        amount: atomic(c.priceUsdc),
        asset: c.asset,
        payTo: c.payTo,
        maxTimeoutSeconds: 300,
        extra: { name: 'USDC', version: '2', resourceUrl },
      },
    ],
  };
}

async function verifyWithFacilitator(paymentHeader, resourceUrl, env) {
  const c = cfg(env);
  const body = JSON.stringify({ x402Version: 2, paymentHeader, paymentRequirements: paymentRequirements(resourceUrl, env) });
  const res = await fetch(`${c.facilitatorUrl}/verify`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
  });
  if (!res.ok) return { ok: false, reason: `facilitator verify HTTP ${res.status}` };
  const v = await res.json();
  if (!v.isValid) return { ok: false, reason: v.invalidReason || 'invalid payment' };

  const settle = await fetch(`${c.facilitatorUrl}/settle`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
  });
  if (!settle.ok) return { ok: false, reason: `facilitator settle HTTP ${settle.status}` };
  const s = await settle.json();
  if (!s.success) return { ok: false, reason: s.error || 'settlement failed' };
  return { ok: true, txHash: s.txHash || null };
}

// gatePayment(req, resourceUrl, env): { paid:true } or { paid:false, status, headers, body }.
export async function gatePayment(req, resourceUrl, env) {
  const c = cfg(env);
  if (c.mode === 'mock') return { paid: true, mode: 'mock' };

  const paymentHeader = req.headers && (req.headers['x-payment'] || req.headers['X-Payment']);
  if (!paymentHeader) {
    return {
      paid: false,
      status: 402,
      headers: {
        'content-type': 'application/json',
        'PAYMENT-REQUIRED': Buffer.from(JSON.stringify(paymentRequirements(resourceUrl, env))).toString('base64'),
      },
      body: JSON.stringify(paymentRequirements(resourceUrl, env)),
    };
  }
  const verdict = await verifyWithFacilitator(paymentHeader, resourceUrl, env);
  if (!verdict.ok) {
    return {
      paid: false,
      status: 402,
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...paymentRequirements(resourceUrl, env), error: verdict.reason }),
    };
  }
  return { paid: true, txHash: verdict.txHash };
}

export { cfg, paymentRequirements as requirements, verifyWithFacilitator };