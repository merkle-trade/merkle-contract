module merkle::lootbox_v2 {
    // <-- USE ----->
    use std::signer::address_of;
    use std::vector;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event;
    use aptos_framework::event::EventHandle;
    use merkle::referral;
    use merkle::season;
    use merkle::gear;
    use merkle::random;
    use merkle::gear_calc;
    use merkle::shard_token;

    // <-- FRIEND ----->
    friend merkle::profile;
    friend merkle::managed_lootbox_v2;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When call function with invalid tier
    const E_INVALID_TIER: u64 = 2;
    /// When open a lootbox with 0 amount
    const E_NO_LOOTBOX: u64 = 3;
    /// When call function with invalid season
    const E_INVALID_SEASON: u64 = 4;
    /// When user already claimed ftu lootbox
    const E_FTU_LOOTBOX_ALREADY_CLAIMED: u64 = 5;

    const MAX_TIER: u64 = 4;

    const T_FTU_REWARD_TIER_NO_REFERRER: u64 = 0;
    const T_FTU_REWARD_TIER_STANDARD_REFERRER: u64 = 1;
    const T_FTU_REWARD_TIER_AFFILIATES_REFERRER: u64 = 2;
    const T_FTU_REWARD_TIER_SPECIAL_AFFILIATES_REFERRER: u64 = 3;

    struct LootBoxInfo has key {
        season_lootbox: table::Table<u64, UsersLootBox> // key = season
    }

    struct UsersLootBox has store {
        users: table::Table<address, vector<u64>>
    }

    struct FtuLootBoxInfo has key {
        user_ftu_lootbox: table::Table<address, u64> // key: user, value: reward tier
    }

    struct UserLootBoxEvent has key {
        lootbox_events: EventHandle<LootBoxEvent>,
        lootbox_open_events: EventHandle<LootBoxOpenEvent>
    }

    struct LootBoxEvent has drop, store {
        /// season number
        season: u64,
        /// user address
        user: address,
        /// gained loot box
        lootbox: vector<u64>
    }

    struct LootBoxOpenEvent has drop, store {
        season: u64,
        user: address,
        tier: u64,
    }

    struct UserFtuLootBoxEvents has key {
        ftu_lootbox_events: EventHandle<FtuLootBoxEvent>,
    }

    struct FtuLootBoxEvent has drop, store {
        user: address,
        reward_tier: u64,
        referrer: address
    }

    struct AdminCapability has copy, store, drop {}

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<LootBoxInfo>(address_of(_admin))) {
            move_to(_admin, LootBoxInfo {
                season_lootbox: table::new()
            });
        };

        if (!exists<UserLootBoxEvent>(address_of(_admin))) {
            move_to(_admin, UserLootBoxEvent {
                lootbox_events: new_event_handle<LootBoxEvent>(_admin),
                lootbox_open_events: new_event_handle<LootBoxOpenEvent>(_admin)
            })
        };

        if (!exists<FtuLootBoxInfo>(address_of(_admin))) {
            move_to(_admin, FtuLootBoxInfo {
                user_ftu_lootbox: table::new<address, u64>()
            })
        };

        if (!exists<UserFtuLootBoxEvents>(address_of(_admin))) {
            move_to(_admin, UserFtuLootBoxEvents {
               ftu_lootbox_events: new_event_handle<FtuLootBoxEvent>(_admin)
            });
        }
    }

    fun mint_gear_rand(_user: &signer, _tier: u64, _season: u64) {
        let is_appear = random::get_random_between(1, 100) <= 40; // 40%
        if (!is_appear) {
            // no gear
            random::add_random_padding();
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
        gear::mint_v2_rand(_user, gear_tier,_season);
    }

    fun mint_shard_rand(_user_addr: address, _tier: u64) {
        let (min_shard, max_shard) = gear_calc::calc_lootbox_shard_range(_tier);
        let shard_amount = random::get_random_between(min_shard, max_shard);
        shard_token::mint(_user_addr, shard_amount);
    }

    /// called by entry function
    public(friend) fun open_lootbox_rand(_user: &signer, _tier: u64, _season: u64) acquires LootBoxInfo, UserLootBoxEvent {
        assert!(_tier <= MAX_TIER, E_INVALID_TIER);

        let user_addr = address_of(_user);
        let lootbox_info = borrow_global_mut<LootBoxInfo>(@merkle);
        assert!(table::contains(&lootbox_info.season_lootbox, _season), E_INVALID_SEASON);

        let season_lootbox = table::borrow_mut(&mut lootbox_info.season_lootbox, _season);
        assert!(table::contains(&season_lootbox.users, user_addr), E_NO_LOOTBOX);
        let lootbox = table::borrow_mut(&mut season_lootbox.users, user_addr);
        let box = vector::borrow_mut(lootbox, _tier);
        assert!(*box > 0, E_NO_LOOTBOX);
        *box = *box - 1;

        mint_shard_rand(user_addr, _tier);
        mint_gear_rand(_user, _tier, _season);

        event::emit_event(&mut borrow_global_mut<UserLootBoxEvent>(@merkle).lootbox_open_events, LootBoxOpenEvent {
            season: _season,
            user: address_of(_user),
            tier: _tier,
        })
    }

    public fun open_ftu_lootbox(_user: &signer, _referrer: address) acquires FtuLootBoxInfo, UserFtuLootBoxEvents {
        let ftu_lootbox_info = borrow_global_mut<FtuLootBoxInfo>(@merkle);
        // check already claim
        assert!(!table::contains(&ftu_lootbox_info.user_ftu_lootbox, address_of(_user)), E_FTU_LOOTBOX_ALREADY_CLAIMED);
        // reward tier
        let reward_tier = T_FTU_REWARD_TIER_NO_REFERRER;
        if (_referrer != @0x0) {
            reward_tier = T_FTU_REWARD_TIER_STANDARD_REFERRER;
            if (referral::check_affiliates_address(_referrer)) {
                reward_tier = T_FTU_REWARD_TIER_AFFILIATES_REFERRER
            };
        };
        // mint gear
        if (reward_tier == T_FTU_REWARD_TIER_NO_REFERRER) {
            gear::mint_basic(address_of(_user), 0, 0);
            gear::mint_basic(address_of(_user), 0, 2);
        } else if (reward_tier == T_FTU_REWARD_TIER_STANDARD_REFERRER) {
            gear::mint_basic(address_of(_user), 0, 0);
            gear::mint_basic(address_of(_user), 0, 1);
            gear::mint_basic(address_of(_user), 0, 2);
        } else if (reward_tier == T_FTU_REWARD_TIER_AFFILIATES_REFERRER) {
            gear::mint_basic(address_of(_user), 1, 0);
            gear::mint_basic(address_of(_user), 1, 1);
            gear::mint_basic(address_of(_user), 2, 2);
        };
        // add here for special term
        // set claimed
        table::upsert(&mut ftu_lootbox_info.user_ftu_lootbox, address_of(_user), reward_tier);
        // emit event
        event::emit_event(&mut borrow_global_mut<UserFtuLootBoxEvents>(@merkle).ftu_lootbox_events, FtuLootBoxEvent {
            user: address_of(_user),
            reward_tier,
            referrer: _referrer
        });
    }

    public(friend) fun mint_lootbox(_user_addr: address, _tier: u64, _amount: u64) acquires LootBoxInfo {
        assert!(_tier <= MAX_TIER, E_INVALID_TIER);
        let season = season::get_current_season_number();
        let lootbox_info = borrow_global_mut<LootBoxInfo>(@merkle);
        if (!table::contains(&lootbox_info.season_lootbox, season)) {
            table::add(&mut lootbox_info.season_lootbox, season, UsersLootBox {
                users: table::new<address, vector<u64>>()
            });
        };
        let season_lootbox = table::borrow_mut(&mut lootbox_info.season_lootbox, season);
        if (!table::contains(&season_lootbox.users, _user_addr)) {
            table::add(&mut season_lootbox.users, _user_addr, vector::empty());
        };
        let lootbox = table::borrow_mut(&mut season_lootbox.users, _user_addr);

        while(_tier >= vector::length(lootbox)) {
            vector::push_back(lootbox, 0);
        };
        let box = vector::borrow_mut(lootbox, _tier);
        *box = *box + _amount;
    }

    public(friend) fun emit_lootbox_events(_user_address: address, initial_lootbox: vector<u64>, latest_lootbox: vector<u64>)
    acquires UserLootBoxEvent {
        let lootbox_gained: vector<u64> = vector[];
        let season = season::get_current_season_number();
        let total_gained = 0;
        let i = 0;
        while(i <= MAX_TIER) {
            let gained = 0;
            if (i < vector::length(&latest_lootbox)) {
                let initial = 0;
                if (i < vector::length(&initial_lootbox)) {
                    initial = *vector::borrow(&initial_lootbox, i);
                };
                gained = *vector::borrow(&latest_lootbox, i) - initial;
            };
            vector::push_back(&mut lootbox_gained, gained);
            i = i + 1;
            total_gained = total_gained + gained;
        };
        if (total_gained > 0) {
            event::emit_event(&mut borrow_global_mut<UserLootBoxEvent>(@merkle).lootbox_events, LootBoxEvent {
                season,
                user: _user_address,
                lootbox: lootbox_gained
            })
        };
    }

    public(friend) fun mint_soft_reset_lootboxes(_admin: &signer, _user_addr: address, lootboxes: vector<u64>)
    acquires UserLootBoxEvent, LootBoxInfo {
        let season = season::get_current_season_number();
        let tier = 0;
        while(tier < 5) {
            let amount = vector::borrow(&lootboxes, tier);
            if (*amount > 0) {
                mint_lootbox(_user_addr, tier, *amount);
            };
            tier = tier + 1;
        };
        event::emit_event(&mut borrow_global_mut<UserLootBoxEvent>(@merkle).lootbox_events, LootBoxEvent {
            season,
            user: _user_addr,
            lootbox: lootboxes
        })
    }

    public fun mint_mission_lootboxes_admin(_admin_cap: &AdminCapability, _user_addr: address, _tier: u64, _amount: u64)
    acquires UserLootBoxEvent, LootBoxInfo {
        let season = season::get_current_season_number();
        let initial_lootbox = get_user_lootboxes(_user_addr, season);
        mint_lootbox(_user_addr, _tier, _amount);
        let latest_lootbox = get_user_lootboxes(_user_addr, season);
        emit_lootbox_events(_user_addr, initial_lootbox, latest_lootbox);
    }

    public fun get_user_current_season_lootboxes(_user_addr: address): vector<u64> acquires LootBoxInfo {
        let season = season::get_current_season_number();
        get_user_lootboxes(_user_addr, season)
    }

    public fun get_user_all_lootboxes(_user_addr: address): vector<LootBoxEvent> acquires LootBoxInfo {
        let lootbox_info = borrow_global_mut<LootBoxInfo>(@merkle);
        let current_season = season::get_current_season_number();
        let lootboxes: vector<LootBoxEvent> = vector[];
        let i = 0;
        while (i <= current_season) {
            if (!table::contains(&lootbox_info.season_lootbox, i)) {
                i = i + 1;
                continue
            };
            let season_lootbox = table::borrow(&lootbox_info.season_lootbox, i);
            if (!table::contains(&season_lootbox.users, _user_addr)) {
                i = i + 1;
                continue
            };
            let lootbox = *table::borrow(&season_lootbox.users, _user_addr);
            let j = vector::length(&lootbox);
            while(j <= MAX_TIER) {
                vector::push_back(&mut lootbox, 0);
                j = j + 1;
            };
            vector::push_back(&mut lootboxes, LootBoxEvent {
                season: i,
                user: _user_addr,
                lootbox
            });
            i = i + 1;
        };
        lootboxes
    }

    public fun get_user_lootboxes(_user_addr: address, _season: u64): vector<u64> acquires LootBoxInfo {
        let lootbox_info = borrow_global_mut<LootBoxInfo>(@merkle);
        if (!table::contains(&lootbox_info.season_lootbox, _season)) {
            let lootboxes: vector<u64> = vector[];
            let i = 0;
            while(i <= MAX_TIER) {
                vector::push_back(&mut lootboxes, 0);
                i = i + 1;
            };
            return lootboxes
        };
        let season_lootbox = table::borrow(&lootbox_info.season_lootbox, _season);
        let lootboxes: vector<u64> = vector[];
        if (table::contains(&season_lootbox.users, _user_addr)) {
            lootboxes = *table::borrow(&season_lootbox.users, _user_addr);
        };
        let i = vector::length(&lootboxes);
        while(i <= MAX_TIER) {
            vector::push_back(&mut lootboxes, 0);
            i = i + 1;
        };
        lootboxes
    }

    public fun generate_admin_cap(
        _admin: &signer
    ): AdminCapability {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        (AdminCapability {})
    }

    #[test_only]
    use aptos_framework::aptos_account;

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    public fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };

        initialize_module(host);
    }

    #[test_only]
    public fun init_module_for_test(host: &signer) {
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_init_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }
}