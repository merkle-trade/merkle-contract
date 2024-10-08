module merkle::shard_token {
    use std::signer::address_of;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event::{Self, EventHandle};

    friend merkle::gear;
    friend merkle::lootbox;
    friend merkle::lootbox_v2;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// shard amount is not enough
    const E_NOT_ENOUGH_SHARD_AMOUNT: u64 = 2;

    // SHRD
    // decimals: 6

    struct ShardInfo has key {
        supply: u64,
        user_balance: table::Table<address, u64>
    }

    // events
    struct ShardEvents has key {
        mint_events: EventHandle<MintEvent>,
        burn_event: EventHandle<BurnEvent>
    }

    struct MintEvent has drop, store {
        /// user address
        user: address,
        /// minted shard
        amount: u64
    }

    struct BurnEvent has drop, store {
        /// user address
        user: address,
        /// burned shard
        amount: u64
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (exists<ShardInfo>(address_of(_admin))) {
            return
        };

        move_to(_admin, ShardInfo {
            supply: 0,
            user_balance: table::new()
        });

        move_to(_admin, ShardEvents {
            mint_events: new_event_handle<MintEvent>(_admin),
            burn_event: new_event_handle<BurnEvent>(_admin),
        })
    }

    public(friend) fun mint(_user: address, _amount: u64) acquires ShardInfo, ShardEvents {
        let shard_info = borrow_global_mut<ShardInfo>(@merkle);
        if (!table::contains(&shard_info.user_balance, _user)) {
            table::upsert(&mut shard_info.user_balance, _user, 0);
        };
        let user_balance = table::borrow_mut(&mut shard_info.user_balance, _user);
        *user_balance = *user_balance + _amount;
        shard_info.supply = shard_info.supply + _amount;

        event::emit_event(&mut borrow_global_mut<ShardEvents>(@merkle).mint_events, MintEvent {
            user: _user,
            amount: _amount
        });
    }

    public fun get_shard_balance(_user: address): u64 acquires ShardInfo {
        let shard_info = borrow_global_mut<ShardInfo>(@merkle);
        *table::borrow_with_default(&shard_info.user_balance, _user, &0)
    }

    public(friend) fun burn(_user: address, _amount: u64) acquires ShardInfo, ShardEvents {
        let shard_info = borrow_global_mut<ShardInfo>(@merkle);
        if (!table::contains(&shard_info.user_balance, _user)) {
            table::upsert(&mut shard_info.user_balance, _user, 0);
        };
        let user_balance = table::borrow_mut(&mut shard_info.user_balance, _user);
        assert!(_amount <= *user_balance, E_NOT_ENOUGH_SHARD_AMOUNT);
        *user_balance = *user_balance - _amount;
        shard_info.supply = shard_info.supply - _amount;

        event::emit_event(&mut borrow_global_mut<ShardEvents>(@merkle).burn_event, BurnEvent {
            user: _user,
            amount: _amount
        });
    }

    // <--- test --->
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::timestamp;

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
    public fun T_initialize_module(host: &signer, aptos_framework: &signer) acquires ShardInfo {
        call_test_setting(host, aptos_framework);
        let shard_info = borrow_global<ShardInfo>(address_of(host));
        assert!(0 == shard_info.supply, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_mint(host: &signer, aptos_framework: &signer) acquires ShardInfo, ShardEvents {
        call_test_setting(host, aptos_framework);

        mint(address_of(host), 1000);
        let shard_info = borrow_global<ShardInfo>(address_of(host));
        assert!(1000 == shard_info.supply, 0);
        assert!(1000 == *table::borrow(&shard_info.user_balance, address_of(host)), 0);
        assert!(1000 == get_shard_balance(address_of(host)), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_burn(host: &signer, aptos_framework: &signer) acquires ShardInfo, ShardEvents {
        call_test_setting(host, aptos_framework);

        mint(address_of(host), 1000);
        burn(address_of(host), 500);

        let shard_info = borrow_global<ShardInfo>(address_of(host));
        assert!(500 == shard_info.supply, 0);
        assert!(500 == *table::borrow(&shard_info.user_balance, address_of(host)), 0);
        assert!(500 == get_shard_balance(address_of(host)), 0);
    }
}