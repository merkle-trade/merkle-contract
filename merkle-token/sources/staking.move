module merkle::staking {
    use std::option;
    use std::string;
    use std::vector;
    use std::signer::address_of;
    use aptos_std::simple_map;
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_framework::timestamp;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account::{Self, SignerCapability, new_event_handle};
    use aptos_framework::object::{Self, TransferRef, Object};
    use aptos_framework::fungible_asset::{Self, FungibleStore, FungibleAsset};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp::now_seconds;
    use aptos_token_objects::collection;
    use aptos_token_objects::royalty;
    use aptos_token_objects::token;
    use merkle::pre_mkl_token;

    use merkle::safe_math::{safe_mul_div, min};
    use merkle::esmkl_token;
    use merkle::mkl_token;

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When invalid lock duration
    const E_INVALID_LOCK_DURATION: u64 = 1;
    /// When invalid lock Asset type
    const E_INVALID_LOCK_ASSET_TYPE: u64 = 2;
    /// When unable unlock vemkl
    const E_UNABLE_UNLOCK: u64 = 3;
    /// When maximum number of vemkl exceeded
    const E_MAX_NUM_VEMKL_EXCEEDED: u64 = 4;
    /// When invalid epoch start at
    const E_INVALID_EPOCH_START_AT: u64 = 5;
    /// When lock amount too small
    const E_TOO_SMALL_LOCK_AMOUNT: u64 = 6;
    /// staking does not start yet
    const E_STAKING_NOT_STARTED: u64 = 7;

    const VEMKL_COLLECTION_NAME: vector<u8> = b"veMKL";
    const DAY_SECONDS: u64 = 60 * 60 * 24; // 1 day
    const STAKING_START_AT: u64 = 1721908800; // 2024-07-25T12:00:00.000Z

    struct VoteEscrowedMKLConfig has key {
        signer_cap: SignerCapability,
        collection_mutator_ref: collection::MutatorRef,
        royalty_mutator_ref: royalty::MutatorRef,
        max_lock_duration: u64,
        min_lock_duration: u64,
        epoch_duration: u64,
        mkl_multiplier: u64,
        esmkl_multiplier: u64,
        max_num_vemkl: u64
    }

    struct VoteEscrowedPowers has key {
        total_mkl_power: simple_map::SimpleMap<u64, u64>, // key = epoch started at, value = total mkl amount
        total_esmkl_power: simple_map::SimpleMap<u64, u64>, // key = epoch started at, value = total esmkl amount
    }

    struct VoteEscrowedMKL has key {
        lock_time: u64,
        unlock_time: u64,
        mutator_ref: token::MutatorRef,
        burn_ref: token::BurnRef,
        transfer_ref: TransferRef,
        mkl_token: Object<FungibleStore>,
        mkl_delete_ref: object::DeleteRef,
        esmkl_token: Object<FungibleStore>,
        esmkl_delete_ref: object::DeleteRef,
        mkl_multiplier: u64,
        esmkl_multiplier: u64,
    }

    struct UserVoteEscrowedMKL has key {
        vemkl_tokens: vector<address>,
        mkl_power: simple_map::SimpleMap<u64, u64>, // key = epoch started at, value = total mkl amount
        esmkl_power: simple_map::SimpleMap<u64, u64>, // key = epoch started at, value = total esmkl amount
    }

    struct StakingEvents has key {
        staking_lock_events: EventHandle<LockEvent>,
        staking_unlock_events: EventHandle<UnlockEvent>,
    }

    struct LockEvent has drop, store {
        user: address,
        asset_type: TypeInfo,
        amount: u64,
        lock_time: u64,
        unlock_time: u64
    }

    struct UnlockEvent has drop, store {
        user: address,
        mkl_amount: u64,
        esmkl_amount: u64,
        lock_time: u64,
        unlock_time: u64
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if (!exists<VoteEscrowedMKLConfig>(address_of(_admin))) {
            let (resource_signer, resource_signer_cap) = account::create_resource_account(_admin, vector[1]);
            let collection_constructor_ref = collection::create_unlimited_collection(
                &resource_signer, // creator
                string::utf8(VEMKL_COLLECTION_NAME), // description
                string::utf8(VEMKL_COLLECTION_NAME), // name
                option::none(), // royalty
                string::utf8(b""), // uri
            );
            let collection_mutator_ref = collection::generate_mutator_ref(&collection_constructor_ref);
            let extend_ref = object::generate_extend_ref(&collection_constructor_ref);
            let royalty_mutator_ref = royalty::generate_mutator_ref(extend_ref);
            move_to(_admin, VoteEscrowedMKLConfig {
                signer_cap: resource_signer_cap,
                collection_mutator_ref,
                royalty_mutator_ref,
                max_lock_duration: DAY_SECONDS * 364, // 1 years
                min_lock_duration: DAY_SECONDS * 14, // 2 weeks
                epoch_duration: DAY_SECONDS * 7, // week
                mkl_multiplier: 1,
                esmkl_multiplier: 1,
                max_num_vemkl: 1
            });
        };
        if (!exists<VoteEscrowedPowers>(address_of(_admin))) {
            move_to(_admin, VoteEscrowedPowers {
                total_mkl_power: simple_map::new<u64, u64>(),
                total_esmkl_power: simple_map::new<u64, u64>(),
            });
        };
        if (!exists<StakingEvents>(address_of(_admin))) {
            move_to(_admin, StakingEvents {
                staking_lock_events: new_event_handle<LockEvent>(_admin),
                staking_unlock_events: new_event_handle<UnlockEvent>(_admin)
            });
        };
    }

    public fun get_epoch_duration(): u64 acquires VoteEscrowedMKLConfig {
        let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
        config.epoch_duration
    }

    public fun get_current_epoch_start_time(): u64 acquires VoteEscrowedMKLConfig {
        let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
        get_current_epoch_start_time_internal(config)
    }

    fun get_current_epoch_start_time_internal(_config: &VoteEscrowedMKLConfig): u64 {
        let now = timestamp::now_seconds();
        now - (now % _config.epoch_duration)
    }

    fun mint_vemkl(_user_address: address, _unlock_time: u64): (VoteEscrowedMKL, signer) acquires VoteEscrowedMKLConfig {
        let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);

        let now = timestamp::now_seconds();
        let lock_time = get_current_epoch_start_time_internal(config) + config.epoch_duration;
        let lock_duration = _unlock_time - lock_time;

        assert!(config.min_lock_duration <= lock_duration && lock_duration <= config.max_lock_duration, E_INVALID_LOCK_DURATION);
        assert!(_unlock_time >= mkl_token::mkl_tge_at() + DAY_SECONDS * 14, E_INVALID_LOCK_DURATION);
        assert!(lock_duration % DAY_SECONDS == 0, E_INVALID_LOCK_DURATION);

        let creator = account::create_signer_with_capability(&config.signer_cap);
        let constructor_ref = token::create(
            &creator, // creator
            string::utf8(VEMKL_COLLECTION_NAME), // collection_name
            string::utf8(b""), // description
            string::utf8(VEMKL_COLLECTION_NAME), // name
            option::none(), // royalty
            string::utf8(b""), // uri
        );
        let object_signer = object::generate_signer(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let mutator_ref = token::generate_mutator_ref(&constructor_ref);
        let burn_ref = token::generate_burn_ref(&constructor_ref);
        // transfer to user
        object::transfer_raw(&creator, address_of(&object_signer), _user_address);
        object::disable_ungated_transfer(&transfer_ref); // soul bound

        // create mkl(pre-mkl) store
        let mkl_constructor_ref = object::create_object(address_of(&creator));
        let mkl_delete_ref = object::generate_delete_ref(&mkl_constructor_ref);
        let mkl_store: Object<FungibleStore>;
        if (now >= mkl_token::mkl_tge_at()) {
            mkl_store = fungible_asset::create_store(&mkl_constructor_ref, mkl_token::get_metadata());
            mkl_token::freeze_mkl_store(&mkl_store, true);
        } else {
            mkl_store = fungible_asset::create_store(&mkl_constructor_ref, pre_mkl_token::get_metadata());
            pre_mkl_token::freeze_pre_mkl_store(&mkl_store, true);
        };
        // create esmkl store
        let esmkl_constructor_ref = object::create_object(address_of(&creator));
        let esmkl_delete_ref = object::generate_delete_ref(&esmkl_constructor_ref);
        let esmkl_store = fungible_asset::create_store(&esmkl_constructor_ref, esmkl_token::get_metadata());
        esmkl_token::freeze_esmkl_store(&esmkl_store, true);

        let vemkl = VoteEscrowedMKL {
            lock_time,
            unlock_time: _unlock_time,
            mutator_ref,
            burn_ref,
            transfer_ref,
            mkl_token: mkl_store, // object address (FungibleStore)
            mkl_delete_ref,
            esmkl_token: esmkl_store, // object address (FungibleStore)
            esmkl_delete_ref,
            mkl_multiplier: config.mkl_multiplier,
            esmkl_multiplier: config.esmkl_multiplier
        };
        (vemkl, object_signer)
    }

    public fun lock(_user: &signer, _fa: FungibleAsset, _unlock_time: u64)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents {
        assert!(now_seconds() >= STAKING_START_AT, E_STAKING_NOT_STARTED);
        assert!(fungible_asset::amount(&_fa) > 100000, E_TOO_SMALL_LOCK_AMOUNT);
        if (!exists<UserVoteEscrowedMKL>(address_of(_user))) {
            move_to(_user, UserVoteEscrowedMKL {
                vemkl_tokens: vector::empty<address>(),
                mkl_power: simple_map::new<u64, u64>(),
                esmkl_power: simple_map::new<u64, u64>(),
            })
        };
        let user_vemkl = borrow_global_mut<UserVoteEscrowedMKL>(address_of(_user));
        {
            clean_up_ve_powers(user_vemkl); // clean up old powers
            let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
            assert!(vector::length(&user_vemkl.vemkl_tokens) < config.max_num_vemkl, E_MAX_NUM_VEMKL_EXCEEDED);
        };

        // mint vemkl
        let (vemkl, vemkl_object_signer) = mint_vemkl(address_of(_user), _unlock_time);
        // deposit asset
        let asset_type: TypeInfo;
        let amount = fungible_asset::amount(&_fa);
        if (fungible_asset::metadata_from_asset(&_fa) == mkl_token::get_metadata()) {
            // mkl
            mkl_token::deposit_to_freezed_mkl_store(&vemkl.mkl_token, _fa);
            asset_type = type_info::type_of<mkl_token::MKL>();
        } else if (fungible_asset::metadata_from_asset(&_fa) == esmkl_token::get_metadata()) {
            // esmkl
            esmkl_token::deposit_to_freezed_esmkl_store(&vemkl.esmkl_token, _fa);
            asset_type = type_info::type_of<esmkl_token::ESMKL>();
        } else if (fungible_asset::metadata_from_asset(&_fa) == pre_mkl_token::get_metadata()) {
            // premkl
            pre_mkl_token::deposit_to_freezed_pre_mkl_store(&vemkl.mkl_token, _fa);
            asset_type = type_info::type_of<pre_mkl_token::PreMKL>();
        } else {
            abort E_INVALID_LOCK_ASSET_TYPE
        };
        // update vote power
        update_vote_power(address_of(_user), user_vemkl, &vemkl, true);

        // event emit
        event::emit_event(&mut borrow_global_mut<StakingEvents>(@merkle).staking_lock_events, LockEvent {
            user: address_of(_user),
            asset_type,
            amount,
            lock_time: vemkl.lock_time,
            unlock_time: vemkl.unlock_time
        });
        move_to(&vemkl_object_signer, vemkl);
        // push back to vector
        vector::push_back(&mut user_vemkl.vemkl_tokens, address_of(&vemkl_object_signer));
    }

    public fun unlock(_user: &signer, _vemkl_address: address)
    acquires VoteEscrowedMKL, UserVoteEscrowedMKL, StakingEvents {
        let vemkl_object = object::address_to_object<VoteEscrowedMKL>(_vemkl_address);
        assert!(address_of(_user) == object::owner(vemkl_object), E_NOT_AUTHORIZED);
        let vemkl = move_from<VoteEscrowedMKL>(_vemkl_address);
        assert!(timestamp::now_seconds() >= vemkl.unlock_time, E_UNABLE_UNLOCK);

        let mkl_amount = fungible_asset::balance(vemkl.mkl_token);
        if (mkl_amount > 0) {
            if (fungible_asset::store_metadata(vemkl.mkl_token) == mkl_token::get_metadata()) {
                let mkl = mkl_token::withdraw_from_freezed_mkl_store(&vemkl.mkl_token, mkl_amount);
                primary_fungible_store::deposit(address_of(_user), mkl);
            } else {
                let pre_mkl = pre_mkl_token::withdraw_from_freezed_pre_mkl_store(&vemkl.mkl_token, mkl_amount);
                if (timestamp::now_seconds() >= mkl_token::mkl_tge_at()) {
                    // pre mkl to mkl
                    let mkl = pre_mkl_token::swap_pre_mkl_to_mkl_with_fa(_user, pre_mkl);
                    primary_fungible_store::deposit(address_of(_user), mkl);
                } else {
                    pre_mkl_token::deposit_user_pre_mkl(_user, pre_mkl);
                };
            };
        };
        let esmkl_amount = fungible_asset::balance(vemkl.esmkl_token);
        if (esmkl_amount > 0) {
            let esmkl = esmkl_token::withdraw_from_freezed_esmkl_store(&vemkl.esmkl_token, esmkl_amount);
            esmkl_token::deposit_user_esmkl(_user, esmkl);
        };

        let user_vemkl = borrow_global_mut<UserVoteEscrowedMKL>(address_of(_user));
        vector::remove_value(&mut user_vemkl.vemkl_tokens, &_vemkl_address);

        // emit event
        event::emit_event(&mut borrow_global_mut<StakingEvents>(@merkle).staking_unlock_events, UnlockEvent {
            user: address_of(_user),
            mkl_amount,
            esmkl_amount,
            lock_time: vemkl.lock_time,
            unlock_time: vemkl.unlock_time
        });
        drop_vemkl(vemkl);
    }

    fun drop_vemkl(_vemkl: VoteEscrowedMKL) {
        let VoteEscrowedMKL {
            lock_time: _,
            unlock_time: _,
            mutator_ref: _,
            burn_ref,
            transfer_ref: _,
            mkl_token: _,
            mkl_delete_ref,
            esmkl_token: _,
            esmkl_delete_ref,
            mkl_multiplier: _,
            esmkl_multiplier: _,
        } = _vemkl;
        fungible_asset::remove_store(&mkl_delete_ref);
        fungible_asset::remove_store(&esmkl_delete_ref);
        token::burn(burn_ref);
    }

    public fun increase_lock(_user: &signer, _vemkl_address: address, _fa: FungibleAsset, _unlock_at: u64)
    acquires VoteEscrowedMKLConfig, VoteEscrowedMKL, VoteEscrowedPowers, StakingEvents, UserVoteEscrowedMKL {
        let vemkl = borrow_global_mut<VoteEscrowedMKL>(_vemkl_address);
        let vemkl_object = object::address_to_object<VoteEscrowedMKL>(_vemkl_address);
        assert!(address_of(_user) == object::owner(vemkl_object), E_NOT_AUTHORIZED);

        let user_vemkl = borrow_global_mut<UserVoteEscrowedMKL>(address_of(_user));
        clean_up_ve_powers(user_vemkl); // clean up old powers

        if (timestamp::now_seconds() <= vemkl.unlock_time) {
            update_vote_power(address_of(_user), user_vemkl, vemkl, false);
        };

        let asset_type: TypeInfo;
        let amount = fungible_asset::amount(&_fa);
        if (timestamp::now_seconds() >= mkl_token::mkl_tge_at() && fungible_asset::metadata_from_asset(&_fa) == mkl_token::get_metadata()) {
            // mkl
            if (fungible_asset::store_metadata(vemkl.mkl_token) == pre_mkl_token::get_metadata()) {
                // swap preMKL to MKL
                let pre_mkl = pre_mkl_token::withdraw_from_freezed_pre_mkl_store(&vemkl.mkl_token, fungible_asset::balance(vemkl.mkl_token));
                let mkl = pre_mkl_token::swap_pre_mkl_to_mkl_with_fa(_user, pre_mkl);

                let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
                let creator = account::create_signer_with_capability(&config.signer_cap);
                let mkl_constructor_ref = object::create_object(address_of(&creator));
                let mkl_delete_ref = object::generate_delete_ref(&mkl_constructor_ref);
                let mkl_store = fungible_asset::create_store(&mkl_constructor_ref, mkl_token::get_metadata());
                mkl_token::freeze_mkl_store(&mkl_store, true);

                // remove pre mkl store
                fungible_asset::remove_store(&vemkl.mkl_delete_ref);

                // assign mkl store
                vemkl.mkl_token = mkl_store;
                vemkl.mkl_delete_ref = mkl_delete_ref;
                mkl_token::deposit_to_freezed_mkl_store(&vemkl.mkl_token, mkl);
            };
            mkl_token::deposit_to_freezed_mkl_store(&vemkl.mkl_token, _fa);
            asset_type = type_info::type_of<mkl_token::MKL>();
        } else if (fungible_asset::metadata_from_asset(&_fa) == esmkl_token::get_metadata()) {
            // esmkl
            esmkl_token::deposit_to_freezed_esmkl_store(&vemkl.esmkl_token, _fa);
            asset_type = type_info::type_of<esmkl_token::ESMKL>();
        } else if (fungible_asset::metadata_from_asset(&_fa) == pre_mkl_token::get_metadata()) {
            // premkl
            pre_mkl_token::deposit_to_freezed_pre_mkl_store(&vemkl.mkl_token, _fa);
            asset_type = type_info::type_of<pre_mkl_token::PreMKL>();
        } else {
            abort E_INVALID_LOCK_ASSET_TYPE
        };

        {
            let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
            let new_lock_time = get_current_epoch_start_time_internal(config) + config.epoch_duration;
            let lock_duration = _unlock_at - new_lock_time;
            assert!(config.min_lock_duration <= lock_duration && lock_duration <= config.max_lock_duration, E_INVALID_LOCK_DURATION);
            assert!(vemkl.unlock_time <= _unlock_at, E_INVALID_LOCK_DURATION);
            assert!(lock_duration % DAY_SECONDS == 0, E_INVALID_LOCK_DURATION);

            vemkl.lock_time = new_lock_time;
            vemkl.unlock_time = _unlock_at;
            vemkl.mkl_multiplier = config.mkl_multiplier;
            vemkl.esmkl_multiplier = config.esmkl_multiplier;
        };
        update_vote_power(address_of(_user), user_vemkl, vemkl, true);

        event::emit_event(&mut borrow_global_mut<StakingEvents>(@merkle).staking_lock_events, LockEvent {
            user: address_of(_user),
            asset_type,
            amount,
            lock_time: vemkl.lock_time,
            unlock_time: vemkl.unlock_time
        });
    }

    fun clean_up_ve_powers(_user_vemkl: &mut UserVoteEscrowedMKL)
    acquires VoteEscrowedPowers, VoteEscrowedMKLConfig {
        let ve_powers = borrow_global_mut<VoteEscrowedPowers>(@merkle);
        let total_mkl_power_keys = simple_map::keys(&ve_powers.total_mkl_power);
        let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
        let current_epoch_start_time = get_current_epoch_start_time_internal(config);

        vector::for_each(total_mkl_power_keys, |key| {
            if (current_epoch_start_time > key && (current_epoch_start_time - key) / config.epoch_duration > 12) {
                simple_map::remove(&mut ve_powers.total_mkl_power, &key);
                simple_map::remove(&mut ve_powers.total_esmkl_power, &key);
            };
        });

        let user_mkl_power_keys = simple_map::keys(&_user_vemkl.mkl_power);
        vector::for_each(user_mkl_power_keys, |key| {
            if (current_epoch_start_time > key && (current_epoch_start_time - key) / config.epoch_duration > 12) {
                simple_map::remove(&mut _user_vemkl.mkl_power, &key);
                simple_map::remove(&mut _user_vemkl.esmkl_power, &key);
            };
        });
    }

    fun update_vote_power(_user_address: address, _user_vemkl: &mut UserVoteEscrowedMKL, _vemkl: &VoteEscrowedMKL, _increase: bool)
    acquires VoteEscrowedPowers, VoteEscrowedMKLConfig {
        let ve_powers = borrow_global_mut<VoteEscrowedPowers>(@merkle);
        let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
        let next_epoch_start_time = get_current_epoch_start_time_internal(config) + config.epoch_duration;
        let duration_left = _vemkl.unlock_time - min(next_epoch_start_time, _vemkl.unlock_time);
        let initial_user_mkl_power = fungible_asset::balance(_vemkl.mkl_token) * _vemkl.mkl_multiplier;
        let initial_user_esmkl_power = fungible_asset::balance(_vemkl.esmkl_token) * _vemkl.esmkl_multiplier;

        let idx = 0;
        while(true) {
            if (duration_left == 0 || idx > 52) {
                break
            };
            // mkl
            let new_mkl_power = safe_mul_div(initial_user_mkl_power, duration_left, config.max_lock_duration);
            // user mkl power
            if (simple_map::contains_key(&_user_vemkl.mkl_power, &next_epoch_start_time)) {
                let user_mkl_power = simple_map::borrow_mut(&mut _user_vemkl.mkl_power, &next_epoch_start_time);
                *user_mkl_power = if (_increase) {
                    *user_mkl_power + new_mkl_power
                } else {
                    if (*user_mkl_power > new_mkl_power) {
                        *user_mkl_power - new_mkl_power
                    } else {
                        0
                    }
                };
            } else if(_increase) {
                simple_map::add(&mut _user_vemkl.mkl_power, next_epoch_start_time, new_mkl_power);
            };

            // total mkl power
            if (simple_map::contains_key(&ve_powers.total_mkl_power, &next_epoch_start_time)) {
                let total_mkl_power = simple_map::borrow_mut(&mut ve_powers.total_mkl_power, &next_epoch_start_time);
                *total_mkl_power = if (_increase) {
                    *total_mkl_power + new_mkl_power
                } else {
                    if (*total_mkl_power > new_mkl_power) {
                        *total_mkl_power - new_mkl_power
                    } else {
                        0
                    }
                };
            } else if (_increase) {
                simple_map::add(&mut ve_powers.total_mkl_power, next_epoch_start_time, new_mkl_power);
            };

            // esmkl
            let new_esmkl_power = safe_mul_div(initial_user_esmkl_power, duration_left, config.max_lock_duration);
            // user esmkl power
            if (simple_map::contains_key(&_user_vemkl.esmkl_power, &next_epoch_start_time)) {
                let user_esmkl_power = simple_map::borrow_mut(&mut _user_vemkl.esmkl_power, &next_epoch_start_time);
                *user_esmkl_power = if (_increase) {
                    *user_esmkl_power + new_esmkl_power
                } else {
                    if (*user_esmkl_power > new_esmkl_power) {
                        *user_esmkl_power - new_esmkl_power
                    } else {
                        0
                    }
                };
            } else if (_increase) {
                simple_map::upsert(&mut _user_vemkl.esmkl_power, next_epoch_start_time, new_esmkl_power);
            };

            // total esmkl power
            if (simple_map::contains_key(&ve_powers.total_esmkl_power, &next_epoch_start_time)) {
                let total_esmkl_power = simple_map::borrow_mut(&mut ve_powers.total_esmkl_power, &next_epoch_start_time);
                *total_esmkl_power = if (_increase) {
                    *total_esmkl_power + new_esmkl_power
                } else {
                    if (*total_esmkl_power > new_esmkl_power) {
                        *total_esmkl_power - new_esmkl_power
                    } else {
                        0
                    }
                };
            } else if (_increase) {
                simple_map::upsert(&mut ve_powers.total_esmkl_power, next_epoch_start_time, new_esmkl_power);
            };

            // next epoch
            next_epoch_start_time = next_epoch_start_time + config.epoch_duration;
            duration_left = duration_left - min(config.epoch_duration, duration_left);
            idx = idx + 1;
        };
    }

    public fun get_epoch_user_vote_power(_user_address: address, _epoch_start_at: u64): (u64, u64)
    acquires VoteEscrowedMKLConfig, VoteEscrowedPowers, UserVoteEscrowedMKL {
        let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
        assert!(_epoch_start_at % config.epoch_duration == 0, E_INVALID_EPOCH_START_AT);

        let ve_powers = borrow_global<VoteEscrowedPowers>(@merkle);
        let acc_user_ve_power = 0;
        let total_ve_power = 0;
        if (exists<UserVoteEscrowedMKL>(_user_address)) {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(_user_address);
            if (simple_map::contains_key(&user_vemkl.mkl_power, &_epoch_start_at)) {
                acc_user_ve_power = *simple_map::borrow(&user_vemkl.mkl_power, &_epoch_start_at);
            };
            if (simple_map::contains_key(&user_vemkl.esmkl_power, &_epoch_start_at)) {
                acc_user_ve_power = acc_user_ve_power + *simple_map::borrow(&user_vemkl.esmkl_power, &_epoch_start_at);
            };
        };
        if (simple_map::contains_key(&ve_powers.total_mkl_power, &_epoch_start_at)) {
            total_ve_power = *simple_map::borrow(&ve_powers.total_mkl_power, &_epoch_start_at);
        };
        if (simple_map::contains_key(&ve_powers.total_esmkl_power, &_epoch_start_at)) {
            total_ve_power = total_ve_power + *simple_map::borrow(&ve_powers.total_esmkl_power, &_epoch_start_at);
        };
        (acc_user_ve_power, total_ve_power)
    }

    public fun set_max_lock_duration(_admin: &signer, _duration: u64) acquires VoteEscrowedMKLConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let config = borrow_global_mut<VoteEscrowedMKLConfig>(@merkle);
        config.max_lock_duration = _duration;
    }

    public fun set_min_lock_duration(_admin: &signer, _duration: u64) acquires VoteEscrowedMKLConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let config = borrow_global_mut<VoteEscrowedMKLConfig>(@merkle);
        config.min_lock_duration = _duration;
    }

    public fun set_epoch_duration(_admin: &signer, _duration: u64) acquires VoteEscrowedMKLConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let config = borrow_global_mut<VoteEscrowedMKLConfig>(@merkle);
        config.epoch_duration = _duration;
    }

    public fun user_swap_vemkl_premkl_to_mkl(_user: &signer)
    acquires VoteEscrowedMKL, UserVoteEscrowedMKL, VoteEscrowedMKLConfig {
        swap_vemkl_premkl_to_mkl_internal(address_of(_user));
    }

    public fun admin_swap_vemkl_premkl_to_mkl(_admin: &signer, _user_address: address)
    acquires VoteEscrowedMKL, UserVoteEscrowedMKL, VoteEscrowedMKLConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        swap_vemkl_premkl_to_mkl_internal(_user_address);
    }

    fun swap_vemkl_premkl_to_mkl_internal(_user_address: address)
    acquires VoteEscrowedMKL, UserVoteEscrowedMKL, VoteEscrowedMKLConfig {
        if (!exists<UserVoteEscrowedMKL>(_user_address)) {
            return
        };
        let user_vemkl = borrow_global_mut<UserVoteEscrowedMKL>(_user_address);
        if (vector::length(&user_vemkl.vemkl_tokens) == 0) {
            return
        };
        let vemkl_obj_address = vector::borrow(&user_vemkl.vemkl_tokens, 0);
        let vemkl = borrow_global_mut<VoteEscrowedMKL>(*vemkl_obj_address);

        if (fungible_asset::store_metadata(vemkl.mkl_token) == pre_mkl_token::get_metadata()) {
            let pre_mkl = pre_mkl_token::withdraw_from_freezed_pre_mkl_store(&vemkl.mkl_token, fungible_asset::balance(vemkl.mkl_token));
            let mkl = pre_mkl_token::swap_pre_mkl_to_mkl_with_fa_v2(_user_address, pre_mkl);

            let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
            let creator = account::create_signer_with_capability(&config.signer_cap);
            let mkl_constructor_ref = object::create_object(address_of(&creator));
            let mkl_delete_ref = object::generate_delete_ref(&mkl_constructor_ref);
            let mkl_store = fungible_asset::create_store(&mkl_constructor_ref, mkl_token::get_metadata());
            mkl_token::freeze_mkl_store(&mkl_store, true);

            // remove pre mkl store
            fungible_asset::remove_store(&vemkl.mkl_delete_ref);

            // assign mkl store
            vemkl.mkl_token = mkl_store;
            vemkl.mkl_delete_ref = mkl_delete_ref;
            mkl_token::deposit_to_freezed_mkl_store(&vemkl.mkl_token, mkl);
        };
    }

    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use std::features;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use merkle::mkl_token::{COMMUNITY_POOL, get_metadata};
    #[test_only]
    struct TEST_USDC {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::update_global_time_for_test_secs(mkl_token::mkl_tge_at());
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        let decimals = 6;
        let (bc, fc, mc) = coin::initialize<TEST_USDC>(host,
            string::utf8(b"TEST_USDC"),
            string::utf8(b"TEST_USDC"),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<TEST_USDC>(host);
        coin::deposit(address_of(host), coin::mint<TEST_USDC>(1000000000, &mc));
        coin::destroy_mint_cap(mc);

        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);
        esmkl_token::initialize_module(host);
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_initialize_module_error_not_authorized(host: &signer) {
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_lock(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents, VoteEscrowedMKL {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(86400 * 100);
        let cap = mkl_token::mint_claim_capability<COMMUNITY_POOL>(host);
        primary_fungible_store::deposit(address_of(host), mkl_token::claim_mkl_with_cap(&cap, 2000000));
        esmkl_token::deposit_user_esmkl(host, esmkl_token::mint_esmkl_for_test(1000000));

        lock(host, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 2419200);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 1000000, 0);
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
            assert!(fungible_asset::balance(vemkl.mkl_token) == 1000000, 0);
        };
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            increase_lock(host, *object_addr, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 4838400);
        };
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
            assert!(fungible_asset::balance(vemkl.mkl_token) == 2000000, 0);
            assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 0, 0);
        };
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            increase_lock(host, *object_addr, esmkl_token::withdraw_user_esmkl(host, 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 9676800);
        };
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
            assert!(fungible_asset::balance(vemkl.esmkl_token) == 1000000, 0);
            assert!(primary_fungible_store::balance(address_of(host), esmkl_token::get_metadata()) == 0, 0);
            assert!(vemkl.unlock_time == timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 9676800, 0);
        };
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            increase_lock(host, *object_addr, esmkl_token::withdraw_user_esmkl(host, 0), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 19353600);
        };
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
            assert!(fungible_asset::balance(vemkl.esmkl_token) == 1000000, 0);
            assert!(primary_fungible_store::balance(address_of(host), esmkl_token::get_metadata()) == 0, 0);
            assert!(vemkl.unlock_time == timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 19353600, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_MAX_NUM_VEMKL_EXCEEDED)]
    fun T_lock_twice(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(86400 * 100);
        let cap = mkl_token::mint_claim_capability<COMMUNITY_POOL>(host);
        primary_fungible_store::deposit(address_of(host), mkl_token::claim_mkl_with_cap(&cap, 2000000));
        esmkl_token::deposit_user_esmkl(host, esmkl_token::mint_esmkl_for_test(2000000));

        lock(host, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 2419200);
        lock(host, esmkl_token::withdraw_user_esmkl(host, 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 2419200); // lock twice!
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_lock_escrowedMKL(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(86400 * 100);
        esmkl_token::deposit_user_esmkl(host, esmkl_token::mint_esmkl_for_test(2000000));
        lock(host, esmkl_token::withdraw_user_esmkl(host, 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 2419200);
        assert!(primary_fungible_store::balance(address_of(host), esmkl_token::get_metadata()) == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_INVALID_LOCK_DURATION)]
    fun T_lock_error_less_than_min_lock_duration(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(86400 * 100);
        let cap = mkl_token::mint_claim_capability<COMMUNITY_POOL>(host);
        primary_fungible_store::deposit(address_of(host), mkl_token::claim_mkl_with_cap(&cap, 2000000));
        esmkl_token::deposit_user_esmkl(host, esmkl_token::mint_esmkl_for_test(1000000));

        lock(host, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), 1000000), timestamp::now_seconds() + 4838400);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_INVALID_LOCK_DURATION)]
    fun T_lock_error_exceeded_max_lock_duration(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(86400 * 100);
        let cap = mkl_token::mint_claim_capability<COMMUNITY_POOL>(host);
        primary_fungible_store::deposit(address_of(host), mkl_token::claim_mkl_with_cap(&cap, 2000000));
        esmkl_token::deposit_user_esmkl(host, esmkl_token::mint_esmkl_for_test(1000000));

        let config = borrow_global<VoteEscrowedMKLConfig>(@merkle);
        let exceeded_max_lock_duration = config.max_lock_duration + DAY_SECONDS;
        lock(host, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), 1000000), timestamp::now_seconds() + exceeded_max_lock_duration);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_unlock(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents, VoteEscrowedMKL {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(86400 * 100);
        let cap = mkl_token::mint_claim_capability<COMMUNITY_POOL>(host);
        primary_fungible_store::deposit(address_of(host), mkl_token::claim_mkl_with_cap(&cap, 1000000));
        esmkl_token::deposit_user_esmkl(host, esmkl_token::mint_esmkl_for_test(1000000));

        lock(host, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 2419200);
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            increase_lock(host, *object_addr, esmkl_token::withdraw_user_esmkl(host, 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 4838400);
        };
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 0, 0);
        assert!(primary_fungible_store::balance(address_of(host), esmkl_token::get_metadata()) == 0, 0);
        timestamp::fast_forward_seconds(4838400);
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            unlock(host, *object_addr);
        };
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 1000000, 0);
        assert!(primary_fungible_store::balance(address_of(host), esmkl_token::get_metadata()) == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_lock_pre_mkl(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents, VoteEscrowedMKL {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::update_global_time_for_test_secs(STAKING_START_AT);
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);
        mkl_token::initialize_module(host);
        esmkl_token::initialize_module(host);
        initialize_module(host);

        timestamp::fast_forward_seconds(86400);
        let cap = pre_mkl_token::mint_claim_capability(host);
        pre_mkl_token::claim_user_pre_mkl(&cap, address_of(host), 2000000);

        lock(host, pre_mkl_token::withdraw_from_user(address_of(host), 1000000), mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS + DAY_SECONDS + 2419200);
        assert!(primary_fungible_store::balance(address_of(host), pre_mkl_token::get_metadata()) == 1000000, 0);
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
            assert!(fungible_asset::balance(vemkl.mkl_token) == 1000000, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_INVALID_LOCK_DURATION)]
    fun T_lock_pre_mkl_E_INVALID_LOCK_DURATION(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::update_global_time_for_test_secs(STAKING_START_AT);
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);
        mkl_token::initialize_module(host);
        esmkl_token::initialize_module(host);
        initialize_module(host);

        timestamp::fast_forward_seconds(86400);
        let cap = pre_mkl_token::mint_claim_capability(host);
        pre_mkl_token::claim_user_pre_mkl(&cap, address_of(host), 2000000);

        lock(host, pre_mkl_token::withdraw_from_user(address_of(host), 1000000), mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_lock_pre_mkl_increase_swap_mkl(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents, VoteEscrowedMKL {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::update_global_time_for_test_secs(STAKING_START_AT);
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
        esmkl_token::initialize_module(host);
        initialize_module(host);

        timestamp::fast_forward_seconds(86400);
        let pre_cap = pre_mkl_token::mint_claim_capability(host);
        pre_mkl_token::claim_user_pre_mkl(&pre_cap, address_of(host), 1000000);
        lock(host, pre_mkl_token::withdraw_from_user(address_of(host), 1000000), mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS + DAY_SECONDS + 2419200);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() - pre_mkl_token::pre_mkl_tge_at());
        {
            let cap = mkl_token::mint_claim_capability<COMMUNITY_POOL>(host);
            primary_fungible_store::deposit(address_of(host), mkl_token::claim_mkl_with_cap(&cap, 1000000));
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            increase_lock(host, *object_addr, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), 1000000), timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECONDS + 4838400);
        };

        let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
        let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
        let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
        assert!(fungible_asset::balance(vemkl.mkl_token) == 2000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_admin_swap_vemkl_premkl_to_mkl(host: &signer, aptos_framework: &signer)
    acquires VoteEscrowedMKLConfig, UserVoteEscrowedMKL, VoteEscrowedPowers, StakingEvents, VoteEscrowedMKL {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::update_global_time_for_test_secs(STAKING_START_AT);
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
        esmkl_token::initialize_module(host);
        initialize_module(host);

        timestamp::fast_forward_seconds(86400);
        let pre_cap = pre_mkl_token::mint_claim_capability(host);
        pre_mkl_token::claim_user_pre_mkl(&pre_cap, address_of(host), 1000000);
        lock(host, pre_mkl_token::withdraw_from_user(address_of(host), 1000000), mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS + DAY_SECONDS + 2419200);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() - pre_mkl_token::pre_mkl_tge_at());

        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
            assert!(fungible_asset::store_metadata(vemkl.mkl_token) == pre_mkl_token::get_metadata(), 0);
            assert!(fungible_asset::balance(vemkl.mkl_token) == 1000000, 0);
        };
        admin_swap_vemkl_premkl_to_mkl(host, address_of(host));
        {
            let user_vemkl = borrow_global<UserVoteEscrowedMKL>(address_of(host));
            let object_addr = vector::borrow(&user_vemkl.vemkl_tokens, 0);
            let vemkl = borrow_global<VoteEscrowedMKL>(*object_addr);
            assert!(fungible_asset::store_metadata(vemkl.mkl_token) == mkl_token::get_metadata(), 0);
            assert!(fungible_asset::balance(vemkl.mkl_token) == 1000000, 0);
        };
    }
}