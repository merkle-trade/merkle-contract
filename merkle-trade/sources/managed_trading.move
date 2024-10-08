module merkle::managed_trading {

    // Entry functions for trading

    // <-- USE ----->
    use std::signer::address_of;
    use std::string::String;
    use std::vector;

    use merkle::trading;
    use merkle::trading::{ExecuteCapability, AdminCapability, ExecuteCapabilityV2, CapabilityProvider};
    use merkle::price_oracle;
    use merkle::referral;

    #[test_only]
    use aptos_framework::timestamp::set_time_has_started_for_testing;
    #[test_only]
    use aptos_framework::account::create_account_for_test;
    #[test_only]
    use merkle::pair_types::BTC_USD;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    /// Capability to call execute_order and execute_exit_position.
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    /// CollateralType: collateral type ex) lzUSDC
    struct ExecuteCapabilityStore<phantom PairType, phantom CollateralType> has key, drop {
        execute_cap: ExecuteCapability<PairType, CollateralType>,
    }

    struct ExecuteCapabilityStoreV2<phantom CollateralType> has key, drop {
        execute_cap: ExecuteCapabilityV2<CollateralType>,
    }

    /// Capability to call set configs
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    /// CollateralType: collateral type ex) lzUSDC
    struct AdminCapabilityStore<phantom PairType, phantom CollateralType> has key, drop {
        admin_cap: AdminCapability<PairType, CollateralType>,
    }

    /// Other addresses with ExecuteCapability
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    /// CollateralType: collateral type ex) lzUSDC
    struct ExecuteCapabilityCandidate<phantom PairType, phantom CollateralType> has key, copy, drop {
        execute_cap_candidate: vector<address>,
        execute_caps: vector<ExecuteCapability<PairType, CollateralType>>,
    }

    struct ExecuteCapabilityCandidateV2<phantom CollateralType> has key, copy, drop {
        execute_cap_candidate: vector<address>,
        execute_caps: vector<ExecuteCapabilityV2<CollateralType>>,
    }

    /// Other addresses with AdminCapability
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    /// CollateralType: collateral type ex) lzUSDC
    struct AdminCapabilityCandidate<phantom PairType, phantom CollateralType> has key, copy, drop {
        admin_cap_candidate: vector<address>,
        admin_caps: vector<AdminCapability<PairType, CollateralType>>,
    }

    public entry fun initialize<PairType, CollateralType>(
        _host: &signer
    ) {
        if (!exists<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(_host))) {
            let (execute_cap, admin_cap) = trading::initialize<PairType, CollateralType>(_host);
            move_to(_host, ExecuteCapabilityStore { execute_cap });
            move_to(_host, AdminCapabilityStore { admin_cap });
        };
        price_oracle::register_oracle<PairType>(_host);
        trading::initialize_v2<PairType, CollateralType>(_host);
    }

    public entry fun initialize_module_v2<CollateralType>(_host: &signer) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<ExecuteCapabilityCandidateV2<CollateralType>>(address_of(_host))) {
            move_to(_host, ExecuteCapabilityCandidateV2<CollateralType> {
                execute_cap_candidate: vector::empty(),
                execute_caps: vector::empty()
            });
        };
    }

    /// Register the ExecuteCapability to be claimed by other addresses.
    /// Only allowed for admin.
    public entry fun set_address_executor_candidate<PairType, CollateralType>(
        _host: &signer,
        candidate: address
    ) acquires AdminCapabilityStore, ExecuteCapabilityCandidate {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);

        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_host)).admin_cap;
        let execute_cap =
            trading::generate_execute_cap<PairType, CollateralType>(_host, admin_cap);

        if (!exists<ExecuteCapabilityCandidate<PairType, CollateralType>>(address_of(_host))) {
            move_to(_host, ExecuteCapabilityCandidate<PairType, CollateralType> {
                execute_cap_candidate: vector::empty(),
                execute_caps: vector::empty()
            });
        };
        let candidates =
            borrow_global_mut<ExecuteCapabilityCandidate<PairType, CollateralType>>(address_of(_host));
        vector::push_back(&mut candidates.execute_cap_candidate, candidate);
        vector::push_back(&mut candidates.execute_caps, execute_cap);
    }

    public fun set_address_executor_candidate_v2<CollateralType>(
        _host: &signer,
        candidate: address,
        _cap: &CapabilityProvider
    ) acquires ExecuteCapabilityCandidateV2 {
        if (exists<ExecuteCapabilityStoreV2<CollateralType>>(candidate)) {
            return
        };
        let execute_cap = trading::generate_execute_cap_v2<CollateralType>(_host, _cap);
        let candidates = borrow_global_mut<ExecuteCapabilityCandidateV2<CollateralType>>(@merkle);
        vector::push_back(&mut candidates.execute_cap_candidate, candidate);
        vector::push_back(&mut candidates.execute_caps, execute_cap);
    }

    /// Register the AdminCapability to be claimed by other addresses.
    /// Only allowed for admin.
    public entry fun set_address_admin_candidate<PairType, CollateralType>(
        _host: &signer,
        candidate: address
    ) acquires AdminCapabilityStore, AdminCapabilityCandidate {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        if (exists<AdminCapabilityStore<PairType, CollateralType>>(candidate)) {
            return
        };
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_host)).admin_cap;
        let admin_cap =
            trading::generate_admin_cap<PairType, CollateralType>(_host, admin_cap);

        if (!exists<AdminCapabilityCandidate<PairType, CollateralType>>(address_of(_host))) {
            move_to(_host, AdminCapabilityCandidate<PairType, CollateralType> {
                admin_cap_candidate: vector::empty(),
                admin_caps: vector::empty()
            });
        };
        let candidates =
            borrow_global_mut<AdminCapabilityCandidate<PairType, CollateralType>>(address_of(_host));
        vector::push_back(&mut candidates.admin_cap_candidate, candidate);
        vector::push_back(&mut candidates.admin_caps, admin_cap);
    }

    /// Allows an executor candidate to claim ExecuteCapability.
    /// Only allowed for executor candidate.
    public entry fun claim_executor_cap<PairType, CollateralType>(
        _host: &signer,
    ) acquires ExecuteCapabilityCandidate {
        let candidate =
            borrow_global_mut<ExecuteCapabilityCandidate<PairType, CollateralType>>(@merkle);
        let (exist, idx) = vector::index_of(&candidate.execute_cap_candidate, &address_of(_host));
        if (exist) {
            vector::remove(&mut candidate.execute_cap_candidate, idx);
            let store = vector::pop_back(&mut candidate.execute_caps);
            if (!exists<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(_host))) {
                move_to(_host, ExecuteCapabilityStore<PairType, CollateralType> {
                    execute_cap: store
                })
            };
        };
    }

    public entry fun claim_executor_cap_v2<CollateralType>(
        _host: &signer,
    ) acquires ExecuteCapabilityCandidateV2 {
        let candidate = borrow_global_mut<ExecuteCapabilityCandidateV2<CollateralType>>(@merkle);
        let (exist, idx) = vector::index_of(&candidate.execute_cap_candidate, &address_of(_host));
        assert!(exist, E_NOT_AUTHORIZED);
        vector::remove(&mut candidate.execute_cap_candidate, idx);
        let store = vector::pop_back(&mut candidate.execute_caps);
        if (exists<ExecuteCapabilityStoreV2<CollateralType>>(address_of(_host))) {
            return
        };
        move_to(_host, ExecuteCapabilityStoreV2<CollateralType> {
            execute_cap: store
        });
    }

    /// Allows an admin candidate to claim AdminCapability.
    /// Only allowed for admin candidate.
    public entry fun claim_admin_cap<PairType, CollateralType>(
        _host: &signer,
    ) acquires AdminCapabilityCandidate {
        if (exists<AdminCapabilityStore<PairType, CollateralType>>(address_of(_host))) {
            return
        };
        let candidate =
            borrow_global_mut<AdminCapabilityCandidate<PairType, CollateralType>>(@merkle);
        let (exist, idx) = vector::index_of(&candidate.admin_cap_candidate, &address_of(_host));
        if (exist) {
            vector::remove(&mut candidate.admin_cap_candidate, idx);
            let store = vector::pop_back(&mut candidate.admin_caps);
            if (!exists<AdminCapabilityStore<PairType, CollateralType>>(address_of(_host))) {
                move_to(_host, AdminCapabilityStore<PairType, CollateralType> {
                    admin_cap: store
                })
            };
        };
    }

    /// Burn ExecuteCapability
    /// Only allowed for executor candidate.
    public entry fun burn_execute_cap<PairType, CollateralType>(
        _host: &signer,
        target_address: address
    ) acquires ExecuteCapabilityStoreV2 {
        // If target_address is @merkle, the modules may no longer be available
        // Executor can remove its own ExecuteCapability, or admin can remove executor's ExecuteCapabilityStore.
        assert!(target_address != @merkle &&
            (target_address == address_of(_host) || address_of(_host) == @merkle), E_NOT_AUTHORIZED);
        move_from<ExecuteCapabilityStoreV2<CollateralType>>(target_address);
    }

    /// Burn AdminCapability
    /// Only allowed for executor candidate.
    public entry fun burn_admin_cap<PairType, CollateralType>(
        _host: &signer,
        target_address: address
    ) acquires AdminCapabilityStore {
        // If target_address is @merkle, the modules may no longer be available
        // Admin can remove its own AdminCapability, or admin can remove admin's AdminCapabilityStore.
        assert!(target_address != @merkle &&
            (target_address == address_of(_host) || address_of(_host) == @merkle), E_NOT_AUTHORIZED);
        move_from<AdminCapabilityStore<PairType, CollateralType>>(target_address);
    }

    /// Clean ExecuteCapability
    /// Only allowed admin.
    public entry fun clean_execute_cap<PairType, CollateralType>(
        _host: &signer,
    ) acquires ExecuteCapabilityCandidate {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        let candidates =
            borrow_global_mut<ExecuteCapabilityCandidate<PairType, CollateralType>>(address_of(_host));
        while(!vector::is_empty(&candidates.execute_cap_candidate)) {
            vector::pop_back(&mut candidates.execute_cap_candidate);
        };
        while(!vector::is_empty(&candidates.execute_caps)) {
            vector::pop_back(&mut candidates.execute_caps);
        };
    }

    /// Clean AdminCapability
    /// Only allowed admin.
    public entry fun clean_admin_cap<PairType, CollateralType>(
        _host: &signer,
    ) acquires AdminCapabilityCandidate {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        let candidates =
            borrow_global_mut<AdminCapabilityCandidate<PairType, CollateralType>>(address_of(_host));
        while(!vector::is_empty(&candidates.admin_cap_candidate)) {
            vector::pop_back(&mut candidates.admin_cap_candidate);
        };
        while(!vector::is_empty(&candidates.admin_caps)) {
            vector::pop_back(&mut candidates.admin_caps);
        };
    }

    public entry fun place_order<PairType, CollateralType>(
        _user: &signer,
        _size_delta: u64,
        _collateral_delta: u64,
        _price: u64,
        _is_long: bool,
        _is_increase: bool,
        _is_market: bool,
        _stop_loss_trigger_price: u64,
        _take_profit_trigger_price: u64,
        _can_execute_above_price: bool
    ) {
        trading::place_order<PairType, CollateralType>(
            _user,
            _size_delta,
            _collateral_delta,
            _price,
            _is_long,
            _is_increase,
            _is_market,
            _stop_loss_trigger_price,
            _take_profit_trigger_price,
            _can_execute_above_price
        );
    }

    public entry fun place_order_with_referrer<PairType, CollateralType>(
        _user: &signer,
        _size_delta: u64,
        _collateral_delta: u64,
        _price: u64,
        _is_long: bool,
        _is_increase: bool,
        _is_market: bool,
        _stop_loss_trigger_price: u64,
        _take_profit_trigger_price: u64,
        _can_execute_above_price: bool,
        _referrer: address
    ) {
        referral::register_referrer<CollateralType>(address_of(_user), _referrer);
        trading::place_order<PairType, CollateralType>(
            _user,
            _size_delta,
            _collateral_delta,
            _price,
            _is_long,
            _is_increase,
            _is_market,
            _stop_loss_trigger_price,
            _take_profit_trigger_price,
            _can_execute_above_price
        );
    }

    public entry fun place_order_v3<PairType, CollateralType>(
        _signer: &signer,
        _user_address: address,
        _size_delta: u64,
        _collateral_delta: u64,
        _price: u64,
        _is_long: bool,
        _is_increase: bool,
        _is_market: bool,
        _stop_loss_trigger_price: u64,
        _take_profit_trigger_price: u64,
        _can_execute_above_price: bool,
        _referrer: address
    ) {
        referral::register_referrer<CollateralType>(_user_address, _referrer);
        trading::place_order_v3<PairType, CollateralType>(
            _signer,
            _user_address,
            _size_delta,
            _collateral_delta,
            _price,
            _is_long,
            _is_increase,
            _is_market,
            _stop_loss_trigger_price,
            _take_profit_trigger_price,
            _can_execute_above_price
        );
    }

    public entry fun cancel_order<PairType, CollateralType>(
        _user: &signer,
        _order_id: u64
    ) {
        trading::cancel_order<PairType, CollateralType>(_user, _order_id);
    }

    public entry fun cancel_order_v3<PairType, CollateralType>(
        _signer: &signer,
        _user_address: address,
        _order_id: u64
    ) {
        trading::cancel_order_v3<PairType, CollateralType>(_signer, _user_address, _order_id);
    }

    public entry fun execute_order_self<PairType, CollateralType>(
        _executor: &signer,
        _order_id: u64
    ) {
        trading::execute_order_self<PairType, CollateralType>(_executor, _order_id);
    }

    public entry fun update_position_tp_sl<PairType, CollateralType>(
        _host: &signer,
        _is_long: bool,
        _take_profit_trigger_price: u64,
        _stop_loss_trigger_price: u64
    ) {
        trading::update_position_tp_sl<PairType, CollateralType>(_host, _is_long, _take_profit_trigger_price, _stop_loss_trigger_price);
    }

    public entry fun update_position_tp_sl_v3<PairType, CollateralType>(
        _signer: &signer,
        _user_address: address,
        _is_long: bool,
        _take_profit_trigger_price: u64,
        _stop_loss_trigger_price: u64
    ) {
        trading::update_position_tp_sl_v3<
            PairType,
            CollateralType
        >(
            _signer,
            _user_address,
            _is_long,
            _take_profit_trigger_price,
            _stop_loss_trigger_price
        );
    }

    public entry fun execute_order_all<PairType, CollateralType>(
        _executor: &signer,
        _fast_price: u64,
        _pyth_vaa: vector<u8>
    ) acquires ExecuteCapabilityStore {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_order_all<PairType, CollateralType>(_executor, _fast_price, _pyth_vaa, execute_cap);
    }

    public entry fun execute_order_all_v2<PairType, CollateralType>(
        _executor: &signer,
        _fast_price: u64,
        _pyth_vaa: vector<u8>
    ) acquires ExecuteCapabilityStoreV2 {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStoreV2<CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_order_all_v2<PairType, CollateralType>(_executor, _fast_price, _pyth_vaa, execute_cap);
    }

    public entry fun execute_order<PairType, CollateralType>(
        _executor: &signer,
        _order_id: u64,
        _fast_price: u64,
        _pyth_vaa: vector<u8>
    ) acquires ExecuteCapabilityStore {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_order<PairType, CollateralType>(_executor, _order_id, _fast_price, _pyth_vaa, execute_cap);
    }

    public entry fun execute_order_v2<PairType, CollateralType>(
        _executor: &signer,
        _order_id: u64,
        _fast_price: u64,
        _pyth_vaa: vector<u8>
    ) acquires ExecuteCapabilityStoreV2 {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStoreV2<CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_order_v2<PairType, CollateralType>(_executor, _order_id, _fast_price, _pyth_vaa, execute_cap);
    }

    public entry fun execute_exit_position<PairType, CollateralType>(
        _executor: &signer,
        _user: address,
        _is_long: bool,
        _fast_price: u64,
        _pyth_vaa: vector<u8>
    ) acquires ExecuteCapabilityStore {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStore<PairType, CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_exit_position<PairType, CollateralType>(_executor, _user, _is_long, _fast_price, _pyth_vaa, execute_cap);
    }

    public entry fun execute_exit_position_v2<PairType, CollateralType>(
        _executor: &signer,
        _user: address,
        _is_long: bool,
        _fast_price: u64,
        _pyth_vaa: vector<u8>
    ) acquires ExecuteCapabilityStoreV2 {
        let execute_cap =
            &borrow_global<ExecuteCapabilityStoreV2<CollateralType>>(address_of(_executor)).execute_cap;
        trading::execute_exit_position_v2<PairType, CollateralType>(_executor, _user, _is_long, _fast_price, _pyth_vaa, execute_cap);
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

    public entry fun set_rollover_fee_per_block<PairType, CollateralType>(
        _admin: &signer,
        _fee: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_rollover_fee_per_block(_fee, admin_cap);
    }

    public entry fun set_taker_fee<PairType, CollateralType>(
        _admin: &signer,
        _fee: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_taker_fee(_fee, admin_cap);
    }

    public entry fun set_maker_fee<PairType, CollateralType>(
        _admin: &signer,
        _fee: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_maker_fee(_fee, admin_cap);
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

    public entry fun set_skew_factor<PairType, CollateralType>(
        _admin: &signer,
        _skew_factor: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_skew_factor(_skew_factor, admin_cap);
    }

    public entry fun set_max_funding_velocity<PairType, CollateralType>(
        _admin: &signer,
        _set_max_funding_velocity: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_max_funding_velocity(_set_max_funding_velocity, admin_cap);
    }

    public entry fun set_minimum_order_collateral<PairType, CollateralType>(
        _admin: &signer,
        _minimum_collateral: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_minimum_order_collateral(_minimum_collateral, admin_cap);
    }

    public entry fun set_minimum_position_collateral<PairType, CollateralType>(
        _admin: &signer,
        _minimum_collateral: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_minimum_position_collateral(_minimum_collateral, admin_cap);
    }

    public entry fun set_minimum_position_size<PairType, CollateralType>(
        _admin: &signer,
        _minimum_position_size: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_minimum_position_size(_minimum_position_size, admin_cap);
    }

    public entry fun set_maximum_position_collateral<PairType, CollateralType>(
        _admin: &signer,
        _maximum_collateral: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_maximum_position_collateral(_maximum_collateral, admin_cap);
    }

    public entry fun set_execution_fee<PairType, CollateralType>(
        _admin: &signer,
        _execution_fee: u64
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_execution_fee(_execution_fee, admin_cap);
    }

    public entry fun set_param<PairType, CollateralType>(
        _admin: &signer,
        _key: String,
        _value: vector<u8>
    ) acquires AdminCapabilityStore {
        let admin_cap =
            &borrow_global<AdminCapabilityStore<PairType, CollateralType>>(address_of(_admin)).admin_cap;
        trading::set_param(_key, _value, admin_cap);
    }

    #[test_only]
    struct TEST_USDC {}

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test register Pair
    fun T_initialize(host: &signer, aptos_framework: &signer) {
        let host_addr = address_of(host);
        set_time_has_started_for_testing(aptos_framework);
        create_account_for_test(host_addr);
        initialize<BTC_USD, TEST_USDC>(host);
    }
}