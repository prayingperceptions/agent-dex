#!/usr/bin/env bash
# moon-landing.sh — a small on-chain $CPT trade on Base, with an Armstrong-style message.
#
#   "One small step for a token, one giant leap for the agent economy."
#
# USAGE:
#   1) Put your private key (64 hex) into /Users/cmpgfb/.openclaw/tmp/deployer_key
#   2) bash scripts/moon-landing.sh
#
# SAFETY: the script derives your signer address FIRST and verifies it holds USDC.
# The DEX buy() pulls USDC from the signer, so a gas-only key (0xcA60…, $0 USDC)
# will be refused with a clear message — use the key that controls the USDC address.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC=https://mainnet.base.org
DEX=0xB1a77D1CEBb2BdF7A1Dd12758992BfC1408de996
CPT=0xad3dc01fE083dEF0F3e7DE0F2164865494eB0322
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
KEYFILE=/Users/cmpgfb/.openclaw/tmp/deployer_key
TRADE_USDC_ATOMIC=1000000   # $1.00 USDC -> a small CPT buy

[ -f "$KEYFILE" ] || { echo "ERROR: no key at $KEYFILE. Write your 64-hex key there first."; exit 1; }

KEY="$(cat "$KEYFILE" | tr -d '[:space:]')"
[ "${#KEY}" -ge 64 ] || { echo "ERROR: key looks too short. It must be a 64-hex private key."; exit 1; }

echo "== deriving signer address (key never printed)..."
SIGNER="$(cast wallet address --private-key "$KEY" 2>/dev/null | tail -1)"
# cast may emit a checksummed address; normalize lowercase for compare
SIGNER="${SIGNER,,}"
[ -n "$SIGNER" ] || { echo "ERROR: could not derive an address from the key."; exit 1; }
echo "== signer:  $SIGNER"

BAL_RAW="$(cast call "$USDC" 'balanceOf(address)(uint256)' "0x${SIGNER#0x}" --rpc-url "$RPC" 2>/dev/null)"
BAL="$(( 10#${BAL_RAW:-0} ))"
echo "== signer USDC: $BAL_RAW atomic = \$(python3 -c 'print("%.2f" % ($BAL/1e6))')"
if [ "$BAL" -lt "$TRADE_USDC_ATOMIC" ]; then
  echo ">> Signer holds < \$$(( TRADE_USDC_ATOMIC/1000000 ))." 
  echo ">> (Gas-only deployer 0xcA60… has \$0 USDC.) Use the key that controls the USDC address."
  exit 2
fi

echo "== broadcasting a small $CPT buy (\$$(( TRADE_USDC_ATOMIC/1000000 )).00 USDC)..."
TX="$(cast send "$DEX" 'buy(address,uint256,address)' "$CPT" "$TRADE_USDC_ATOMIC" "$SIGNER" \
  --rpc-url "$RPC" --private-key "$KEY" 2>&1 | grep -ioE "0x[0-9a-f]{64}" | head -1)"
echo "   trade tx: $TX"

# Leave the moon-landing message on-chain (self-transfer carrying the message as data).
MSG="One small step for a token, one giant leap for the agent economy."
MSGHEX="$(printf '%s' "$MSG" | xxd -p | tr -d '\n')"
echo "== carving the message on-chain (Basescan input data)..."
cast send "$SIGNER" --value 0 --data "0x$MSGHEX" --rpc-url "$RPC" --private-key "$KEY" 2>&1 \
  | grep -ioE "0x[0-9a-f]{64}" | head -1

echo "== done. /stats will tick up as the trade settles."