# DeepSeek — R1 Audit Response

**Auditor:** DeepSeek
**Date:** 2026-04-26
**Verdict:** GREEN — ready for mainnet publish (post-smoke test)

---

## Findings

No HIGH, MEDIUM, or LOW severity issues were identified. The contract's design, implementation, and threat model are consistent; the critical invariants hold under Sui's type system and module privacy rules.

### INFORMATIONAL‑1: Self‑transfer lint warnings on entry wrappers (intentional, safe)
**Location:** `lock.move` – `lock_position_entry`, `claim_fees_entry`, `redeem_entry`
**Description:** Each entry wrapper transfers the result back to `tx_context::sender(ctx)`, triggering Sui linter warning `W99001` (non‑composable self‑transfer). The submission already acknowledges this and mirrors the same pattern used in `darbitex::pool`.
**Impact:** None. The warnings are cosmetic; the entry functions are meant for block‑explorer direct execution, not for composition. Downstream composability is provided by the primitive functions (`lock_position`, `claim_fees`, `redeem`) that return values to the caller.
**Recommendation:** No change required. The existing rationale is sound.

---

## Design questions we want answered

### D‑1 `borrow_position` exposes `&LpPosition`
The read‑only reference is safe. Move's borrow checker prevents upgrading `&LpPosition` to `&mut` or by‑value. No public function in `darbitex::pool` consumes `&LpPosition` to extract value or authority; the only mutating call that takes `&mut LpPosition` is `claim_lp_fees`, which is not callable with an immutable reference. The view functions (`position_shares`, `pending_fees`, etc.) leak only publicly readable state. Exposing the immutable reference enables legitimate downstream use cases without compromising the lock invariant.

### D‑2 Asymmetric time semantics (`unlock_at_ms > now` at lock, `now >= unlock_at_ms` at redeem)
Both polarities are correct and align with user expectations. Strict `>` at lock guarantees that even a one‑millisecond lock is meaningful, preventing a degenerate "instant lock" (which wouldn't be a lock at all). Inclusive `>=` at redeem mirrors the natural reading "locked until time T" → at T the lock ends. There is no edge case that breaks the lock's intent. The asymmetry is well‑chosen.

### D‑3 `redeem` does not take `&mut TxContext`
No `ctx` is needed because `redeem` neither creates new objects, reads the sender (auth is by object ownership), nor transfers. The emitted event already contains sufficient context; off‑chain indexers can join with the transaction's `sender` metadata. Adding `ctx` for hypothetical future use would be premature and not improve security.

### D‑4 No permission/delegation model
Relying exclusively on Sui object ownership for authentication is robust and minimal. Delegation use cases (smart wallets, custodians) must wrap the locker in their own contract, which is a deliberate and acceptable trade‑off. This keeps the locker simple and eliminates an entire class of access‑control bugs.

### D‑5 No hard cap on lock duration
`u64::MAX` sentinel for permanent locks is safe. All comparisons are unsigned; no overflow. The absence of an arbitrary cap gives users maximum flexibility without introducing risk.

### D‑6 No extend/shorten/cancel
The one‑way time gate is a deliberate design choice to keep the locker pure and prevent economic gaming by downstream protocols. The on‑chain disclosure clearly documents this limitation. The invariant `unlock_at_ms` immutability is enforced by module privacy (no setter). This is correct.

### D‑7 Pool dependency is sealed Immutable
Both the locker and the pool are sealed immutable; the call surface (`pool::claim_lp_fees`, `pool::position_pool_id`, `pool::position_shares`) is stable forever. Any Sui framework change that breaks the pool would break the entire ecosystem, not just the locker. No special risk.

### D‑8 Composability with downstream staking — lock invariant holds
The invariant "no `LpPosition` extraction from `LockedPosition` before `unlock_at_ms`" is **fully enforced** by the type system and module privacy:
- The fields of `LockedPosition` are not `public`; only this module can destructure it.
- The only public path that returns `LpPosition` is `redeem`, which strictly asserts `now >= unlock_at_ms`.
- `claim_fees` gives a `&mut LpPosition` to `pool::claim_lp_fees`, which cannot extract the position (it only updates fee debt and returns coins).
- `borrow_position` returns an immutable reference that cannot be upgraded.
- No other public function in this module or in `darbitex::pool` can consume or extract a by‑value `LpPosition` from a reference.
- When a downstream staking package holds a `LockedPosition` inside its own struct, it cannot bypass the time gate because destructuring `LockedPosition` is impossible outside this module. The layered defense (object ownership → staking module invariants → locker time gate) is sound.

The assertion that the only path to a by‑value `LpPosition` for an arbitrary caller is through `lock::redeem` (or creating a new one via `pool::add_liquidity`) is **verified**.

### D‑9 Events are sufficient for off‑chain analytics
Each event carries all relevant identifiers (`locker_id`, `position_id`, `pool_id`), timestamps, and value fields (`shares` in `Locked`, `fees_a`/`fees_b` in `FeesClaimed`). Indexers can reconstruct the entire lifecycle without querying chain state. The addition of `pool_id` directly in `FeesClaimed` is an improvement over the Aptos version and simplifies cross‑package correlation. No further data is needed.

### D‑10 Lint warnings not suppressed
The visible self‑transfer warnings are intentional and mirror `darbitex::pool`'s style. No composability harm exists because the primitive functions are designed for composition. This informational noise does not affect security; suppressing would be a cosmetic change only.

---

## Things we got right

- **Invariant enforcement through module privacy:** Making `LockedPosition` fields non‑public is the simplest and strongest way to prevent unauthorized extraction. The design correctly relies on Move's module boundary rather than runtime checks.
- **Fees‑follow‑wrapper design:** By requiring `&mut LockedPosition` for `claim_fees`, Sui's ownership system naturally gates fee claims to the current owner, and fees are returned directly to the caller. No stored owner address or internal accounting is needed, eliminating a class of bugs.
- **Principal recovery independent of pool liveness:** `redeem` does not touch the pool, so even if the pool were somehow frozen (it shouldn't be, because it's immutable), the underlying LP position can still be recovered. This orthogonality is a strong resilience feature.
- **Use of `coin::destroy_zero` in entry wrapper:** Preventing dust zero‑value coins from reaching user wallets is a thoughtful usability improvement with no security downside.
- **`unlock_at_ms = u64::MAX` for permanent locks:** This avoids special sentinel logic and keeps the data model pure.
- **No math, no reentrancy surface, no admin:** The contract has an extremely small attack surface. The acyclic call graph and absence of callback‑capable coin types eliminate reentrancy risk.
- **Comprehensive on‑chain disclosure (`WARNING`):** Users are clearly warned about the immutable, admin‑less nature of the locker and all known limitations. This is a responsible practice.

---

## Overall verdict

**GREEN** — ready for mainnet publish after testnet smoke.

The contract is minimal, well‑reasoned, and correctly enforces all security invariants. The threat model is properly addressed, the design decisions are principled, and no path exists to extract the inner `LpPosition` before the time gate. The composability with downstream staking layers is secure by construction. Pending a successful testnet smoke test with real parameters (as planned), mainnet deployment can proceed.
