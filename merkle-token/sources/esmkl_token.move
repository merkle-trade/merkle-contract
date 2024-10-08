module merkle::esmkl_token {
    friend merkle::staking;
    friend merkle::managed_staking;

    use std::option;
    use std::string;
    use std::signer::address_of;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset, FungibleStore};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use merkle::mkl_token;
    use merkle::claimable_fa_store;
    use merkle::vesting;

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When vest too small amount
    const E_TOO_SMALL_VEST_AMOUNT: u64 = 1;
    /// When esmkl is not claimable
    const E_NOT_CLAIMABLE: u64 = 2;
    /// When use invalid fa
    const E_INVALID_FA: u64 = 3;

    const ESCROWED_MKL_SYMBOL: vector<u8> = b"esMKL";

    struct ESMKL {}
    struct MintCapability has store, drop {}

    struct EsmklConfig has key {
        mint_ref: fungible_asset::MintRef,
        transfer_ref: fungible_asset::TransferRef,
        burn_ref: fungible_asset::BurnRef
    }

    struct VestingConfig has key {
        vesting_duration: u64,
        esmkl_minimum_amount: u64,
        cfa_store_admin_cap: claimable_fa_store::AdminCapability
    }

    struct MklClaimCapability has key {
        cap: mkl_token::ClaimCapability<mkl_token::COMMUNITY_POOL>
    }

    struct EsmklVestingPlan has key, drop {
        vesting_plan: vesting::VestingPlan,
        claim_cap: vesting::ClaimCapability,
        admin_cap: vesting::AdminCapability,
        object_delete_ref: object::DeleteRef
    }

    public fun initialize_module(_admin: &signer) {
        assert!(@merkle == address_of(_admin), E_NOT_AUTHORIZED);
        if (!exists<EsmklConfig>(address_of(_admin))) {
            let constructor_ref = &object::create_named_object(_admin, ESCROWED_MKL_SYMBOL);
            primary_fungible_store::create_primary_store_enabled_fungible_asset(
                constructor_ref,
                option::none(),
                string::utf8(ESCROWED_MKL_SYMBOL),
                string::utf8(ESCROWED_MKL_SYMBOL),
                6,
                string::utf8(b""),
                string::utf8(b""),
            );
            let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
            let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
            let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
            move_to(
                _admin,
                EsmklConfig {
                    mint_ref,
                    transfer_ref,
                    burn_ref
                }
            );
        };
        if (!exists<VestingConfig>(address_of(_admin))) {
            let admin_cap = claimable_fa_store::add_claimable_fa_store(_admin, mkl_token::get_metadata());
            move_to(_admin, VestingConfig {
                vesting_duration: 86400 * 90, // 90 days
                esmkl_minimum_amount: 1000000, // 1 esmkl
                cfa_store_admin_cap: admin_cap
            });
        };
        if (!exists<MklClaimCapability>(address_of(_admin))) {
            move_to(_admin, MklClaimCapability {
                cap: mkl_token::mint_claim_capability<mkl_token::COMMUNITY_POOL>(_admin)
            });
        };
    }

    public fun restore_cfa_store_admin_cap(_admin: &signer) acquires VestingConfig {
        assert!(@merkle == address_of(_admin), E_NOT_AUTHORIZED);
        let vesting_config = borrow_global_mut<VestingConfig>(@merkle);
        let admin_cap = claimable_fa_store::add_claimable_fa_store(_admin, mkl_token::get_metadata());
        vesting_config.cfa_store_admin_cap = admin_cap;
    }

    public fun restore_cfa_store_claim_cap(_admin: &signer, _object_address: address) acquires EsmklVestingPlan, VestingConfig {
        assert!(@merkle == address_of(_admin), E_NOT_AUTHORIZED);
        let vesting_config = borrow_global_mut<VestingConfig>(@merkle);
        let esmkl_vesting_plan = borrow_global_mut<EsmklVestingPlan>(_object_address);
        let claim_cap = claimable_fa_store::mint_claim_capability(&vesting_config.cfa_store_admin_cap);
        vesting::change_claim_cap(&mut esmkl_vesting_plan.vesting_plan, &esmkl_vesting_plan.admin_cap, claim_cap);
    }

    // <--- token --->
    public fun get_metadata(): Object<Metadata> {
        let asset_address = object::create_object_address(&@merkle, ESCROWED_MKL_SYMBOL);
        object::address_to_object<Metadata>(asset_address)
    }

    public fun mint_esmkl_with_cap(_cap: &MintCapability, _amount: u64): FungibleAsset acquires EsmklConfig {
        mint_esmkl_internal(_amount)
    }

    fun mint_esmkl_internal(_amount: u64): FungibleAsset acquires EsmklConfig {
        let now = timestamp::now_seconds();
        assert!(now >= mkl_token::mkl_tge_at(), E_NOT_CLAIMABLE);
        let config = borrow_global<EsmklConfig>(@merkle);
        fungible_asset::mint(&config.mint_ref, _amount)
    }

    public fun burn_esmkl(_fa: FungibleAsset)
    acquires EsmklConfig {
        // burn esmkl
        let config = borrow_global<EsmklConfig>(@merkle);
        fungible_asset::burn(&config.burn_ref, _fa);
    }

    public(friend) fun withdraw_user_esmkl(_user: &signer, _amount: u64): FungibleAsset acquires EsmklConfig {
        withdraw_from_freezed_esmkl_store(
            &primary_fungible_store::primary_store(address_of(_user), get_metadata()),
            _amount
        )
    }

    public fun deposit_user_esmkl(_user: &signer, _fa: FungibleAsset) acquires EsmklConfig {
        assert!(fungible_asset::metadata_from_asset(&_fa) == get_metadata(), E_INVALID_FA);
        let config = borrow_global<EsmklConfig>(@merkle);
        let user_address = address_of(_user);
        if (!primary_fungible_store::is_frozen(user_address, get_metadata())) {
            primary_fungible_store::set_frozen_flag(&config.transfer_ref, user_address, true);
        };
        primary_fungible_store::deposit_with_ref(&config.transfer_ref, user_address, _fa);
    }

    public(friend) fun freeze_esmkl_store(_store: &Object<FungibleStore>, frozen: bool)
    acquires EsmklConfig {
        assert!(fungible_asset::store_metadata(*_store) == get_metadata(), E_INVALID_FA);
        let esmkl_config = borrow_global<EsmklConfig>(@merkle);
        fungible_asset::set_frozen_flag(&esmkl_config.transfer_ref, *_store, frozen);
    }

    public(friend) fun deposit_to_freezed_esmkl_store(_store: &Object<FungibleStore>, _fa: FungibleAsset)
    acquires EsmklConfig {
        assert!(fungible_asset::store_metadata(*_store) == get_metadata(), E_INVALID_FA);
        let esmkl_config = borrow_global<EsmklConfig>(@merkle);
        fungible_asset::deposit_with_ref(&esmkl_config.transfer_ref, *_store, _fa);
    }

    public(friend) fun withdraw_from_freezed_esmkl_store(_store: &Object<FungibleStore>, _amount: u64): FungibleAsset
    acquires EsmklConfig {
        if (_amount == 0) {
            return fungible_asset::zero(get_metadata())
        };
        assert!(fungible_asset::store_metadata(*_store) == get_metadata(), E_INVALID_FA);
        let esmkl_config = borrow_global<EsmklConfig>(@merkle);
        fungible_asset::withdraw_with_ref(&esmkl_config.transfer_ref, *_store, _amount)
    }

    public fun mint_mint_capability(_admin: &signer): MintCapability {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        MintCapability {}
    }

    // <--- vesting --->
    public fun vest(_user: &signer, _amount: u64): address
    acquires EsmklConfig, VestingConfig {
        let vesting_config = borrow_global<VestingConfig>(@merkle);
        assert!(_amount >= vesting_config.esmkl_minimum_amount, E_TOO_SMALL_VEST_AMOUNT);
        // burn esmkl
        let esmkl = withdraw_user_esmkl(_user, _amount);
        burn_esmkl(esmkl);

        // create vesting plan
        let now = timestamp::now_seconds();
        let (vesting_plan, claim_cap, admin_cap) = vesting::create(
            address_of(_user),
            now,
            now + vesting_config.vesting_duration,
            0,
            _amount,
            claimable_fa_store::mint_claim_capability(&vesting_config.cfa_store_admin_cap) // community vesting vault
        );

        let constructor_ref = object::create_object(address_of(_user));
        let object_signer = object::generate_signer(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        move_to(&object_signer, EsmklVestingPlan {
            vesting_plan,
            claim_cap,
            admin_cap,
            object_delete_ref: object::generate_delete_ref(&constructor_ref)
        });
        address_of(&object_signer)
    }

    fun claim_mkl_deposit_pool(_amount: u64)
    acquires MklClaimCapability, VestingConfig {
        let mkl_claim_cap = borrow_global<MklClaimCapability>(@merkle);
        let mkl = mkl_token::claim_mkl_with_cap(&mkl_claim_cap.cap, _amount);
        let vesting_config = borrow_global<VestingConfig>(@merkle);
        claimable_fa_store::deposit_funding_store_fa(&vesting_config.cfa_store_admin_cap, mkl);
    }

    public fun claim(_user: &signer, _object_address: address)
    acquires EsmklVestingPlan, VestingConfig, MklClaimCapability {
        let object = object::address_to_object<EsmklVestingPlan>(_object_address);
        assert!(object::is_owner(object, address_of(_user)), E_NOT_AUTHORIZED);

        let esmkl_vesting_plan = borrow_global_mut<EsmklVestingPlan>(_object_address);
        claim_mkl_deposit_pool(vesting::get_claimable(&esmkl_vesting_plan.vesting_plan));

        let mkl = vesting::claim(&mut esmkl_vesting_plan.vesting_plan, &esmkl_vesting_plan.claim_cap);
        primary_fungible_store::deposit(address_of(_user), mkl);
        let (_, _, _, _, _, total_amount, claimed_amount, _) = vesting::get_vesting_plan_data(&esmkl_vesting_plan.vesting_plan);
        if (total_amount == claimed_amount) {
            let EsmklVestingPlan {
                vesting_plan: _,
                claim_cap: _,
                admin_cap: _,
                object_delete_ref,
            } = move_from<EsmklVestingPlan>(_object_address);
            object::delete(object_delete_ref);
        };
    }

    public fun cancel(_user: &signer, _object_address: address)
    acquires EsmklVestingPlan, EsmklConfig, VestingConfig, MklClaimCapability {
        let object = object::address_to_object<EsmklVestingPlan>(_object_address);
        assert!(object::is_owner(object, address_of(_user)), E_NOT_AUTHORIZED);
        let EsmklVestingPlan {
            vesting_plan,
            claim_cap,
            admin_cap,
            object_delete_ref,
        } = move_from<EsmklVestingPlan>(_object_address);

        claim_mkl_deposit_pool(vesting::get_claimable(&vesting_plan));

        let (mkl, claimed_esmkl_amount) = vesting::cancel(vesting_plan, claim_cap, admin_cap);
        let esmkl = mint_esmkl_internal(claimed_esmkl_amount);
        primary_fungible_store::deposit(address_of(_user), mkl);
        deposit_user_esmkl(_user, esmkl);
        object::delete(object_delete_ref);
    }


    #[test_only]
    use std::features;
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
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 100);

        initialize_module(host);
        vesting::initialize_module(host);
    }

    #[test_only]
    public fun mint_esmkl_for_test(_amount: u64): FungibleAsset acquires EsmklConfig {
        mint_esmkl_internal(_amount)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_mint_esmkl_deposit(host: &signer, aptos_framework: &signer)
    acquires EsmklConfig {
        call_test_setting(host, aptos_framework);

        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, 1000000);
        assert!(fungible_asset::amount(&esmkl) == 1000000, 0);
        deposit_user_esmkl(host, esmkl);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_burn_esmkl(host: &signer, aptos_framework: &signer)
    acquires EsmklConfig {
        call_test_setting(host, aptos_framework);

        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, 1000000);
        assert!(fungible_asset::amount(&esmkl) == 1000000, 0);
        burn_esmkl(esmkl);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_esmkl_withdraw(host: &signer, aptos_framework: &signer)
    acquires EsmklConfig {
        call_test_setting(host, aptos_framework);

        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, 1000000);
        deposit_user_esmkl(host, esmkl);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 1000000, 0);
        let esmkl2 = withdraw_user_esmkl(host, 1000000);
        assert!(fungible_asset::amount(&esmkl2) == 1000000, 0);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 0, 0);
        burn_esmkl(esmkl2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_esmkl_vest(host: &signer, aptos_framework: &signer)
    acquires EsmklConfig, VestingConfig {
        call_test_setting(host, aptos_framework);

        let amount = 1000000;
        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, amount);
        deposit_user_esmkl(host, esmkl);
        let object_address = vest(host, amount);
        assert!(exists<EsmklVestingPlan>(object_address), 0);
        let esmkl_vesting_plan_object = object::address_to_object<EsmklVestingPlan>(object_address);
        assert!(object::is_owner(esmkl_vesting_plan_object, address_of(host)), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 2, location = vesting)]
    fun T_esmkl_claim_0_fail(host: &signer, aptos_framework: &signer)
    acquires EsmklConfig, VestingConfig, EsmklVestingPlan, MklClaimCapability {
        call_test_setting(host, aptos_framework);

        let amount = 1000000;
        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, amount);
        deposit_user_esmkl(host, esmkl);
        let object_address = vest(host, amount);
        claim(host, object_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_esmkl_claim(host: &signer, aptos_framework: &signer, user: &signer)
    acquires EsmklConfig, VestingConfig, EsmklVestingPlan, MklClaimCapability {
        call_test_setting(host, aptos_framework);

        let amount = 1000000;
        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, amount);
        deposit_user_esmkl(user, esmkl);
        let object_address = vest(user, amount);

        {
            let vesting_config = borrow_global<VestingConfig>(@merkle);
            timestamp::fast_forward_seconds(vesting_config.vesting_duration / 2); // 50% vesting
        };
        claim(user, object_address);
        assert!(primary_fungible_store::balance(address_of(user), mkl_token::get_metadata()) == amount / 2, 0);
        {
            let vesting_config = borrow_global<VestingConfig>(@merkle);
            timestamp::fast_forward_seconds(vesting_config.vesting_duration); // 100% vesting
        };
        claim(user, object_address);
        assert!(primary_fungible_store::balance(address_of(user), mkl_token::get_metadata()) == amount, 0);
        assert!(!exists<EsmklVestingPlan>(object_address), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_esmkl_cancel(host: &signer, aptos_framework: &signer, user: &signer)
    acquires EsmklConfig, VestingConfig, EsmklVestingPlan, MklClaimCapability {
        call_test_setting(host, aptos_framework);

        let amount = 1000000;
        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, amount);
        deposit_user_esmkl(user, esmkl);
        let object_address = vest(user, amount);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 0, 0);
        {
            let vesting_config = borrow_global<VestingConfig>(@merkle);
            timestamp::fast_forward_seconds(vesting_config.vesting_duration / 2); // 50% vesting
        };
        claim(user, object_address);
        assert!(primary_fungible_store::balance(address_of(user), mkl_token::get_metadata()) == amount / 2, 0);
        {
            let vesting_config = borrow_global<VestingConfig>(@merkle);
            timestamp::fast_forward_seconds(vesting_config.vesting_duration / 4); // 20% vesting
        };
        cancel(user, object_address);
        assert!(primary_fungible_store::balance(address_of(user), mkl_token::get_metadata()) == amount / 4 * 3, 0);
        assert!(primary_fungible_store::balance(address_of(user), get_metadata()) == amount / 4, 0);
        assert!(!exists<EsmklVestingPlan>(object_address), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_esmkl_cancel2(host: &signer, aptos_framework: &signer, user: &signer)
    acquires EsmklConfig, VestingConfig, EsmklVestingPlan, MklClaimCapability {
        call_test_setting(host, aptos_framework);

        let amount = 1000000;
        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, amount);
        deposit_user_esmkl(user, esmkl);
        let object_address = vest(user, amount);
        timestamp::fast_forward_seconds(10);
        cancel(user, object_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_CLAIMABLE, location = Self)]
    fun T_mint_E_NOT_CLAIMABLE(host: &signer, aptos_framework: &signer)
    acquires EsmklConfig {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        mkl_token::initialize_module(host);
        initialize_module(host);

        let cap = mint_mint_capability(host);
        let esmkl = mint_esmkl_with_cap(&cap, 1000000);
        deposit_user_esmkl(host, esmkl);
    }
}