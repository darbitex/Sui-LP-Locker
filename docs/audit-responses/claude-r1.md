# Darbitex Sui LP Locker — External Audit Response (Claude, R1)

**Auditor:** Claude (Anthropic, Opus 4.7)
**Audit date:** 2026-04-26
**Scope:** `darbitex_lp_locker::lock` (single file, 196 LoC) per `AUDIT-LOCKER-SUBMISSION.md`
**Methodology:** static review of the Move source against the §5 design decisions, §6 threat-model walk-through, §9 pool surface excerpts, the Sui ownership/borrow model, and the Move type system. No on-chain or test-suite execution by the auditor.
**Pinned dependency reviewed against:** `darbitex` core at `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68` (sealed Immutable per submission).

---

## Executive summary

**Verdict: GREEN for mainnet publish.**

Zero HIGH, zero MEDIUM, zero LOW findings. Four INFORMATIONAL items, all of which are observations or polish suggestions — none block mainnet, none constitute a defect.

The principal-lock invariant (§5 D-8) holds under the Move type system + module privacy. The only path to extract `LpPosition<A,B>` by value from a `LockedPosition<A,B>` is `redeem`, and `redeem` is gated on `clock::timestamp_ms(clock) >= locked.unlock_at_ms`. No alternative public-ABI path produces a by-value `LpPosition<A,B>`, no path upgrades `&LpPosition` to `&mut` or by-value, and no admin override exists.

The submission is unusually well-prepared. The structured §5 design decisions pre-empt nearly every question an auditor would ask, the §6 per-function threat walk-through is explicit about what's enforced by Move vs. by Sui runtime vs. by application logic, and the on-chain `WARNING` constant is the most thorough disclosure I've seen in a Move package. The 14-test suite covers boundary inequalities, transferred-wrapper cases, repeat-claim no-double-count, and the read-only quote → claim composability pattern.

The only thing that meaningfully blocks mainnet is the testnet smoke (§7.3) — which the submission already acknowledges as a gating step.

---

## Findings

### INFORMATIONAL-1: `FeesClaimed` and `Redeemed` events lack actor address

**Location:** `lock.move` — `claim_fees` (event emit, ~line 498), `redeem` (event emit, ~line 523).

**Description:** Of the three events, only `Locked` carries an actor field (`owner: address`). `FeesClaimed` and `Redeemed` carry `locker_id`, `position_id`, `pool_id`, and `timestamp_ms`, but no `claimer` / `redeemer` address.

**Impact:** Off-chain indexers must join with transaction-level metadata or with `pool::LpFeesClaimed` (which does carry `claimer`) to attribute these events to a wallet. For `Redeemed`, no upstream pool event exists — only the tx sender field is available. This is a usability/indexing concern, not a security issue. The on-chain authorization is unchanged because it's enforced by Sui runtime, not by event content.

**Why it isn't worse:** `tx_context::sender(ctx)` is recoverable from any Sui RPC's tx envelope; this is standard practice for Sui indexers. And on the locker-`FeesClaimed` side, `pool::LpFeesClaimed` is emitted in the same transaction with `claimer: tx_context::sender(ctx)`, so indexers correlating both events get the actor for free.

**Design tension:** Adding `redeemer: address` to `Redeemed` requires giving `redeem` a `&mut TxContext`, which D-3 explicitly rejected on minimalism grounds. I think the D-3 trade-off is defensible — but flagging the asymmetry between `Locked.owner` and the missing `Redeemed.redeemer` for the record.

**Recommended fix (optional):** If the asymmetry bothers you, take `&TxContext` (immutable, not `&mut`) in `redeem` solely to read sender for the event. This keeps `redeem`'s "no new objects, no mutation" character intact while making events self-contained. Alternatively, accept the join cost and document the indexer pattern. Either is fine.

### INFORMATIONAL-2: `Locked.owner` field name is mildly misleading at the primitive boundary

**Location:** `lock.move` — `lock_position` event emit (~line 473).

**Description:** `Locked.owner` is set to `tx_context::sender(ctx)`. Through the `lock_position_entry` wrapper this is correct — the entry function transfers the wrapper to the sender immediately, so the recorded `owner` is the eventual owner. But the **primitive** `lock_position` returns the `LockedPosition` by value to the caller and does not transfer it. A composing module could route the wrapper anywhere — to a downstream staking package's struct, to a kiosk, to another address via `transfer::public_transfer`. In those cases, `Locked.owner` records the *creator/sender at lock time*, not the eventual custodian.

