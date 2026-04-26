#[test_only]
module darbitex_lp_locker::lock_tests {
    use sui::clock::{Self, Clock};
    use sui::coin;
    use sui::test_scenario::{Self as ts, Scenario};
    use std::unit_test;

    use darbitex::pool::{Self, Pool, LpPosition};
    use darbitex::pool_factory::{Self, FactoryRegistry};

    use darbitex_lp_locker::lock::{Self, LockedPosition};

    public struct TEST_A has drop {}
    public struct TEST_B has drop {}

    const ALICE: address = @0xA11CE;
    const BOB:   address = @0xB0B;

    // ===== Helpers =====

    fun start(): Scenario {
        let mut sc = ts::begin(ALICE);
        pool_factory::init_for_testing(ts::ctx(&mut sc));
        sc
    }

    /// Tx 1: take factory, create 100k/100k pool, transfer LpPosition to ALICE.
    fun create_pool_basic(sc: &mut Scenario, clk: &Clock) {
        ts::next_tx(sc, ALICE);
        let mut factory = ts::take_shared<FactoryRegistry>(sc);
        let coin_a = coin::mint_for_testing<TEST_A>(100_000, ts::ctx(sc));
        let coin_b = coin::mint_for_testing<TEST_B>(100_000, ts::ctx(sc));
        let pos = pool_factory::create_canonical_pool<TEST_A, TEST_B>(
            &mut factory, coin_a, coin_b, clk, ts::ctx(sc),
        );
        transfer::public_transfer(pos, ALICE);
        ts::return_shared(factory);
    }

    fun take_alice_lp(sc: &mut Scenario): LpPosition<TEST_A, TEST_B> {
        ts::next_tx(sc, ALICE);
        ts::take_from_sender<LpPosition<TEST_A, TEST_B>>(sc)
    }

    /// Mint 10k A and swap to accrue ~5 A in LP fee accumulator.
    /// LP holds 99k of 100k shares (1k locked at creation) → ~4 A claimable.
    fun swap_to_accrue_fees(pool: &mut Pool<TEST_A, TEST_B>, clk: &Clock, sc: &mut Scenario) {
        let coin_in = coin::mint_for_testing<TEST_A>(10_000, ts::ctx(sc));
        let coin_out = pool::swap_a_to_b(pool, coin_in, 0, clk, ts::ctx(sc));
        unit_test::destroy(coin_out);
    }

    // ===== Happy path =====

