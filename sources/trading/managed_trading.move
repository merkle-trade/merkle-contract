module merkle::managed_trading {

    // <-- USE ----->
    use merkle::trading;
    use merkle::trading::{ExecuteCapability, AdminCapability};
    use merkle::price_oracle;
    use std::signer::address_of;

    #[test_only]
    use aptos_framework::timestamp::set_time_has_started_for_testing;
    #[test_only]
    use aptos_framework::account::create_account_for_test;
    #[test_only]
    use merkle::pair_types::BTC_USD;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    struct ExecuteCapabilityStore<phantom PairType, phantom CollateralType> has key {
        execute_cap: ExecuteCapability<PairType, CollateralType>,
    }

    struct AdminCapabilityStore<phantom PairType, phantom CollateralType> has key {
        admin_cap: AdminCapability<PairType, CollateralType>,
    }

    public entry fun initialize<PairType, CollateralType>(
        _host: &signer
    ) {
        let (execute_cap, admin_cap) = trading::initialize<PairType, CollateralType>(_host);

        move_to(_host, ExecuteCapabilityStore { execute_cap });
        move_to(_host, AdminCapabilityStore { admin_cap });

        price_oracle::register_oracle<PairType>(_host, 0);
    }

    public entry fun execute_order<PairType, CollateralType>(
        _executor: &signer,
        _order_id: u64,
        _fast_price: u64
    ) acquires ExecuteCapabilityStore {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_order<PairType, CollateralType>(_executor, _order_id, _fast_price, execute_cap);
    }

    public entry fun execute_exit_position<PairType, CollateralType>(
        _executor: &signer,
        _user: address,
        _is_long: bool,
        _fast_price: u64
    ) acquires ExecuteCapabilityStore {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_exit_position<PairType, CollateralType>(_executor, _user, _is_long, _fast_price, execute_cap);
    }


    public entry fun pause<PairType, CollateralType>(
        _admin: &signer
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::pause(admin_cap);
    }

    public entry fun restart<PairType, CollateralType>(
        _admin: &signer
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::restart(admin_cap);
    }

    public entry fun set_funding_fee_per_block<PairType, CollateralType>(
        _admin: &signer,
        _fee: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_funding_fee_per_block(_fee, admin_cap);
    }

    public entry fun set_rollover_fee_per_block<PairType, CollateralType>(
        _admin: &signer,
        _fee: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_rollover_fee_per_block(_fee, admin_cap);
    }

    public entry fun set_entry_exit_fee<PairType, CollateralType>(
        _admin: &signer,
        _fee: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_entry_exit_fee(_fee, admin_cap);
    }

    public entry fun set_max_interest<PairType, CollateralType>(
        _admin: &signer,
        _max_interest: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_max_interest(_max_interest, admin_cap);
    }

    public entry fun set_min_leverage<PairType, CollateralType>(
        _admin: &signer,
        _min_leverage: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_min_leverage(_min_leverage, admin_cap);
    }

    public entry fun set_max_leverage<PairType, CollateralType>(
        _admin: &signer,
        _max_leverage: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_max_leverage(_max_leverage, admin_cap);
    }

    public entry fun set_market_depth_above<PairType, CollateralType>(
        _admin: &signer,
        _market_depth_above: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_market_depth_above(_market_depth_above, admin_cap);
    }

    public entry fun set_market_depth_below<PairType, CollateralType>(
        _admin: &signer,
        _market_depth_below: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_market_depth_below(_market_depth_below, admin_cap);
    }

    public entry fun set_execute_time_limit<PairType, CollateralType>(
        _admin: &signer,
        _execute_time_limit: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_execute_time_limit(_execute_time_limit, admin_cap);
    }

    public entry fun set_liquidate_threshold<PairType, CollateralType>(
        _admin: &signer,
        _liuquidate_threshold: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_liquidate_threshold(_liuquidate_threshold, admin_cap);
    }

    public entry fun set_maximum_profit<PairType, CollateralType>(
        _admin: &signer,
        _maximum_profit: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_maximum_profit(_maximum_profit, admin_cap);
    }

    public entry fun set_spread<PairType, CollateralType>(
        _admin: &signer,
        _spread: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_spread(_spread, admin_cap);
    }

    /// Remove execute capability from `signer`.
    public entry fun remove_execute_capability<PairType, CollateralType>(signer: &signer): ExecuteCapabilityStore<PairType, CollateralType>
    acquires ExecuteCapabilityStore {
        move_from<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(signer))
    }

    /// Remove admin capability from `signer`.
    public entry fun remove_admin_capability<PairType, CollateralType>(signer: &signer): AdminCapabilityStore<PairType, CollateralType>
    acquires AdminCapabilityStore {
        move_from<AdminCapabilityStore<PairType, CollateralType>>(address_of(signer))
    }

    #[test_only]
    struct TEST_USDC {}

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test register Pair
    public entry fun T_initialize(host: &signer, aptos_framework: &signer) {
        let host_addr = address_of(host);
        set_time_has_started_for_testing(aptos_framework);
        create_account_for_test(host_addr);
        initialize<BTC_USD, TEST_USDC>(host);
    }
}