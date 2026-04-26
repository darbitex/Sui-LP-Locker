# Kimi — R1 Audit Response

**Auditor:** Kimi
**Date:** 2026-04-26
**Verdict:** GREEN — mainnet publish readiness

---

I'll conduct a thorough audit of the Darbitex Sui LP Locker. Let me first review the source code and verify the invariants against the threat model.
Based on my thorough review of the source code, threat model, and design decisions, here is the audit report.

---

## Findings

### INFORMATIONAL-1: Inconsistent `pool_id` sourcing in `claim_fees`
**Location:** `lock.move:claim_fees`
**Description:** `pool_id` is derived from `object::id(pool)` (the caller-provided argument) rather than `pool::position_pool_id(&locked.position)` (the canonical source embedded in the position itself).
**Impact:** None functional — `pool::claim_lp_fees` aborts on `E_WRONG_POOL` before any state change or event emission, so a mismatched pool can never produce a spurious event. However, this is inconsistent with `lock_position` and `redeem`, which both read `pool_id` from the position.
**Recommended fix:** Change to `let pool_id = pool::position_pool_id(&locked.position);` for defense-in-depth consistency. This makes the event resilient to the (already-impossible) wrong-pool scenario without relying on the downstream abort.

### INFORMATIONAL-2: `FeesClaimed` event omits claimer address
**Location:** `lock.move:FeesClaimed` struct definition
**Description:** The event does not include the `address` of the account claiming fees.
**Impact:** Low — Sui transaction metadata captures the sender, and indexers can join on `tx_digest`. However, the event is not fully self-contained for indexers that ingest only module events without parsing transaction context.
**Recommended fix:** Consider adding `claimer: address` to `FeesClaimed` if downstream analytics pipelines require fully self-contained event streams. This is purely additive and does not affect auth logic.

---

## Design questions we want answered

**D-1 — `borrow_position` exposes `&LpPosition`:**
**SAFE.** Move's borrow checker makes it impossible to upgrade `&LpPosition` to `&mut LpPosition` or to a by-value `LpPosition`. The only public functions in `darbitex::pool` that accept `&LpPosition` are `position_shares`, `position_pool_id`, and `pending_fees` — all read-only views with no side effects. There is no leak path.

**D-2 — Asymmetric time semantics (`>` at lock, `>=` at redeem):**
**CORRECT.** Strict `>` at `lock_position` prevents zero-duration locks, preserving the semantic meaning of "locked." Inclusive `>=` at `redeem` matches user intuition ("locked until 5pm" means 5pm is fair game). Flipping either polarity would either allow meaningless locks or force users to wait an extra millisecond past their deadline for no benefit.

**D-3 — `redeem` does not take `&mut TxContext`:**
**CORRECT.** `redeem` performs no object creation, no sender-dependent logic, and no transfers. Omitting `ctx` is appropriate minimalism. The `Redeemed` event already carries `locker_id`, `position_id`, `pool_id`, and `timestamp_ms`; the sender is recoverable from transaction metadata.

**D-4 — No `permit` / approval / delegation model:**
**CORRECT.** Sui's object ownership model is the right abstraction here. Adding delegation would introduce bloat and a new trust surface without adding meaningful capability. Custodians and smart wallets can wrap `LockedPosition` in their own contracts if they need delegation semantics.

**D-5 — No hard cap on lock duration:**
**CORRECT.** `u64::MAX` ms (~580 million years) is a principled "permanent lock" sentinel. The comparison operations `unlock_at_ms > now` and `now >= unlock_at_ms` are bounded u64 comparisons with no overflow risk.

**D-6 — No extend / shorten / cancel operations:**
**CORRECT.** One-way immutability of `unlock_at_ms` is the right call for a minimal satellite. Adding `extend` would open economic gaming vectors for downstream staking protocols; adding `shorten` or `cancel` would defeat the purpose of the lock. The re-lock-after-redeem pattern covers legitimate use cases.

