module merkle::profile {
    // <-- USE ----->
    use std::signer::address_of;
    use std::vector;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;
    use merkle::season;
    use merkle::gear;
    use merkle::safe_math::safe_mul_div;
    use merkle::lootbox_v2;

    // <-- FRIEND ----->
    friend merkle::trading;

    const BOOST_PRECISION: u64 = 1000000;
    const SOFT_RESET_PRECISION: u64 = 1000000;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    /// When invalid apply soft reset parameter
    const E_APPLY_SOFT_RESET_INVALID_PARAMETER: u64 = 2;

    struct ClassInfo has key {
        /// required xp to level up
        required_xp: vector<u64>,
        /// required level to class
        required_level: vector<u64>
    }

    struct LevelInfo has store {
        /// current level
        level: u64,
        /// current xp
        xp: u64,
    }

    struct UserInfo has key {
        /// key: user address, value: level info
        level_info: table::Table<address, LevelInfo>,
        /// key: user address, value: daily boost info
        daily_boost_info: table::Table<address, vector<u64>>
    }

    struct SoftResetConfig has key {
        /// soft reset rate 100% = 1000000
        soft_reset_rate: u64,
        /// key = user address, value = applied last soft reset season
        user_soft_reset: table::Table<address, u64>
    }

    // events
    struct ProfileEvent has key {
        increase_xp_events: EventHandle<IncreaseXPEvent>
    }

    struct BoostEvent has key {
        increase_boost_events: EventHandle<IncreaseBoostEvent>
    }

    struct SoftResetEvents has key {
        profile_soft_reset_events: EventHandle<SoftResetEvent>
    }

    struct IncreaseXPEvent has drop, store {
        /// user address
        user: address,
        /// boost percentage
        boosted: u64,
        /// xp user gained
        gained_xp: u64,
        /// before add xp info
        xp_from: u64,
        level_from: u64,
        class_from: u64,
        required_xp_from: u64,
        /// after add xp info
        xp_to: u64,
        level_to: u64,
        class_to: u64,
        required_xp_to: u64,
    }

    struct IncreaseBoostEvent has drop, store {
        /// user address
        user: address,
        /// boosted date
        boosted: vector<u64>
    }

    struct SoftResetEvent has drop, store {
        /// user address
        user: address,
        /// latest season number
        season_number: u64,
        /// previous tier
        previous_tier: u64,
        /// previous level
        previous_level: u64,
        /// soft reset tier
        soft_reset_tier: u64,
        /// soft reset level
        soft_reset_level: u64,
        /// reward loot boxes
        reward_lootboxes: vector<u64>
    }

    fun init_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        move_to(_admin, ClassInfo {
            required_xp: vector[300000000, 600000000, 1200000000, 2400000000, 4800000000],
            // xp decimal 6
            required_level: vector[1, 6, 16, 51, 81]
            // class 0 = rookie
            // class 1 = beginner
            // class 2 = competent
            // class 3 = proficient
            // class 4 = expert
        });

        move_to(_admin, UserInfo {
            level_info: table::new(),
            daily_boost_info: table::new()
        });

        move_to(_admin, ProfileEvent {
            increase_xp_events: new_event_handle<IncreaseXPEvent>(_admin)
        });

