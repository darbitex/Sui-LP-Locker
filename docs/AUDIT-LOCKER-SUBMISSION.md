# Darbitex Sui LP Locker — External Audit Submission (Round 1)

**Package:** `DarbitexLpLocker` (`darbitex_lp_locker`)
**Version:** 0.1.0
**Date:** 2026-04-26
**Chain:** Sui mainnet (target)
**Edition:** `2024.beta`, Sui CLI `1.70.2-6d4ec0b0621d`
**Audit package size:** 1 Move source file (`sources/lock.move`), 196 LoC, compile-clean (4 lint W99001 self-transfer warnings on entry wrappers, intentional, mirrors `darbitex::pool` style)
**Test suite:** `tests/lock_tests.move`, 14 tests, all passing
**Self-audit:** `docs/AUDIT-R1-SELF.md` (GREEN, 0 HIGH/MED/LOW, 1 INFO actionable applied pre-submission)
**Dependency target:** `darbitex` core at `0xf4c6b9255d67590f3c715137ea0c53ce05578c0979ea3864271f39ebc112aa68` (Sui mainnet, **sealed Immutable** since 2026-04-26)
**Previous deploys:** none.
**Planned mainnet publisher:** TBD (1/5 multisig publish → smoke → `package::make_immutable` → 3/5 multisig irrelevant since sealed; SOP per `feedback_mainnet_deploy_sop.md`).
**Upgrade policy:** sealed via `package::make_immutable` immediately after publish (Tx2). No compat soak phase — `darbitex::pool` is already sealed Immutable, so the locker has nothing to gain from a compat window.

---

## 1. What we are asking from you

You are reviewing a single Move source file for a **small external satellite** that wraps Darbitex Sui's `LpPosition<A,B>` object inside a time-based lock. We want an **independent security review** focused on:

1. **Authorization correctness** — can any unauthorized party call `claim_fees`, `redeem`, or otherwise extract value from someone else's locker? Sui object ownership is the sole authentication mechanism; verify no path bypasses this.
2. **Principal-lock invariant** — can the wrapped `LpPosition` be extracted from a `LockedPosition` before `unlock_at_ms`? The only intended path is `redeem` after deadline. Verify no other path (claim_fees, views, framework primitives) leaks a way to recover the `LpPosition` early.
3. **Fee harvest invariant** — `claim_fees` is open throughout the lock period. Verify (a) it works correctly, (b) it does not leak any authority beyond fees (i.e., no path from claim_fees to extracting LP shares).
4. **Transferability correctness** — `LockedPosition` has `key, store` and is transferable via `transfer::public_transfer`. Verify lock state carries correctly on transfer; original owner cannot reclaim after transfer; new owner inherits both fee-claim and redeem rights.
5. **Composability — read-only inner-ref leak** — `borrow_position(&LockedPosition) -> &LpPosition` returns an immutable reference. Verify there is no way to upgrade this `&LpPosition` to a `&mut` or by-value handle in a downstream caller, and no way to use the immutable ref to extract value.
6. **Resource lifecycle** — `redeem` destructures `LockedPosition` and calls `object::delete(id)`. Verify the UID is cleanly deleted with no dangling refs, no leaked `ExtendRef`-like resources (we have none, but please confirm).
7. **Interaction with `darbitex::pool`** — only one mutating call (`pool::claim_lp_fees`). Verify the call surface matches pool's expectations and the returned `(Coin<A>, Coin<B>)` is correctly forwarded to caller.
8. **Event attribution** — 3 events (`Locked`, `FeesClaimed`, `Redeemed`). Verify fields capture everything an off-chain indexer needs.
9. **Composability with planned staking package** — see §5 D-8. The locker is designed to be wrapped inside a future staking package's `StakePosition` enum. The lock invariant must hold even when `LockedPosition` is held inside arbitrary downstream wrappers. Verify nothing in the public ABI lets a downstream wrapper extract `LpPosition` early.
10. **Any admin override or trust escape we did not explicitly acknowledge.**

**Output format we'd like back:**

```
## Findings

### HIGH-1: <title>
Location: lock.move:<line>
Description: <what>
Impact: <why it matters>
Recommended fix: <how>

### MEDIUM-1: ...
### LOW-1: ...
### INFORMATIONAL-1: ...

## Design questions we want answered
(any specific question from §5 below)

## Overall verdict
(green / yellow / red for mainnet publish readiness)
```

Please also comment on **things we considered and got right** — we want to know which decisions held up under scrutiny, not just where we failed.

---

## 2. Project context

**Darbitex Sui LP Locker** is a **tiny external satellite** for Darbitex Sui's xyk AMM. It wraps an existing `darbitex::pool::LpPosition<A,B>` object inside a new `LockedPosition<A,B>` Sui object with an `unlock_at_ms: u64` gate. The wrapped position is held **by-value** inside the wrapper struct (Sui semantics — embedded as a field, not transferred to a child object). LP fees remain claimable throughout the lock period — only the **principal** (extracting the `LpPosition`) is gated.

**Why a satellite (not a core upgrade):**

- **Core is sealed Immutable.** Darbitex Sui core at `0xf4c6b925...` was sealed via `package::make_immutable` on 2026-04-26. There is no upgrade path. Any new feature must ship as a satellite consuming the existing public API.
- **Faithful to Darbitex's "satellite over feature upgrade" rule** (memory: `feedback_no_core_upgrade.md`). Features live in satellites; core stays minimal.
- **Minimalism.** Final 196 LoC. The entire attack surface fits on two screens.

**Sui-specific differences from the Aptos predecessor (`darbitex_lp_locker::lock`, 179 LoC):**

