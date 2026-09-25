# Agent DEX

An **agent-native token exchange on Base** where agent-launched tokens get real liquidity
and a disclosed stream of protocol fees — the trade floor for [Agent Stack](https://agentos-landing.vercel.app).

A token deployed through Agent DEX is pooled into an instantly-tradable market, so the
protocol's 0.5% receipt is **liquid from mint #1** (it can trade, not sit dead), and it
earns by being an LP position. Every order is identity + permission + safety gated,
fail-closed.

---

## The launch split (per token)

| Share | Goes to | Earns how |
|---|---|---|
| **1%** | Deployer | Ownership + LP trade fees + can sell |
| **0.5%** | Protocol recipient | Guaranteed, minted at launch |
| **0.5%** | **Lottery escrow** → one random wallet after **≥100 distinct traders** | On-chain draw; the venue **can't tell a human from an agent** |
| **98%** | **Tradable float** → pooled against the quote | Liquidity; deployer is the initial LP |

Total = 100%. Supply conserved (proven in tests).

## Fees — protocol earns at every rail

- **Launch 0.5%** of supply (atomic, cannot be skipped)
- **Listing 0.5%** of the seed quote
- **Trade 0.05%** per swap — **half to the protocol rail, half accrues to LP holders** pro-rata by shares (your receipt *earns* as an LP position)

## Dual quote (Uniswap-style pair choice)

A token lists against **USDC or ETH on Base** — the accepted-quote registry is
protocol-controlled, and `list()` picks the pair like Uniswap. Uses the **real USDC**
contract via a standard `IERC20` interface (not a mock).

## Why deploy here? (the honest pitch)

Rolling a token yourself means finding external liquidity, a safety layer, and a fee
mechanism. Agent DEX bundles all three: **instant liquidity, disclosed fair fees, and
identity/permission/safety gates built in.** Deployers export their liquidity and safety
problems to the rail and get a tradable token for it — and they earn as the LP.

---

## Contracts

| File | Role |
|---|---|
| `IERC20.sol` | minimal ERC-20 interface (accepts real USDC/ETH on Base) |
| `SimpleERC20.sol` | the deployable token (mints full supply to the DEX, which splits 1/0.5/0.5/98) |
| `DemoAMM.sol` | constant-product pool (x·y=k, Uniswap-style) with LP-share ledger + fee routing |
| `AgentDEX.sol` | venue: launch → split → list (choose USDC/ETH) → buy/sell → lottery draw |

> **v1 note:** the pool is a self-contained constant-product simulator (safe, tested),
> designed so a real **Aerodrome / Uniswap-v3 wrapper** can drop in behind the same
> surface once there's volume. A bonding curve is a deliberate v2 option, not v1.

## Agent gates (fail-closed)

`AgentDEX` exposes `setGates(identity, authority, safety)` (protocol-only). When a gate is
set, every launch/order is checked; a denying gate blocks the action. Unset = skipped
(demo), but the mechanism is proven by test.

## Lottery

- Every distinct trader is tracked (platform-blind — just addresses).
- Once **≥100 distinct wallets** have traded, `draw()` picks **one winner** from the
  candidate pool by **on-chain blockhash** and releases the **0.5% escrow**.
- The platform genuinely can't know if the winner is a human or an agent.

## Tests

```bash
forge test    # 7/7: split, dual quote, buy/sell round-trip, fees every rail, lottery threshold + draw
```

## Live (Base mainnet)

| Contract | Address (Base) | Basescan |
|---|---|---|
| **AgentDEX** (venue) | `0xB1a77D1CEBb2BdF7A1Dd12758992BfC1408de996` | [view](https://basescan.org/address/0xB1a77D1CEBb2BdF7A1Dd12758992BfC1408de996) |
| **Compute (CPT)** | `0xad3dc01fE083dEF0F3e7DE0F2164865494eB0322` | [view](https://basescan.org/token/0xad3dc01fe083def0f3e7de0f2164865494eb0322) |
| **LotteryLedger** | `0xD4a6BbF436C67f0CcFbA687f01378713AE38ba66` | [view](https://basescan.org/address/0xD4a6BbF436C67f0CcFbA687f01378713AE38ba66) |

**Verified on-chain (CPT, supply 1,000,000):** deployer 1% = **10,000** · protocol 0.5% = **5,000 → `0x2091…5DeA`** · lottery 0.5% = **5,000** (ledger) · DEX float **980,000** (98%). Supply conserved.

## Live

- Endpoint: `https://agent-dex-eight.vercel.app` (`/health`, `/fee/rate`, `/launch`, `/list`, `/trade`)
- Demo step 6: `https://agentos-landing.vercel.app/demo.html`
- Repo: `github.com/prayingperceptions/agent-dex`

## License
MIT — open source, free, no platform lock-in.