module merkle::price_oracle {
    use std::signer;
    use std::signer::address_of;
    use std::vector;
    use aptos_std::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use merkle::pair_types;
    use merkle::pyth_scripts;
    use merkle::safe_math::{safe_mul_div, exp};

    const BASIS_POINTS_DIVISOR: u64 = 1000000; // 1000000 = 100%
    const PRICE_DECIMALS: u64 = 10;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When Price is also 0 and there is no Switchboard value
    const E_NO_VALUE_NO_SWITCHBOARD: u64 = 1;
    /// When the pyth identifier does not exist
    const E_PYTH_IDENTIFIER_DOES_NOT_EXIST: u64 = 2;

    struct PriceOracleConfig<phantom PairType> has key, drop {
        /// price update delay timeout
        max_price_update_delay: u64, /// default 1hour, 3600
        /// spread applied when max price update delay time has elapsed
        spread_basis_points_if_update_delay: u64,
        /// Percentage limit of difference between price and switchboard price
        max_deviation_basis_points: u64,  /// default 150 -> 1.5%
        /// address to get switchboard price information
        switchboard_oracle_address: address,
        /// flag whether to apply switchboard price
        is_spread_enabled: bool,
        /// flag whether to update and verify prices via pyth
        update_pyth_enabled: bool,
        /// identifier used to get pyth price
        pyth_price_identifier: vector<u8>,
        /// vector containing the different executor addresses
        allowed_update: vector<address>
    }

    struct DataRecord<phantom PairType> has key, drop {
        /// Price
        value: u64,
        /// update timestamp seconds
        updated_at: u64,
        /// pyth verify data
        pyth_vaa: vector<u8>
    }

    struct UpdateCapabilityCandidate has key, drop {
        candidates: vector<address>
    }

    struct AptVault has key {
        coin_store: Coin<AptosCoin>,
    }

    struct UpdateCapability has key, drop {}

    struct CapabilityProvider has copy, store, drop {}

    public fun register_oracle<PairType>(host: &signer) {
        let host_addr = signer::address_of(host);
        assert!(host_addr == @merkle, E_NOT_AUTHORIZED);

        if (!exists<PriceOracleConfig<PairType>>(host_addr)) {
            move_to(host, PriceOracleConfig<PairType> {
                max_price_update_delay: 3600,
                spread_basis_points_if_update_delay: 0,
                max_deviation_basis_points: 150,
                switchboard_oracle_address: @0x0,
                is_spread_enabled: true,
                update_pyth_enabled: false,
                pyth_price_identifier: vector::empty(),
                allowed_update: vector::empty()
            });
        };
        if (!exists<DataRecord<PairType>>(host_addr)) {
            move_to(host, DataRecord<PairType> {
                value: 0,
                updated_at: 0,
                pyth_vaa: vector::empty()
            })
        };
    }

    public fun initialize_module(_host: &signer) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        if(!exists<UpdateCapabilityCandidate>(address_of(_host))) {
            move_to(_host, UpdateCapabilityCandidate {
                candidates: vector::empty<address>()
            });
        };

