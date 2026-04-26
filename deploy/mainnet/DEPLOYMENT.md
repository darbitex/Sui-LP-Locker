# Darbitex Sui LP Locker — Mainnet Deployment

**Date:** 2026-04-26
**Network:** Sui mainnet (chain-id `35834a8a`)
**Deployer (hot wallet):** `0x6915bc38bccd03a6295e9737143e4ef3318bcdc75be80a3114f317633bdd3304`
**Deploy mode:** Fast-track (hot wallet, no multisig). Justified because Tx2 destroys UpgradeCap immediately — multisig adds no value once package is sealed Immutable.

---

## Artifacts

| Resource | Value |
|---|---|
| Package | `0x62d8ca51e77fccbbc8be88905760a84db752a02fb398da115294cb5aa373d23c` |
| UpgradeCap | `0x9d605d54073211ad6cc37546b2243f18f2032e792a2275cdafdd9b19085f1a1a` (DESTROYED) |
| Owner | **Immutable** |
| Pool dep (sealed) | `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68` |

## Transactions

| Tx | Digest | Effect |
|---|---|---|
| Tx1 publish | `FFfF5Aw1LSsy1i4vJeXfXbtnCz9BduQSNWtpyVGRs2Dt` | Package created, UpgradeCap minted to deployer |
| Tx2 make_immutable | `AdkpQg6MeZFSnQxVDYn4Cf3oaY3diLKtdFrcNGH7zKN5` | UpgradeCap consumed → package sealed Immutable |

## Gas

- Tx1: storage 49,217,600 + compute 221,000 - rebate 978,120 ≈ 0.0485 SUI
- Tx2: ~0.001 SUI (cap deletion)
- Total: ~0.05 SUI

## Verification

- Package owner: `Immutable` (verified via `sui client object`)
- UpgradeCap object: not found (consumed)
- `read_warning()` callable on mainnet ✓

## Pre-deploy gates (all passed)

- 14/14 unit tests passing (`sui move test`)
- Self-audit R1 GREEN (0 HIGH/MED/LOW, 1 INFO applied)
- 6 LLM external audits all GREEN (Gemini, Claude, Grok, Qwen, DeepSeek, Kimi); 0 HIGH/MED/LOW total
- Testnet smoke comprehensive (6 txs, positive + negative paths, heterogeneous-decimal pool)

## Mainnet smoke (2026-04-26, post-seal)

Real mainnet smoke on Circle's SUI/USDC pool at `0x8c67e4c1b6c22203ae6b3d8a4e3e14c6a32bea7d3a94f6627722f8d76af5ce03`.

| Step | Tx | Detail |
|---|---|---|
| Tx-smoke-1 (PTB atomic) | `EJBbe2VwAc6bzRErB8yezVQVX7SApM3UZaw69MjzrDPC` | lock 60s + swap SUI→USDC (10k MIST → 9 µUSDC, fee 5 MIST) + swap back (9 µUSDC → 9536 MIST) + claim_fees (4 MIST). LockedPosition `0xad5481a9...` |
| Tx-smoke-2 (redeem post-unlock) | `B9YUab5SBxehHM93QmNA2o3Eqe8yKdqwG2r9vCi23Ymu` | LpPosition `0x204c9511...` returned, LockedPosition deleted |

All paths verified live on Circle USDC pool. Heterogeneous decimal (SUI=9, USDC=6).

## What this means

- No admin authority. No upgrade path. Forever.
- Anyone can lock their `LpPosition<A,B>` from `darbitex::pool` via `lock_position` / `lock_position_entry`.
- LockedPosition is `key, store` — transferable, embeddable in downstream wrappers (staking, escrow, vesting).
- The full disclosure (10 known limitations including "non-exhaustive lower bound" and AI-only audit) is on-chain via `read_warning()`.
