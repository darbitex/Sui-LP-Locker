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