**D-7 — Pool dep is sealed Immutable:**
**CORRECT.** Since `darbitex::pool` is already sealed, the locker has no upgrade dependency risk beyond what the pool itself already bears. Pinning via `Move.lock` is the right approach.

**D-8 — Composability with planned staking package:**
**INVARIANT HOLDS.** The critical invariant is satisfied:
- `LockedPosition` fields are module-private; only `lock::redeem` can destructure the struct.
- `lock::redeem` unconditionally asserts `now >= unlock_at_ms` before destructuring.
- No public function in the module returns `LpPosition<A,B>` except `redeem`.
- Even if a downstream staking wrapper is fully compromised, the attacker can at worst obtain the `LockedPosition` wrapper — they still cannot extract the inner `LpPosition` without passing the time gate, because they cannot bypass `lock::redeem`.

**D-9 — No correlation event omission:**
**CORRECT.** Including `pool_id` directly in all three events is strictly better than requiring off-chain correlation. No privacy degradation — `pool_id` is already public via `pool::LpFeesClaimed`.

**D-10 — Self-transfer lint warnings unsuppressed:**
**CORRECT.** Keeping W99001 visible is the right call. Entry wrappers are intentionally non-composable; composers use the primitive variants. Suppressing the lint would hide the intentional design choice from future reviewers.

---

## Things you considered and got right

These decisions held up under scrutiny and should stay locked in:

1. **By-value field embedding over child-object custody.** Holding `LpPosition` as a struct field rather than transferring it to a child object eliminates the `ExtendRef` signer-dance complexity from the Aptos predecessor. It also makes the position completely unaddressable from outside the module — there is no object ID an attacker can target.

2. **`key, store` on `LockedPosition`.** This is the critical enabler for downstream composability (staking, escrow, marketplace) without sacrificing the lock invariant. The combination of `store` (embeddable) + module-private fields (indestructible except via `redeem`) is exactly the right Sui idiom.

3. **No math in the locker.** The only arithmetic is timestamp comparison. This eliminates an entire class of vulnerabilities (overflow, rounding, division-by-zero) that plague LP wrappers on other chains.

4. **Fail-fast destructure order in `redeem`.** Asserting the time gate *before* destructuring `LockedPosition` is the correct pattern. If the assert fails, the wrapper remains intact and no UID is left in limbo.

5. **Entry wrapper / primitive split.** Separating block-explorer-executable entry functions (with self-transfer) from composable primitive functions (returning values) is clean API design. The `destroy_zero` handling in `claim_fees_entry` is correct and safe.

6. **Event field selection.** `shares` in `Locked` enables stake-weight derivation for downstream indexers. `pool_id` in all events enables cross-package correlation. `owner` in `Locked` captures the locker creator even if the wrapper is later transferred.

7. **No deadline on entry functions.** Correct reasoning — locker operations are not mempool-sensitive (no reserve-ratio race condition), and Sui object ownership already prevents unauthorized execution.

8. **Test boundary coverage.** The 14 tests cover the exact boundaries that matter: exact-unlock redemption, 1ms-before-unlock rejection, strict `>` at lock, zero-fee claims, post-unlock pre-redeem claims, and ownership transfer mid-lock. This is the right test surface for a module with no math.

---

## Overall verdict

**GREEN — mainnet publish readiness**

No HIGH, MEDIUM, or LOW security findings were identified. The two INFORMATIONAL items are polish/consistency suggestions with no security impact. The core invariants — authorization correctness, principal-lock enforcement, fee-harvest safety, transferability, read-only composability, resource lifecycle cleanliness, and downstream-wrapper resilience — all hold under the Sui Move type system and runtime.

The satellite is appropriately minimal, correctly leverages Sui's object model for authentication, and maintains the lock invariant even under arbitrary downstream composition. Ready for testnet smoke test and subsequent mainnet deploy.
