module merkle::vesting {
    use std::signer::address_of;
    use aptos_framework::fungible_asset::{Self, FungibleAsset};
    use aptos_framework::timestamp;

    use merkle::claimable_fa_store;
    use merkle::safe_math::{safe_mul_div, min};

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When deposit amount too small
    const E_TOO_SMALL_DEPOSIT_AMOUNT: u64 = 1;
    /// When not enough claimable
    const E_NOT_ENOUGH_CLAIMABLE: u64 = 2;
    /// When custom vesting paused. contact the team.
    const E_PAUSED: u64 = 3;
    /// When create with invalid end time
    const E_INVALID_START_END_SEC: u64 = 4;
    /// When create with invalid initial amount
    const E_INVALID_INITIAL_AMOUNT: u64 = 5;
    /// When already vesting finished but call cancel
    const E_VESTING_ALREADY_FINISHED: u64 = 6;

    struct VestingConfig has key {
        next_uid: u64
    }

    struct VestingPlan has store, drop {
        uid: u64,
        user: address,
        start_at_sec: u64,
        end_at_sec: u64,
        initial_amount: u64,
        total_amount: u64,
        claimed_amount: u64,
        paused: bool,
        claimable_fa_store_claim_cap: claimable_fa_store::ClaimCapability
    }

    struct ClaimCapability has store, drop {
        uid: u64
    }

    struct AdminCapability has store, drop {
        uid: u64
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if (!exists<VestingConfig>(address_of(_admin))) {
            move_to(_admin, VestingConfig {
                next_uid: 1,
            })
        };
    }

    public fun create(
        _user_address: address,
        _start_at_sec: u64,
        _end_at_sec: u64,
        _initial_amount: u64,
        _total_amount: u64,
        _claimable_fa_store_claim_cap: claimable_fa_store::ClaimCapability
    ): (VestingPlan, ClaimCapability, AdminCapability)
    acquires VestingConfig {
        let now = timestamp::now_seconds();
        assert!(now < _end_at_sec && _start_at_sec < _end_at_sec , E_INVALID_START_END_SEC);
        assert!(_initial_amount <= _total_amount, E_INVALID_INITIAL_AMOUNT);
        let config = borrow_global_mut<VestingConfig>(@merkle);
        let uid = config.next_uid;
        let vesting_plan = VestingPlan {
            uid,
            user: _user_address,
            start_at_sec: _start_at_sec,
            end_at_sec: _end_at_sec,
            initial_amount: _initial_amount,
            total_amount: _total_amount,
            claimed_amount: 0,
            paused: false,
            claimable_fa_store_claim_cap: _claimable_fa_store_claim_cap
        };
        config.next_uid = config.next_uid + 1;
        (vesting_plan, ClaimCapability { uid }, AdminCapability { uid })
    }

    public fun get_vesting_plan_data(_vesting_plan: &VestingPlan): (u64, address, u64, u64, u64, u64, u64, bool) {
        (
            _vesting_plan.uid,
            _vesting_plan.user,
            _vesting_plan.start_at_sec,
            _vesting_plan.end_at_sec,
            _vesting_plan.initial_amount,
            _vesting_plan.total_amount,
            _vesting_plan.claimed_amount,
            _vesting_plan.paused,
        )
    }

    public fun get_claimable(_vesting_plan: &VestingPlan): u64 {
        let now = timestamp::now_seconds();
        if (_vesting_plan.paused || now < _vesting_plan.start_at_sec) {
            return 0
        };
        _vesting_plan.initial_amount + safe_mul_div(
            _vesting_plan.total_amount - _vesting_plan.initial_amount,
            min(now, _vesting_plan.end_at_sec) - min(now, _vesting_plan.start_at_sec),
            (_vesting_plan.end_at_sec - _vesting_plan.start_at_sec)
        ) - _vesting_plan.claimed_amount
    }

    public fun claim(_vesting_plan: &mut VestingPlan, _claim_cap: &ClaimCapability): FungibleAsset {
        assert!(!_vesting_plan.paused, E_PAUSED);
        assert!(_vesting_plan.uid == _claim_cap.uid, E_NOT_AUTHORIZED);

        let claimable = get_claimable(_vesting_plan);
        assert!(claimable > 0, E_NOT_ENOUGH_CLAIMABLE);
        claim_internal(_vesting_plan, claimable)
    }

    fun claim_internal(_vesting_plan: &mut VestingPlan, _amount: u64): FungibleAsset {
        _vesting_plan.claimed_amount = _vesting_plan.claimed_amount + _amount;
        claimable_fa_store::claim_funding_store(&_vesting_plan.claimable_fa_store_claim_cap, _amount)
    }

    public fun cancel(_vesting_plan: VestingPlan, _claim_cap: ClaimCapability, _admin_cap: AdminCapability): (FungibleAsset, u64) {
        assert!(!_vesting_plan.paused, E_PAUSED);
        assert!(_vesting_plan.uid == _claim_cap.uid && _vesting_plan.uid == _admin_cap.uid, E_NOT_AUTHORIZED);
        let claimable = get_claimable(&_vesting_plan);
        let claimed_asset = fungible_asset::zero(claimable_fa_store::get_metadata_by_uid(&_vesting_plan.claimable_fa_store_claim_cap));
        if (claimable > 0) {
            fungible_asset::merge(&mut claimed_asset, claim_internal(&mut _vesting_plan, claimable));
        };
        let cancel_amount = _vesting_plan.total_amount - _vesting_plan.claimed_amount;
        assert!(cancel_amount > 0, E_VESTING_ALREADY_FINISHED);

        (claimed_asset, cancel_amount)
    }

