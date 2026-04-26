# Darbitex Sui LP Locker — Self-Audit R1

**Package:** `DarbitexLpLocker` (`darbitex_lp_locker`)
**Version:** 0.1.0
**Date:** 2026-04-26
**Chain:** Sui mainnet (target)
**Source:** `sources/lock.move`, 196 LoC, edition `2024.beta`
**Tests:** `tests/lock_tests.move`, 14 tests, all passing
**Compile status:** clean — 0 errors, 4× lint W99001 self-transfer in entry wrappers (intentional, mirrors `darbitex::pool` pattern)
**Dependency target:** `darbitex` core at `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68` (mainnet, sealed/Immutable since 2026-04-26)

---

## Audit categories (per Darbitex satellite SOP)

ABI / args / math / reentrancy / edges / interactions / errors / events.

---

## 1. ABI

Public surface — 12 functions:

| # | Function | Kind | Returns | Notes |
|---|---|---|---|---|
| 1 | `lock_position<A,B>` | primitive | `LockedPosition<A,B>` | composable, return-by-value |
| 2 | `claim_fees<A,B>` | primitive | `(Coin<A>, Coin<B>)` | composable |
| 3 | `redeem<A,B>` | primitive | `LpPosition<A,B>` | composable, consumes wrapper |
| 4 | `lock_position_entry<A,B>` | entry wrapper | — | transfer-to-sender |
| 5 | `claim_fees_entry<A,B>` | entry wrapper | — | transfer-to-sender, zero-coin destroyed |
| 6 | `redeem_entry<A,B>` | entry wrapper | — | transfer-to-sender |
| 7 | `unlock_at_ms<A,B>` | view | `u64` | |
| 8 | `position_shares<A,B>` | view | `u64` | proxies `pool::position_shares` |
| 9 | `pool_id<A,B>` | view | `ID` | proxies `pool::position_pool_id` |
| 10 | `is_unlocked<A,B>` | view | `bool` | convenience |
| 11 | `borrow_position<A,B>` | view | `&LpPosition<A,B>` | read-only inner ref |
| 12 | `read_warning` | view | `vector<u8>` | on-chain disclosure |

**Module-private:**
- `LockedPosition` constructor (only `lock_position` builds one)
- `LockedPosition` destructure (only `redeem` unpacks)

**Findings:**
- All public surface is permissionless. No `Cap`, no admin, no friend.
- No `entry` keyword used (pure `public fun`). Sui PTB-callable. ✓
- `borrow_position` returns immutable ref only — type system prevents `pool::claim_lp_fees` (needs `&mut`) or `pool::remove_liquidity` (consumes by-value) being called via this path. ✓
- Generic `<A, B>` parameters bound by `LpPosition<A,B>` and `Pool<A,B>` — Sui type system enforces pair consistency at compile time.

**Verdict: GREEN.**

---

## 2. Args / parameter validation

### `lock_position(position, unlock_at_ms, clock, ctx)`
- `position: LpPosition<A,B>` — by value, runtime ownership enforced by Sui.
- `unlock_at_ms: u64` — validated `> now` (strict). `unlock_at_ms == now` aborts.
- `clock: &Clock` — Sui shared Clock object. Standard.
- `ctx: &mut TxContext` — for `object::new`.

Edge: `unlock_at_ms = u64::MAX` → passes (5.8×10⁸ years). Equivalent to "never unlock". Valid input, user error scope only.

Edge: `unlock_at_ms = now + 1` → passes. 1ms lock. Trivial but valid.

### `claim_fees(locked, pool, clock, ctx)`
- `locked: &mut LockedPosition` — mutable ref, requires owner authority via Sui object model.
- `pool: &mut Pool<A,B>` — pair binding enforced at compile time. `pool_id` mismatch caught by `pool::claim_lp_fees` assert (`E_WRONG_POOL = 6`, pool.move:374).
- No internal time check — claim is open through full lock period (intentional, matches Aptos parent design).

Edge: pool-position mismatch unreachable in practice — factory enforces canonical-pair invariant (1 pool per `(A,B)` pair). Type system + factory together preclude two `Pool<A,B>` instances.

