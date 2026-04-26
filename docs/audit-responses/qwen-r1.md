# Qwen — R1 Audit Response

**Auditor:** Qwen
**Date:** 2026-04-26
**Verdict:** 🟢 GREEN — ready for mainnet publish (post-smoke test)

---

## Findings

### HIGH-1: None identified
**Location:** N/A
**Description:** The code contains no paths that bypass authorization, leak principal, or violate the stated lock invariants.
**Impact:** N/A
**Recommended fix:** N/A

### MEDIUM-1: None identified
**Location:** N/A
**Description:** All cross-package calls, state mutations, and resource lifecycles are correctly bounded by Sui's ownership model and Move's linear type system.
**Impact:** N/A
**Recommended fix:** N/A

### LOW-1: None identified
**Location:** N/A
**Description:** Edge cases (clock granularity, zero-fee claims, boundary timestamps) are correctly handled or explicitly documented as accepted trade-offs.
**Impact:** N/A
**Recommended fix:** N/A

### INFORMATIONAL-1: Event `owner` field captures transaction sender, not dynamic ownership
**Location:** `lock.move:~82` (`Locked` event)
**Description:** The `Locked` event records `owner: tx_context::sender(ctx)`, which reflects the address that submitted the lock transaction. If the `LockedPosition` is later transferred via `transfer::public_transfer`, this event field remains unchanged.
**Impact:** Off-chain indexers relying on `event.owner` to track *current* ownership will see stale data. Indexers must track on-chain ownership changes via Sui's `TransferObject` events or wallet-state queries.
**Recommended fix:** No code change required. This is standard for immutable lock-minting events. Document in indexer guidelines that `Locked.owner` is `initial_locker`, not `current_owner`.

### INFORMATIONAL-2: Implicit import completeness assumption
**Location:** `lock.move:~1-5`
**Description:** The provided excerpt omits `use sui::object::{Self, ID, UID};`, `use sui::transfer;`, and `use sui::tx_context::TxContext;`. While noted as "compile-clean", ensure these are explicitly imported in the final `lock.move` to avoid linter/package-resolution drift.
**Impact:** None if already present. Compilation failure if omitted.
**Recommended fix:** Verify imports match Sui CLI 1.70.2 framework paths.

---

## Design questions we want answered

### D-1: `borrow_position` exposes `&LpPosition`
**Verdict:** Safe. Move's borrow checker strictly enforces immutability. `&LpPosition` cannot be coerced to `&mut LpPosition` or consumed by-value. `pool::remove_liquidity` requires `LpPosition` by value, and `pool::claim_lp_fees` requires `&mut`. Neither can be satisfied with a `&` reference. Downstream modules can safely call view-only pool functions (`pool::pending_fees`, etc.) without risking principal extraction or fee claim authority.

### D-2: Asymmetric time boundary (`>` at lock, `>=` at redeem)
**Verdict:** Correct and user-aligned. `unlock_at_ms > now` guarantees a non-zero lock duration (≥1ms). `now >= unlock_at_ms` allows redemption exactly at the deadline millisecond, matching the semantic "locked until T, unlock at T". Flipping either polarity would introduce UX friction or meaningless zero-duration locks. No edge case breaks this model.

### D-3: `redeem` omits `&mut TxContext`
**Verdict:** Optimal. `redeem` consumes an object, deletes its UID, and returns another object. It performs no transfers, creations, or signer reads. Including `ctx` would violate the "minimalist, no-bloat" principle and introduce unnecessary PTB argument overhead. Sender attribution is correctly handled at the transaction layer by indexers.

### D-4: No permit/approval/delegation model
**Verdict:** Correct. Sui's object-centric auth (`&mut` / by-value ownership) is cryptographically and economically sufficient. Adding delegations would expand the attack surface (approval revocation bugs, stale caps, proxy reentrancy) without solving a real Sui-native problem. Custodians/smart wallets should implement delegation at the contract or wallet level, not the primitive.