    public fun pause(_vesting_plan: &mut VestingPlan, _admin_cap: &AdminCapability) {
        assert!(_vesting_plan.uid == _admin_cap.uid, E_NOT_AUTHORIZED);
        _vesting_plan.paused = true;
    }

    public fun unpause(_vesting_plan: &mut VestingPlan, _admin_cap: &AdminCapability) {
        assert!(_vesting_plan.uid == _admin_cap.uid, E_NOT_AUTHORIZED);
        _vesting_plan.paused = false;
    }

    public fun change_claim_cap(_vesting_plan: &mut VestingPlan, _admin_cap: &AdminCapability, _claim_cap: claimable_fa_store::ClaimCapability) {
        assert!(_vesting_plan.uid == _admin_cap.uid, E_NOT_AUTHORIZED);
        _vesting_plan.claimable_fa_store_claim_cap = _claim_cap;
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use std::features;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::primary_fungible_store;
    #[test_only]
    use merkle::mkl_token;

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
        initialize_module(host);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 86400 * 365);

        let mkl = mkl_token::claim_mkl_with_cap(&mkl_token::mint_claim_capability<mkl_token::COMMUNITY_POOL>(host), 10000000000);
        primary_fungible_store::deposit(address_of(host), mkl);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module_exist_resource(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
        initialize_module(host);
    }

    #[test(host = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_initialize_module_error_not_authorized(host: &signer) {
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_create(host: &signer, aptos_framework: &signer, user: &signer)
    acquires VestingConfig {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(user));

        let admin_cap = claimable_fa_store::add_claimable_fa_store(host, mkl_token::get_metadata());
        claimable_fa_store::deposit_funding_store_with_admin_cap(host, &admin_cap, 10000000000);

        let (vesting_plan, _, _) = create(
            address_of(user),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 6000,
            0,
            10000000,
            claimable_fa_store::mint_claim_capability(&admin_cap)
        );
        assert!(vesting_plan.start_at_sec == timestamp::now_seconds(), 0);
        assert!(vesting_plan.end_at_sec == timestamp::now_seconds() + 6000, 0);
        assert!(vesting_plan.initial_amount == 0, 0);
        assert!(vesting_plan.total_amount == 10000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_get_claimable(host: &signer, aptos_framework: &signer, user: &signer)
    acquires VestingConfig {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(user));

        let admin_cap = claimable_fa_store::add_claimable_fa_store(host, mkl_token::get_metadata());
        claimable_fa_store::deposit_funding_store_with_admin_cap(host, &admin_cap, 10000000000);

        let (vesting_plan, _, _) = create(
            address_of(user),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 6000,
            0,
            10000000,
            claimable_fa_store::mint_claim_capability(&admin_cap)
        );
        assert!(get_claimable(&vesting_plan) == 0, 0);
        timestamp::fast_forward_seconds(3000);
        assert!(get_claimable(&vesting_plan) == 5000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_claim(host: &signer, aptos_framework: &signer, user: &signer)
    acquires VestingConfig {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(user));

        let admin_cap = claimable_fa_store::add_claimable_fa_store(host, mkl_token::get_metadata());
        claimable_fa_store::deposit_funding_store_with_admin_cap(host, &admin_cap, 10000000000);

        let (vesting_plan, claim_cap, _) = create(
            address_of(user),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 6000,
            0,
            10000000,
            claimable_fa_store::mint_claim_capability(&admin_cap)
        );
        timestamp::fast_forward_seconds(3000);
        let claimable = get_claimable(&vesting_plan);
        let mkl = claim(&mut vesting_plan, &claim_cap);
        assert!(fungible_asset::amount(&mkl) == claimable, 0);
        timestamp::fast_forward_seconds(13000);
        let mkl2 = claim(&mut vesting_plan, &claim_cap);
        assert!(fungible_asset::amount(&mkl2) + fungible_asset::amount(&mkl2) == 10000000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);
        primary_fungible_store::deposit(address_of(host), mkl2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_cancel(host: &signer, aptos_framework: &signer, user: &signer)
    acquires VestingConfig {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(user));

        let admin_cap = claimable_fa_store::add_claimable_fa_store(host, mkl_token::get_metadata());
        claimable_fa_store::deposit_funding_store_with_admin_cap(host, &admin_cap, 10000000000);

        let (vesting_plan, claim_cap, admin_cap) = create(
            address_of(user),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 6000,
            0,
            10000000,
            claimable_fa_store::mint_claim_capability(&admin_cap)
        );
        timestamp::fast_forward_seconds(3000);
        let (claimed, cancel) = cancel(vesting_plan, claim_cap, admin_cap);
        assert!(fungible_asset::amount(&claimed) == 5000000, 0);
        assert!(cancel == 5000000, 0);
        primary_fungible_store::deposit(address_of(user), claimed);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_cancel_with_initial_amount(host: &signer, aptos_framework: &signer, user: &signer)
    acquires VestingConfig {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(user));

        let admin_cap = claimable_fa_store::add_claimable_fa_store(host, mkl_token::get_metadata());
        claimable_fa_store::deposit_funding_store_with_admin_cap(host, &admin_cap, 10000000000);

        let (vesting_plan, claim_cap, admin_cap) = create(
            address_of(user),
            timestamp::now_seconds(),
            timestamp::now_seconds() + 6000,
            1000000,
            10000000,
            claimable_fa_store::mint_claim_capability(&admin_cap)
        );
        timestamp::fast_forward_seconds(3000);
        let (claimed, cancel) = cancel(vesting_plan, claim_cap, admin_cap);
        assert!(fungible_asset::amount(&claimed) == 5500000, 0);
        assert!(cancel == 4500000, 0);
        primary_fungible_store::deposit(address_of(user), claimed);
    }
}