| Concern | Aptos | Sui |
|---|---|---|
| Position custody | `object::transfer(position, locker_addr)` + `extend_ref` to act as owner for fee claims | by-value field embedding (`position: LpPosition<A,B>` inside struct) — no signer dance needed |
| Authorization | `object::owner(locker) == signer::address_of(user)` | Sui runtime — `&mut LockedPosition` only obtainable by current owner |
| Time source | `timestamp::now_seconds()` | `clock::timestamp_ms(&Clock)` — shared object |
| Wrapper transferability | `object::transfer<LockedPosition>` (Aptos object) | `transfer::public_transfer(locked, addr)` (`key, store`) |
| Fee proxy mechanism | locker_signer via extend_ref → `pool::claim_lp_fees(&signer, position)` | `pool::claim_lp_fees(&mut pool, &mut position, ...)` direct mutable borrow |
| Composability for downstream wrappers | requires extending `LockedPosition` fields or new resource | `key, store` lets `LockedPosition` sit inside any downstream struct or enum variant |

**Design philosophy (owner-mandated):**

- **Se-primitive mungkin, sesederhana mungkin.** 1 struct, 3 primitives, 3 entry wrappers, 5 views, 1 disclosure. No extend / shorten / partial unlock / fee beneficiary / emissions / governance / admin.
- **Zero admin surface.** No global registry, no `Cap`, no admin address. Each `LockedPosition` is independent.
- **Block-explorer executable.** Every entry function's args are `address`/`u64`/`Object<T>`/coin types. Sui Explorer "Run Function" must work without a frontend.
- **Transferability is Sui-native.** `transfer::public_transfer<LockedPosition>` from sui framework handles ownership change. Lock state is a struct field; transferring the struct carries it.
- **No sentinel for permanent locks.** Want permanent? Set `unlock_at_ms = u64::MAX`. No special case.
- **Composability for downstream wrappers.** `key, store` ability means `LockedPosition<A,B>` can be embedded as a field in a future staking package's `StakePosition` enum (or any other wrapper), with the lock invariant preserved end-to-end.

**Differentiators vs state of the art on Sui:**

- **Cetus `lp_burn.move`** — production-proven wrapper-NFT-escrow pattern, but **permanent-only** (no time-based unlock).
- **Turbos LP Lock** — closed-source, behaviorally narrower than Cetus.
- **No production Sui locker** (as of 2026-04-26) ships time-based unlock with **fees-while-locked** AND **wrapper transferability** AND **`key, store` composability for downstream wrapping**.

---

## 3. Core design principles

These are **intentional**. If you find something that violates one of these, that's a HIGH finding. If you disagree with a principle, note it under "Design questions" rather than as a finding.