### `redeem(locked, clock)`
- `locked: LockedPosition` — by value.
- `clock: &Clock`.
- No `ctx` — no object creation, no sender read. Ownership enforced by by-value reception.
- Assert: `now >= unlock_at_ms` (>=, not >, so boundary millisecond unlocks immediately).

Edge: `now == unlock_at_ms` → passes. Tested.
Edge: `now == unlock_at_ms - 1` → aborts. Tested.

### Entry wrappers
- `lock_position_entry`, `claim_fees_entry`, `redeem_entry` all transfer to `tx_context::sender(ctx)`. Zero-value coins destroyed via `coin::destroy_zero` to avoid dust spam (claim_fees_entry).

**Findings:**
- All input validation present.
- No silent truncation, no unchecked casts.
- Sui object ownership is the sole authentication mechanism. No address whitelist, no Cap, no admin. ✓

**Verdict: GREEN.**

---

## 3. Math

**No arithmetic in this module.** All math delegated to `darbitex::pool`:
- `pool::claim_lp_fees` does the per-share accumulator math + debt update.
- `pool::position_shares` is a field read.

Local operations:
- `unlock_at_ms > now` — comparison.
- `now >= unlock_at_ms` — comparison.

No overflow paths, no division, no rounding decisions, no fixed-point.

**Verdict: GREEN — out of scope.**

---

## 4. Reentrancy

Sui Move framework guarantees:
- `Coin<T>` has no callback hooks (no analog of EVM `receive()` or ERC-777 hooks).
- Shared object access is serialized at consensus.
- Move bytecode is non-recursive across module boundaries by design (no `dyn dispatch`).

Cross-package call graph from this module:
- `darbitex::pool::claim_lp_fees` (only mutating call)
- `darbitex::pool::position_pool_id`, `position_shares` (read-only)

Acyclic — `darbitex::pool` does NOT import `darbitex_lp_locker`. ✓

**Specific scenarios checked:**

1. **Flash loan + claim_fees in same PTB.** A PTB could `pool::flash_borrow_a → claim_fees on locked → pool::flash_repay_a`. Effect: `claim_fees` reads pool's current accumulator state. Flash borrow does not advance the accumulator (pool.move flash design accrues fee at repay, not borrow). Re-ordering attack requires moving accumulator forward without paying — pool's `k_after >= k_before` invariant + strict repay equality preclude this. Locker has no exposure beyond what pool itself withstands.

2. **claim_fees called twice in same tx.** Second call: position's `fee_debt` was bumped to current accumulator on first call → returns zero coins. No double-claim possible. ✓ (tested: `test_repeat_claim_no_double_count`)

3. **lock + claim_fees + redeem in same tx with `unlock_at = now+0`.** Aborts at lock_position (strict `>`). ✓

**Verdict: GREEN — N/A.**

---

## 5. Edges

| # | Edge | Behavior | Test coverage |
|---|---|---|---|
| 1 | `unlock_at_ms == now` | abort E_INVALID_UNLOCK | ✓ `test_lock_unlock_at_now_aborts` |
| 2 | `unlock_at_ms < now` | abort E_INVALID_UNLOCK | ✓ `test_lock_unlock_at_past_aborts` |
| 3 | `unlock_at_ms == now + 1` | succeeds, 1ms lock | implicit |
| 4 | `unlock_at_ms = u64::MAX` | succeeds, 580M-year lock | not tested (valid but pointless) |
| 5 | `now == unlock_at_ms` at redeem | succeeds (>= boundary) | ✓ `test_redeem_at_exact_unlock_succeeds` |
| 6 | `now == unlock_at_ms - 1` | abort E_STILL_LOCKED | ✓ `test_redeem_one_ms_before_unlock_aborts` |
| 7 | claim_fees with no fees accumulated | returns (zero, zero), no abort | ✓ `test_claim_fees_no_swap_returns_zero` |
| 8 | claim_fees twice in succession | second returns zero | ✓ `test_repeat_claim_no_double_count` |
| 9 | claim_fees after `now > unlock_at_ms` but before redeem | succeeds | ✓ `test_claim_fees_after_unlock_still_works_before_redeem` |
| 10 | wrapper transferred mid-lock to new owner | new owner can claim+redeem | ✓ `test_locked_wrapper_transferable_*` (×2) |
| 11 | LpPosition with `shares == 0` wrapped | unreachable (pool::add_liquidity asserts shares > 0) | structural |
| 12 | wrapper transferred to `0x0` | object becomes irrecoverable, no exploit | user error scope |
| 13 | `is_unlocked` boundary at exact ms | `>=` semantics | ✓ `test_is_unlocked_boundary` |
| 14 | borrow_position quote → claim immediately after | quote matches claim amount | ✓ `test_borrow_position_pending_fees` |
| 15 | concurrent shared `Pool<A,B>` writers | Sui consensus serializes | framework guarantee |