**Impact:** Indexer-correctness only. An indexer that treats `Locked.owner` as "current owner" would be wrong from the moment the wrapper moves. There is no security implication.

**Recommended fix (optional):** Rename to `creator` or `sender_at_lock`, or document explicitly in the doc-comment that this field is "the tx sender at lock time, not necessarily the eventual or current owner." Note that Sui object ownership tracking is the source of truth for current owner; the event field is just a convenience snapshot.

### INFORMATIONAL-3: `pool_id` in `FeesClaimed` is sourced from the passed `Pool`, not from the position

**Location:** `lock.move` — `claim_fees` (~line 492), `let pool_id = object::id(pool);`

**Description:** The locker captures `pool_id` from the passed `&mut Pool<A,B>` rather than from the wrapped position via `pool::position_pool_id(&locked.position)`. When pool's `E_WRONG_POOL` assert passes, these are necessarily equal — and when it fails, the tx aborts and the event is not emitted, so the recorded `pool_id` is always correct.

**Impact:** None today. The two values are equal whenever the function returns successfully, and aborts revert events. Defense-in-depth observation only: sourcing from the position's view of `pool_id` would survive a hypothetical future where pool's `E_WRONG_POOL` was relaxed. Given pool is sealed Immutable, that "future" can't happen, so this is a pure stylistic note.

**Recommended fix (optional):** Replace with `pool::position_pool_id(&locked.position)` for consistency with how `Locked` and `Redeemed` derive `pool_id`. Or leave as-is — both are correct. I'd take the consistency.

### INFORMATIONAL-4: `borrow_position` widens read access to inner state if the wrapper is later wrapped in a shared object

**Location:** `lock.move` — `borrow_position` (~line 592).

**Description:** `borrow_position(&LockedPosition) -> &LpPosition` requires only an immutable borrow of `LockedPosition`. For owned wrappers in Sui, `&LockedPosition` is owner-gated by the runtime, so this is appropriately scoped. However, if a downstream protocol later embeds `LockedPosition` inside a *shared* object, anyone with a transaction handle to the shared object can pass `&LockedPosition` and call `borrow_position` to read the inner `LpPosition`'s fields via pool's view fns (`position_shares`, `position_pool_id`, `pending_fees`).

**Impact:** None on this audit's scope. The position fields exposed via pool's view fns (`shares`, `pool_id`, `pending_fees`) are already public information — `pool::LpFeesClaimed` events publish the same data on every claim, and `position_shares` / `position_pool_id` are themselves public functions on pool. There is no privacy-sensitive information to leak. And `&` cannot be upgraded to `&mut` or to by-value, so no value extraction is possible.

This is flagged purely as a composability note for downstream wrapper authors: putting a `LockedPosition` inside a shared wrapper is fine for read access (intentional), but if a downstream protocol wants per-user fee-claim auth that's stricter than "anyone with a tx handle to the shared wrapper", the downstream protocol must enforce that itself — the locker's `claim_fees` is gated by `&mut LockedPosition`, which a shared wrapper would expose to any caller.

**Recommended fix:** None for the locker. Recommend adding to the WARNING constant or to a separate `COMPOSING.md` a sentence like: "Downstream wrappers that hold `LockedPosition` inside a shared object expose `claim_fees` to anyone with a transaction handle to the shared wrapper, since `&mut LockedPosition` can be passed by any tx caller of a shared object. Downstream wrappers wanting per-user claim authority must enforce it themselves." The locker itself is correct as written.

---

## Design questions answered

### D-1: `borrow_position` exposes `&LpPosition`

**Verdict: safe as exposed.** The Move borrow checker forbids upgrading `&T` to `&mut T`, and `LpPosition<A,B>` is declared `has key, store` (not `copy`, not `drop`), so:

- It cannot be copied out of the reference.
- It cannot be moved out of the reference (move requires by-value).
- It cannot be dropped (no `drop` ability — the only ways to consume it are passing by-value to `pool::remove_liquidity` or destructuring inside `darbitex::pool` itself, both module-private operations on pool).