    #[test]
    fun test_lock_then_redeem_after_unlock() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);
        let pool_id = pool::position_pool_id(&pos);
        let shares = pool::position_shares(&pos);

        clock::set_for_testing(&mut clk, 1_000);
        let locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));

        assert!(lock::unlock_at_ms(&locked) == 5_000, 0);
        assert!(lock::position_shares(&locked) == shares, 1);
        assert!(lock::pool_id(&locked) == pool_id, 2);
        assert!(!lock::is_unlocked(&locked, &clk), 3);

        clock::set_for_testing(&mut clk, 5_000);
        assert!(lock::is_unlocked(&locked, &clk), 4);

        let pos_back = lock::redeem(locked, &clk);
        assert!(pool::position_pool_id(&pos_back) == pool_id, 5);
        assert!(pool::position_shares(&pos_back) == shares, 6);

        unit_test::destroy(pos_back);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun test_redeem_at_exact_unlock_succeeds() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let locked = lock::lock_position(pos, 2_000, &clk, ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 2_000);

        let pos_back = lock::redeem(locked, &clk);
        unit_test::destroy(pos_back);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Lock invariants =====

    #[test]
    #[expected_failure(abort_code = darbitex_lp_locker::lock::E_INVALID_UNLOCK)]
    fun test_lock_unlock_at_now_aborts() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        // unlock_at == now → abort (strict greater-than required)
        let locked = lock::lock_position(pos, 1_000, &clk, ts::ctx(&mut sc));

        unit_test::destroy(locked);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = darbitex_lp_locker::lock::E_INVALID_UNLOCK)]
    fun test_lock_unlock_at_past_aborts() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 5_000);
        let locked = lock::lock_position(pos, 1_000, &clk, ts::ctx(&mut sc));

        unit_test::destroy(locked);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Redeem invariants =====

    #[test]
    #[expected_failure(abort_code = darbitex_lp_locker::lock::E_STILL_LOCKED)]
    fun test_redeem_one_ms_before_unlock_aborts() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, 4_999);

        let pos_back = lock::redeem(locked, &clk);
        unit_test::destroy(pos_back);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Fee claim =====

    #[test]
    fun test_claim_fees_no_swap_returns_zero() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let mut locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));
        let mut pool = ts::take_shared<Pool<TEST_A, TEST_B>>(&sc);

        let (a, b) = lock::claim_fees(&mut locked, &mut pool, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&a) == 0, 0);
        assert!(coin::value(&b) == 0, 1);
        unit_test::destroy(a);
        unit_test::destroy(b);

        unit_test::destroy(locked);
        ts::return_shared(pool);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun test_claim_fees_during_lock_after_swap() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let mut locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));
        let mut pool = ts::take_shared<Pool<TEST_A, TEST_B>>(&sc);

        swap_to_accrue_fees(&mut pool, &clk, &mut sc);

        // Confirm still locked at fee-claim time
        assert!(!lock::is_unlocked(&locked, &clk), 0);

        let (a, b) = lock::claim_fees(&mut locked, &mut pool, &clk, ts::ctx(&mut sc));
        // 5 A fee × (99000/100000) = 4 (floor)
        assert!(coin::value(&a) == 4, 1);
        assert!(coin::value(&b) == 0, 2);
        unit_test::destroy(a);
        unit_test::destroy(b);

        unit_test::destroy(locked);
        ts::return_shared(pool);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun test_repeat_claim_no_double_count() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let mut locked = lock::lock_position(pos, 9_999, &clk, ts::ctx(&mut sc));
        let mut pool = ts::take_shared<Pool<TEST_A, TEST_B>>(&sc);

        // First swap + claim
        swap_to_accrue_fees(&mut pool, &clk, &mut sc);
        let (a1, b1) = lock::claim_fees(&mut locked, &mut pool, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&a1) > 0, 0);

        // Immediate re-claim with no new swap → zero
        let (a2, b2) = lock::claim_fees(&mut locked, &mut pool, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&a2) == 0, 1);
        assert!(coin::value(&b2) == 0, 2);

        // Second swap + claim → non-zero again
        swap_to_accrue_fees(&mut pool, &clk, &mut sc);
        let (a3, b3) = lock::claim_fees(&mut locked, &mut pool, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&a3) > 0, 3);

        unit_test::destroy(a1);
        unit_test::destroy(b1);
        unit_test::destroy(a2);
        unit_test::destroy(b2);
        unit_test::destroy(a3);
        unit_test::destroy(b3);

        unit_test::destroy(locked);
        ts::return_shared(pool);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun test_claim_fees_after_unlock_still_works_before_redeem() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let mut locked = lock::lock_position(pos, 2_000, &clk, ts::ctx(&mut sc));
        let mut pool = ts::take_shared<Pool<TEST_A, TEST_B>>(&sc);

        // Past unlock — but caller hasn't redeemed yet
        clock::set_for_testing(&mut clk, 10_000);
        assert!(lock::is_unlocked(&locked, &clk), 0);

        swap_to_accrue_fees(&mut pool, &clk, &mut sc);
        let (a, b) = lock::claim_fees(&mut locked, &mut pool, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&a) == 4, 1);
        assert!(coin::value(&b) == 0, 2);
        unit_test::destroy(a);
        unit_test::destroy(b);

        let pos_back = lock::redeem(locked, &clk);
        unit_test::destroy(pos_back);
        ts::return_shared(pool);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Wrapper transferability — carries the lock =====

    #[test]
    fun test_locked_wrapper_transferable_redeem_by_new_owner() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));
        transfer::public_transfer(locked, BOB);

        // BOB picks up wrapper, advances clock, redeems
        ts::next_tx(&mut sc, BOB);
        let locked_b = ts::take_from_sender<LockedPosition<TEST_A, TEST_B>>(&sc);
        clock::set_for_testing(&mut clk, 5_000);

        let pos_back = lock::redeem(locked_b, &clk);
        // BOB now owns the LpPosition
        transfer::public_transfer(pos_back, BOB);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun test_locked_wrapper_new_owner_can_claim_fees_during_lock() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));
        transfer::public_transfer(locked, BOB);

        // Anyone swaps (use ALICE)
        ts::next_tx(&mut sc, ALICE);
        let mut pool = ts::take_shared<Pool<TEST_A, TEST_B>>(&sc);
        swap_to_accrue_fees(&mut pool, &clk, &mut sc);
        ts::return_shared(pool);

        // BOB claims
        ts::next_tx(&mut sc, BOB);
        let mut locked_b = ts::take_from_sender<LockedPosition<TEST_A, TEST_B>>(&sc);
        let mut pool = ts::take_shared<Pool<TEST_A, TEST_B>>(&sc);
        let (a, b) = lock::claim_fees(&mut locked_b, &mut pool, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&a) == 4, 0);
        assert!(coin::value(&b) == 0, 1);
        unit_test::destroy(a);
        unit_test::destroy(b);

        unit_test::destroy(locked_b);
        ts::return_shared(pool);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Composability — borrow_position read-only =====

    #[test]
    fun test_borrow_position_pending_fees() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));
        let mut pool = ts::take_shared<Pool<TEST_A, TEST_B>>(&sc);

        swap_to_accrue_fees(&mut pool, &clk, &mut sc);

        // Read-only quote without claiming
        let inner = lock::borrow_position(&locked);
        let (pa, pb) = pool::pending_fees(&pool, inner);
        assert!(pa == 4, 0);
        assert!(pb == 0, 1);

        // Wrapper still claimable post-quote
        let mut locked_mut = locked;
        let (a, b) = lock::claim_fees(&mut locked_mut, &mut pool, &clk, ts::ctx(&mut sc));
        assert!(coin::value(&a) == 4, 2);
        unit_test::destroy(a);
        unit_test::destroy(b);

        unit_test::destroy(locked_mut);
        ts::return_shared(pool);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== is_unlocked progression =====

    #[test]
    fun test_is_unlocked_boundary() {
        let mut sc = start();
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

        create_pool_basic(&mut sc, &clk);
        let pos = take_alice_lp(&mut sc);

        clock::set_for_testing(&mut clk, 1_000);
        let locked = lock::lock_position(pos, 5_000, &clk, ts::ctx(&mut sc));

        clock::set_for_testing(&mut clk, 4_999);
        assert!(!lock::is_unlocked(&locked, &clk), 0);

        clock::set_for_testing(&mut clk, 5_000);
        assert!(lock::is_unlocked(&locked, &clk), 1);

        clock::set_for_testing(&mut clk, 5_001);
        assert!(lock::is_unlocked(&locked, &clk), 2);

        let pos_back = lock::redeem(locked, &clk);
        unit_test::destroy(pos_back);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ===== Pure views =====

    #[test]
    fun test_read_warning_non_empty_starts_with_d() {
        let w = lock::read_warning();
        assert!(std::vector::length(&w) > 0, 0);
        assert!(*std::vector::borrow(&w, 0) == 68u8, 1); // 'D'
    }
}