**Verdict: GREEN — coverage adequate.**

---

## 6. Interactions

External calls:

| Callee | Direction | Effect |
|---|---|---|
| `pool::claim_lp_fees` | mutating | Drains pool fee accumulator share for our position. Returns Coin<A>, Coin<B>. |
| `pool::position_pool_id` | read | Field read on LpPosition. |
| `pool::position_shares` | read | Field read on LpPosition. |
| `clock::timestamp_ms` | read | Sui Clock. |
| `object::new` / `id` / `uid_to_inner` / `delete` | framework | Object lifecycle. |
| `transfer::public_transfer` | framework | Move object to address. |
| `event::emit` | framework | Log structured event. |

**Acyclic dep graph.** `pool` does not import `lock`. ✓

**Sui-specific:**
- No PTB hot-potato types created/consumed by this module.
- No shared object created — `LockedPosition` is owned, not shared.
- No dynamic field access.
- No display/object metadata registration.

**Verdict: GREEN.**

---

## 7. Errors

Local error codes:

| Code | Constant | Path |
|---|---|---|
| 1 | `E_STILL_LOCKED` | `redeem` when `now < unlock_at_ms` |
| 2 | `E_INVALID_UNLOCK` | `lock_position` when `unlock_at_ms <= now` |

Inherited from pool:
- `E_WRONG_POOL = 6` (pool.move) — `claim_fees` when pool ≠ position.pool_id.

No catch-all `assert!(false, ...)` paths. No reused codes. Error messages omitted (Move convention; codes are stable). ✓

**Findings:**
- 2 codes is minimal and complete for this module's invariants.
- Codes 3+ reserved (gap intentional for future-locker-v2 if ever needed; though current package will be sealed immutable, so reservation is moot for this artifact).

**Verdict: GREEN.**

---

## 8. Events

| Event | Fields | Purpose |
|---|---|---|
| `Locked` | locker_id, position_id, pool_id, owner, shares, unlock_at_ms, timestamp_ms | Indexer hook for new lockers |
| `FeesClaimed` | locker_id, position_id, pool_id, fees_a, fees_b, timestamp_ms | Yield analytics |
| `Redeemed` | locker_id, position_id, pool_id, timestamp_ms | Lifecycle close |

