module merkle::lootbox {
    // <-- USE ----->
    use std::signer::address_of;
    use std::vector;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event;
    use aptos_framework::event::EventHandle;
    use aptos_framework::timestamp;
    use merkle::gear;
    use merkle::pMKL;
    use merkle::random;
    use merkle::gear_calc;
    use merkle::shard_token;

    // <-- FRIEND ----->
    friend merkle::profile;
    friend merkle::managed_lootbox;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When call function with invalid tier
    const E_INVALID_TIER: u64 = 2;
    /// When open a lootbox with 0 amount
    const E_NO_LOOTBOX: u64 = 3;
    /// When lootbox expired
    const E_LOOTBOX_EXPIRED: u64 = 4;

    struct LootBoxConfig has key {
        // start from 0
        max_tier: u64
    }

    struct UsersLootBox has key { // pre season lootbox
        users: table::Table<address, vector<u64>>
    }

    struct UserLootBoxEvent has key {
        loot_box_events: EventHandle<LootBoxEvent>
    }

    struct UserLootBoxOpenEvent has key {
        loot_box_open_events: EventHandle<LootBoxOpenEvent>
    }

    struct LootBoxEvent has drop, store {
        /// user address
        user: address,
        /// gained loot box
        lootbox: vector<u64>
    }

    struct LootBoxOpenEvent has drop, store {
        user: address,
        tier: u64,
    }

    struct AdminCapability has copy, store, drop {}

    public fun dummy() {

    }

    fun init_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        move_to(_admin, LootBoxConfig {
            max_tier: 4
        });

        move_to(_admin, UsersLootBox {
            users: table::new()
        });

