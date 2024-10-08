module merkle::custom_vesting {
    use std::signer::address_of;
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;

    use merkle::vesting;
    use merkle::mkl_token;
    use merkle::claimable_fa_store;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When no claimable amount
    const E_NO_CLAIMABLE: u64 = 1;

    struct AdminPoolCap<phantom PoolType> has key {
        claimable_fa_store_admin_cap: claimable_fa_store::AdminCapability,
        mkl_token_claim_cap: mkl_token::ClaimCapability<PoolType>,
    }

    struct CustomVestingPlan has key, drop {
        vesting_plan: vesting::VestingPlan,
        claim_cap: vesting::ClaimCapability,
        admin_cap: vesting::AdminCapability,
        pool_info: TypeInfo,
        object_delete_ref: object::DeleteRef
    }

    public fun create_custom_vesting<PoolType>(
        _admin: &signer,
        _user_address: address,
        _start_at_sec: u64,
        _end_at_sec: u64,
        _initial_amount: u64,
        _total_amount: u64
    ): address acquires AdminPoolCap {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        // add caps if not exists
        if (!exists<AdminPoolCap<PoolType>>(address_of(_admin))) {
            let admin_cap = claimable_fa_store::add_claimable_fa_store(_admin, mkl_token::get_metadata());
            move_to(_admin, AdminPoolCap<PoolType> {
                claimable_fa_store_admin_cap: admin_cap,
                mkl_token_claim_cap: mkl_token::mint_claim_capability<PoolType>(_admin)
            });
        };
        let admin_pool_cap = borrow_global<AdminPoolCap<PoolType>>(address_of(_admin));
        // create vesting plan
        let (vesting_plan, claim_cap, admin_cap) = vesting::create(
            _user_address,
            _start_at_sec,
            _end_at_sec,
            _initial_amount,
            _total_amount,
            claimable_fa_store::mint_claim_capability(&admin_pool_cap.claimable_fa_store_admin_cap)
        );

        // save to user custom vestings
        let constructor_ref = object::create_object(_user_address);
        let object_signer = object::generate_signer(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        move_to(&object_signer, CustomVestingPlan {
            vesting_plan,
            claim_cap,
            admin_cap,
            pool_info: type_info::type_of<PoolType>(),
            object_delete_ref: object::generate_delete_ref(&constructor_ref)
        });

        address_of(&object_signer)
    }

    fun claim_mkl_deposit_type_info(_pool_type_info: TypeInfo, _amount: u64)
    acquires AdminPoolCap {
        if (_pool_type_info == type_info::type_of<mkl_token::GROWTH_POOL>()) {
            claim_mkl_deposit_pool<mkl_token::GROWTH_POOL>(_amount);
        } else if (_pool_type_info == type_info::type_of<mkl_token::CORE_TEAM_POOL>()) {
            claim_mkl_deposit_pool<mkl_token::CORE_TEAM_POOL>(_amount);
        } else if (_pool_type_info == type_info::type_of<mkl_token::INVESTOR_POOL>()) {
            claim_mkl_deposit_pool<mkl_token::INVESTOR_POOL>(_amount);
        } else if (_pool_type_info == type_info::type_of<mkl_token::ADVISOR_POOL>()) {
            claim_mkl_deposit_pool<mkl_token::ADVISOR_POOL>(_amount);
        }
    }

    fun claim_mkl_deposit_pool<PoolType>(_amount: u64)
    acquires AdminPoolCap {
        let admin_pool_cap = borrow_global<AdminPoolCap<PoolType>>(@merkle);
        // get mkl from pool
        let mkl = mkl_token::claim_mkl_with_cap<PoolType>(
            &admin_pool_cap.mkl_token_claim_cap,
            _amount
        );
        // deposit pool
        claimable_fa_store::deposit_funding_store_fa(&admin_pool_cap.claimable_fa_store_admin_cap, mkl);
    }

    public fun claim(_user: &signer, _object_address: address)
    acquires AdminPoolCap, CustomVestingPlan {
        let user_address = address_of(_user);
        let object = object::address_to_object<CustomVestingPlan>(_object_address);
        assert!(object::is_owner(object, user_address), E_NOT_AUTHORIZED);
        let custom_vesting = borrow_global_mut<CustomVestingPlan>(_object_address);

        // claim from mkl pool, deposit to claimable fa store
        let claimable = vesting::get_claimable(&custom_vesting.vesting_plan);
        assert!(claimable > 0, E_NO_CLAIMABLE);
        claim_mkl_deposit_type_info(custom_vesting.pool_info, claimable);

        primary_fungible_store::deposit(
            user_address,
            vesting::claim(&mut custom_vesting.vesting_plan, &custom_vesting.claim_cap)
        );
    }

    public fun pause(_admin: &signer, _object_address: address)
    acquires CustomVestingPlan {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let custom_vesting = borrow_global_mut<CustomVestingPlan>(_object_address);
        vesting::pause(&mut custom_vesting.vesting_plan, &custom_vesting.admin_cap);
    }

    public fun unpause(_admin: &signer, _object_address: address)
    acquires CustomVestingPlan {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let custom_vesting = borrow_global_mut<CustomVestingPlan>(_object_address);
        vesting::unpause(&mut custom_vesting.vesting_plan, &custom_vesting.admin_cap);
    }

    public fun cancel(_admin: &signer, _object_address: address)
    acquires CustomVestingPlan {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let CustomVestingPlan {
            vesting_plan: _,
            claim_cap: _,
            admin_cap: _,
            pool_info: _,
            object_delete_ref
        } = move_from<CustomVestingPlan>(_object_address);
        object::delete(object_delete_ref);
    }

    #[test_only]
    use std::features;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at());

        vesting::initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_create_custom_vesting(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400,
            0,
            10000000
        );
        let custom_vesting = borrow_global_mut<CustomVestingPlan>(object_address);
        let (vesting_plan_uid, _, _, _, _, _, _, _) = vesting::get_vesting_plan_data(&custom_vesting.vesting_plan);
        assert!(vesting_plan_uid == 1, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_claim(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400,
            0,
            10000000
        );
        let prev = primary_fungible_store::balance(address_of(host), mkl_token::get_metadata());
        timestamp::fast_forward_seconds(43200);
        claim(host, object_address);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) - prev == 5000000, 0);
        timestamp::fast_forward_seconds(43200);
        claim(host, object_address);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) - prev == 10000000, 0);

        object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400 * 2,
            5000000,
            10000000
        );
        prev = primary_fungible_store::balance(address_of(host), mkl_token::get_metadata());
        claim(host, object_address);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) - prev == 5000000, 0);
        timestamp::fast_forward_seconds(86400);
        claim(host, object_address);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) - prev == 7500000, 0);
        timestamp::fast_forward_seconds(86400);
        claim(host, object_address);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) - prev == 10000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NO_CLAIMABLE, location = Self)]
    fun T_E_NO_CLAIMABLE(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400,
            0,
            10000000
        );
        timestamp::fast_forward_seconds(86401);
        claim(host, object_address);
        claim(host, object_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NO_CLAIMABLE, location = Self)]
    fun T_E_NO_CLAIMABLE2(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400,
            0,
            10000000
        );
        claim(host, object_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NO_CLAIMABLE, location = Self)]
    fun T_pause(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400,
            0,
            10000000
        );
        pause(host, object_address);
        timestamp::fast_forward_seconds(86401);
        claim(host, object_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_unpause(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400,
            0,
            10000000
        );
        pause(host, object_address);
        timestamp::fast_forward_seconds(86401);
        unpause(host, object_address);

        let prev = primary_fungible_store::balance(address_of(host), mkl_token::get_metadata());
        claim(host, object_address);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) - prev == 10000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x60002, location = object)]
    fun T_cancel(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let object_address = create_custom_vesting<mkl_token::GROWTH_POOL>(
            host,
            address_of(host),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 86400,
            0,
            10000000
        );
        timestamp::fast_forward_seconds(86401);
        cancel(host, object_address);
        claim(host, object_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_investor_pool_claim(host: &signer, aptos_framework: &signer)
    acquires AdminPoolCap, CustomVestingPlan {
        call_test_setting(host, aptos_framework);
        let start_at = timestamp::now_seconds() + (365 * 86400 / 12 * 6);
        let object_address = create_custom_vesting<mkl_token::INVESTOR_POOL>(
            host,
            address_of(host),
            start_at,
            start_at + 365 * 86400,
            10000000,
            110000000
        );
        timestamp::fast_forward_seconds(86400);
        let custom_vesting = borrow_global_mut<CustomVestingPlan>(object_address);
        let claimable = vesting::get_claimable(&custom_vesting.vesting_plan);
        assert!(claimable == 0, 0);

        timestamp::fast_forward_seconds(start_at - timestamp::now_seconds());
        let claimable = vesting::get_claimable(&custom_vesting.vesting_plan);
        assert!(claimable == 10000000, 0);

        timestamp::fast_forward_seconds(365 / 5 * 86400); // 20% vesting
        let claimable = vesting::get_claimable(&custom_vesting.vesting_plan);
        assert!(claimable == 30000000, 0);
    }
}