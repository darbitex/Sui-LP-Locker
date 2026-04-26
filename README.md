# Darbitex Sui LP Locker

**Status:** LIVE + SEALED on Sui mainnet (2026-04-26).

Time-locked wrapper for `darbitex::pool::LpPosition<A,B>`. Wraps an LP position
with a one-way `unlock_at_ms` deadline. The principal (extracting the underlying
`LpPosition`) is gated by the deadline; LP fees are claimable throughout the
lock period. Zero admin. No extend, no shorten, no early-unlock. Sealed
immutable after publish.

`LockedPosition<A,B>` has `key, store` — kiosk/escrow/marketplace-able and
embeddable as a field in downstream wrappers (staking, vesting, lending, etc.).
The lock invariant is enforced by Move's type system + module privacy: the only
path to extract `LpPosition` is `redeem` after the deadline, regardless of how
deeply the wrapper is composed.

## Mainnet

| Resource | Address |
|---|---|
| Package | `0x62d8ca51e77fccbbc8be88905760a84db752a02fb398da115294cb5aa373d23c` |
| Owner | Immutable (UpgradeCap destroyed) |
| Pool dep | `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68` (also sealed) |

Tx1 publish: `FFfF5Aw1LSsy1i4vJeXfXbtnCz9BduQSNWtpyVGRs2Dt`
Tx2 make_immutable: `AdkpQg6MeZFSnQxVDYn4Cf3oaY3diLKtdFrcNGH7zKN5`

## Public API

| Fn | Purpose |
|---|---|
| `lock_position<A,B>(LpPosition, unlock_at_ms, &Clock, &mut TxContext) -> LockedPosition` | composable primitive |
| `claim_fees<A,B>(&mut LockedPosition, &mut Pool, &Clock, &mut TxContext) -> (Coin<A>, Coin<B>)` | open throughout lock period |
| `redeem<A,B>(LockedPosition, &Clock) -> LpPosition` | gated `now >= unlock_at_ms` |
| `lock_position_entry`, `claim_fees_entry`, `redeem_entry` | block-explorer-callable, transfer-to-sender |
| `unlock_at_ms`, `position_shares`, `pool_id`, `is_unlocked`, `borrow_position` | views |
| `read_warning() -> vector<u8>` | on-chain disclosure (10 known limitations) |

## Audits

- Self-audit R1: `docs/AUDIT-R1-SELF.md` — GREEN, 1 INFO applied.
- External R1 (6 LLM auditors): `docs/audit-responses/{gemini,claude,grok,qwen,deepseek,kimi}-r1.md` — all GREEN, 0 HIGH/MED/LOW total, 14 INFO (none applied per propose-not-apply SOP).
- Audit submission doc: `docs/AUDIT-LOCKER-SUBMISSION.md`.

## Tests

```
sui move test
```

14 tests, all passing. Coverage: happy paths, lock invariants (`E_INVALID_UNLOCK`),
redeem invariants (`E_STILL_LOCKED`), fee claim during/after lock, repeat-claim
no-double-count, wrapper transferability, composability via `borrow_position`,
`is_unlocked` boundary, `read_warning` disclosure.

## Smoke

- Testnet: `deploy/smoke/SMOKE-RESULTS.md` — 6 txs, ETH_FAUCET/USDT_FAUCET pool, positive + negative paths.
- Mainnet: `deploy/mainnet/DEPLOYMENT.md` — 2 txs on Circle SUI/USDC pool, atomic PTB + redeem.

## Source verification

Anyone can independently verify that the on-chain bytecode at
`0x62d8ca51e77fccbbc8be88905760a84db752a02fb398da115294cb5aa373d23c`
matches this repository.

Requires `sui` CLI 1.70.2 (the toolchain used at publish time).

```
git clone https://github.com/darbitex/Sui-LP-Locker.git
cd Sui-LP-Locker
git checkout d090f269dab4eede4bccaab8bd1e034062d0b029
```

Edit `Move.toml` to add `published-at` and set the concrete address:

```toml
[package]
name = "DarbitexLpLocker"
version = "0.1.0"
edition = "2024.beta"
published-at = "0x62d8ca51e77fccbbc8be88905760a84db752a02fb398da115294cb5aa373d23c"

[dependencies]
Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "6d4ec0b0621dd9555753c9ecd5be021b25a0d267", override = true }
Darbitex = { git = "https://github.com/darbitex/darbitex-sui.git", rev = "3c632ab3158e7fe54636902fe5efa064bbf0c62c" }

[addresses]
darbitex_lp_locker = "0x62d8ca51e77fccbbc8be88905760a84db752a02fb398da115294cb5aa373d23c"
```

Then run:

```
sui client verify-source --silence-warnings
```

Expected output: `Source verification succeeded!`

This compares freshly-compiled bytecode against the on-chain modules and proves
the published package was built from this source at the pinned dep revisions.

## License

Public domain (Unlicense). See `LICENSE`.
