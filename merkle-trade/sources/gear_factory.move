module merkle::gear_factory {
    use std::signer::address_of;
    use std::string;
    use std::vector;
    use aptos_std::simple_map;
    use merkle::random;
    use merkle::pair_types;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When gear does not exist
    const E_GEAR_DOES_NOT_EXIST: u64 = 2;
    /// When gear does not exist
    const E_GENERATE_FAILED: u64 = 3;
    /// When gear already exist
    const E_GEAR_ALREADY_EXIST: u64 = 4;
    /// When affix already exist
    const E_AFFIX_ALREADY_EXIST: u64 = 5;

    struct GearInfo has key {
        gear_datas: simple_map::SimpleMap<u64, vector<GearSpec>>, // key: tier
    }

    struct GearSpec has store {
        tier: u64, // 0 ~ 4
        name: string::String,
        uri: string::String,
        gear_type: u64, // A = 0, B = 1 ...
        gear_code: u64, // 100, 200 ...
        min_primary_effect: u64, // 10000 = 1%
        max_primary_effect: u64, // 1000000 = 100%
        gear_affixes: vector<GearAffixSpec>,
    }

    struct GearAffixSpec has store {
        gear_affix_type: u64, // MA = 0, MB = 1 ..
        gear_affix_code: u64, // 1, 2 ..
        min_affix_effect: u64, // 10000 = 1%
        max_affix_effect: u64, // 1000000 = 100%
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if(exists<GearInfo>(address_of(_admin))) {
            return
        };

        move_to(_admin, GearInfo {
            gear_datas: simple_map::create<u64, vector<GearSpec>>()
        })
    }

    public fun register_gear(
        _admin: &signer,
        _tier: u64,
        _name: vector<u8>,
        _uri: vector<u8>,
        _gear_type: u64,
        _gear_code: u64,
        _min_primary_effect: u64,
        _max_primary_effect: u64,
    ) acquires GearInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        let gear_info = borrow_global_mut<GearInfo>(@merkle);
        if (!simple_map::contains_key(&gear_info.gear_datas, &_tier)) {
            simple_map::add(&mut gear_info.gear_datas, _tier, vector::empty<GearSpec>());
        };
        let gear_data_map = simple_map::borrow_mut(&mut gear_info.gear_datas, &_tier);
        let exist = false;
        let i = 0;
        while(i < vector::length(gear_data_map)) {
            let gear_data = vector::borrow(gear_data_map, i);
            if (gear_data.gear_type == _gear_type && gear_data.gear_code == _gear_code) {
                exist = true;
                break
            };
            i = i + 1;
        };
        assert!(!exist, E_GEAR_ALREADY_EXIST);
        vector::push_back(gear_data_map, GearSpec {
            name: string::utf8(_name),
            tier: _tier,
            uri: string::utf8(_uri),
            gear_type: _gear_type,
            gear_code: _gear_code,
            min_primary_effect: _min_primary_effect,
            max_primary_effect: _max_primary_effect,
            gear_affixes: vector::empty()
        });
    }

    public fun register_affix(
        _admin: &signer,
        _tier: u64,
        _gear_type: u64,
        _gear_code: u64,
        _affix_type: u64,
        _affix_code: u64,
        _min_affix_effect: u64,
        _max_affix_effect: u64,
    ) acquires GearInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        let gear_info = borrow_global_mut<GearInfo>(@merkle);
        let gear_datas = simple_map::borrow_mut(&mut gear_info.gear_datas, &_tier);
        let idx = 0;
        while(idx < vector::length(gear_datas)) {
            let gear = vector::borrow_mut(gear_datas, idx);
            if (gear.gear_type == _gear_type && gear.gear_code == _gear_code) {
                break
            };
            idx = idx + 1;
        };
        assert!(idx < vector::length(gear_datas), E_GEAR_DOES_NOT_EXIST);
        let gear = vector::borrow_mut(gear_datas, idx);
        vector::push_back(&mut gear.gear_affixes, GearAffixSpec {
            gear_affix_type: _affix_type,
            gear_affix_code: _affix_code,
            min_affix_effect: _min_affix_effect,
            max_affix_effect: _max_affix_effect,
        });
    }

    public fun generate_specific_gear_property_without_affixes_rand(_tier: u64, _gear_type: u64, _gear_code: u64): (
        string::String, // name
        string::String, // uri
        u64, // gear_type
        u64, // gear_code
        u64, // primary_effect
        vector<u64>, // gear affixes types
        vector<u64>, // gear affixes codes
        vector<string::String>, // gear affixes targets
        vector<u64>, // gear affixes effects
    ) acquires GearInfo {
        let gear_info = borrow_global_mut<GearInfo>(@merkle);
        let gear_datas = simple_map::borrow(&mut gear_info.gear_datas, &_tier);
        let idx = 0;
        while (idx < vector::length(gear_datas)) {
            let gear = vector::borrow(gear_datas, idx);
            if (gear.gear_type == _gear_type && gear.gear_code == _gear_code) {
                break
            };
            idx = idx + 1;
        };
        assert!(idx < vector::length(gear_datas), E_GENERATE_FAILED);
        let gear = vector::borrow(gear_datas, idx);
        let primary_effect = random::get_random_between(gear.min_primary_effect, gear.max_primary_effect);
        (
            gear.name,
            gear.uri,
            gear.gear_type,
            gear.gear_code,
            primary_effect,
            vector[],
            vector[],
            vector[],
            vector[]
        )
    }

    public fun generate_gear_property_rand(_tier: u64): (
        string::String, // name
        string::String, // uri
        u64, // gear_type
        u64, // gear_code
        u64, // primary_effect
        vector<u64>, // gear affixes types
        vector<u64>, // gear affixes codes
        vector<string::String>, // gear affixes targets
        vector<u64>, // gear affixes effects
    ) acquires GearInfo {
        let gear_info = borrow_global_mut<GearInfo>(@merkle);
        let gear_datas = simple_map::borrow(&mut gear_info.gear_datas, &_tier);
        let gear_idx = random::get_random_between(0, vector::length(gear_datas) - 1);
        let gear = vector::borrow(gear_datas, gear_idx);
        let primary_effect = random::get_random_between(gear.min_primary_effect, gear.max_primary_effect);
        let (gear_affixes_types,
            gear_affixes_codes,
            gear_affixes_targets,
            gear_affixes_effects
        ) = generate_gear_affixes_internal_rand(gear, vector[]);

        (
            gear.name,
            gear.uri,
            gear.gear_type,
            gear.gear_code,
            primary_effect,
            gear_affixes_types,
            gear_affixes_codes,
            gear_affixes_targets,
            gear_affixes_effects
        )
    }

    public fun get_basic_gear_property(_tier: u64, _gear_type: u64): (
        string::String, // name
        string::String, // uri
        u64, // gear_type
        u64, // gear_code
        u64, // primary_effect
        vector<u64>, // gear affixes types
        vector<u64>, // gear affixes codes
        vector<string::String>, // gear affixes targets
        vector<u64>, // gear affixes effects
    ) acquires GearInfo {
        let gear_info = borrow_global_mut<GearInfo>(@merkle);
        let gear_datas = simple_map::borrow(&mut gear_info.gear_datas, &_tier);
        let gear = vector::borrow(gear_datas, _gear_type);
        let basic_gear_effect = gear.min_primary_effect; // default min effect
        // custom effect
        if (gear.tier == 0 && _gear_type == 2) {
            // gives max effect when miner cap gear (2%)
            basic_gear_effect = gear.max_primary_effect;
        };

        (
            gear.name,
            gear.uri,
            gear.gear_type,
            gear.gear_code,
            basic_gear_effect,
            vector[],
            vector[],
            vector[],
            vector[]
        )
    }

    public fun generate_gear_affix_rand(_tier: u64, _gear_type: u64, _gear_code: u64, _exclude: vector<string::String>): (
        vector<u64>, // gear affixes types
        vector<u64>, // gear affixes codes
        vector<string::String>, // gear affixes targets
        vector<u64>, // gear affixes effects
    ) acquires GearInfo {
        let gear_info = borrow_global_mut<GearInfo>(@merkle);
        let gear_datas = simple_map::borrow(&mut gear_info.gear_datas, &_tier);
        let idx = 0;
        while (idx < vector::length(gear_datas)) {
            let gear = vector::borrow(gear_datas, idx);
            if (gear.gear_type == _gear_type && gear.gear_code == _gear_code) {
                return generate_gear_affixes_internal_rand(gear, _exclude)
            };
            idx = idx + 1;
        };
        abort E_GENERATE_FAILED
    }

    fun generate_gear_affixes_internal_rand(_gear: &GearSpec, _exclude: vector<string::String>): (
        vector<u64>, // gear affixes types
        vector<u64>, // gear affixes codes
        vector<string::String>, // gear affixes targets
        vector<u64>, // gear affixes effects
    ) {
        let gear_affix_length = vector::length(&_gear.gear_affixes);
        let gear_affix_idx = 0;
        let gear_affixes_types: vector<u64> = vector[];
        let gear_affixes_codes: vector<u64> = vector[];
        let gear_affixes_targets: vector<string::String> = vector[];
        let gear_affixes_effects: vector<u64> = vector[];
        let random_retry = 0;
        while(gear_affix_idx < gear_affix_length) {
            let gear_affix = vector::borrow(&_gear.gear_affixes, gear_affix_idx);
            let target: vector<u8> = b"";
            if (gear_affix.gear_affix_code == 1) {
                // one pair
                let target_pair = random::get_random_between(0, pair_types::len_pair() - 1);
                target = pair_types::get_pair_name(target_pair);
            } else if (gear_affix.gear_affix_code == 2) {
                // one class
                let target_class = random::get_random_between(0, pair_types::len_pair_class() - 1);
                target = pair_types::get_class_name(target_class);
            };
            let gear_affix_effect = random::get_random_between(gear_affix.min_affix_effect, gear_affix.max_affix_effect);
            random_retry = random_retry + 1;
            if (vector::contains(&gear_affixes_targets, &string::utf8(target)) || vector::contains(&_exclude, &string::utf8(target))) {
                assert!(random_retry < 10, E_GENERATE_FAILED);
                continue
            };
            vector::push_back(&mut gear_affixes_types, gear_affix.gear_affix_type);
            vector::push_back(&mut gear_affixes_codes, gear_affix.gear_affix_code);
            vector::push_back(&mut gear_affixes_targets, string::utf8(target));
            vector::push_back(&mut gear_affixes_effects, gear_affix_effect);
            gear_affix_idx = gear_affix_idx + 1;
        };

        (
            gear_affixes_types,
            gear_affixes_codes,
            gear_affixes_targets,
            gear_affixes_effects
        )
    }

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_GEAR_ALREADY_EXIST, location = Self)]
    public fun T_check_gear_already_exists(host: &signer, aptos_framework: &signer) acquires GearInfo {
        call_test_setting(host, aptos_framework);
        register_gear(
            host,
            0,
            b"g11",
            b"",
            0,
            0,
            100000,
            200000,
        );
        register_gear(
            host,
            0,
            b"g11",
            b"",
            0,
            0,
            100000,
            200000,
        );
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_GEAR_DOES_NOT_EXIST, location = Self)]
    public fun T_check_gear_not_exist(host: &signer, aptos_framework: &signer) acquires GearInfo {
        call_test_setting(host, aptos_framework);
        register_gear(
            host,
            0,
            b"g11",
            b"",
            0,
            0,
            100000,
            200000,
        );
        register_affix(
            host,
            0,
            0,
            1,
            0,
            0,
            1000000,
            2000000,
        );
    }
}