        move_to(_admin, UserLootBoxEvent {
            loot_box_events: new_event_handle<LootBoxEvent>(_admin)
        })
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        move_to(_admin, UserLootBoxOpenEvent {
            loot_box_open_events: new_event_handle<LootBoxOpenEvent>(_admin)
        })
    }

    fun mint_pMKL_rand(_user_addr: address, _tier: u64) {
        let min_amount: vector<u64> = vector[10000000, 21000000, 48000000, 122000000, 320000000];
        let max_amount: vector<u64> = vector[20000000, 43000000, 100000000, 242000000, 640000000];
        let amount = random::get_random_between(
          *vector::borrow(&min_amount, _tier),
            *vector::borrow(&max_amount, _tier)
        );
        pMKL::mint_pmkl(_user_addr, amount);
    }

    fun mint_gear_rand(_user: &signer, _tier: u64) {
        let is_appear = random::get_random_between(1, 100) <= 40; // 40%
        if (!is_appear) {
            return
        };
        let gear_tier = 0;
        let num = random::get_random_between(1, 100);
        if (_tier == 0) {
            gear_tier = if (num <= 90) 0 else 1;
        } else if (_tier == 1) {
            gear_tier = if (num <= 30) 0 else 1;
        } else if (_tier == 2) {
            gear_tier = if (num <= 10) 0 else if (num <= 70) 1 else 2;
        } else if (_tier == 3) {
            gear_tier = if (num <= 40) 1 else if (num <= 86) 2 else 3;
        } else if (_tier == 4) {
            gear_tier = if (num <= 65) 2 else if (num <= 95) 3 else 4;
        };
        gear::mint_rand(_user, gear_tier);
    }

    fun mint_shard_rand(_user_addr: address, _tier: u64) {
        let (min_shard, max_shard) = gear_calc::calc_lootbox_shard_range(_tier);
        let shard_amount = random::get_random_between(min_shard, max_shard);
        shard_token::mint(_user_addr, shard_amount);
    }

    public fun open_lootbox_admin_cap_rand(_admin_cap: &AdminCapability, _user_addr: address, _tier: u64)
    acquires UsersLootBox, UserLootBoxOpenEvent {
        let loot_box_info = borrow_global_mut<UsersLootBox>(@merkle);
        assert!(table::contains(&loot_box_info.users, _user_addr), E_NO_LOOTBOX);
        let lootbox = table::borrow_mut(&mut loot_box_info.users, _user_addr);
        let box = vector::borrow_mut(lootbox, _tier);
        assert!(*box > 0, E_NO_LOOTBOX);
        *box = *box - 1;

        // no signer, cannot mint gears
        // TODO: create signer from resource account, mint gear, transfer to user
        mint_pMKL_rand(_user_addr, _tier);
        mint_shard_rand(_user_addr, _tier);

        event::emit_event(&mut borrow_global_mut<UserLootBoxOpenEvent>(@merkle).loot_box_open_events, LootBoxOpenEvent {
            user: _user_addr,
            tier: _tier,
        })
    }

    /// called by entry function
    public(friend) fun open_lootbox_rand(_user: &signer, _tier: u64) acquires LootBoxConfig, UsersLootBox, UserLootBoxOpenEvent {
        assert!(timestamp::now_seconds() <= 1706184000, E_LOOTBOX_EXPIRED); // 2024/01/25 12:00 UTC

        let loot_box_config = borrow_global<LootBoxConfig>(@merkle);
        assert!(_tier <= loot_box_config.max_tier, E_INVALID_TIER);

        let user_addr = address_of(_user);
        let loot_box_info = borrow_global_mut<UsersLootBox>(@merkle);
        assert!(table::contains(&loot_box_info.users, user_addr), E_NO_LOOTBOX);
        let lootbox = table::borrow_mut(&mut loot_box_info.users, user_addr);
        let box = vector::borrow_mut(lootbox, _tier);
        assert!(*box > 0, E_NO_LOOTBOX);
        *box = *box - 1;

        mint_pMKL_rand(user_addr, _tier);
        mint_shard_rand(user_addr, _tier);
        mint_gear_rand(_user, _tier);

        event::emit_event(&mut borrow_global_mut<UserLootBoxOpenEvent>(@merkle).loot_box_open_events, LootBoxOpenEvent {
            user: address_of(_user),
            tier: _tier,
        })
    }

    public(friend) fun mint_lootbox(_user_addr: address, _tier: u64, _amount: u64) acquires UsersLootBox, LootBoxConfig {
        let loot_box_config = borrow_global<LootBoxConfig>(@merkle);
        assert!(_tier <= loot_box_config.max_tier, E_INVALID_TIER);

        let loot_box_info = borrow_global_mut<UsersLootBox>(@merkle);
        if (!table::contains(&loot_box_info.users, _user_addr)) {
            table::add(&mut loot_box_info.users, _user_addr, vector::empty());
        };
        let lootbox = table::borrow_mut(&mut loot_box_info.users, _user_addr);

        while(true) {
            if (_tier < vector::length(lootbox)) {
                break
            };
            vector::push_back(lootbox, 0);
        };
        let box = vector::borrow_mut(lootbox, _tier);
        *box = *box + _amount;
    }

    public(friend) fun emit_loot_box_events(_user_address: address, initial_loot_box: vector<u64>, latest_loot_box: vector<u64>)
    acquires UserLootBoxEvent, LootBoxConfig {
        let loot_box_gained: vector<u64> = vector[];
        let loot_box_config = borrow_global<LootBoxConfig>(@merkle);
        let total_gained = 0;
        let i = 0;
        while(true) {
            if (i > loot_box_config.max_tier) {
                break
            };
            let gained = 0;
            if (i < vector::length(&latest_loot_box)) {
                let initial = 0;
                if (i < vector::length(&initial_loot_box)) {
                    initial = *vector::borrow(&initial_loot_box, i);
                };
                gained = *vector::borrow(&latest_loot_box, i) - initial;
                total_gained = total_gained + gained;
            };
            vector::push_back(&mut loot_box_gained, gained);
            i = i + 1;
        };
        if (total_gained > 0) {
            event::emit_event(&mut borrow_global_mut<UserLootBoxEvent>(@merkle).loot_box_events, LootBoxEvent {
                user: _user_address,
                lootbox: loot_box_gained
            })
        };
    }

    public fun mint_mission_lootboxes(_admin: &signer, _user_addr: address, _tier: u64, _amount: u64)
    acquires UsersLootBox, UserLootBoxEvent, LootBoxConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let initial_loot_box = get_user_loot_boxes(_user_addr);
        mint_lootbox(_user_addr, _tier, _amount);
        let latest_loot_box = get_user_loot_boxes(_user_addr);
        emit_loot_box_events(_user_addr, initial_loot_box, latest_loot_box);
    }

    public fun mint_mission_lootboxes_admin_cap(_admin_cap: &AdminCapability, _user_addr: address, _tier: u64, _amount: u64)
    acquires UsersLootBox, UserLootBoxEvent, LootBoxConfig {
        let initial_loot_box = get_user_loot_boxes(_user_addr);
        mint_lootbox(_user_addr, _tier, _amount);
        let latest_loot_box = get_user_loot_boxes(_user_addr);
        emit_loot_box_events(_user_addr, initial_loot_box, latest_loot_box);
    }

    public fun increase_max_tier(_admin: &signer, _amount: u64) acquires LootBoxConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let loot_box_config = borrow_global_mut<LootBoxConfig>(@merkle);
        loot_box_config.max_tier = loot_box_config.max_tier + _amount;
    }

    public fun get_user_loot_boxes(_user_addr: address): vector<u64> acquires UsersLootBox, LootBoxConfig {
        let loot_box_config = borrow_global<LootBoxConfig>(@merkle);
        let loot_box_info = borrow_global_mut<UsersLootBox>(@merkle);
        let loot_boxes: vector<u64> = vector [];
        if (table::contains(&loot_box_info.users, _user_addr)) {
            loot_boxes = *table::borrow(&mut loot_box_info.users, _user_addr);
        };

        let i = vector::length(&loot_boxes);
        while(true) {
            if (i > loot_box_config.max_tier) {
                break
            };
            vector::push_back(&mut loot_boxes, 0);
            i = i + 1;
        };
        loot_boxes
    }

    public fun get_max_tier(): u64 acquires LootBoxConfig {
        let loot_box_config = borrow_global_mut<LootBoxConfig>(@merkle);
        loot_box_config.max_tier
    }

    public fun generate_admin_cap(
        _admin: &signer
    ): AdminCapability {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        (AdminCapability {})
    }

    // <--- test --->
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;

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
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_init_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
        assert!(exists<UsersLootBox>(address_of(host)), 0);
    }

    #[test(host = @0xC0FFEE, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_init_module_not_authorized(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_mint_loot_box(host: &signer, aptos_framework: &signer) acquires UsersLootBox, LootBoxConfig {
        call_test_setting(host, aptos_framework);

        mint_lootbox(address_of(host), 0, 3);
        {
            let users_loot_box = borrow_global<UsersLootBox>(address_of(host));
            let loot_box = table::borrow(&users_loot_box.users, address_of(host));
            assert!(*vector::borrow(loot_box, 0) == 3, 0);
        };
        mint_lootbox(address_of(host), 1, 4);
        mint_lootbox(address_of(host), 2, 5);
        mint_lootbox(address_of(host), 3, 6);
        mint_lootbox(address_of(host), 4, 7);
        {
            let users_loot_box = borrow_global<UsersLootBox>(address_of(host));
            let loot_box = table::borrow(&users_loot_box.users, address_of(host));
            assert!(*vector::borrow(loot_box, 0) == 3, 0);
            assert!(*vector::borrow(loot_box, 1) == 4, 0);
            assert!(*vector::borrow(loot_box, 2) == 5, 0);
            assert!(*vector::borrow(loot_box, 3) == 6, 0);
            assert!(*vector::borrow(loot_box, 4) == 7, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_INVALID_TIER, location = Self)]
    fun T_mint_loot_box_invalid_tier(host: &signer, aptos_framework: &signer) acquires UsersLootBox, LootBoxConfig {
        call_test_setting(host, aptos_framework);
        mint_lootbox(address_of(host), 5, 3);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_mint_mission_lootboxes(host: &signer, aptos_framework: &signer) acquires UsersLootBox, UserLootBoxEvent, LootBoxConfig {
        call_test_setting(host, aptos_framework);

        mint_mission_lootboxes(host, address_of(host), 0, 3);
        {
            let users_loot_box = borrow_global<UsersLootBox>(address_of(host));
            let loot_box = table::borrow(&users_loot_box.users, address_of(host));
            assert!(*vector::borrow(loot_box, 0) == 3, 0);
        };

        mint_mission_lootboxes(host, address_of(host), 3, 5);
        {
            let users_loot_box = borrow_global<UsersLootBox>(address_of(host));
            let loot_box = table::borrow(&users_loot_box.users, address_of(host));
            assert!(*vector::borrow(loot_box, 3) == 5, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_mint_mission_lootboxes_admin_cap(host: &signer, aptos_framework: &signer) acquires UsersLootBox, UserLootBoxEvent, LootBoxConfig {
        call_test_setting(host, aptos_framework);
        let admin_cap = AdminCapability {};

        mint_mission_lootboxes_admin_cap(&admin_cap, address_of(host), 0, 3);
        {
            let users_loot_box = borrow_global<UsersLootBox>(address_of(host));
            let loot_box = table::borrow(&users_loot_box.users, address_of(host));
            assert!(*vector::borrow(loot_box, 0) == 3, 0);
        };

        mint_mission_lootboxes_admin_cap(&admin_cap, address_of(host), 3, 5);
        {
            let users_loot_box = borrow_global<UsersLootBox>(address_of(host));
            let loot_box = table::borrow(&users_loot_box.users, address_of(host));
            assert!(*vector::borrow(loot_box, 3) == 5, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_mint_mission_lootboxes_not_authorized(host: &signer, aptos_framework: &signer, coffee: &signer) acquires UsersLootBox, UserLootBoxEvent, LootBoxConfig {
        call_test_setting(host, aptos_framework);
        mint_mission_lootboxes(coffee, address_of(host), 0, 3);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_get_user_loot_boxes_empty(host: &signer, aptos_framework: &signer) acquires UsersLootBox, LootBoxConfig {
        call_test_setting(host, aptos_framework);
        let loot_boxes = get_user_loot_boxes(address_of(host));
        let loot_box_config = borrow_global<LootBoxConfig>(address_of(host));
        assert!(vector::length(&loot_boxes) == loot_box_config.max_tier + 1, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_increease_max_tier(host: &signer, aptos_framework: &signer) acquires UsersLootBox, LootBoxConfig {
        call_test_setting(host, aptos_framework);
        increase_max_tier(host, 5);

        let loot_boxes = get_user_loot_boxes(address_of(host));
        assert!(vector::length(&loot_boxes) == 10, 0); // 4 + 5 -> 9 (0 ~ 9)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_increease_max_tier_not_authorized(host: &signer, aptos_framework: &signer, coffee: &signer) acquires LootBoxConfig {
        call_test_setting(host, aptos_framework);
        increase_max_tier(coffee, 5);
    }
}