        move_to(_admin, BoostEvent {
            increase_boost_events: new_event_handle<IncreaseBoostEvent>(_admin)
        });
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if(!exists<SoftResetEvents>(address_of(_admin))) {
            move_to(_admin, SoftResetEvents {
                profile_soft_reset_events: new_event_handle<SoftResetEvent>(_admin)
            });
        };
        if(!exists<SoftResetConfig>(address_of(_admin))) {
            move_to(_admin, SoftResetConfig {
                soft_reset_rate: 800000,
                user_soft_reset: table::new()
            });
        };
    }

    public(friend) fun increase_xp<PairType>(_user_address: address, _xp: u64) acquires UserInfo, ClassInfo, ProfileEvent {
        // get_boost
        let gear_boost = gear::get_xp_boost_effect<PairType>(_user_address, true);
        let daily_boost: u64 = get_boost(_user_address);
        let boost = BOOST_PRECISION + (daily_boost * BOOST_PRECISION / 100 + gear_boost);
        _xp = safe_mul_div(_xp, boost, BOOST_PRECISION);

        let initial_lootbox = lootbox_v2::get_user_current_season_lootboxes(_user_address);
        let user_info = borrow_global_mut<UserInfo>(@merkle);
        if (!table::contains(&user_info.level_info, _user_address)) {
            table::add(&mut user_info.level_info, _user_address, LevelInfo {
                level: 1,
                xp: 0
            });
        };

        let level_info = table::borrow_mut(&mut user_info.level_info, _user_address);
        let xp_from = level_info.xp;
        let level_from = level_info.level;
        let (class_from, required_xp_from) = get_level_class(level_info.level);
        level_info.xp = level_info.xp + _xp;

        while(true) {
            let (class, required_xp) = get_level_class(level_info.level);
            if (required_xp <= level_info.xp) {
                // level up
                level_info.level = level_info.level + 1;
                level_info.xp = level_info.xp - required_xp;
                lootbox_v2::mint_lootbox(_user_address, class, 1)
            } else {
                break
            };
        };
        let latest_lootbox = lootbox_v2::get_user_current_season_lootboxes(_user_address);
        let (class_to, required_xp_to) = get_level_class(level_info.level);
        lootbox_v2::emit_lootbox_events(_user_address, initial_lootbox, latest_lootbox);
        event::emit_event(&mut borrow_global_mut<ProfileEvent>(@merkle).increase_xp_events, IncreaseXPEvent {
            user: _user_address,
            boosted: boost,
            gained_xp: _xp,
            xp_from,
            level_from,
            class_from,
            required_xp_from,
            xp_to: level_info.xp,
            level_to: level_info.level,
            class_to,
            required_xp_to,
        })
    }

    public fun apply_soft_reset_level(_admin: &signer, users: vector<address>, rewards: vector<vector<u64>>)
    acquires SoftResetConfig, UserInfo, SoftResetEvents, ClassInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        assert!(vector::length(&users) == vector::length(&rewards), E_APPLY_SOFT_RESET_INVALID_PARAMETER);

        let current_season_number = season::get_current_season_number() - 1;
        let soft_reset_config = borrow_global_mut<SoftResetConfig>(address_of(_admin));

        let idx = 0;
        while(idx < vector::length(&users)) {
            let can_reset = true;
            let user = *vector::borrow(&users, idx);
            // already reset check
            if (table::contains(&soft_reset_config.user_soft_reset, user)) {
                can_reset = *table::borrow(&soft_reset_config.user_soft_reset, user) < current_season_number;
            };
            let user_info = borrow_global_mut<UserInfo>(address_of(_admin));
            can_reset = can_reset && table::contains(&user_info.level_info, user);
            if(!can_reset) {
                idx = idx + 1;
                continue
            };

            let user_level_info = table::borrow_mut(&mut user_info.level_info, user);

            // calculate event
            let soft_reset_level = (
                user_level_info.level * soft_reset_config.soft_reset_rate + (SOFT_RESET_PRECISION - 1) // ceil
            ) / SOFT_RESET_PRECISION;
            if (soft_reset_level == 0) {
                soft_reset_level = 1;
            };

            let (previous_tier, _) = get_level_class(user_level_info.level);
            let (soft_reset_tier, _) = get_level_class(soft_reset_level);
            let reward = *vector::borrow(&rewards, idx);

            // emit event
            event::emit_event(
                &mut borrow_global_mut<SoftResetEvents>(@merkle).profile_soft_reset_events,
                SoftResetEvent {
                    user,
                    season_number: current_season_number,
                    previous_tier,
                    previous_level: user_level_info.level,
                    soft_reset_tier,
                    soft_reset_level,
                    reward_lootboxes: reward
                }
            );

            // mint lootboxes
            lootbox_v2::mint_soft_reset_lootboxes(_admin, user, reward);

            // set value
            table::upsert(&mut soft_reset_config.user_soft_reset, user, current_season_number);
            user_level_info.level = soft_reset_level;
            user_level_info.xp = 0;

            idx = idx + 1;
        };
    }

    public fun set_user_soft_reset_level(_admin: &signer, _user: address, _value: u64) acquires SoftResetConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let soft_reset_config = borrow_global_mut<SoftResetConfig>(address_of(_admin));
        table::upsert(&mut soft_reset_config.user_soft_reset, _user, _value);
    }

    fun get_level_class(_level: u64): (u64, u64) acquires ClassInfo {
        let class_info = borrow_global<ClassInfo>(@merkle);
        let class = 1;
        let required_xp = 0;
        while(true) {
            if (class == vector::length(&class_info.required_level)) {
                required_xp = *vector::borrow(&class_info.required_xp, class - 1);
                break
            };
            let required_level = *vector::borrow(&class_info.required_level, class);
            if (_level < required_level) {
                required_xp = *vector::borrow(&class_info.required_xp, class - 1);
                break
            };
            class = class + 1;
        };
        (class - 1, required_xp)
    }
    
    public(friend) fun add_daily_boost(_user_address: address) acquires UserInfo, BoostEvent {
        let user_info = borrow_global_mut<UserInfo>(@merkle);
        if (!table::contains(&user_info.daily_boost_info, _user_address)) {
            table::add(&mut user_info.daily_boost_info, _user_address, vector::empty<u64>());
        };
        let daily_boost_info = table::borrow_mut(&mut user_info.daily_boost_info, _user_address);
        let today = timestamp::now_seconds() / 86400;

        while(true) {
            if (vector::length(daily_boost_info) == 0) {
                break
            };
            let prev = *vector::borrow(daily_boost_info, 0);
            if (today - prev < 7) {
                break
            };
            vector::remove(daily_boost_info, 0);
        };
        if (!vector::contains(daily_boost_info, &today)) {
            vector::push_back(daily_boost_info, today);
            event::emit_event(&mut borrow_global_mut<BoostEvent>(@merkle).increase_boost_events, IncreaseBoostEvent {
                user: _user_address,
                boosted: *daily_boost_info,
            })
        };
    }

    public fun add_new_class(_admin: &signer, _required_level: u64, _required_xp: u64) acquires ClassInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        let class_info = borrow_global_mut<ClassInfo>(address_of(_admin));
        vector::push_back(&mut class_info.required_level, _required_level);
        vector::push_back(&mut class_info.required_xp, _required_xp);
    }

    public fun update_class(_admin: &signer, _class: u64, _required_level: u64, _required_xp: u64) acquires ClassInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        let class_info = borrow_global_mut<ClassInfo>(address_of(_admin));
        let required_level = vector::borrow_mut(&mut class_info.required_level, _class);
        *required_level = _required_level;
        let required_xp = vector::borrow_mut(&mut class_info.required_xp, _class);
        *required_xp = _required_xp;
    }

    public fun get_level_info(_user_address: address): (u64, u64, u64, u64) acquires UserInfo, ClassInfo {
        // (xp, level, class, required_xp)
        let user_info = borrow_global_mut<UserInfo>(@merkle);
        if (!table::contains(&user_info.daily_boost_info, _user_address)) {
            let (class, required_xp) = get_level_class(1);
            return (0, 1, class, required_xp)
        };
        let level_info = table::borrow_mut(&mut user_info.level_info, _user_address);
        let (class, required_xp) = get_level_class(level_info.level);
        (level_info.xp, level_info.level, class, required_xp)
    }

    public fun get_boost(_user_address: address): u64 acquires UserInfo {
        let user_info = borrow_global_mut<UserInfo>(@merkle);
        if (!table::contains(&user_info.daily_boost_info, _user_address)) {
            table::add(&mut user_info.daily_boost_info, _user_address, vector::empty<u64>());
        };
        let daily_boost_info = table::borrow_mut(&mut user_info.daily_boost_info, _user_address);

        let today = timestamp::now_seconds() / 86400;
        let boosted = 0;
        let idx = 0;
        while(true) {
            if (vector::length(daily_boost_info) == idx) {
                break
            };
            let prev = *vector::borrow(daily_boost_info, idx);
            if (today - prev < 7) {
                boosted = boosted + 1
            };
            idx = idx + 1;
        };
        boosted
    }

    public fun boost_event_initialized(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if (exists<BoostEvent>(address_of(_admin))) {
            return
        };
        move_to(_admin, BoostEvent {
            increase_boost_events: new_event_handle<IncreaseBoostEvent>(_admin)
        })
    }

    public fun set_soft_reset_rate(_admin: &signer, _soft_reset_rate: u64) acquires SoftResetConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        let soft_reset_config = borrow_global_mut<SoftResetConfig>(address_of(_admin));
        soft_reset_config.soft_reset_rate = _soft_reset_rate;
    }

    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    struct TEST_USDC {}

    #[test_only]
    public fun init_module_for_test(host: &signer) {
        init_module(host)
    }

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        init_module(host);
        initialize_module(host);
        lootbox_v2::init_module_for_test(host);
        season::initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_init_module(host: &signer, aptos_framework: &signer) acquires ClassInfo {
        call_test_setting(host, aptos_framework);

        let class_info = borrow_global_mut<ClassInfo>(address_of(host));
        assert!(vector::length(&class_info.required_xp) == vector::length(&class_info.required_level), 0);
    }

    #[test(host = @0xC0FFEE, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_init_module_not_authorized(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_increase_XP(host: &signer, aptos_framework: &signer) acquires ClassInfo, UserInfo, ProfileEvent {
        call_test_setting(host, aptos_framework);
        {
            let (xp, level, class, required_xp) = get_level_info(address_of(host));
            assert!(xp == 0, 0);
            assert!(level == 1, 0);
            assert!(class == 0, 0);
            assert!(required_xp == 300000000, 0);
        };
        increase_xp<TEST_USDC>(address_of(host), 900000000);
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let level_info = table::borrow(&user_info.level_info, address_of(host));
            assert!(level_info.level == 4, 0);
        };

        increase_xp<TEST_USDC>(address_of(host), 1300000000);
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let level_info = table::borrow(&user_info.level_info, address_of(host));
            assert!(level_info.level == 7, 0);
        };
        let (xp, level, class, required_xp) = get_level_info(address_of(host));
        assert!(xp == 100000000, 0);
        assert!(level == 7, 0);
        assert!(class == 1, 0);
        assert!(required_xp == 600000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_max_class_test(host: &signer, aptos_framework: &signer) acquires ClassInfo, UserInfo, ProfileEvent {
        call_test_setting(host, aptos_framework);
        increase_xp<TEST_USDC>(address_of(host), 121500000000); // level 81
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let level_info = table::borrow(&user_info.level_info, address_of(host));
            assert!(level_info.level == 81, 0);
            let (class, required_xp) = get_level_class(level_info.level);
            assert!(class == 4, 0);
            assert!(required_xp == 4800000000, 0);
        };
        increase_xp<TEST_USDC>(address_of(host), 4900000000); // level 82
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let level_info = table::borrow(&user_info.level_info, address_of(host));
            assert!(level_info.level == 82, 0);
            assert!(level_info.xp == 100000000, 0);
            let (class, required_xp) = get_level_class(level_info.level);
            assert!(class == 4, 0);
            assert!(required_xp == 4800000000, 0);
        };
        let lootboxes = lootbox_v2::get_user_current_season_lootboxes(address_of(host));
        assert!(*vector::borrow(&lootboxes, 0) == 5, 0);
        assert!(*vector::borrow(&lootboxes, 1) == 10, 0);
        assert!(*vector::borrow(&lootboxes, 2) == 35, 0);
        assert!(*vector::borrow(&lootboxes, 3) == 30, 0);
        assert!(*vector::borrow(&lootboxes, 4) == 1, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_add_new_class(host: &signer, aptos_framework: &signer) acquires ClassInfo {
        call_test_setting(host, aptos_framework);

        add_new_class(host, 91, 6400000000);

        let class_info = borrow_global_mut<ClassInfo>(address_of(host));
        assert!(vector::length(&class_info.required_xp) == 6, 0);
        assert!(vector::length(&class_info.required_level) == 6, 1);
        assert!(*vector::borrow(&class_info.required_xp, 5) == 6400000000, 2);
        assert!(*vector::borrow(&class_info.required_level, 5) == 91, 3);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_add_new_class_not_authorized(host: &signer, aptos_framework: &signer, coffee: &signer) acquires ClassInfo {
        call_test_setting(host, aptos_framework);
        add_new_class(coffee, 91, 6400000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_update_class(host: &signer, aptos_framework: &signer) acquires ClassInfo {
        call_test_setting(host, aptos_framework);

        update_class(host, 1, 5, 700000000);

        let class_info = borrow_global_mut<ClassInfo>(address_of(host));
        assert!(vector::length(&class_info.required_xp) == 5, 0);
        assert!(vector::length(&class_info.required_level) == 5, 1);
        assert!(*vector::borrow(&class_info.required_xp, 1) == 700000000, 2);
        assert!(*vector::borrow(&class_info.required_level, 1) == 5, 3);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_update_class_not_authorized(host: &signer, aptos_framework: &signer, coffee: &signer) acquires ClassInfo {
        call_test_setting(host, aptos_framework);
        update_class(coffee, 1, 5, 700000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_daily_boost(host: &signer, aptos_framework: &signer) acquires UserInfo, BoostEvent {
        call_test_setting(host, aptos_framework);

        add_daily_boost(address_of(host));
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let daily_boost_info = table::borrow(&user_info.daily_boost_info, address_of(host));
            assert!(vector::length(daily_boost_info) == 1, 0);
        };
        timestamp::fast_forward_seconds(10000);
        add_daily_boost(address_of(host));
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let daily_boost_info = table::borrow(&user_info.daily_boost_info, address_of(host));
            assert!(vector::length(daily_boost_info) == 1, 0);
        };
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let daily_boost_info = table::borrow(&user_info.daily_boost_info, address_of(host));
            assert!(vector::length(daily_boost_info) == 2, 0);
        };
        let boost = get_boost(address_of(host));
        assert!(boost == 2, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_maximum_daily_boost(host: &signer, aptos_framework: &signer) acquires UserInfo, BoostEvent {
        call_test_setting(host, aptos_framework);

        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let daily_boost_info = table::borrow(&user_info.daily_boost_info, address_of(host));
            assert!(vector::length(daily_boost_info) == 7, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_daily_boost_passed_too_much(host: &signer, aptos_framework: &signer) acquires UserInfo, BoostEvent {
        call_test_setting(host, aptos_framework);

        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400);
        add_daily_boost(address_of(host));
        timestamp::fast_forward_seconds(86400*5);
        assert!(get_boost(address_of(host)) == 2, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_boost_event_initialized(host: &signer, aptos_framework: &signer){
        call_test_setting(host, aptos_framework);
        boost_event_initialized(host);
        boost_event_initialized(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_boost_event_initialized_not_authorized(host: &signer, aptos_framework: &signer){
        call_test_setting(host, aptos_framework);
        boost_event_initialized(aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_apply_soft_reset_level(host: &signer, aptos_framework: &signer)
    acquires ClassInfo, UserInfo, ProfileEvent, SoftResetEvents, SoftResetConfig {
        call_test_setting(host, aptos_framework);
        increase_xp<TEST_USDC>(address_of(host), 70000000000); // 59 level, 1300 xp
        let reward: vector<u64> = vector[0, 0, 0, 0, 0];

        apply_soft_reset_level(host, vector[address_of(host)], vector[reward]);
        let (xp, level, class, _) = get_level_info(address_of(host));
        assert!(level == 48, 0);
        assert!(xp == 0, 0);
        assert!(class == 2, 0);

        // will not be applied more than once.
        apply_soft_reset_level(host, vector[address_of(host)], vector[reward]);
        let (xp, level, class, _) = get_level_info(address_of(host));
        assert!(level == 48, 0);
        assert!(xp == 0, 0);
        assert!(class == 2, 0);

        increase_xp<TEST_USDC>(address_of(host), 20000000000); // 57 level, 800 xp
        let (xp, level, class, _) = get_level_info(address_of(host));
        assert!(level == 57, 0);
        assert!(xp == 2000000000, 0);
        assert!(class == 3, 0);

        // season 2
        season::add_new_season(host, 24 * 60 * 60 * 28 * 2);
        timestamp::update_global_time_for_test((24 * 60 * 60 * 28 + 100) * 1000000);
        let current_season_number = season::get_current_season_number();
        // mint lootbox
        reward = vector[1, 2, 3, 4, 5];
        apply_soft_reset_level(host, vector[address_of(host)], vector[reward]);
        let (xp, level, class, _) = get_level_info(address_of(host));
        assert!(level == 46, 0);
        assert!(xp == 0, 0);
        assert!(class == 2, 0);
        let lootboxes = lootbox_v2::get_user_lootboxes(address_of(host), current_season_number);
        assert!(*vector::borrow(&lootboxes, 0) == 1, 0);
        assert!(*vector::borrow(&lootboxes, 1) == 2, 0);
        assert!(*vector::borrow(&lootboxes, 2) == 3, 0);
        assert!(*vector::borrow(&lootboxes, 3) == 4, 0);
        assert!(*vector::borrow(&lootboxes, 4) == 5, 0);

        // still same
        apply_soft_reset_level(host, vector[address_of(host)], vector[reward]);
        let (xp, level, class, _) = get_level_info(address_of(host));
        assert!(level == 46, 0);
        assert!(xp == 0, 0);
        assert!(class == 2, 0);
        let lootboxes = lootbox_v2::get_user_lootboxes(address_of(host), current_season_number);
        assert!(*vector::borrow(&lootboxes, 0) == 1, 0);
        assert!(*vector::borrow(&lootboxes, 1) == 2, 0);
        assert!(*vector::borrow(&lootboxes, 2) == 3, 0);
        assert!(*vector::borrow(&lootboxes, 3) == 4, 0);
        assert!(*vector::borrow(&lootboxes, 4) == 5, 0);
    }
}