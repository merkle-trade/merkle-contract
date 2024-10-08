module merkle::test_trading {

    use std::string;
    use std::signer;
    use aptos_std::table;
    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, MintCapability};
    use aptos_framework::event::EventHandle;
    use merkle::safe_math::exp;

    /// User not allowed to call method
    const E_NOT_ALLOWED: u64 = 1;
    /// faucet limit 24hrs
    const E_FAUCET_LIMIT_EXCEEDED: u64 = 2;

    const TEST_USDC_DECIMALS: u64 = 6;

    /// USDC for test
    struct TEST_USDC has store, drop {}
    struct TEST_USDC2 has store, drop {}


    /// USDC info
    struct TEST_USDC_INFO<phantom T> has key, store {
        /// Capability for mint TEST_USDC
        mint_cap: MintCapability<T>,
        /// flag whether to limit the faucet
        limit_faucet: bool,
        /// If limit_faucet is true, the maximum amount of faucet you can receive per day.
        limit_faucet_amount: u64,
        /// The last time you received a faucet.
        last_faucet: table::Table<address, u64>,
        /// Total faucet volume received per day.
        faucet_amount: table::Table<address, u64>,
    }

    struct FaucetEvent has copy, drop, store {
        amount: u64
    }

    /// whole events in faucet for merkle
    struct FaucetEvents has key {
        /// Event handle for faucet events.
        faucet_events: EventHandle<FaucetEvent>,
    }

    /// Set up the trading & oracle & house_lp & distributor
    fun init_module(
        host: &signer
    ) {
        let name = b"tUSDC";
        let decimals = (TEST_USDC_DECIMALS as u8);
        let (bc, fc, mc) = coin::initialize<TEST_USDC>(host,
            string::utf8(name),
            string::utf8(name),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<TEST_USDC>(host);

        move_to(host, TEST_USDC_INFO<TEST_USDC> {
            mint_cap: mc,
            limit_faucet: false,
            limit_faucet_amount: 1000 * exp(10, TEST_USDC_DECIMALS),
            last_faucet: table::new(),
            faucet_amount: table::new()
        });
        coin::destroy_mint_cap(mc);

        let name = b"pUSDC";
        let decimals = (TEST_USDC_DECIMALS as u8);
        let (bc, fc, mc) = coin::initialize<TEST_USDC2>(host,
            string::utf8(name),
            string::utf8(name),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<TEST_USDC2>(host);

        move_to(host, TEST_USDC_INFO<TEST_USDC2> {
            mint_cap: mc,
            limit_faucet: false,
            limit_faucet_amount: 1000 * exp(10, TEST_USDC_DECIMALS),
            last_faucet: table::new(),
            faucet_amount: table::new()
        });
        coin::destroy_mint_cap(mc);
    }

    public entry fun set_limit_faucet<T>(host: &signer, _limit_faucet: bool) acquires TEST_USDC_INFO {
        let host_addr = signer::address_of(host);
        assert!(host_addr == @merkle, E_NOT_ALLOWED);

        let info = borrow_global_mut<TEST_USDC_INFO<T>>(host_addr);
        info.limit_faucet = _limit_faucet;
    }

    public entry fun set_limit_faucet_amount<T>(host: &signer, _limit_faucet_amount: u64) acquires TEST_USDC_INFO {
        let host_addr = signer::address_of(host);
        assert!(host_addr == @merkle, E_NOT_ALLOWED);

        let info = borrow_global_mut<TEST_USDC_INFO<T>>(host_addr);
        info.limit_faucet_amount = _limit_faucet_amount;
    }

    /// faucet TEST_USDC
    public entry fun faucet_coin<T>(host: &signer, amount: u64) acquires TEST_USDC_INFO {
        let host_addr = signer::address_of(host);
        let info = borrow_global_mut<TEST_USDC_INFO<T>>(@merkle);
        aptos_account::deposit_coins(host_addr, coin::mint<T>(amount, &info.mint_cap));
    }

    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::timestamp;

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    /// faucet tests
    fun T_faucet_test(host: &signer, aptos_framework: &signer, user: &signer) acquires TEST_USDC_INFO {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        aptos_account::create_account(signer::address_of(host));
        aptos_account::create_account(signer::address_of(user));
        init_module(host);
        let host_addr = signer::address_of(host);
        let user_addr = signer::address_of(user);
        let initial_balance = coin::balance<TEST_USDC>(host_addr);

        faucet_coin<TEST_USDC>(host, 10000 * exp(10, TEST_USDC_DECIMALS));
        assert!(coin::balance<TEST_USDC>(host_addr) - initial_balance == 10000 * exp(10, TEST_USDC_DECIMALS), 1);

        faucet_coin<TEST_USDC>(user, 10000 * exp(10, TEST_USDC_DECIMALS));
        assert!(coin::balance<TEST_USDC>(user_addr) == 10000 * exp(10, TEST_USDC_DECIMALS), 2);

        faucet_coin<TEST_USDC>(user, 10000 * exp(10, TEST_USDC_DECIMALS));
        assert!(coin::balance<TEST_USDC>(user_addr) == 20000 * exp(10, TEST_USDC_DECIMALS), 3);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_ALLOWED, location = Self)]
    /// faucet tests
    fun T_E_NOT_ALLOWED_set_limit_faucet(host: &signer, aptos_framework: &signer, user: &signer) acquires TEST_USDC_INFO {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        aptos_account::create_account(signer::address_of(host));
        aptos_account::create_account(signer::address_of(user));
        init_module(host);

        set_limit_faucet<TEST_USDC>(user, true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_ALLOWED, location = Self)]
    /// faucet tests
    fun T_E_NOT_ALLOWED_set_limit_faucet_amount(host: &signer, aptos_framework: &signer, user: &signer) acquires TEST_USDC_INFO {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        aptos_account::create_account(signer::address_of(host));
        aptos_account::create_account(signer::address_of(user));
        init_module(host);

        set_limit_faucet<TEST_USDC>(host, true);
        set_limit_faucet_amount<TEST_USDC>(user, 1000 * exp(10, TEST_USDC_DECIMALS));
    }
}