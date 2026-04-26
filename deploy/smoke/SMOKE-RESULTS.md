# Darbitex Sui LP Locker — Testnet Smoke Results

**Date:** 2026-04-26
**Network:** Sui testnet
**Tester:** `0x6915bc38bccd03a6295e9737143e4ef3318bcdc75be80a3114f317633bdd3304`
**Locker package (testnet):** `0x0b068dad8589d0a2c9699badfbe70b5fc590d52aa312cb607804ad2fcafd8ef9`
**UpgradeCap (testnet):** `0x4e5e329631c8f3b150af4cb6bcae4893048b4683655024e792cc4f6df408e6ca` (kept; testnet not sealed)
**Pool target (testnet):** `0x3957dea77226f5533a0ead74d9156cef5f31055c95e71d6fbd908d0fb5279818` (`Pool<ETH_FAUCET, USDT_FAUCET>`)
**Pair decimals:** ETH_FAUCET=8, USDT_FAUCET=6 — heterogeneous decimal coverage per SOP `feedback_smoke_test.md` ✓

---

## Round 1 — sequential lock/swap/claim/redeem (post-unlock claim)

| Step | Tx digest | Result |
|---|---|---|
| `01_lock` | `C2NvLb7hc744CmnZtfuLHveBwGv4TbaX88Y7251omUzF` | LockedPosition `0x9e4980ae…` created, lock 90s, `Locked` event with `shares=19999000`, `pool_id`, `position_id`, `owner`, `unlock_at_ms` ✓ |
| `02_swap` | `BT5Hf47yBkdjjb8LWKiwsWirjbH56vanuByjUg8rWLAd` | swap 100k ETH→USDT, lp_fee=50 accrued in pool ✓ |
| `03_claim` | `C92xPSZFbYDSbSnfqVyhbWgcuAaPGB46XURVjn5fAzCV` | claim_fees_entry → `fees_a=49, fees_b=0` (49 ETH ≈ 50 × 19999000 / 20000000 floor). Both `pool::LpFeesClaimed` AND `lock::FeesClaimed` events emitted, correlated by `position_id` and same `timestamp_ms` ✓ |
| `04_redeem` | `GXx4qLmuxc5PXpvZhr7MqS75LVmrtQyLAedcZ1sFP6uN` | redeem_entry → LpPosition `0x5d3e7f7e…` mutated back to caller. LockedPosition deleted (UID consumed). `Redeemed` event ✓ |

Note: command-by-command overhead pushed steps 02-03 past the 90s unlock window — claim_fees verified post-unlock pre-redeem (valid path per design, equivalent to unit test `test_claim_fees_after_unlock_still_works_before_redeem`).

## Round 2 — atomic PTB demonstrating claim DURING lock

| Step | Tx digest | Result |
|---|---|---|
| `05_lock_swap_claim_ptb` | `B2gQPgoowouNX8PrNRG7yAW2wTBmU62ifEupGgPzVZt4` | Single PTB: `lock_position` (10-min lock) → `pool::swap_a_to_b` → `lock::claim_fees` → transfers. **All 4 events at same timestamp_ms = 1777210640571**, with `unlock_at_ms=1777211233802` (~10min ahead). `fees_a=49, fees_b=0`. Definitively mid-lock claim ✓ |
| `06_redeem_too_early` (negative) | `GaafDLjajUds7AayU2ifkfeVeZeYB2W8rd1NKTmYdoH2` | redeem before unlock → **aborted at `lock::redeem` instruction 11 with code 1** (E_STILL_LOCKED = 1) ✓ |

LockedPosition `0xe1c3125ed13bd0f8d63624e612d840b4d3f83b4118dac4d540f0c9ec40af4c2a` left active on testnet (unlocks at ms 1777211233802; can be redeemed manually after).

---

## Coverage matrix — SOP smoke checks

| Check | Status |
|---|---|
| Heterogeneous-decimal pair (8 vs 6) | ✓ ETH_FAUCET / USDT_FAUCET |
| Real-network pool with non-trivial reserves | ✓ ~100M ETH / 4M USDT pool |
| Swap-induced fee accrual | ✓ 50 lp_fee per 100k swap |
| Lock + claim during lock | ✓ Round 2 PTB |
| Lock + claim post-unlock pre-redeem | ✓ Round 1 step 03 |
| Redeem at boundary | ✓ Round 1 step 04 |
| Redeem before unlock aborts E_STILL_LOCKED | ✓ Round 2 step 06 |
| Event correlation pool ↔ locker | ✓ same `position_id`, same `timestamp_ms` per tx |
| LockedPosition cleanup on redeem | ✓ UID deleted, LpPosition mutated back |
| Heterogeneous-decimal coin handling in entries | ✓ both Coin<A> and Coin<B> handled in claim_fees_entry |

---

## Verdict

**Testnet smoke passed.** All audit-cleared paths (positive + negative) verified on-chain with real pool, real heterogeneous-decimal coins, real fee accrual, real event correlation. No discrepancy from unit-test behavior.

Ready for mainnet publish per SOP `feedback_mainnet_deploy_sop.md`:
1. 1/5 multisig publish
2. Smoke (optional on mainnet — already validated on testnet)
3. `package::make_immutable` to seal

Pool dep at mainnet `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68` is already sealed Immutable since 2026-04-26.