**Correlation with parent:**
- `FeesClaimed` correlates with `pool::LpFeesClaimed` via shared `position_id` + same tx.
- Locker events double the on-chain audit trail (firewall #2 trace per the layered-defense design).

**Findings:**
- `Locked` carries `shares` for analytics — derivable from pool but emitted explicitly to spare indexers a lookup.
- `Redeemed` does not emit "redeemer" address — Sui object-transfer events from framework cover that.
- All three events use `copy, drop` (standard).

**Verdict: GREEN.**

---

## 9. Authorization model

**Single mechanism:** Sui object ownership.

| Operation | Required handle | Enforcement |
|---|---|---|
| Lock | `LpPosition<A,B>` by value | Sui runtime — only owner can pass by-value |
| Claim fees | `&mut LockedPosition` | Sui runtime — only owner gets `&mut` |
| Redeem | `LockedPosition` by value | Sui runtime — only owner can pass by-value |
| Read views | `&LockedPosition` | Anyone (not security-relevant; views are public read-only) |

No address checks, no Cap, no admin, no governance.

**Wrapper transferability**: `LockedPosition` has `key, store` → `transfer::public_transfer` works. Transferring carries the lock state. New owner inherits both fee-claim and redeem rights. No owner-address baked into struct.

**Verdict: GREEN.**

---

## 10. Code-level findings

### INFO-1: `redeem` could fail-fast before destructure

Current order at `lock.move:144-152`:
```move
let now = clock::timestamp_ms(clock);
let LockedPosition { id, position, unlock_at_ms } = locked;  // destructure
assert!(now >= unlock_at_ms, E_STILL_LOCKED);                // then assert
```

**Impact:** None — Move's abort path drops all locals automatically; the destructure-then-abort is bytecode-correct.
**Style:** Slight readability hit; convention favors assert-before-destructure. Could refactor:
```move
assert!(now >= locked.unlock_at_ms, E_STILL_LOCKED);
let LockedPosition { id, position, unlock_at_ms: _ } = locked;
```

**Decision:** Refactor to fail-fast variant. Trivial and clarifies intent.

### INFO-2: Entry wrappers carry `W99001` self-transfer lint

4 instances. Intentional pattern — entries are user-facing, transfer-to-sender is the convention. `darbitex::pool` itself ships these warnings (no suppression). Mirrors that style. No action.

### INFO-3: `lock_position` event ordering

Event `Locked` emitted AFTER `LockedPosition` is constructed but BEFORE return. Standard. The locker_id used in event matches the returned object's id. ✓

### No HIGH / MEDIUM / LOW findings.

---

## 11. Sui-specific risks

| Risk | Status |
|---|---|
| UpgradeCap before seal | Deploy SOP requires Tx2 = `package::make_immutable` immediately after publish. Documented in WARNING #8. |
| Pyth/oracle dependency | None — no oracle consumed. ✓ |
| Pool dep upgrade risk | `darbitex::pool` is **sealed Immutable** as of 2026-04-26 → cannot be modified. Locker pinned to that artifact via `Move.lock` mainnet pinning. ✓ |
| Sui framework upgrade | Validators upgrade Sui framework regularly. Module uses only stable framework APIs (clock, coin, event, object, transfer). No deprecated functions. |
| PTB cross-package compose | Documented as composability feature, not risk. Locker primitives are designed to be composed. |
| Shared-object contention | `LockedPosition` is owned (not shared). Pool is shared but Sui handles serialization. |

---

## 12. Test coverage map

14 tests cover:
- Happy paths: lock+redeem, redeem at boundary
- Lock invariants: 2 negative cases (E_INVALID_UNLOCK)
- Redeem invariants: 1 negative case (E_STILL_LOCKED), 1 boundary positive
- Fee claim: zero-fee, with-fees, repeat-no-double, post-unlock-pre-redeem
- Transferability: redeem by new owner, claim by new owner
- Composability: borrow_position pending_fees quote
- Views: is_unlocked progression, read_warning content

**Gaps (not blocking):**
- Entry wrappers (`lock_position_entry`, `claim_fees_entry`, `redeem_entry`) untested directly. They are thin transfer-to-sender wrappers over the tested primitives. Risk: low.
- `unlock_at_ms = u64::MAX` extreme — semantically valid, pointless to test.

---

## 13. Verdict

**GREEN for mainnet publish**, conditional on:
1. Apply INFO-1 refactor (`redeem` fail-fast).
2. Run testnet smoke (lock 100k/100k pool position, claim fees via swap-induced accrual, redeem at unlock_at boundary). SOP requires real-params smoke before seal.
3. Mainnet deploy via SOP: 1/5 multisig publish → smoke → `package::make_immutable` to seal.

No HIGH/MEDIUM/LOW findings. 1 INFO actionable.

---

## 14. Sign-off

Self-audit performed by author with Claude (Anthropic AI). External LLM cross-review (Gemini / Grok / DeepSeek / Kimi / Qwen) optional but not required for satellite of this size — the surface is small (12 fns, 196 LOC) and primitives are inherited from the already-audited `darbitex::pool` core.
