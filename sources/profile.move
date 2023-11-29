module merkle::profile {
    // <-- USE ----->
    use std::signer::address_of;
    use std::vector;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;
    use merkle::safe_math_u64::safe_mul_div;
    use merkle::lootbox;

    // <-- FRIEND ----->
    friend merkle::trading;

    const BOOST_PRECISION: u64 = 1000000;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

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

    struct ProfileEvent has key {
        increase_xp_events: EventHandle<IncreaseXPEvent>
    }

    struct BoostEvent has key {
        increase_boost_events: EventHandle<IncreaseBoostEvent>
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
        })
    }

    public(friend) fun increase_xp(_user_address: address, _xp: u64) acquires UserInfo, ClassInfo, ProfileEvent {
        let initial_loot_box = lootbox::get_user_loot_boxes(_user_address);
        let boost_num: u64;
        {
            boost_num = get_boost(_user_address);
            let boost = BOOST_PRECISION + boost_num * BOOST_PRECISION / 100;
            _xp = safe_mul_div(_xp, boost, BOOST_PRECISION);
        };
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
                lootbox::mint_lootbox(_user_address, class, 1)
            } else {
                break
            };
        };
        let latest_loot_box = lootbox::get_user_loot_boxes(_user_address);
        let (class_to, required_xp_to) = get_level_class(level_info.level);
        lootbox::emit_loot_box_events(_user_address, initial_loot_box, latest_loot_box);
        event::emit_event(&mut borrow_global_mut<ProfileEvent>(@merkle).increase_xp_events, IncreaseXPEvent {
            user: _user_address,
            boosted: boost_num,
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

    #[test_only]
    use aptos_framework::aptos_account;

    #[test_only]
    public fun init_module_for_test(host: &signer) {
        init_module(host)
    }

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_account::create_account(address_of(host));
        init_module(host);
        lootbox::init_module_for_test(host);
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
        increase_xp(address_of(host), 900000000);
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let level_info = table::borrow(&user_info.level_info, address_of(host));
            assert!(level_info.level == 4, 0);
        };

        increase_xp(address_of(host), 1300000000);
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
        increase_xp(address_of(host), 121500000000); // level 81
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let level_info = table::borrow(&user_info.level_info, address_of(host));
            assert!(level_info.level == 81, 0);
            let (class, required_xp) = get_level_class(level_info.level);
            assert!(class == 4, 0);
            assert!(required_xp == 4800000000, 0);
        };
        increase_xp(address_of(host), 4900000000); // level 82
        {
            let user_info = borrow_global<UserInfo>(address_of(host));
            let level_info = table::borrow(&user_info.level_info, address_of(host));
            assert!(level_info.level == 82, 0);
            assert!(level_info.xp == 100000000, 0);
            let (class, required_xp) = get_level_class(level_info.level);
            assert!(class == 4, 0);
            assert!(required_xp == 4800000000, 0);
        };
        let lootboxes = lootbox::get_user_loot_boxes(address_of(host));
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
}