A downstream caller holding `&LpPosition` can only invoke pool's view fns that take `&LpPosition` (the §9.3 read-only views). None of those produce a by-value position. No path upgrades `&` to `&mut`. The counter-argument (hide `borrow_position`, force downstream to mirror state) is correctly rejected — it would just push state duplication onto every downstream consumer for zero security gain.

### D-2: Asymmetric time semantic (`>` at lock, `>=` at redeem)

**Verdict: correct as written.** The asymmetry is the right call:

- `unlock_at_ms > now` at lock prevents zero-duration locks, which would be semantically meaningless and would emit a `Locked` event with `unlock_at_ms == timestamp_ms`, immediately redeemable in the next tx. Strict-`>` here matches the principle that "locked" implies at least 1ms of real lock.
- `now >= unlock_at_ms` at redeem matches the user-facing semantic "locked until time T → at time T, redeem is allowed." The alternative (strict `>` at redeem) would force users to wait one tick past their own deadline, which is user-hostile and unnecessary.

The alternative considered (both strict, requiring `now > unlock_at_ms` at redeem) is correctly rejected. There's no edge case where flipping either polarity is preferable.

One sanity check on the boundary: at lock T0, set `unlock_at_ms = T0 + 1`. Lock succeeds (T0+1 > T0). At T0+1, redeem succeeds (T0+1 >= T0+1). Effective lock duration: 1ms. The contract's "minimum lock = 1ms" is enforced, and the boundary test (`test_redeem_at_exact_unlock_succeeds`) confirms the inclusive redeem semantic. Good.

### D-3: `redeem` does not take `&mut TxContext`

**Verdict: defensible, with one note.** The argument that `redeem` doesn't create new objects (just destructures and deletes one) and doesn't transfer (caller receives the by-value `LpPosition`) is sound. `clock::timestamp_ms` doesn't need ctx. `object::delete` takes `UID` directly. The destructure doesn't need ctx.

The one cost is INFORMATIONAL-1: the `Redeemed` event can't carry a `redeemer: address` without ctx, and indexers must join with tx metadata. If you decide that's worth one parameter, take `&TxContext` (immutable — `redeem` doesn't mint or transfer, so it doesn't need `&mut`). Otherwise, leave as-is.

### D-4: No permit / approval / delegation model

**Verdict: correct.** Sui's owned-object model already gives you owner-gated `&mut` and by-value access. Layering an approval system on top would be either redundant (if it just mirrors object ownership) or subtly different (and introduce attack surface). The trade-off — that custodial smart-wallet patterns must wrap the locker in their own contracts — is the right call. Smart wallets composing the locker is exactly the use case `key, store` enables.

### D-5: No hard cap on lock duration

**Verdict: correct.** The overflow analysis is right: both `unlock_at_ms > now` and `now >= unlock_at_ms` are u64 comparisons that don't overflow regardless of operand magnitude. `u64::MAX` ms ≈ 580M years, which is "permanent" for any practical purpose. Any cap would be arbitrary and would lock out the legitimate "permanent burn" use case (token-launch trust signal). Leave uncapped.

### D-6: No extend / shorten / cancel

**Verdict: correct.** This is the single most important design decision in the file. `extend_unlock_at` is the kind of "looks benign" operation that creates exactly the multi-call gameability surface you'd want to avoid in a primitive lock. Downstream protocols that need extension semantics can implement them on their own (re-lock-after-redeem, or composite stake-and-extend logic in a staking package). Hard reject of shorten/cancel is obvious. The KNOWN LIMITATION #1 disclosure in the WARNING constant is the right way to communicate this to users.

### D-7: Pool dep is sealed Immutable

**Verdict: correct, with the caveat already noted in §4.** Pool being sealed means the locker's `pool::claim_lp_fees` call surface is bytecode-frozen. The locker pins via `Move.lock` mainnet pinning to the sealed package address. The framework-deprecation concern is correctly out of scope — if Sui validators ship a framework upgrade that breaks `clock::timestamp_ms`, `coin::from_balance`, etc., the entire Sui ecosystem breaks together, not just this locker.

### D-8: Composability with planned staking package — lock invariant must hold

**Verdict: invariant holds.** This is the single most important verification request, and I want to be explicit about how it's enforced.