        if(!exists<AptVault>(address_of(_host))) {
            move_to(_host, AptVault {
                coin_store: coin::zero()
            })
        }
    }

    /// Register other executor addresses.
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    public fun register_allowed_update<PairType>(host: &signer, addr: address) acquires PriceOracleConfig {
        assert!(signer::address_of(host) == @merkle, E_NOT_AUTHORIZED);
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        if (!vector::contains(&price_oracle_config.allowed_update, &addr)) {
            vector::push_back(&mut price_oracle_config.allowed_update, addr);
        };
    }

    public fun register_allowed_update_v2(_host: &signer, _addr: address, _cap: &CapabilityProvider) acquires UpdateCapabilityCandidate {
        let update_capability_candidate = borrow_global_mut<UpdateCapabilityCandidate>(@merkle);
        if (!vector::contains(&update_capability_candidate.candidates, &_addr)) {
            vector::push_back(&mut update_capability_candidate.candidates, _addr);
        };
    }

    public fun claim_allowed_update(_user: &signer) acquires UpdateCapabilityCandidate {
        let user_address = signer::address_of(_user);
        let update_capability_candidate = borrow_global_mut<UpdateCapabilityCandidate>(@merkle);
        let (exist, idx) = vector::index_of(&update_capability_candidate.candidates, &user_address);
        assert!(exist, E_NOT_AUTHORIZED);
        vector::remove(&mut update_capability_candidate.candidates, idx);
        if (exists<UpdateCapability>(user_address)) {
            return
        };
        move_to(_user, UpdateCapability {});
    }

    /// Remove other executor addresses.
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    public fun remove_allowed_update<PairType>(host: &signer, addr: address) acquires PriceOracleConfig {
        assert!(signer::address_of(host) == @merkle, E_NOT_AUTHORIZED);
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        let (exists, idx) = vector::index_of(&price_oracle_config.allowed_update, &addr);
        if (exists) {
            vector::remove(&mut price_oracle_config.allowed_update, idx);
        };
    }

    public fun generate_capability_provider(
        _admin: &signer,
    ): CapabilityProvider {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        (CapabilityProvider {})
    }

    /// Update OracleInfo
    public fun set_max_price_update_delay<PairType>(host: &signer, max_price_update_delay: u64) acquires PriceOracleConfig {
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        price_oracle_config.max_price_update_delay = max_price_update_delay;
    }

    public fun set_spread_basis_points_if_update_delay<PairType>(host: &signer, spread_basis_points_if_update_delay: u64) acquires PriceOracleConfig {
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        price_oracle_config.spread_basis_points_if_update_delay = spread_basis_points_if_update_delay;
    }

    public fun set_max_deviation_basis_points<PairType>(host: &signer, max_deviation_basis_points: u64) acquires PriceOracleConfig {
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        price_oracle_config.max_deviation_basis_points = max_deviation_basis_points;
    }

    public fun set_switchboard_oracle_address<PairType>(host: &signer, switchboard_oracle_address: address) acquires PriceOracleConfig {
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        price_oracle_config.switchboard_oracle_address = switchboard_oracle_address;
    }

    public fun set_is_spread_enabled<PairType>(host: &signer, is_spread_enabled: bool) acquires PriceOracleConfig {
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        price_oracle_config.is_spread_enabled = is_spread_enabled;
    }

    public fun set_update_pyth_enabled<PairType>(host: &signer, update_pyth_enabled: bool) acquires PriceOracleConfig {
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        price_oracle_config.update_pyth_enabled = update_pyth_enabled;
    }

    public fun set_pyth_price_identifier<PairType>(host: &signer, pyth_price_identifier: vector<u8>) acquires PriceOracleConfig {
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(signer::address_of(host));
        price_oracle_config.pyth_price_identifier = pyth_price_identifier;
    }

    /// Read price
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    public fun read<PairType>(_maximize: bool): u64 acquires PriceOracleConfig, DataRecord {
        let data_record = borrow_global<DataRecord<PairType>>(@merkle);
        let price = data_record.value;
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(@merkle);
        if (price_oracle_config.update_pyth_enabled) {
            let _pyth_price = 0;
            let _expo = 0;
            // If update_pyth_enabled is true, use pyth price.
            // Only prices within 10 seconds are allowed.
            (_pyth_price, _expo, _) = pyth_scripts::get_price_from_vaa_no_older_than(price_oracle_config.pyth_price_identifier, 10);
            price = safe_mul_div(_pyth_price, exp(10, PRICE_DECIMALS), exp(10, _expo));
        };
        if (price_oracle_config.is_spread_enabled && price_oracle_config.spread_basis_points_if_update_delay > 0) {
            if (_maximize) {
                price = price * (BASIS_POINTS_DIVISOR + price_oracle_config.spread_basis_points_if_update_delay) / BASIS_POINTS_DIVISOR;
            } else {
                price = price * (BASIS_POINTS_DIVISOR - price_oracle_config.spread_basis_points_if_update_delay) / BASIS_POINTS_DIVISOR;
            };
        };
        if (price == 0) {
            abort E_NO_VALUE_NO_SWITCHBOARD
        };
        price
    }

    /// Update price
    /// @Type Parameters
    /// PairType: pair type ex) ETH_USD
    public fun update<PairType>(host: &signer, value: u64, pyth_vaa: vector<u8>)
    acquires PriceOracleConfig, DataRecord, AptVault {
        let host_addr = signer::address_of(host);
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<PairType>>(@merkle);
        assert!(
            host_addr == @merkle ||
                exists<UpdateCapability>(host_addr) ||
                vector::contains(&price_oracle_config.allowed_update, &host_addr),
            E_NOT_AUTHORIZED
        );

        if (price_oracle_config.update_pyth_enabled) {
            // If update_pyth_enabled is true, it will update the price to the pyth module.
            if (exists<AptVault>(@merkle)) {
                // If AptVault exists and has a balance, it will send Apt to the host for the pyth update fee.
                let apt_vault = borrow_global_mut<AptVault>(@merkle);
                if (coin::value(&apt_vault.coin_store) > 0) {
                    let apt = coin::extract(&mut apt_vault.coin_store, 1);
                    coin::deposit(host_addr, apt);
                };
            };
            pyth_scripts::update_pyth(host, pyth_vaa);
        };
        let data_record = borrow_global_mut<DataRecord<PairType>>(@merkle);
        data_record.value = value;
        data_record.updated_at = timestamp::now_seconds();
        data_record.pyth_vaa = pyth_vaa;
    }

    public fun get_price_for_random(): u64 acquires PriceOracleConfig {
        if (!exists<PriceOracleConfig<pair_types::ETH_USD>>(@merkle)) {
            return 0 // for test
        };
        let price_oracle_config = borrow_global<PriceOracleConfig<pair_types::ETH_USD>>(@merkle);
        assert!(!vector::is_empty(&price_oracle_config.pyth_price_identifier), E_PYTH_IDENTIFIER_DOES_NOT_EXIST);
        pyth_scripts::get_price_for_random(price_oracle_config.pyth_price_identifier)
    }

    public fun deposit_apt(_host: &signer, _amount: u64) acquires AptVault {
        let apt_vault = borrow_global_mut<AptVault>(@merkle);
        let apt = coin::withdraw<AptosCoin>(_host, _amount);
        coin::merge(&mut apt_vault.coin_store, apt);
    }

    /* test */
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    struct TESTUSD has copy,store,drop {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        let host_addr = signer::address_of(host);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        account::create_account_for_test(host_addr);

        register_oracle<TESTUSD>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_register_oracle(host: &signer, aptos_framework: &signer) acquires PriceOracleConfig {
        call_test_setting(host, aptos_framework);
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<TESTUSD>>(@merkle);
        assert!(price_oracle_config.max_price_update_delay == 3600 , 0);
        assert!(price_oracle_config.spread_basis_points_if_update_delay == 0, 2);
        assert!(price_oracle_config.max_deviation_basis_points == 150, 4);
        assert!(price_oracle_config.switchboard_oracle_address == @0x0, 5);
        assert!(price_oracle_config.is_spread_enabled == true, 7);
        assert!(vector::length(&price_oracle_config.allowed_update) == 0, 7);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update_oracle_price(host: &signer, aptos_framework: &signer) acquires PriceOracleConfig, DataRecord, AptVault {
        call_test_setting(host, aptos_framework);
        update<TESTUSD>(host, 10, vector::empty());
        let value = read<TESTUSD>(true);
        assert!(value == 10, 0);

        update<TESTUSD>(host, 20, vector::empty());
        value = read<TESTUSD>(true);
        assert!(value == 20, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update_oracle_info(host: &signer, aptos_framework: &signer) acquires PriceOracleConfig {
        call_test_setting(host, aptos_framework);
        let price_oracle_config = borrow_global_mut<PriceOracleConfig<TESTUSD>>(@merkle);

        assert!(price_oracle_config.max_price_update_delay == 3600, 0);
        assert!(price_oracle_config.spread_basis_points_if_update_delay == 0, 2);
        assert!(price_oracle_config.max_deviation_basis_points == 150, 4);
        assert!(price_oracle_config.switchboard_oracle_address == @0x0, 5);
        assert!(price_oracle_config.is_spread_enabled == true, 7);

        set_max_price_update_delay<TESTUSD>(host, 4600 * 1000 * 1000);
        set_spread_basis_points_if_update_delay<TESTUSD>(host, 10);
        set_max_deviation_basis_points<TESTUSD>(host, 200);
        set_switchboard_oracle_address<TESTUSD>(host, @merkle);
        set_is_spread_enabled<TESTUSD>(host, false);

        let price_oracle_config = borrow_global_mut<PriceOracleConfig<TESTUSD>>(@merkle);

        assert!(price_oracle_config.max_price_update_delay == 4600 * 1000 * 1000, 8);
        assert!(price_oracle_config.spread_basis_points_if_update_delay == 10, 10);
        assert!(price_oracle_config.max_deviation_basis_points == 200, 12);
        assert!(price_oracle_config.switchboard_oracle_address == @merkle, 13);
        assert!(price_oracle_config.is_spread_enabled == false, 14);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, allowed = @0xC0FFEE)]
    fun test_register_allowed_address(host: &signer, aptos_framework: &signer, allowed: &signer) acquires PriceOracleConfig, DataRecord, AptVault {
        call_test_setting(host, aptos_framework);
        register_allowed_update<TESTUSD>(host, signer::address_of(allowed));

        update<TESTUSD>(allowed, 22, vector::empty());
        let value = read<TESTUSD>(true);
        assert!(value == 22, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, allowed = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun test_remove_allowed_address(host: &signer, aptos_framework: &signer, allowed: &signer) acquires PriceOracleConfig, DataRecord, AptVault {
        call_test_setting(host, aptos_framework);
        register_allowed_update<TESTUSD>(host, signer::address_of(allowed));
        update<TESTUSD>(allowed, 22, vector::empty());
        let value = read<TESTUSD>(true);
        assert!(value == 22, 0);
        remove_allowed_update<TESTUSD>(host, signer::address_of(allowed));
        update<TESTUSD>(allowed, 22, vector::empty());
    }
}
