module merkle::test_trading {

    // <-- USE ----->
    use merkle::price_oracle;
    use merkle::pair_types::{BTC_USD, ETH_USD};
    use merkle::managed_trading;
    use merkle::math_u64;
    use merkle::distributor;
    use merkle::fee_distributor;
    use merkle::merkle_distributor;
    use merkle::house_lp::{Self, MKLP};
    use std::string;
    use aptos_framework::coin;
    use std::signer;
    use aptos_framework::coin::MintCapability;
    use aptos_std::type_info;

    #[test_only]
    use merkle::trading;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::aptos_account;

    /// opening_fee = 10000  => 1%
    const ENTRY_EXIT_FEE_PRECISION: u64 = 100 * 10000;
    /// interest_precision 1e6 => 1
    const INTEREST_PRECISION: u64 = 100 * 10000;
    /// leverage_precision 1e6 => 1
    const LEVERAGE_PRECISION: u64 = 100 * 10000;

    const TEST_USDC_DECIMALS: u64 = 6;

    struct TEST_USDC has store, drop {}
    struct TEST_BTC has store, drop {}
    struct TEST_CAP<phantom T> has key, store {
        mint_cap: MintCapability<T>
    }

    /// Set up the trading & oracle & house_lp & distributor
    fun init_module(
        host: &signer
    ) {
        let price_decimals = (price_oracle::get_price_decimals() as u64);
        price_oracle::register_oracle<TEST_USDC>(host, 30 * math_u64::exp(10, price_decimals));
        price_oracle::register_oracle<TEST_BTC>(host, 30 * math_u64::exp(10, price_decimals));
        create_test_coins<TEST_USDC>(host, b"USDC", (TEST_USDC_DECIMALS as u8), 10000000 * math_u64::exp(10, TEST_USDC_DECIMALS));

        new_listing<BTC_USD, TEST_USDC>(host);
        new_listing<ETH_USD, TEST_USDC>(host);

        house_lp::register<TEST_USDC>(host, 10);
        house_lp::deposit<TEST_USDC>(host, 100000 * math_u64::exp(10, TEST_USDC_DECIMALS));

        distributor::initialize(host);
        distributor::register_reward<TEST_USDC>(host);

        distributor::register_staking_coin<MKLP>(host);
        fee_distributor::register_pool<MKLP>(host, 0);
        fee_distributor::set_alloc_point<MKLP>(host, 0, 1000000);
        merkle_distributor::register_pool<MKLP>(host);
        merkle_distributor::set_reward_per_time(host, 100);
        merkle_distributor::set_alloc_point<MKLP>(host, 1000000);
    }

    public entry fun new_listing<PairType, CollateralType>(host: &signer) {
        managed_trading::initialize<PairType, CollateralType>(host);
        managed_trading::set_entry_exit_fee<PairType, CollateralType>(host, 3000);
        managed_trading::set_max_interest<PairType, CollateralType>(host, 100000 * INTEREST_PRECISION);
        managed_trading::set_min_leverage<PairType, CollateralType>(host, 3 * LEVERAGE_PRECISION);
        managed_trading::set_max_leverage<PairType, CollateralType>(host, 100 * LEVERAGE_PRECISION);
    }

    fun create_test_coins<T>(
        host: &signer,
        name: vector<u8>,
        decimals: u8,
        amount: u64
    ) {
        let (bc, fc, mc) = coin::initialize<T>(host,
            string::utf8(name),
            string::utf8(name),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<T>(host);

        assert!(type_info::account_address(&type_info::type_of<T>()) == signer::address_of(host), 0);
        move_to(host, TEST_CAP<T> {
            mint_cap: mc
        });
        coin::deposit(signer::address_of(host), coin::mint<T>(amount, &mc));
        coin::destroy_mint_cap(mc);
    }

    public entry fun faucet_coin<T>(host: &signer, amount: u64) acquires TEST_CAP {
        let coin_addr = type_info::account_address(&type_info::type_of<T>());
        let caps = borrow_global_mut<TEST_CAP<T>>(coin_addr);
        if (!coin::is_account_registered<T>(signer::address_of(host))) {
            coin::register<T>(host);
        };
        coin::deposit(signer::address_of(host), coin::mint<T>(amount, &caps.mint_cap));
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    public entry fun T_execute_increase_market_order_2(host: &signer, aptos_framework: &signer) {
        let price_decimals = (price_oracle::get_price_decimals() as u64);
        aptos_account::create_account(signer::address_of(host));
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(host);

        trading::place_order<BTC_USD, TEST_USDC>(
            host,
            50 * math_u64::exp(10, TEST_USDC_DECIMALS),
            10 * math_u64::exp(10, TEST_USDC_DECIMALS),
            30 * math_u64::exp(10, price_decimals),
            false,
            true,
            true,
            0,
            0,
            true
        );
        managed_trading::execute_order<BTC_USD, TEST_USDC>(host, 1, 31 * math_u64::exp(10, price_decimals));

        trading::place_order<BTC_USD, TEST_USDC>(
            host,
            50 * math_u64::exp(10, TEST_USDC_DECIMALS),
            0,
            30 * math_u64::exp(10, price_decimals),
            false,
            false,
            true,
            0,
            0,
            true
        );
        managed_trading::execute_order<BTC_USD, TEST_USDC>(host, 2, 30 * math_u64::exp(10, price_decimals));
    }
}