The claim:
> The only path to extract `LpPosition<A,B>` from `LockedPosition<A,B>` is `darbitex_lp_locker::lock::redeem`, which requires `clock::timestamp_ms(clock) >= locked.unlock_at_ms`.

Enforcement chain:

1. **`LockedPosition<A,B>` destructure is module-private to `darbitex_lp_locker::lock`.** Move struct destructure (`let LockedPosition { id, position, unlock_at_ms: _ } = locked`) is only legal inside the module that defines the struct. No downstream module can destructure `LockedPosition` to extract `position`. ✓

2. **Only `redeem` performs the destructure.** Searching the source: `lock_position` constructs but does not destructure; `claim_fees` takes `&mut LockedPosition` (no destructure); the entry wrappers and views never destructure. Only `redeem` does. ✓

3. **`redeem` asserts the time gate before destructure.** `assert!(now >= locked.unlock_at_ms, E_STILL_LOCKED)` runs first (per §6.3 — fail-fast, applied as the INFO actionable from self-audit). The destructure cannot execute if the assert aborts. ✓

4. **No public function returns `LpPosition<A,B>` by value other than `redeem`.** Reviewed each public fn in `lock.move`:
   - `lock_position`: takes `LpPosition` by value, returns `LockedPosition`. Consumes, doesn't produce.
   - `claim_fees`: returns `(Coin<A>, Coin<B>)`. Doesn't produce `LpPosition`.
   - `redeem`: returns `LpPosition` (gated). ✓
   - Entry wrappers: same as primitives + transfer.
   - Views (`unlock_at_ms`, `position_shares`, `pool_id`, `is_unlocked`, `borrow_position`, `read_warning`): return `u64`/`ID`/`bool`/`&LpPosition`/`vector<u8>`. None return `LpPosition` by value. ✓

5. **`borrow_position` returns `&LpPosition` (immutable).** Move's borrow checker forbids:
   - Upgrading `&T` to `&mut T` (would-be use: passing to `pool::claim_lp_fees`).
   - Moving `&T` to `T` by value (would-be use: passing to `pool::remove_liquidity`).
   - Storing `&T` in a struct (references lack `store`).
   - Copying — `LpPosition<A,B>` lacks `copy` ability per §9.1, so even a copy-from-reference is structurally impossible. ✓

6. **`LpPosition<A,B>` has no `drop`.** From §9.1 (`has key, store`, no `drop`, no `copy`), the position cannot be silently destroyed by a downstream wrapper holding it. The only ways to consume it are pool-internal destructure (via `remove_liquidity`) or being held in a `LockedPosition` (which keeps it alive until `redeem`). ✓

7. **Pool's API does not produce a by-value `LpPosition` for arbitrary callers.** Per §9 and the submission's assertion in §9.4: the only ways for a caller to obtain a by-value `LpPosition<A,B>` are (a) creating it themselves via `pool::add_liquidity` (their own LP, never in a locker), or (b) receiving it from `lock::redeem` (gated). No other public pool function returns `LpPosition` by value. ✓

The invariant is enforced **by the Move type system + module privacy**, not by application logic. That's the strongest possible guarantee. Even a buggy or malicious downstream wrapper holding `LockedPosition<A,B>` cannot extract `LpPosition<A,B>` early — the Move compiler would refuse to compile the offending code, period.

The "three independent firewalls" framing in §5 D-8 is accurate. I'd call out specifically that firewall (3) — the locker time-gate — is enforced at compile-time by Move's privacy rules and does not depend on the staking package's correctness. That's the load-bearing property.

### D-9: `FeesClaimed` carries `pool_id` directly

**Verdict: correct.** No de-anonymization concern — `pool_id` is already public via `pool::LpFeesClaimed` and via the Sui object graph (any LP position is associated with its pool by the `Pool<A,B>` type and `position.pool_id` field, both public). Self-contained events are unambiguously better for indexers. The Aptos-vs-Sui asymmetry is explained well — Sui's `pool::position_pool_id` being public is what enables this; Aptos's was module-private.

### D-10: Lint warnings unsuppressed on entry wrappers

**Verdict: correct.** The W99001 self-transfer lint on entry wrappers is a true positive — the entry forms are non-composable. That's the *whole point* of an entry wrapper: convenience for direct human/explorer callers, with the primitive forms (`lock_position`, `claim_fees`, `redeem`) returning values directly for composers. Suppressing the lint with `#[allow(...)]` would be cosmetic and would lose the visible signal that "these are end-user-facing, not building blocks." Keep visible.

