module merkle::pre_mkl_token {

    friend merkle::staking;
    friend merkle::managed_staking;
    friend merkle::liquidity_auction;

    use std::option;
    use std::signer::address_of;
    use std::string;
    use aptos_std::table;
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata, FungibleAsset};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use merkle::safe_math;
    use merkle::mkl_token;

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// The MKL token has not been generated yet
    const E_NOT_SWAPPABLE: u64 = 1;
    /// The Pre MKL has not claimable yet
    const E_NOT_CLAIMABLE: u64 = 2;
    /// Only Pre MKL allowed
    const E_INVALID_ASSET: u64 = 3;

    const PRE_MKL_SYMBOL: vector<u8> = b"PreMKL";
    const PRECISION: u64 = 1000000;

    // <-- MKL Distribution ----->
    const PRE_MKL_GENERATE_AT_SEC: u64 = 1721908800; // 2024-07-25T12:00:00.000Z
    const PRE_MKL_TOTAL_SUPPLY: u64 = 9_500_000_000000; // 9,500,000 * 10^6 (9.5%)

    struct PreMKL {}

    struct PreMklConfig has key {
        mint_ref: fungible_asset::MintRef,
        transfer_ref: fungible_asset::TransferRef,
        burn_ref: fungible_asset::BurnRef,
        mkl_cap: mkl_token::ClaimCapability<mkl_token::COMMUNITY_POOL>
    }
    struct PoolStore has key {
        pre_mkl: Object<FungibleStore>, // object address for fungible store
    }
    struct GrowthFundResource has key {
        user: table::Table<address, GrowthFundRecipt>,
        mkl_cap: mkl_token::ClaimCapability<mkl_token::GROWTH_POOL>
    }
    struct GrowthFundRecipt has store, drop {
        initial_amount: u64,
        swapped_amount: u64
    }
    struct ClaimCapability has store, drop {}

    public fun initialize_module(_admin: &signer) {
        assert!(@merkle == address_of(_admin), E_NOT_AUTHORIZED);
        if (!exists<PreMklConfig>(address_of(_admin))) {
            let constructor_ref = &object::create_named_object(_admin, PRE_MKL_SYMBOL);
            primary_fungible_store::create_primary_store_enabled_fungible_asset(
                constructor_ref,
                option::none(),
                string::utf8(PRE_MKL_SYMBOL),
                string::utf8(PRE_MKL_SYMBOL),
                6,
                string::utf8(b""),
                string::utf8(b""),
            );
            let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
            let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
            let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
            move_to(
                _admin,
                PreMklConfig {
                    mint_ref,
                    transfer_ref,
                    burn_ref,
                    mkl_cap: mkl_token::mint_claim_capability<mkl_token::COMMUNITY_POOL>(_admin)
                }
            );
        };
    }

    public fun get_metadata(): Object<Metadata> {
        let asset_address = object::create_object_address(&@merkle, PRE_MKL_SYMBOL);
        object::address_to_object<Metadata>(asset_address)
    }

    public fun run_token_generation_event(_admin: &signer) acquires PreMklConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        // mkl vaults
        let pre_mkl_config = borrow_global<PreMklConfig>(address_of(_admin));
        let constructor_ref = object::create_object(address_of(_admin));
        let store = fungible_asset::create_store(&constructor_ref, get_metadata());
        fungible_asset::deposit(store, fungible_asset::mint(&pre_mkl_config.mint_ref, PRE_MKL_TOTAL_SUPPLY));

        move_to(_admin, PoolStore {
            pre_mkl: store,
        });
    }

    public fun deploy_pre_mkl_from_growth_fund(_admin: &signer, _user_address: address, _amount: u64)
    acquires PreMklConfig, GrowthFundResource {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if (!exists<GrowthFundResource>(address_of(_admin))) {
            move_to(_admin, GrowthFundResource {
                user: table::new<address, GrowthFundRecipt>(),
                mkl_cap: mkl_token::mint_claim_capability<mkl_token::GROWTH_POOL>(_admin)
            });
        };
        let growth_fund_resource = borrow_global_mut<GrowthFundResource>(address_of(_admin));
        let growth_fund_receipt = table::borrow_mut_with_default(
            &mut growth_fund_resource.user,
            _user_address,
            GrowthFundRecipt {
                initial_amount: 0,
                swapped_amount: 0
            }
        );
        growth_fund_receipt.initial_amount = growth_fund_receipt.initial_amount + _amount;

        // mint pre mkl for growth fund
        // PoolStore pre mkl is only for community pool
        let pre_mkl_config = borrow_global<PreMklConfig>(address_of(_admin));
        let pre_mkl = fungible_asset::mint(&pre_mkl_config.mint_ref, _amount);

        if (!primary_fungible_store::is_frozen(_user_address, get_metadata())) {
            primary_fungible_store::set_frozen_flag(&pre_mkl_config.transfer_ref, _user_address, true);
        };
        primary_fungible_store::deposit_with_ref(&pre_mkl_config.transfer_ref, _user_address, pre_mkl);
    }

    public fun claim_user_pre_mkl(_cap: &ClaimCapability, _user_address: address, _amount: u64)
    acquires PoolStore, PreMklConfig {
        let pre_mkl = claim_pre_mkl_with_cap(_cap, _amount);
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        if (!primary_fungible_store::is_frozen(_user_address, get_metadata())) {
            primary_fungible_store::set_frozen_flag(&pre_mkl_config.transfer_ref, _user_address, true);
        };
        primary_fungible_store::deposit_with_ref(&pre_mkl_config.transfer_ref, _user_address, pre_mkl);
    }

    public(friend) fun deposit_user_pre_mkl(_user: &signer, _fa: FungibleAsset)
    acquires PreMklConfig {
        assert!(fungible_asset::metadata_from_asset(&_fa) == get_metadata(), E_INVALID_ASSET);

        let user_address = address_of(_user);
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        if (!primary_fungible_store::is_frozen(user_address, get_metadata())) {
            primary_fungible_store::set_frozen_flag(&pre_mkl_config.transfer_ref, user_address, true);
        };
        primary_fungible_store::deposit_with_ref(&pre_mkl_config.transfer_ref, user_address, _fa);
    }

    public fun claim_pre_mkl_with_cap(_cap: &ClaimCapability, _amount: u64): FungibleAsset
    acquires PoolStore, PreMklConfig {
        // from pre mkl tge at to mkl tge at + 2 seasons (28 days)
        assert!(timestamp::now_seconds() >= pre_mkl_tge_at() && timestamp::now_seconds() < mkl_token::mkl_tge_at() + 86400 * 28, E_NOT_CLAIMABLE);
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        let pool_store = borrow_global<PoolStore>(@merkle);

        fungible_asset::withdraw_with_ref(&pre_mkl_config.transfer_ref, pool_store.pre_mkl, _amount)
    }

    public fun mint_claim_capability(_admin: &signer): ClaimCapability {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        ClaimCapability {}
    }

    public(friend) fun freeze_pre_mkl_store(_store: &Object<FungibleStore>, frozen: bool)
    acquires PreMklConfig {
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        fungible_asset::set_frozen_flag(&pre_mkl_config.transfer_ref, *_store, frozen);
    }

    public(friend) fun deposit_to_freezed_pre_mkl_store(_store: &Object<FungibleStore>, _fa: FungibleAsset)
    acquires PreMklConfig {
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        fungible_asset::deposit_with_ref(&pre_mkl_config.transfer_ref, *_store, _fa);
    }

    public(friend) fun withdraw_from_freezed_pre_mkl_store(_store: &Object<FungibleStore>, _amount: u64): FungibleAsset
    acquires PreMklConfig {
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        fungible_asset::withdraw_with_ref(&pre_mkl_config.transfer_ref, *_store, _amount)
    }

    public(friend) fun withdraw_from_user(_user_address: address, _amount: u64): FungibleAsset
    acquires PreMklConfig {
        if (_amount == 0) {
            return fungible_asset::zero(get_metadata())
        };
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        primary_fungible_store::withdraw_with_ref(&pre_mkl_config.transfer_ref, _user_address, _amount)
    }

    public fun swap_pre_mkl_to_mkl(_user: &signer): FungibleAsset
    acquires PreMklConfig, GrowthFundResource {
        let user_address = address_of(_user);
        let amount = primary_fungible_store::balance(user_address, get_metadata());
        if (amount == 0) {
            return fungible_asset::zero(mkl_token::get_metadata())
        };
        // withdraw all and swap
        swap_pre_mkl_to_mkl_with_fa_v2(address_of(_user), withdraw_from_user(user_address, amount))
    }

    public(friend) fun swap_pre_mkl_to_mkl_with_fa(_user: &signer, _fa: FungibleAsset): FungibleAsset
    acquires PreMklConfig, GrowthFundResource {
        swap_pre_mkl_to_mkl_with_fa_v2(address_of(_user), _fa)
    }

    public(friend) fun swap_pre_mkl_to_mkl_with_fa_v2(_user_address: address, _fa: FungibleAsset): FungibleAsset
    acquires PreMklConfig, GrowthFundResource {
        let amount = fungible_asset::amount(&_fa);
        let growth_fund_amount = safe_math::min(get_leftover_growth_fund_amount(_user_address), amount);
        let mkl = fungible_asset::zero(mkl_token::get_metadata());
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        if (growth_fund_amount > 0) {
            let growth_fund_resource = borrow_global_mut<GrowthFundResource>(@merkle);
            let growth_mkl = burn_pre_mkl_claim_mkl_with_ref_cap(
                fungible_asset::extract(&mut _fa, growth_fund_amount),
                &pre_mkl_config.burn_ref,
                &growth_fund_resource.mkl_cap
            );
            fungible_asset::merge(&mut mkl, growth_mkl);

            let growth_fund_receipt = table::borrow_mut(&mut growth_fund_resource.user, _user_address);
            growth_fund_receipt.swapped_amount = growth_fund_receipt.swapped_amount + growth_fund_amount;
        };
        let community_mkl = burn_pre_mkl_claim_mkl_with_ref_cap(
            _fa,
            &pre_mkl_config.burn_ref,
            &pre_mkl_config.mkl_cap
        );
        fungible_asset::merge(&mut mkl, community_mkl);
        mkl
    }

    fun get_leftover_growth_fund_amount(_user_address: address): u64
    acquires GrowthFundResource {
        if (!exists<GrowthFundResource>(@merkle)) {
            return 0
        };

        let growth_fund_resource = borrow_global<GrowthFundResource>(@merkle);
        if (table::contains(&growth_fund_resource.user, _user_address)) {
            let growth_fund_receipt = table::borrow(&growth_fund_resource.user, _user_address);
            return growth_fund_receipt.initial_amount - growth_fund_receipt.swapped_amount
        };
        return 0
    }

    public(friend) fun burn_pre_mkl_claim_mkl_with_ref_cap<PoolType>(
        _fa: FungibleAsset,
        _burn_ref: &fungible_asset::BurnRef,
        _cap: &mkl_token::ClaimCapability<PoolType>
    ): FungibleAsset {
        assert!(timestamp::now_seconds() >= mkl_token::mkl_tge_at(), E_NOT_SWAPPABLE);
        assert!(fungible_asset::metadata_from_asset(&_fa) == get_metadata(), E_NOT_SWAPPABLE);
        let amount = fungible_asset::amount(&_fa);
        if (amount > 0) {
            fungible_asset::burn(_burn_ref, _fa);
        } else {
            fungible_asset::destroy_zero(_fa);
        };
        mkl_token::claim_mkl_with_cap(_cap, amount)
    }

    public(friend) fun burn_pre_mkl_claim_mkl(_fa: FungibleAsset): FungibleAsset
    acquires PreMklConfig {
        // almost deprecated, use this only for lba swap
        assert!(timestamp::now_seconds() >= mkl_token::mkl_tge_at(), E_NOT_SWAPPABLE);
        assert!(fungible_asset::metadata_from_asset(&_fa) == get_metadata(), E_NOT_SWAPPABLE);
        let amount = fungible_asset::amount(&_fa);
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        if (amount > 0) {
            fungible_asset::burn(&pre_mkl_config.burn_ref, _fa);
        } else {
            fungible_asset::destroy_zero(_fa);
        };
        mkl_token::claim_mkl_with_cap(&pre_mkl_config.mkl_cap, amount)
    }

    public fun pre_mkl_tge_at(): u64 {
        PRE_MKL_GENERATE_AT_SEC
    }

    public fun user_swap_premkl_to_mkl(_user: &signer)
    acquires PreMklConfig, GrowthFundResource {
        swap_premkl_to_mkl_internal(address_of(_user));
    }

    public fun admin_swap_premkl_to_mkl(_admin: &signer, _user_address: address)
    acquires PreMklConfig, GrowthFundResource {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        swap_premkl_to_mkl_internal(_user_address);
    }

    fun swap_premkl_to_mkl_internal(_user_address: address)
    acquires PreMklConfig, GrowthFundResource {
        let balance = primary_fungible_store::balance(_user_address, get_metadata());
        if (balance == 0) {
            return
        };
        let pre_mkl = withdraw_from_user(_user_address, balance);
        let swapped_mkl = swap_pre_mkl_to_mkl_with_fa_v2(_user_address, pre_mkl);
        primary_fungible_store::deposit(_user_address, swapped_mkl);
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
    fun call_test_setting(host: &signer, aptos_framework: &signer) acquires PreMklConfig {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        initialize_module(host);
        run_token_generation_event(host);
        timestamp::fast_forward_seconds(pre_mkl_tge_at());
    }

    #[test_only]
    public fun deposit_user_pre_mkl_for_testing(_user: &signer, _fa: FungibleAsset)
    acquires PreMklConfig {
        deposit_user_pre_mkl(_user, _fa);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) acquires PreMklConfig {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module_exist_resource(host: &signer, aptos_framework: &signer) acquires PreMklConfig {
        call_test_setting(host, aptos_framework);
        initialize_module(host);
    }

    #[test(host = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_initialize_module_error_not_authorized(host: &signer) {
        initialize_module(host);
    }

    #[test(admin = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_set_schedule_info_error_not_authorized(admin: &signer) acquires PreMklConfig {
        run_token_generation_event(admin);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_claim_pre_mkl(host: &signer, aptos_framework: &signer) acquires PoolStore, PreMklConfig {
        call_test_setting(host, aptos_framework);
        let cap = mint_claim_capability(host);
        let pre_mkl = claim_pre_mkl_with_cap(&cap, 100000);
        assert!(fungible_asset::amount(&pre_mkl) == 100000, 0);
        primary_fungible_store::deposit(address_of(host), pre_mkl);
    }

    #[test(admin = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_generate_admin_cap_error_not_authorized(admin: &signer) {
        mint_claim_capability(admin);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_swap_pre_mkl_to_mkl(host: &signer, aptos_framework: &signer)
    acquires PoolStore, PreMklConfig, GrowthFundResource {
        call_test_setting(host, aptos_framework);
        let cap = mint_claim_capability(host);
        let pre_mkl = claim_pre_mkl_with_cap(&cap, 100000);
        assert!(fungible_asset::amount(&pre_mkl) == 100000, 0);
        primary_fungible_store::deposit(address_of(host), pre_mkl);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 10);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);

        let mkl = swap_pre_mkl_to_mkl(host);
        assert!(fungible_asset::amount(&mkl) == 100000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 100000, 0);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_burn_pre_mkl_claim_mkl_with_ref_cap(host: &signer, aptos_framework: &signer) acquires PoolStore, PreMklConfig, GrowthFundResource {
        call_test_setting(host, aptos_framework);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);

        move_to(host, GrowthFundResource {
            user: table::new<address, GrowthFundRecipt>(),
            mkl_cap: mkl_token::mint_claim_capability<mkl_token::GROWTH_POOL>(host)
        });

        let cap = mint_claim_capability(host);
        let pre_mkl = claim_pre_mkl_with_cap(&cap, 100000);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 10);
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        let growth_fund_resource = borrow_global<GrowthFundResource>(@merkle);
        let mkl = burn_pre_mkl_claim_mkl_with_ref_cap(pre_mkl, &pre_mkl_config.burn_ref, &growth_fund_resource.mkl_cap);
        assert!(fungible_asset::amount(&mkl) == 100000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 100000, 0);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_SWAPPABLE)]
    fun T_burn_pre_mkl_claim_mkl_E_NOT_SWAPPABLE(host: &signer, aptos_framework: &signer) acquires PoolStore, PreMklConfig, GrowthFundResource {
        call_test_setting(host, aptos_framework);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);

        move_to(host, GrowthFundResource {
            user: table::new<address, GrowthFundRecipt>(),
            mkl_cap: mkl_token::mint_claim_capability<mkl_token::GROWTH_POOL>(host)
        });

        let cap = mint_claim_capability(host);
        let pre_mkl = claim_pre_mkl_with_cap(&cap, 100000);
        let pre_mkl_config = borrow_global<PreMklConfig>(@merkle);
        let growth_fund_resource = borrow_global<GrowthFundResource>(@merkle);
        let mkl = burn_pre_mkl_claim_mkl_with_ref_cap(pre_mkl, &pre_mkl_config.burn_ref, &growth_fund_resource.mkl_cap);
        primary_fungible_store::deposit(address_of(host), mkl);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_swap_pre_mkl_to_mkl_with_growth_fund(host: &signer, aptos_framework: &signer)
    acquires PoolStore, PreMklConfig, GrowthFundResource {
        call_test_setting(host, aptos_framework);
        let cap = mint_claim_capability(host);
        let pre_mkl = claim_pre_mkl_with_cap(&cap, 1000000);
        primary_fungible_store::deposit(address_of(host), pre_mkl);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 10);
        deploy_pre_mkl_from_growth_fund(host, address_of(host), 1000000);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 2000000, 0);

        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
        let mkl = swap_pre_mkl_to_mkl(host);
        assert!(fungible_asset::amount(&mkl) == 2000000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);

        let growth_fund_resource = borrow_global<GrowthFundResource>(@merkle);
        let growth_fund_receipt = table::borrow(&growth_fund_resource.user, address_of(host));
        assert!(growth_fund_receipt.initial_amount == 1000000, 0);
        assert!(growth_fund_receipt.swapped_amount == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_swap_pre_mkl_to_mkl_with_growth_fund2(host: &signer, aptos_framework: &signer)
    acquires PoolStore, PreMklConfig, GrowthFundResource {
        call_test_setting(host, aptos_framework);
        let cap = mint_claim_capability(host);
        let pre_mkl = claim_pre_mkl_with_cap(&cap, 1000000);
        primary_fungible_store::deposit(address_of(host), pre_mkl);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 10);
        deploy_pre_mkl_from_growth_fund(host, address_of(host), 1000000);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 2000000, 0);

        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);

        let user_pre_mkl = withdraw_from_user(address_of(host), 500000);
        let mkl = swap_pre_mkl_to_mkl_with_fa(host, user_pre_mkl);
        assert!(fungible_asset::amount(&mkl) == 500000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);
        {
            let growth_fund_resource = borrow_global<GrowthFundResource>(@merkle);
            let growth_fund_receipt = table::borrow(&growth_fund_resource.user, address_of(host));
            assert!(growth_fund_receipt.initial_amount == 1000000, 0);
            assert!(growth_fund_receipt.swapped_amount == 500000, 0);
        };
        let user_pre_mkl = withdraw_from_user(address_of(host), 1000000);
        let mkl = swap_pre_mkl_to_mkl_with_fa(host, user_pre_mkl);
        assert!(fungible_asset::amount(&mkl) == 1000000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 500000, 0);
        {
            let growth_fund_resource = borrow_global<GrowthFundResource>(@merkle);
            let growth_fund_receipt = table::borrow(&growth_fund_resource.user, address_of(host));
            assert!(growth_fund_receipt.initial_amount == 1000000, 0);
            assert!(growth_fund_receipt.swapped_amount == 1000000, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_admin_swap_vemkl_premkl_to_mkl(host: &signer, aptos_framework: &signer)
    acquires PoolStore, PreMklConfig, GrowthFundResource {
        call_test_setting(host, aptos_framework);
        let cap = mint_claim_capability(host);
        let pre_mkl = claim_pre_mkl_with_cap(&cap, 100000);
        deposit_user_pre_mkl(host, pre_mkl);

        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 10);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);

        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 100000, 0);
        admin_swap_premkl_to_mkl(host, address_of(host));
        assert!(primary_fungible_store::balance(address_of(host), get_metadata()) == 0, 0);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 100000, 0);
    }
}