1. **Wrapper, not forwarder.** `LockedPosition<A,B>` directly owns the `LpPosition<A,B>` as a by-value struct field (`position: LpPosition<A, B>`). The user's wallet owns the `LockedPosition`, and the `LpPosition` lives inside it. No way to address the inner `LpPosition` via Sui object id from outside the locker — it has its own UID but it's "wrapped" inside the locker struct (owned by the locker via Move's struct semantics, not by Sui ownership transfer).

2. **Fees follow the wrapper, not the original locker.** `claim_fees` requires `&mut LockedPosition`. Sui's runtime enforces "only current owner can pass `&mut`" for owned objects. So whoever owns the wrapper at call-time can claim fees. The fees are returned as `(Coin<A>, Coin<B>)` to the **caller** (whoever invoked the function); they are not deposited to a stored owner address. On wrapper transfer, the new owner gets all subsequent fee claims because they hold `&mut`.

3. **Transfer preserves lock state.** `LockedPosition` has `key, store` so `transfer::public_transfer` works. Lock state (`unlock_at_ms`, wrapped `position`) lives inside the struct. Transferring the wrapper carries the struct verbatim — zero custom transfer logic needed.

4. **Redeem returns the intact `LpPosition<A,B>`, not withdrawn reserves.** After `redeem`, the user can call `pool::remove_liquidity` themselves — or keep the position and continue earning fees as a normal LP. The locker does not short-cut through `remove_liquidity`. Keeps the locker orthogonal to pool liquidity accounting.

5. **No `unlock_at_ms == now` loophole.** `lock_position` asserts `unlock_at_ms > now` (strict `>`). Matches the semantic that "locked" must mean at least one millisecond of real lock. Callers who want "no lock" shouldn't call the locker at all.

6. **`now >= unlock_at_ms` for redeem.** Inclusive boundary — the millisecond `clock` reaches `unlock_at_ms`, redeem is allowed. Matches the Aptos predecessor and matches user expectation ("locked until 5pm" → at 5pm sharp the lock is over).

7. **No deadline on entry fns.** Unlike `pool::add_liquidity_entry` / `remove_liquidity_entry` which take `deadline_ms`, the locker entries do **not**. Reasoning: the operations are not mempool-sensitive (no reserve-ratio race condition to front-run, since locker doesn't trade), and Sui object ownership already prevents unauthorized execution. Adding deadline = bloat without value.

8. **No math.** The locker does not do arithmetic. The only operations are `unlock_at_ms > now` and `now >= unlock_at_ms` comparisons. Zero overflow risk, zero rounding risk, zero division.

9. **No reentrancy surface.** `claim_fees` calls `pool::claim_lp_fees`, which performs balance split + coin emission. Sui `Coin<T>` has no callback hooks (unlike EVM ERC-777). Cross-package call graph is acyclic — `darbitex::pool` does not import `darbitex_lp_locker`.

10. **`borrow_position` is read-only.** Returns `&LpPosition<A,B>`. Move's borrow checker prevents upgrading this to `&mut` or by-value. The function is for downstream view-only consumers — e.g., a staking package or a frontend wanting to call `pool::pending_fees(&pool, &lp)` without claim authority. Mutable access to the inner LP is **only** via `claim_fees`, which is bound to the explicit fee-claim path.

11. **Composability for downstream wrappers.** `key, store` ability lets `LockedPosition<A,B>` sit inside an enum variant or struct field of any downstream Move module. The planned (separate, not in this audit scope) staking package will hold `LockedPosition<A,B>` inside a `StakedLp<A,B>::Locked(LockedPosition<A,B>)` enum variant. The lock invariant — "no `LpPosition` extraction before unlock_at_ms" — is preserved by Move's type system + module privacy: only `redeem` can destructure `LockedPosition`, and `redeem` checks the time gate. Downstream wrappers cannot bypass this.

12. **Events for analytics, not authentication.** Events are emit-only and carry the full data needed for off-chain indexers (`shares` in `Locked` for stake-weight derivation; `pool_id` in all 3 for cross-package correlation with `pool::LpFeesClaimed`). Auth is enforced by Sui runtime, not events.

---

## 4. Security model and trust assumptions

### Trusted parties

- **Publisher** (TBD: 1/5 bootstrap multisig; sealed immediately after publish): publishes the satellite. After `package::make_immutable` (Tx2), the UpgradeCap is destroyed and there is **no upgrade path, ever**.
- **Darbitex Sui core** at `0xf4c6b925...`: the locker trusts core's `pool::claim_lp_fees` semantics (per-share accumulator math, balance split, event emission, k-invariant). Core passed its own R1 self-audit (5/5 GREEN, sealed 2026-04-26).
- **Sui framework**: standard.

### Untrusted parties

- Anyone can call any locker function as long as they hold the required object handle.
- Anyone can receive a transferred `LockedPosition` (via `transfer::public_transfer`).
- Sui object ownership at the runtime level is the sole authentication mechanism for `&mut` and by-value paths.

### Threat model we care about

1. **Unauthorized fee harvest** — can a non-owner extract fees from someone else's locker?
2. **Unauthorized redeem** — can a non-owner pull the principal?
3. **Principal-lock bypass** — can the user (or anyone) bypass the lock by directly calling `pool::remove_liquidity` on the wrapped position? They shouldn't be able to: the `LpPosition<A,B>` is held by-value inside `LockedPosition` and is **not addressable** as a top-level Sui object — Move's borrow checker won't let any caller obtain a `&mut LpPosition` or by-value `LpPosition` except through this module's `claim_fees` (`&mut`) or `redeem` (by-value, time-gated).
4. **Lock-state mutation post-lock** — can `unlock_at_ms` be changed after `lock_position`? Field is module-private; only the `redeem` destructure ever rewrites it, and that's a destructure (not a mutation).
5. **Double-spend on owner transfer** — if Alice transfers the locker to Bob, can Alice still call `claim_fees` or `redeem`? She shouldn't — Sui runtime tracks current owner; once transferred, Alice no longer has the handle.
6. **Stuck position** — can the wrapped `LpPosition` ever be stuck in the locker with no path out? Only if `now < unlock_at_ms` forever, which only happens if `unlock_at_ms = u64::MAX` (user-chosen permanent lock). For finite `unlock_at_ms`, redeem path is always available.
7. **Event spoofing** — can an attacker emit a fake `Locked` / `FeesClaimed` / `Redeemed` event from outside the module? Sui event emission is tied to module address; off-chain indexers should filter by `<package_addr>::lock::<EventName>`.
8. **Resource leak on redeem** — after `redeem`, is `LockedPosition` fully destructured and `id` deleted? Verify no path leaves a dangling UID in storage.
9. **Coin handling on claim_fees** — `pool::claim_lp_fees` returns `(Coin<A>, Coin<B>)`. Verify there is no path where these coins get dropped without being returned to caller (Move's linear type system should prevent this; please confirm at the bytecode level).
10. **Composition with downstream wrappers** — when a future staking package holds `LockedPosition<A,B>` inside its own struct, can that staking package (even with bugs) extract the `LpPosition<A,B>` early? See §5 D-8.

### Threat model we do NOT care about

- **Dead lockers** (user forgets they have one) — not a security issue.
- **Gas griefing** — the locker is self-contained; caller pays their own gas.
- **Off-chain indexer decisions** — out of scope.
- **Pool dep upgrades** — pool is sealed Immutable; cannot change.
- **Sui framework upgrades** — validators upgrade Sui framework regularly. Module uses only stable framework APIs (clock, coin, event, object, transfer, tx_context). No deprecated functions.
- **User error** (transferring wrapper to `0x0`, locking with `unlock_at = u64::MAX`, etc.) — valid input, user's responsibility.

---

## 5. Key design decisions we want challenged

### D-1: `borrow_position` exposes `&LpPosition`

**Decision:** Public view `borrow_position(&LockedPosition<A,B>) -> &LpPosition<A,B>`.

**Rationale:** Lets downstream wrappers (staking, escrow, marketplace) and frontends call view fns like `pool::pending_fees(&pool, &lp)` without holding claim authority. Mutable access to the inner LP is only via `claim_fees` (which itself is bound to the fee-claim semantics — no path from `claim_fees` to LP extraction).

**Concern:** Does exposing the immutable inner ref enable any unintended capability?

**Specific verifications requested:**
- Move's borrow checker enforces "from `&T` you can only get `&` of fields, never `&mut`" — verify this holds for `&LpPosition` consumers.
- `pool::remove_liquidity` consumes `LpPosition` by value, not by `&` — verify the borrow ref cannot be coerced.
- `pool::claim_lp_fees` requires `&mut LpPosition` — verify the borrow ref cannot be upgraded to `&mut`.
- Any other public function in `darbitex::pool` that takes `&LpPosition`: are there read-only fns that would leak useful info to an attacker? (Looking at pool.move §9.4: `position_shares`, `position_pool_id`, `position_fee_debt` — all just field reads, no security implication.)

**Counter-argument considered:** Hide `borrow_position`, force downstream to maintain their own mirror of position state. Rejected because: (a) duplicates state on-chain unnecessarily; (b) downstream view-only quote functionality is a legitimate need; (c) Move's type system already enforces the read-only constraint.

### D-2: `unlock_at_ms > now` strict inequality at lock; `now >= unlock_at_ms` inclusive at redeem

**Decision:** Asymmetric — strict at lock, inclusive at redeem.

**Rationale:**
- At lock: "locked until time T" should mean lock duration ≥ 1ms. `unlock_at == now` is meaningless. Strict guards the semantic.
- At redeem: "locked until time T" should mean "at time T, lock is over". Inclusive matches user expectation.

**Concern:** Is there a sensible reason to flip either polarity?

**Alternative:** Both strict (would require `now > unlock_at_ms` at redeem, i.e., user must wait 1ms past deadline). Rejected — user-hostile.

### D-3: `redeem` does not take `&mut TxContext`

**Decision:** Signature is `redeem<A,B>(LockedPosition, &Clock) -> LpPosition`. No ctx.

**Rationale:** Redeem doesn't create new objects (just destructures + deletes one), doesn't read sender (caller is implicit via by-value reception of `LockedPosition`), doesn't transfer. So `ctx` is not needed.

**Concern:** Should we keep ctx for future-proofing (e.g., if we ever want to emit sender in `Redeemed` event)?

**Counter:** That's premature flexibility. The event already includes `locker_id`, `position_id`, `pool_id`, `timestamp_ms`. Sui's tx-level metadata captures the sender. Indexers can join.

### D-4: No `permit` / approval / delegation model

**Decision:** Sui object ownership is the sole authentication. No address whitelists, no approval, no delegation, no Cap.

**Rationale:** Sui's object model already gives you "only the owner can pass `&mut` or by-value handles". That's authentication. Anything else is bloat.

**Concern:** Use cases that need delegation (e.g., a smart wallet or a custodian operating on behalf of users) — these need to wrap the locker in their own contracts. Acceptable trade-off.

### D-5: No hard cap on lock duration

**Decision:** `unlock_at_ms` accepts any `u64`. Effective max is `u64::MAX` ms ≈ 580M years.

**Rationale:** No principled value to cap at. Any cap is arbitrary and limits use cases (e.g., "permanent" locks via `u64::MAX` are useful for token-launch trust signals).

**Concern:** Are there integer-overflow concerns at `u64::MAX`? Specifically, `unlock_at_ms > now` comparison is u64-bound; doesn't overflow. `now >= unlock_at_ms` doesn't overflow. ✓

### D-6: No extend / shorten / cancel operations

**Decision:** `unlock_at_ms` is set once at `lock_position` and immutable thereafter. Documented as KNOWN LIMITATION #1 in the on-chain WARNING.

**Rationale:** Adding `extend_unlock_at` (push deadline further out) seems benign but introduces a multi-call pathway for downstream protocols (e.g., a multiplier-staking protocol could let users boost their multiplier by extending mid-stake). This is exactly the pattern that has economic gaming concerns we discussed in design (memory: locked_at_ms vs remaining-time multiplier discussion). Keeping the locker pure means downstream protocols implement their own extend semantics if needed (e.g., via re-lock-after-redeem pattern).

**Adding shorten / cancel** would defeat the purpose entirely. Hard reject.

### D-7: Pool dep is sealed Immutable

**Decision:** Locker pins `darbitex` core via `Move.lock` mainnet pinning to the sealed package address.

**Rationale:** Pool was sealed via `package::make_immutable` on 2026-04-26 (memory: `darbitex_sui_deployed.md`). The locker depends on `pool::claim_lp_fees`, `pool::position_pool_id`, `pool::position_shares` — all stable forever.

**Concern:** What if the Sui framework deprecates a primitive used by pool, breaking pool transitively? Pool itself is sealed and bytecode-frozen; if framework changes break the pool, the entire ecosystem on Sui breaks together. Locker's exposure is no worse than pool's.

### D-8: Composability with planned staking package — lock invariant must hold

**Decision:** `LockedPosition<A,B>` has `key, store`, designed to be embedded in a future staking package's `StakedLp<A,B>::Locked(LockedPosition<A,B>)` enum variant.

**Rationale:** Layered defense — staking package adds emission rewards on top of locker; user opts in to both. Three independent firewalls protect a `LockedPosition`-staked LP:
1. **Sui object ownership** — attacker needs signature to move `StakePosition`.
2. **Staking module invariants** — staking destructure is module-private to staking; downstream of staking can't extract the inner `LockedPosition`.
3. **Locker time-gate** — even if staking is compromised and the attacker gets `LockedPosition`, they still can't extract `LpPosition` until `unlock_at_ms`.

**Critical invariant for the auditor to verify on this submission:**

> The only path to extract `LpPosition<A,B>` from `LockedPosition<A,B>` is `darbitex_lp_locker::lock::redeem`, which requires `clock::timestamp_ms(clock) >= locked.unlock_at_ms`.

If you find any other path — public, package-visible, or via clever composition — that's a HIGH finding.

**Specific things to check:**
- `LockedPosition` destructure is module-private (only `redeem` calls `let LockedPosition { id, position, unlock_at_ms: _ } = locked`).
- No public function returns `LpPosition<A,B>` other than `redeem` (which has the time-gate assert).
- No public function takes `&mut LockedPosition` and gives back a path to swap out the inner `position`.
- `borrow_position` returns `&LpPosition` (immutable) — not upgradeable to `&mut` or by-value.

### D-9: No correlation event omission (vs Aptos)

**Decision:** `FeesClaimed` carries `pool_id` directly. (Aptos version omitted `pool_addr` because Aptos's `LpPosition.pool_addr` was module-private; Sui's `pool::position_pool_id` is `public`, so we can carry it.)

**Rationale:** Self-contained events are more indexer-friendly than correlation-required events.

**Concern:** Privacy or de-anonymization risk? None — pool_id is already public via `pool::LpFeesClaimed` event. Not adding new info.

### D-10: 4× lint W99001 self-transfer warnings on entry wrappers (not suppressed)

**Decision:** Entry wrappers `lock_position_entry`, `claim_fees_entry`, `redeem_entry` each call `transfer::public_transfer(obj, tx_context::sender(ctx))`. Sui linter flags this as "non-composable transfer to sender". We do **not** suppress with `#[allow(lint(self_transfer))]`.

**Rationale:** Mirrors `darbitex::pool` which ships these warnings unsuppressed. Entry wrappers are user-facing (block-explorer-callable); their non-composability is intentional. Composers use the primitive variants (`lock_position` / `claim_fees` / `redeem`) which return values directly.

**Concern:** Is silent suppression preferable for cleanliness? Consensus from prior darbitex audits: keep visible. Auditors should flag if they see real composability harm here.

---

## 6. Threat-model walk-through per fn

### 6.1 `lock_position(position: LpPosition<A,B>, unlock_at_ms: u64, clock: &Clock, ctx: &mut TxContext) -> LockedPosition<A,B>`

**Auth:** caller must hold `LpPosition<A,B>` by-value → Sui runtime guarantees they own it.

**Flow:**
1. `now = clock::timestamp_ms(clock)`
2. `assert!(unlock_at_ms > now, E_INVALID_UNLOCK)`
3. Read position metadata (id, pool_id, shares) via `pool::position_*` views.
4. Construct `LockedPosition` with `id: object::new(ctx)`, `position` (by-value), `unlock_at_ms`.
5. Emit `Locked` event with all fields.
6. Return `LockedPosition` to caller.

**Threats:**
- **Replay** — N/A; lock_position isn't a signed message.
- **Front-run** — N/A; position is by-value, attacker can't even see it pre-tx.
- **Lock with stale clock** — Sui Clock is consensus-driven; `clock::timestamp_ms` returns a non-decreasing value across txs in the same epoch. Worst case: tiny lock duration if validator clock is slightly behind real time. Acceptable.
- **`unlock_at_ms = 0`** — aborts because `0 > now` is false (as soon as Sui mainnet has any clock > 0).

### 6.2 `claim_fees(locked: &mut LockedPosition<A,B>, pool: &mut Pool<A,B>, clock: &Clock, ctx: &mut TxContext) -> (Coin<A>, Coin<B>)`

**Auth:** caller must hold `&mut LockedPosition<A,B>` → only current Sui owner can pass it.

**Flow:**
1. Read locker_id, position_id, pool_id (for event).
2. Call `pool::claim_lp_fees(pool, &mut locked.position, clock, ctx)` → returns `(Coin<A>, Coin<B>)`.
3. Read coin values for event.
4. Emit `FeesClaimed`.
5. Return coins to caller.

**Threats:**
- **Wrong pool** — pool's own assert (`E_WRONG_POOL = 6` at pool.move:374) catches mismatch. Though canonical-pair invariant means there's only one `Pool<A,B>` ever, so structurally hard.
- **Reentrancy** — pool::claim_lp_fees doesn't call back into locker; acyclic.
- **Coin loss** — Move's linear type system requires `(Coin<A>, Coin<B>)` to be consumed (returned, transferred, or destroyed) before function exit. Compiler-enforced. ✓
- **Fee siphon to wrong recipient** — coins are returned to caller; caller (PTB or entry wrapper) is responsible for routing. Entry wrapper transfers to `tx_context::sender(ctx)`. Primitive form gives caller full control.
- **Claim-during-redeem** — can't happen; primitives are sequential within a tx, can't have `&mut LockedPosition` AND consumed `LockedPosition` simultaneously.

### 6.3 `redeem(locked: LockedPosition<A,B>, clock: &Clock) -> LpPosition<A,B>`

**Auth:** caller must hold `LockedPosition<A,B>` by-value → only current owner.

**Flow:**
1. `now = clock::timestamp_ms(clock)`
2. `assert!(now >= locked.unlock_at_ms, E_STILL_LOCKED)` — fail-fast before destructure.
3. Destructure: `LockedPosition { id, position, unlock_at_ms: _ } = locked`.
4. Compute locker_id via `object::uid_to_inner(&id)` (id is consumed in step 6).
5. `position_id`, `pool_id` for event.
6. `object::delete(id)` — destroy UID.
7. Emit `Redeemed`.
8. Return `position` (by-value) to caller.

**Threats:**
- **Pre-unlock redeem** — assert blocks. ✓ tested.
- **Skip-time** — Sui Clock can't be controlled by users. ✓
- **UID leak** — `object::delete(id)` consumes UID. ✓
- **Position double-spend** — `LockedPosition` is consumed by destructure; can't be re-redeemed in same tx (compiler-enforced linear types).

### 6.4 `lock_position_entry` / `claim_fees_entry` / `redeem_entry`

Thin transfer-to-sender wrappers over the primitives. `claim_fees_entry` destroys zero-value coins to avoid dust.

**Threats:**
- **Self-transfer lint** — flagged as non-composable. Intentional; entry forms are not for composition.
- **Coin destroyed by mistake** — `coin::destroy_zero` aborts if value > 0; safe.

### 6.5 Views (`unlock_at_ms`, `position_shares`, `pool_id`, `is_unlocked`, `borrow_position`, `read_warning`)

All `&LockedPosition` (or `()` for `read_warning`). Read-only. No security implications.

`borrow_position` returns `&LpPosition`. See D-1.

---

## 7. Pre-audit self-review evidence

### 7.1 Structured self-audit (2026-04-26)

`docs/AUDIT-R1-SELF.md` covers all 8 SOP categories (ABI / args / math / reentrancy / edges / interactions / errors / events) and a 9th Sui-specific risk section. Verdict GREEN. 1 INFO actionable (`redeem` fail-fast destructure-order) applied pre-submission.

### 7.2 Move unit test suite — 14/14 passing

Run `sui move test` from package root.

| Test | Coverage |
|---|---|
| `test_lock_then_redeem_after_unlock` | Happy path: lock → views → unlock → redeem |
| `test_redeem_at_exact_unlock_succeeds` | Boundary: `now == unlock_at_ms` |
| `test_lock_unlock_at_now_aborts` | Strict `>` requirement |
| `test_lock_unlock_at_past_aborts` | Past timestamp |
| `test_redeem_one_ms_before_unlock_aborts` | E_STILL_LOCKED at boundary - 1ms |
| `test_claim_fees_no_swap_returns_zero` | Zero-fee no abort |
| `test_claim_fees_during_lock_after_swap` | Exact 4 A claim from 5 A fee × 99% share |
| `test_repeat_claim_no_double_count` | claim → claim → swap → claim |
| `test_claim_fees_after_unlock_still_works_before_redeem` | Post-unlock pre-redeem |
| `test_locked_wrapper_transferable_redeem_by_new_owner` | Transfer ALICE → BOB, BOB redeems |
| `test_locked_wrapper_new_owner_can_claim_fees_during_lock` | ALICE locks, BOB receives, BOB claims |
| `test_borrow_position_pending_fees` | Composability: read-only quote → claim |
| `test_is_unlocked_boundary` | Three stamps: 4999 / 5000 / 5001 |
| `test_read_warning_non_empty_starts_with_d` | Disclosure exposed |

### 7.3 Testnet on-chain smoke test

**Status: not yet performed.** Per SOP `feedback_smoke_test.md`, a real-params smoke (heterogeneous-decimal pair, e.g. SUI/USDC, lock → swap-induced fees → claim → redeem at boundary) must run on Sui testnet before mainnet publish. Planned post-audit-clearance.

---

## 8. Satellite source code

```move
/// Darbitex LP locker — time-locked wrapper for darbitex::pool::LpPosition.
///
/// `lock_position` consumes an `LpPosition<A,B>` and returns a
/// `LockedPosition<A,B>` carrying an `unlock_at_ms` deadline. `redeem`
/// consumes the wrapper and returns the underlying `LpPosition` once
/// `clock >= unlock_at_ms`. `claim_fees` is open throughout the lock
/// period and proxies into `darbitex::pool::claim_lp_fees`.
///
/// `LockedPosition<A,B>` has `key, store` — kiosk/escrow/marketplace-able
/// and embeddable as a field of downstream wrappers (staking, lending,
/// vesting, etc.). The wrapper itself is freely transferable; transfer
/// carries the lock and the unlock_at deadline. Only the inner
/// LpPosition is gated.
///
/// Zero admin. No global registry. No pause, no extend, no early-unlock
/// path. The destructure of `LockedPosition` is module-private; the
/// only route to the inner LpPosition is `redeem` after the deadline.
///
/// WARNING: After make_immutable the package is permanently immutable.
/// The full disclosure (10 known limitations) is exposed on-chain via
/// `read_warning()` and printed in the WARNING constant below.
module darbitex_lp_locker::lock {
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;

    use darbitex::pool::{Self, Pool, LpPosition};

    // ===== Errors =====

    const E_STILL_LOCKED: u64 = 1;
    const E_INVALID_UNLOCK: u64 = 2;

    // ===== On-chain disclosure =====

    const WARNING: vector<u8> = b"DARBITEX LP LOCKER is an immutable time-lock satellite for darbitex::pool::LpPosition on Sui. After make_immutable is called the package is permanently immutable - no admin authority, no pause, no upgrade, no early-unlock path. Bugs are unrecoverable. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) ONE-WAY TIME GATE - unlock_at_ms is set once at lock_position and cannot be extended, shortened, or cancelled by anyone for any reason. There is no admin path to unlock early. The only routes to the underlying LpPosition are redeem after unlock_at_ms or never. (2) CLOCK SOURCE - unlock_at_ms is compared against Sui's shared Clock object timestamp_ms. Lock duration is sensitive to validator clock progression. Standard Sui assumption. (3) WRAPPER TRANSFERABILITY - LockedPosition has key plus store. The wrapper itself is freely transferable via transfer::public_transfer. Transferring the wrapper carries the lock state and the unlock_at deadline; the new owner inherits both the right to claim fees and the right to redeem at unlock_at_ms. Only the inner LpPosition is time-gated, not the wrapper. (4) FEE PROXY - claim_fees calls darbitex::pool::claim_lp_fees and returns Coin<A>, Coin<B> to the caller. Frontends and downstream wrappers are responsible for forwarding fees to the rightful end user. The locker performs no internal fee accounting. (5) POOL DEPENDENCY - claim_fees requires &mut Pool<A,B> matching the wrapped position's pool_id. If the underlying pool is degraded for unrelated reasons, fee claims may fail. redeem does NOT touch the pool and works regardless of pool state once unlock_at_ms is reached - principal recovery is independent of pool liveness. (6) NO RESCUE - lost ownership of the LockedPosition wrapper has no recourse. No admin, no recovery, no pause. The wrapper itself is the only authentication. (7) NO COMPOSITION GUARANTEES - third-party modules that wrap LockedPosition (staking, lending, escrow, marketplace, vesting) provide their own invariants. This module guarantees only that LpPosition cannot exit a LockedPosition before unlock_at_ms. Wrapping a LockedPosition inside an external wrapper is the user's voluntary act and combines the trust assumptions of all layers. (8) SEAL-AT-DEPLOY - the deploy keypair holds UpgradeCap for seconds between Tx 1 (publish) and Tx 2 (make_immutable). After Tx 2 the cap is destroyed and the deploy keypair has zero further authority over the package. (9) AUTHORSHIP AND AUDIT DISCLOSURE - Darbitex LP Locker was built by a solo developer working with Claude (Anthropic AI). All audits performed are AI-based: multi-round Claude self-audit plus external LLM review. NO professional human security audit firm has reviewed this code. Once make_immutable is called the protocol is ownerless and permissionless - no team, no foundation, no legal entity, no responsible party, no support channel. All losses from bugs, exploits, user error, malicious counterparties, or any other cause whatsoever are borne entirely by users. (10) UNKNOWN FUTURE LIMITATIONS - This list reflects only the limitations identified at the time of audit. Future analysis, novel attack vectors, unforeseen interactions with other Sui protocols, framework changes, market dynamics, or regulatory developments may reveal additional weaknesses, risks, or limitations not enumerated here. Because the locker is permanently immutable, newly discovered limitations CANNOT be patched - they become additional risks users continue to bear. Treat the preceding 9 items as a non-exhaustive lower bound on known risks, not a complete enumeration. By interacting with the locker (locking a position, claiming fees, redeeming, transferring the wrapper, or composing with downstream protocols) you confirm that you have read and understood all 10 numbered limitations and accept full responsibility for any and all losses.";

    // ===== State =====

    /// Wrap an LpPosition with a one-way time gate. `key, store` so the
    /// wrapper is transferable and embeddable in downstream protocols.
    public struct LockedPosition<phantom A, phantom B> has key, store {
        id: UID,
        position: LpPosition<A, B>,
        unlock_at_ms: u64,
    }

    // ===== Events =====

    public struct Locked has copy, drop {
        locker_id: ID, position_id: ID, pool_id: ID,
        owner: address, shares: u64,
        unlock_at_ms: u64, timestamp_ms: u64,
    }
    public struct FeesClaimed has copy, drop {
        locker_id: ID, position_id: ID, pool_id: ID,
        fees_a: u64, fees_b: u64, timestamp_ms: u64,
    }
    public struct Redeemed has copy, drop {
        locker_id: ID, position_id: ID, pool_id: ID,
        timestamp_ms: u64,
    }

    // ===== Primitives =====

    /// Lock an LpPosition until `unlock_at_ms`. Returns the wrapper; caller
    /// transfers or composes. Asserts `unlock_at_ms > now`.
    public fun lock_position<A, B>(
        position: LpPosition<A, B>,
        unlock_at_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): LockedPosition<A, B> {
        let now = clock::timestamp_ms(clock);
        assert!(unlock_at_ms > now, E_INVALID_UNLOCK);

        let position_id = object::id(&position);
        let pool_id = pool::position_pool_id(&position);
        let shares = pool::position_shares(&position);

        let locked = LockedPosition<A, B> {
            id: object::new(ctx),
            position,
            unlock_at_ms,
        };
        let locker_id = object::id(&locked);

        event::emit(Locked {
            locker_id, position_id, pool_id,
            owner: tx_context::sender(ctx), shares,
            unlock_at_ms, timestamp_ms: now,
        });

        locked
    }

    /// Claim accrued LP fees on the wrapped position. Returns coins to
    /// the caller. Open throughout the lock period.
    public fun claim_fees<A, B>(
        locked: &mut LockedPosition<A, B>,
        pool: &mut Pool<A, B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        let locker_id = object::id(locked);
        let position_id = object::id(&locked.position);
        let pool_id = object::id(pool);

        let (coin_a, coin_b) = pool::claim_lp_fees(pool, &mut locked.position, clock, ctx);
        let fees_a = coin::value(&coin_a);
        let fees_b = coin::value(&coin_b);

        event::emit(FeesClaimed {
            locker_id, position_id, pool_id,
            fees_a, fees_b,
            timestamp_ms: clock::timestamp_ms(clock),
        });

        (coin_a, coin_b)
    }

    /// Consume the wrapper and return the underlying LpPosition. Asserts
    /// `clock >= unlock_at_ms`. Pool is NOT touched — principal recovery
    /// is independent of pool liveness.
    public fun redeem<A, B>(
        locked: LockedPosition<A, B>,
        clock: &Clock,
    ): LpPosition<A, B> {
        let now = clock::timestamp_ms(clock);
        assert!(now >= locked.unlock_at_ms, E_STILL_LOCKED);
        let LockedPosition { id, position, unlock_at_ms: _ } = locked;

        let locker_id = object::uid_to_inner(&id);
        let position_id = object::id(&position);
        let pool_id = pool::position_pool_id(&position);
        object::delete(id);

        event::emit(Redeemed {
            locker_id, position_id, pool_id,
            timestamp_ms: now,
        });

        position
    }

    // ===== Entry wrappers (block-explorer-executable) =====

    /// Lock and transfer the wrapper to the caller in one TX.
    public fun lock_position_entry<A, B>(
        position: LpPosition<A, B>,
        unlock_at_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let locked = lock_position(position, unlock_at_ms, clock, ctx);
        transfer::public_transfer(locked, tx_context::sender(ctx));
    }

    /// Claim fees and forward both coins to the caller. Zero-value coins
    /// are destroyed in place to avoid dust-coin spam.
    public fun claim_fees_entry<A, B>(
        locked: &mut LockedPosition<A, B>,
        pool: &mut Pool<A, B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let (coin_a, coin_b) = claim_fees(locked, pool, clock, ctx);
        let recipient = tx_context::sender(ctx);
        if (coin::value(&coin_a) > 0) transfer::public_transfer(coin_a, recipient)
        else coin::destroy_zero(coin_a);
        if (coin::value(&coin_b) > 0) transfer::public_transfer(coin_b, recipient)
        else coin::destroy_zero(coin_b);
    }

    /// Redeem and transfer the LpPosition back to the caller.
    public fun redeem_entry<A, B>(
        locked: LockedPosition<A, B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let position = redeem(locked, clock);
        transfer::public_transfer(position, tx_context::sender(ctx));
    }

    // ===== Views =====

    public fun unlock_at_ms<A, B>(locked: &LockedPosition<A, B>): u64 {
        locked.unlock_at_ms
    }

    public fun position_shares<A, B>(locked: &LockedPosition<A, B>): u64 {
        pool::position_shares(&locked.position)
    }

    public fun pool_id<A, B>(locked: &LockedPosition<A, B>): ID {
        pool::position_pool_id(&locked.position)
    }

    public fun is_unlocked<A, B>(locked: &LockedPosition<A, B>, clock: &Clock): bool {
        clock::timestamp_ms(clock) >= locked.unlock_at_ms
    }

    /// Borrow the wrapped position read-only. Useful for downstream
    /// wrappers that need to read pending fees or pool_id without
    /// claim/consume rights. Mutable access is intentionally NOT exposed
    /// publicly — fee claims must go through `claim_fees`.
    public fun borrow_position<A, B>(locked: &LockedPosition<A, B>): &LpPosition<A, B> {
        &locked.position
    }

    public fun read_warning(): vector<u8> { WARNING }
}
```

---

## 9. Relevant Darbitex Sui core excerpts (context for the auditor)

The locker calls into `darbitex::pool` via 3 functions. Their on-chain signatures (sealed, immutable):

### 9.1 `LpPosition<A,B>` struct (pool.move:72-79)

```move
/// `key, store`: kiosk/escrow-able. Each add_liquidity mints fresh
/// (no merging — debt snapshot would be ambiguous).
public struct LpPosition<phantom A, phantom B> has key, store {
    id: UID,
    pool_id: ID,
    shares: u64,
    fee_debt_a: u128,
    fee_debt_b: u128,
}
```

### 9.2 `claim_lp_fees` (pool.move:370-391) — the only mutating call from the locker

```move
public fun claim_lp_fees<A, B>(
    pool: &mut Pool<A, B>, position: &mut LpPosition<A, B>,
    clock: &Clock, ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    assert!(object::id(pool) == position.pool_id, E_WRONG_POOL);
    let claim_a = pending_from_accumulator(pool.lp_fee_per_share_a, position.fee_debt_a, position.shares);
    let claim_b = pending_from_accumulator(pool.lp_fee_per_share_b, position.fee_debt_b, position.shares);
    position.fee_debt_a = pool.lp_fee_per_share_a;
    position.fee_debt_b = pool.lp_fee_per_share_b;

    let coin_a = if (claim_a > 0) coin::from_balance(balance::split(&mut pool.balance_a, claim_a), ctx)
                 else coin::zero<A>(ctx);
    let coin_b = if (claim_b > 0) coin::from_balance(balance::split(&mut pool.balance_b, claim_b), ctx)
                 else coin::zero<B>(ctx);

    event::emit(LpFeesClaimed {
        pool_id: position.pool_id, position_id: object::id(position),
        claimer: tx_context::sender(ctx), fees_a: claim_a, fees_b: claim_b,
        timestamp_ms: clock::timestamp_ms(clock),
    });
    (coin_a, coin_b)
}
```

### 9.3 `position_pool_id`, `position_shares`, `pending_fees` (pool.move:510-521) — read-only views

```move
public fun position_shares<A, B>(pos: &LpPosition<A, B>): u64 { pos.shares }
public fun position_pool_id<A, B>(pos: &LpPosition<A, B>): ID { pos.pool_id }
public fun pending_fees<A, B>(pool: &Pool<A, B>, pos: &LpPosition<A, B>): (u64, u64) { ... }
```

### 9.4 `remove_liquidity` (pool.move:333-368) — NOT called by locker, but relevant to principal-lock invariant

```move
public fun remove_liquidity<A, B>(
    pool: &mut Pool<A, B>, position: LpPosition<A, B>,  // <-- BY VALUE, consumes
    min_amount_a: u64, min_amount_b: u64,
    clock: &Clock, ctx: &mut TxContext,
): (Coin<A>, Coin<B>) { ... }
```

**Why this matters:** `remove_liquidity` consumes `LpPosition<A,B>` by value. The locker holds the position by-value inside `LockedPosition`. The only way a caller can get a by-value `LpPosition<A,B>` to feed into `remove_liquidity` is:
1. They created it themselves via `pool::add_liquidity` — that's their own LP, not in any locker.
2. They received it from `lock::redeem` — which has the time-gate.

There is no other public API in this satellite or in `darbitex::pool` that produces a by-value `LpPosition<A,B>` for an arbitrary caller. **Verify this assertion.**

---

## 10. Asks for the auditor

- Does §5 D-8's invariant hold under the type system + module privacy? Specifically: is there ANY path from the public ABI of `lock.move` to obtain a by-value `LpPosition<A,B>` other than through `redeem`?
- Is `borrow_position` safe as exposed (D-1)?
- Is the asymmetric time semantic (D-2) correct, or is there an edge case that makes both ends of the polarity matter?
- Are the events sufficient for off-chain analytics needs, given the planned downstream staking-package integration?
- Anything we considered and got right that should stay locked in (we want to know what survived scrutiny, not just where we failed)?

Please put the response in `docs/audit-responses/<llm>-r1.md` in this repo's tree.