---

## Specific verifications requested (§1 and §10)

| § | Concern | Verdict |
|---|---|---|
| §1.1 | Authorization correctness | ✓ Sui runtime gates `&mut` and by-value handles to the current owner; no path bypasses this. |
| §1.2 | Principal-lock invariant | ✓ See D-8 above — enforced by Move privacy + type system. Compile-time guarantee. |
| §1.3 | Fee harvest invariant | ✓ `claim_fees` is `&mut`-gated to owner; pool's `E_WRONG_POOL` covers cross-pool misuse; no path from `claim_fees` to LP extraction (different return types — coins vs position). |
| §1.4 | Transferability correctness | ✓ `key, store` + struct field embedding means `transfer::public_transfer` carries lock state verbatim. Original owner loses handle on transfer (Sui runtime), new owner inherits both fee-claim and redeem rights. Tests `test_locked_wrapper_transferable_redeem_by_new_owner` and `test_locked_wrapper_new_owner_can_claim_fees_during_lock` cover the post-transfer paths. |
| §1.5 | Read-only inner-ref leak | ✓ See D-1 above. `&LpPosition` cannot be upgraded to `&mut` or by-value; cannot be copied (no `copy` ability); cannot be stored (refs lack `store`). |
| §1.6 | Resource lifecycle | ✓ `redeem` destructures, calls `object::delete(id)`, returns `position` by value. UID is consumed. No leaked `ExtendRef`-like resources (the locker has none — Sui's by-value field embedding obviates the Aptos `extend_ref` pattern entirely). |
| §1.7 | Interaction with `darbitex::pool` | ✓ Single mutating call (`pool::claim_lp_fees`); call surface matches §9.2 signature; `(Coin<A>, Coin<B>)` is forwarded to caller without modification or stash. |
| §1.8 | Event attribution | ✓ With INFORMATIONAL-1 noted. Fields are sufficient for the primary indexing patterns; actor address is derivable from tx metadata or correlated pool events. |
| §1.9 | Composability with downstream wrappers | ✓ See D-8 above. The `key, store` ability surface, combined with module-private destructure, lets the lock invariant survive arbitrary downstream wrapping. |
| §1.10 | Admin override or trust escape | ✓ None found. No `Cap`, no admin address, no global registry, no pause, no extend, no shorten, no cancel. The `WARNING` constant's KNOWN LIMITATION #1 is on-chain-truthful. |

§10 questions:

- **Path from public ABI to by-value `LpPosition` other than `redeem`?** None. Verified via D-8 enforcement chain.
- **`borrow_position` safe?** Yes. Move's reference rules + ability constraints make extraction structurally impossible.
- **Asymmetric time semantic correct?** Yes — see D-2.
- **Events sufficient for downstream staking integration?** Yes for primary attribution (locker_id, position_id, pool_id correlate cleanly with pool events). With INFORMATIONAL-1's note, consider adding actor addresses if you want self-contained events; otherwise, the join pattern is standard.
- **What survived scrutiny that should stay locked in?** See "What survived scrutiny" below.

---

## What survived scrutiny

You asked for this section explicitly. These decisions held up under review and are load-bearing:

1. **By-value field embedding of `LpPosition` inside `LockedPosition`** instead of the Aptos `extend_ref` + child-object pattern. This is the single most important Sui-native simplification. It eliminates the entire signer-dance attack surface that the Aptos predecessor needed (`object::owner(locker) == signer::address_of(user)` checks, `extend_ref` storage, the locker-signer indirection for fee claims). On Sui, "the wrapper holds the position by value" makes principal-lock a structural property of Move, not a runtime check. Keep this.

2. **Module-private destructure as the only extraction route.** `let LockedPosition { id, position, unlock_at_ms: _ } = locked;` appears exactly once in the source — inside `redeem`, after the time gate. This is the cleanest possible enforcement of the principal-lock invariant. No alternative design (global mapping of locker→state, capability tokens, etc.) would be as tight.

3. **Asymmetric time inequality (`>` at lock, `>=` at redeem).** Symmetric alternatives are either user-hostile (`>` at redeem forces a 1ms post-deadline wait) or semantically loose (`>=` at lock allows zero-duration locks). The current asymmetry is the unique correct choice.

4. **`redeem` does not touch the pool.** Principal recovery being independent of pool liveness is a real property — if the pool is somehow degraded (deep-out-of-balance state, paused future feature, etc.), users can still recover their `LpPosition`. Keeping the pool dep limited to `claim_fees` is the right minimal interaction.

5. **No admin, no Cap, no global registry.** Each `LockedPosition` is independent. The lockers don't share state. Catastrophic-failure blast radius is one user's locker, never the whole protocol.

6. **`key, store` for the wrapper.** This is the composability hinge. Without `store`, downstream protocols can't embed `LockedPosition` in their structs — they'd be forced into shared-object wrapping, which has the auth concerns flagged in INFORMATIONAL-4. With `key, store`, downstream protocols get owned-object semantics and inherit the time-gate by structural composition.

7. **Coin handling via Move's linear types.** `claim_fees` returns `(Coin<A>, Coin<B>)`; the compiler enforces consumption before function exit. The `claim_fees_entry` zero-coin handling (`if value > 0 transfer else destroy_zero`) avoids dust-coin spam without risk — `coin::destroy_zero` aborts on positive value, so the `else` branch is provably safe.

8. **No deadline parameter on entry fns.** D-7's argument is correct: locker operations are not mempool-sensitive (no reserve-ratio race like add/remove liquidity), and Sui object ownership prevents unauthorized execution. Adding `deadline_ms` would be cargo-culting from pool.

9. **Comprehensive on-chain `WARNING` constant with 10 known limitations.** This is genuinely best-in-class for a permissionless immutable Move package. The "non-exhaustive lower bound" framing in limitation #10 is intellectually honest and well-phrased — it directly counters the "the audit said it was safe" social-engineering pattern.

10. **Pre-applied INFO actionable: fail-fast destructure-order in `redeem`.** Asserting `now >= locked.unlock_at_ms` *before* the destructure (rather than after, when `id` and `position` are already pulled out) means a failed redeem doesn't even partially deconstruct the wrapper. It's the right ordering and the self-audit catching it pre-submission shows good discipline.

11. **Event field choices specifically for cross-package correlation.** Including `pool_id` in all three locker events lets indexers join with `pool::LpFeesClaimed` / `pool::LiquidityAdded` events without needing to maintain a locker→pool mapping. The `shares: u64` in `Locked` (for stake-weight derivation by downstream staking packages) is forward-thinking and the right field to expose at lock time.

12. **The 14-test suite tests boundaries, not just happy paths.** `test_redeem_at_exact_unlock_succeeds` (boundary inclusive), `test_redeem_one_ms_before_unlock_aborts` (boundary -1), `test_lock_unlock_at_now_aborts` (strict-`>` lock side), and `test_is_unlocked_boundary` (4999/5000/5001 view symmetry) are the exact tests an auditor would ask for. The transfer-then-redeem and transfer-then-claim tests cover the post-transfer auth paths. Repeat-claim-no-double-count tests the pool's accumulator integration. This is solid coverage for 196 LoC.

---

## Overall verdict

**GREEN for mainnet publish.**

The four INFORMATIONAL items are observations and polish suggestions; none constitute a defect that would block deployment. The principal-lock invariant is structurally enforced by Move's type system and module privacy. The authorization model leans entirely on Sui's owned-object semantics, which is the right choice on Sui. The on-chain disclosure is thorough.

Gating items before mainnet (already acknowledged in the submission, listed for completeness):

1. **Testnet smoke test (§7.3).** Run the real-params flow (heterogeneous-decimal pair, e.g. SUI/USDC, lock → swap-induced fees → claim → redeem at boundary) on Sui testnet before mainnet publish. This is the standard SOP step — not a code concern.
2. **Confirm pinned pool address in `Move.lock` matches the sealed `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68`.** Trivial but worth re-checking immediately before publish.
3. **Tx2 (`package::make_immutable`) lined up immediately after Tx1 (publish).** Per the SOP. No compat soak window is the right call here — pool is already sealed, locker has nothing to gain from a soak phase.

If you want a follow-up review pass, the natural Round 2 would be on the planned staking package that wraps `LockedPosition<A,B>` — that's where the firewall-(3) load-bearing argument from D-8 gets its first real downstream test.

— Claude
