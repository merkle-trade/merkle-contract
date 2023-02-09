module merkle::price_oracle {

    use std::signer;
    use std::vector;
    use std::string::String;

    use aptos_std::table;
    use aptos_std::type_info;

    use aptos_framework::timestamp;

    use switchboard::aggregator;
    use switchboard::math;

    use merkle::math_u64;
    use merkle::oracle_feed;

    const BASIS_POINTS_DIVISOR: u64 = 10000;
    const PRICE_DECIMALS: u8 = 8;

    const ERR_NO_VALUE_NO_SWITCHBOARD: u64 = 101;
    const ERR_NO_SWITCHBOARD2_VALUE: u64 = 102;

    struct PriceOracleConfig has key, store, copy, drop {
        max_price_update_delay: u64, /// 3600 * 1000 * 1000
        price_duration: u64, /// 300 * 1000 * 1000
        spread_basis_points_if_chain_error: u64,
        spread_basis_points_if_inactive: u64,
        max_deviation_basis_points: u64,  /// 150 -> 1.5%
        switchboard_oracle_addresses: vector<address>,
        is_spread_enabled: bool,
    }

    struct PriceOracleInfo has key {
        oracle_info: table::Table<String, PriceOracleConfig>
    }

    public fun register_oracle<CoinT>(host: &signer, init_value: u64) acquires PriceOracleInfo {
        let host_addr = signer::address_of(host);
        let coin_key = type_info::type_name<CoinT>();

        oracle_feed::register_oracle<CoinT>(host, init_value);
        if (!exists<PriceOracleInfo>(host_addr)) {
            move_to(host, PriceOracleInfo {
                oracle_info: table::new()
            });
        };
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(host_addr);
        table::add(&mut price_oracle_info.oracle_info, coin_key, PriceOracleConfig {
            max_price_update_delay: 3600 * 1000 * 1000,
            price_duration: 300 * 1000 * 1000,
            spread_basis_points_if_chain_error: 0,
            spread_basis_points_if_inactive: 0,
            max_deviation_basis_points: 150,
            switchboard_oracle_addresses: vector::empty(),
            is_spread_enabled: true
        })
    }

    public fun get_price_decimals(): u8 {
        PRICE_DECIMALS
    }

    /// Update OracleInfo
    public fun update_price_oracle_info_max_price_update_delay<CoinT>(host: &signer, max_price_update_delay: u64) acquires PriceOracleInfo {
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(signer::address_of(host));
        let coin_key = type_info::type_name<CoinT>();
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, coin_key);
        price_oracle_config.max_price_update_delay = max_price_update_delay;
    }

    public fun update_price_oracle_info_price_duration<CoinT>(host: &signer, price_duration: u64) acquires PriceOracleInfo {
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(signer::address_of(host));
        let coin_key = type_info::type_name<CoinT>();
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, coin_key);
        price_oracle_config.price_duration = price_duration;
    }

    public fun update_price_oracle_info_spread_basis_points_if_chain_error<CoinT>(host: &signer, spread_basis_points_if_chain_error: u64) acquires PriceOracleInfo {
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(signer::address_of(host));
        let coin_key = type_info::type_name<CoinT>();
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, coin_key);
        price_oracle_config.spread_basis_points_if_chain_error = spread_basis_points_if_chain_error;
    }

    public fun update_price_oracle_info_spread_basis_points_if_inactive<CoinT>(host: &signer, spread_basis_points_if_inactive: u64) acquires PriceOracleInfo {
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(signer::address_of(host));
        let coin_key = type_info::type_name<CoinT>();
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, coin_key);
        price_oracle_config.spread_basis_points_if_inactive = spread_basis_points_if_inactive;
    }

    public fun update_price_oracle_info_max_deviation_basis_points<CoinT>(host: &signer, max_deviation_basis_points: u64) acquires PriceOracleInfo {
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(signer::address_of(host));
        let coin_key = type_info::type_name<CoinT>();
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, coin_key);
        price_oracle_config.max_deviation_basis_points = max_deviation_basis_points;
    }

    public fun update_price_oracle_info_switchboard_oracle_addresses<CoinT>(host: &signer, idx: u64, switchboard_oracle_address: address) acquires PriceOracleInfo {
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(signer::address_of(host));
        let coin_key = type_info::type_name<CoinT>();
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, coin_key);
        if (idx == 2) {
            while(!vector::is_empty(&price_oracle_config.switchboard_oracle_addresses)) {
                vector::pop_back(&mut price_oracle_config.switchboard_oracle_addresses);
            };
        } else if (idx >= vector::length(&price_oracle_config.switchboard_oracle_addresses)) {
            vector::push_back(&mut price_oracle_config.switchboard_oracle_addresses, switchboard_oracle_address);
        } else if (idx >= vector::length(&price_oracle_config.switchboard_oracle_addresses)) {
            let _target_address = vector::borrow_mut(&mut price_oracle_config.switchboard_oracle_addresses, idx);
            _target_address = &mut switchboard_oracle_address;
        };
    }

    public fun update_price_oracle_info_is_spread_enabled<CoinT>(host: &signer, is_spread_enabled: bool) acquires PriceOracleInfo {
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(signer::address_of(host));
        let coin_key = type_info::type_name<CoinT>();
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, coin_key);
        price_oracle_config.is_spread_enabled = is_spread_enabled;
    }

    public fun read_with_type<CoinT>(_maximize: bool): u64 acquires PriceOracleInfo {
        let coin_key = type_info::type_name<CoinT>();
        read(coin_key, _maximize)
    }

    public fun read(key: String, _maximize: bool): u64 acquires PriceOracleInfo {
        let _now = timestamp::now_microseconds();
        let (_value, _timestamp) = oracle_feed::unpack_record(oracle_feed::read_record(key));
        let price_oracle_info = borrow_global_mut<PriceOracleInfo>(@merkle);
        let price_oracle_config = table::borrow_mut(&mut price_oracle_info.oracle_info, key);

        if (vector::length(&price_oracle_config.switchboard_oracle_addresses) == 0) {
            if (_value == 0) {
                abort ERR_NO_VALUE_NO_SWITCHBOARD
            };
            return _value
        };
        let switchboard_oracle_addr1 = *vector::borrow(&mut price_oracle_config.switchboard_oracle_addresses, 0);
        let switchboard_price = get_switchboard_price(switchboard_oracle_addr1);
        if (vector::length(&price_oracle_config.switchboard_oracle_addresses) > 1) {
            let switchboard_oracle_addr2 = *vector::borrow(&mut price_oracle_config.switchboard_oracle_addresses, 1);
            let switchboard_price2 = get_switchboard_price(switchboard_oracle_addr2);
            if (switchboard_price2 == 0) {
                abort ERR_NO_SWITCHBOARD2_VALUE
            };
            switchboard_price = switchboard_price * BASIS_POINTS_DIVISOR / switchboard_price2;
        };

        if (_value == 0) {
            if (switchboard_price == 0) {
                abort ERR_NO_VALUE_NO_SWITCHBOARD
            };
            return switchboard_price
        };

        if (_now - _timestamp > price_oracle_config.max_price_update_delay) {
            if (_maximize) {
                return switchboard_price * (BASIS_POINTS_DIVISOR + price_oracle_config.spread_basis_points_if_chain_error) / BASIS_POINTS_DIVISOR
            };
            return switchboard_price * (BASIS_POINTS_DIVISOR - price_oracle_config.spread_basis_points_if_chain_error) / BASIS_POINTS_DIVISOR
        };

        if (_now - _timestamp > price_oracle_config.price_duration) {
            if (_maximize) {
                return switchboard_price * (BASIS_POINTS_DIVISOR + price_oracle_config.spread_basis_points_if_inactive) / BASIS_POINTS_DIVISOR
            };
            return switchboard_price * (BASIS_POINTS_DIVISOR - price_oracle_config.spread_basis_points_if_inactive) / BASIS_POINTS_DIVISOR
        };

        let diff_basis_points = math_u64::abs(switchboard_price, _value) * BASIS_POINTS_DIVISOR / switchboard_price;
        let hasSpread: bool = price_oracle_config.is_spread_enabled || diff_basis_points > price_oracle_config.max_deviation_basis_points;

        if (hasSpread) {
            // return the higher of the two prices
            if(_maximize) {
                return math_u64::max(switchboard_price, _value)
            };
            return math_u64::min(switchboard_price, _value)
        };

        _value
    }

    public fun update_with_type<CoinT>(host: &signer, value: u64) {
        let coin_key = type_info::type_name<CoinT>();
        update(host, coin_key, value);
    }

    public fun update(host: &signer, key: String, value: u64) {
        oracle_feed::update(host, key, value);
    }

    /// Get price from switchboard
    public fun get_switchboard_price(addr: address): u64 {
        let latest_value = aggregator::latest_value(addr);
        let (value, _, _) = math::unpack(latest_value);
        (value as u64)
    }

    /* test */
    #[test_only]
    use aptos_framework::account;

    #[test_only]
    struct TESTUSD has copy,store,drop {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        let host_addr = signer::address_of(host);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(host_addr);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_register_oracle(host: &signer, aptos_framework: &signer) acquires PriceOracleInfo {
        let host_addr = signer::address_of(host);
        let coin_key = type_info::type_name<TESTUSD>();
        call_test_setting(host, aptos_framework);

        register_oracle<TESTUSD>(host, 10);

        let info = borrow_global<PriceOracleInfo>(host_addr);
        let price_oracle_config = table::borrow(&info.oracle_info, coin_key);

        assert!(price_oracle_config.max_price_update_delay == 3600 * 1000 * 1000, 0);
        assert!(price_oracle_config.price_duration == 300 * 1000 * 1000, 1);
        assert!(price_oracle_config.spread_basis_points_if_chain_error == 0, 2);
        assert!(price_oracle_config.spread_basis_points_if_inactive == 0, 3);
        assert!(price_oracle_config.max_deviation_basis_points == 150, 4);
        assert!(vector::length(&price_oracle_config.switchboard_oracle_addresses) == 0, 5);
        assert!(price_oracle_config.is_spread_enabled == true, 7);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update_oracle_price(host: &signer, aptos_framework: &signer) acquires PriceOracleInfo {
        let coin_key = type_info::type_name<TESTUSD>();
        call_test_setting(host, aptos_framework);

        register_oracle<TESTUSD>(host, 10);
        let value = read(coin_key, true);
        assert!(value == 10, 0);

        update(host, coin_key,20);
        value = read(coin_key, true);
        assert!(value == 20, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update_oracle_info(host: &signer, aptos_framework: &signer) acquires PriceOracleInfo {
        let coin_key = type_info::type_name<TESTUSD>();
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);

        register_oracle<TESTUSD>(host, 10);

        let info = borrow_global<PriceOracleInfo>(host_addr);
        let price_oracle_config = table::borrow(&info.oracle_info, coin_key);

        assert!(price_oracle_config.max_price_update_delay == 3600 * 1000 * 1000, 0);
        assert!(price_oracle_config.price_duration == 300 * 1000 * 1000, 1);
        assert!(price_oracle_config.spread_basis_points_if_chain_error == 0, 2);
        assert!(price_oracle_config.spread_basis_points_if_inactive == 0, 3);
        assert!(price_oracle_config.max_deviation_basis_points == 150, 4);
        assert!(vector::length(&price_oracle_config.switchboard_oracle_addresses) == 0, 5);
        assert!(price_oracle_config.is_spread_enabled == true, 7);

        update_price_oracle_info_max_price_update_delay<TESTUSD>(host, 4600 * 1000 * 1000);
        update_price_oracle_info_price_duration<TESTUSD>(host, 400 * 1000 * 1000);
        update_price_oracle_info_spread_basis_points_if_chain_error<TESTUSD>(host, 10);
        update_price_oracle_info_spread_basis_points_if_inactive<TESTUSD>(host, 20);
        update_price_oracle_info_max_deviation_basis_points<TESTUSD>(host, 200);
        update_price_oracle_info_switchboard_oracle_addresses<TESTUSD>(host, 0, @merkle);
        update_price_oracle_info_is_spread_enabled<TESTUSD>(host, false);

        let info = borrow_global<PriceOracleInfo>(host_addr);
        let price_oracle_config = table::borrow(&info.oracle_info, coin_key);

        assert!(price_oracle_config.max_price_update_delay == 4600 * 1000 * 1000, 8);
        assert!(price_oracle_config.price_duration == 400 * 1000 * 1000, 9);
        assert!(price_oracle_config.spread_basis_points_if_chain_error == 10, 10);
        assert!(price_oracle_config.spread_basis_points_if_inactive == 20, 11);
        assert!(price_oracle_config.max_deviation_basis_points == 200, 12);
        assert!(vector::length(&price_oracle_config.switchboard_oracle_addresses) == 1, 13);
        assert!(price_oracle_config.is_spread_enabled == false, 14);

        update_price_oracle_info_switchboard_oracle_addresses<TESTUSD>(host, 2, @merkle);

        let info = borrow_global<PriceOracleInfo>(host_addr);
        let price_oracle_config = table::borrow(&info.oracle_info, coin_key);
        assert!(vector::length(&price_oracle_config.switchboard_oracle_addresses) == 0, 15);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_read(host: &signer, aptos_framework: &signer) acquires PriceOracleInfo {
        let coin_key = type_info::type_name<TESTUSD>();
        call_test_setting(host, aptos_framework);

        register_oracle<TESTUSD>(host, 10);

        let value = read(coin_key, true);
        assert!(value == 10, 8);
    }
}