### D-5: No hard cap on lock duration (`u64::MAX` allowed)
**Verdict:** Safe. `u64` comparisons (`>`, `>=`) are arithmetic-free and cannot overflow. `u64::MAX` ms ≈ 584 million years, effectively permanent. No clock-wrapping or overflow edge exists in Sui's `clock::timestamp_ms` implementation.

### D-6: No extend/shorten/cancel operations
**Verdict:** Strong design choice. Immutability of `unlock_at_ms` eliminates complex state machines, multi-call race conditions, and economic gaming vectors (e.g., dynamic multiplier exploits in downstream staking). Downstream protocols can implement their own "re-lock" patterns if mutability is needed, preserving this module's purity.

### D-7: Pool dep sealed Immutable
**Verdict:** Correct. The locker's security is transitively bound to the sealed pool. Since `pool::claim_lp_fees` is bytecode-frozen, the call surface and math are guaranteed stable. No upgrade risk exists.

### D-8: Composability with downstream wrappers (lock invariant)
**Verdict:** **Invariant holds strongly.** Move's module privacy guarantees that `LockedPosition` can only be destructured within `darbitex_lp_locker::lock`. Downstream wrappers (even buggy ones) can only:
1. Embed it (via `store`)
2. Pass `&LockedPosition` to views
3. Pass `&mut LockedPosition` to `claim_fees` (which only yields fees)
4. Pass `LockedPosition` by-value to `redeem` (which enforces the time gate)
There is zero public ABI surface to extract `LpPosition<A,B>` early. The type system + module boundary act as a cryptographic firewall.

### D-9: Correlation event omission (pool_id included)
**Verdict:** Correct. `FeesClaimed` carrying `pool_id` simplifies off-chain indexing and removes the need for cross-event joins. Since `pool_id` is already public on-chain, no privacy is leaked. Improves indexer reliability.

### D-10: Lint W99001 self-transfer warnings
**Verdict:** Acceptable. Entry wrappers are explicitly non-composable by design. Keeping the lint visible signals intent to auditors/developers. Suppressing it would hide the architectural choice. Mirroring `darbitex::pool` style maintains ecosystem consistency.

---

## Overall verdict
**🟢 GREEN** for mainnet publish readiness.

The package is exceptionally minimal, correctly leverages Sui's object model and Move's type system, and contains no exploitable paths to bypass the principal-lock invariant, steal fees, or leak resources. The security model is correctly bounded to on-chain object ownership, with zero admin or upgrade escape hatches. All 14 test cases cover critical boundaries and composability paths. Proceed to testnet smoke test, then mainnet seal.

---

## Things You Considered and Got Right
1. **By-value embedding over transfer-based custody:** Holding `LpPosition` as a struct field eliminates `extend_ref` complexity, signer-dance overhead, and accidental double-transfer bugs. It's the cleanest Sui-native pattern for wrapping.
2. **`claim_fees` returns coins to caller, not fixed address:** Maximizes composability. PTBs can route fees anywhere; entry wrappers auto-route to sender. No hardcoded beneficiary limits flexibility.
3. **`redeem` returns `LpPosition`, not base coins:** Keeps the locker orthogonal to AMM liquidity accounting. Users retain full control post-unlock (can hold, transfer, or call `remove_liquidity` themselves). Prevents slippage/reserve-swap risks inside the locker.
4. **Fail-fast assert before destructure in `redeem`:** The self-audit applied this correctly. Checking `now >= unlock_at_ms` before consuming `locked` prevents partial execution states and ensures clean abort semantics.
5. **Zero-admin architecture:** Sealing immediately after publish + `object::delete` on redeem + no global registry = true permissionlessness. This eliminates upgrade-cap theft, admin key compromise, and governance attack vectors entirely.
6. **Explicit on-chain disclosure (`read_warning` + `WARNING` constant):** Legally and operationally sound. Sets clear expectations, documents all 10 known limitations, and shifts liability appropriately for an immutable, AI-assisted satellite. Excellent risk transparency.

The code is production-ready. The only prerequisite is the planned testnet smoke test with heterogeneous decimals (e.g., SUI/USDC) to validate cross-package event emission and coin routing under real network conditions.
