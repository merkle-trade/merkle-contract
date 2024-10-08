module merkle::liquidity_auction {

    use std::bcs;
    use std::signer::address_of;
    use aptos_std::table;
    use aptos_std::type_info;
    use aptos_framework::account::{Self, new_event_handle};
    use aptos_framework::aptos_account;
    use aptos_framework::coin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::fungible_asset::{Self, FungibleStore};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_framework::transaction_context;

    use merkle::mkl_token::{Self, MKL};
    use merkle::safe_math::{safe_mul_div, min};
    use merkle::pre_mkl_token;

    use liquidswap_v05::scripts;
    use liquidswap_v05::curves::Uncorrelated;
    use liquidswap_lp::lp_coin::LP;
    use liquidswap_v05::liquidity_pool;
    use liquidswap_v05::router;

    const DAY_SECONDS: u64 = 86400;
    const LBA_START_AT_SEC: u64 = 1724932800; // 2024-08-29T12:00:00Z
    const LBA_END_AT_SEC: u64 = 1724932800 + 86400 * 7; // 2024-09-05T12:00:00Z
    const LBA_DEPOSIT_DURATION_SEC: u64 = 86400 * 5; // 5 days
    const LP_VESTING_DURATION_SEC: u64 = 86400 * 120; // 120 days
    const MKL_REWARD_AMOUNT: u64 = 1_000_000_000000;

    /// signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// deposit amount exceed reward amount
    const E_REWARD_AMOUNT_EXCEEDED: u64 = 2;
    /// withdraw amount exceed deposit amount
    const E_WITHDRAW_AMOUNT_EXCEEDED: u64 = 3;
    /// Currently, it's not LBA deposit time.
    const E_LBA_DEPOSIT_NOW_ALLOWED: u64 = 4;
    /// Currently, it's not LBA withdrawal time.
    const E_LBA_WITHDRAW_NOW_ALLOWED: u64 = 5;
    /// When an invalid user makes a request
    const E_INVALID_USER: u64 = 6;
    /// When amount too small
    const E_AMOUNT_TOO_SMALL: u64 = 7;

    struct PoolInfo<phantom AssetType> has key {
        user_infos: table::Table<address, UserInfo>,
        pre_mkl: Object<FungibleStore>,
        total_pre_mkl_deposit_amount: u64,
        asset_vault: coin::Coin<AssetType>,
        total_asset_deposit_amount: u64
    }

    struct LpInfo<phantom AssetType> has key {
        lp_vault: coin::Coin<LP<MKL, AssetType, Uncorrelated>>,
        total_lp_amount: u64,
        mkl_reward_vault: Object<FungibleStore>
    }

    struct UserInfo has store, drop {
        pre_mkl_deposit_amount: u64,
        asset_deposit_amount: u64,
        phase1_asset_deposit_amount: u64,
        lp_withdraw_amount: u64,
        last_claimed_at: u64
    }

    struct LiquidityAuctionEvents has key {
        deposit_pre_mkl_events: EventHandle<DepositPreMklEvent>,
        deposit_asset_events: EventHandle<DepositAssetEvent>,
        withdraw_asset_events: EventHandle<WithdrawAssetEvent>
    }

    struct DepositPreMklEvent has store, drop {
        pre_mkl_deposit_amount: u64,
        total_pre_mkl_deposit_amount: u64
    }

    struct DepositAssetEvent has store, drop {
        asset_type: type_info::TypeInfo,
        asset_deposit_amount: u64,
        phase1_asset_deposit_amount: u64
    }

    struct WithdrawAssetEvent has store, drop {
        asset_type: type_info::TypeInfo,
        asset_withdraw_amount: u64,
        asset_total_amount: u64,
        phase1_asset_deposit_amount: u64
    }

    public fun initialize_module<AssetType>(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if (!exists<PoolInfo<AssetType>>(address_of(_admin))) {
            let constructor_ref = object::create_object(address_of(_admin));
            let store = fungible_asset::create_store(&constructor_ref, pre_mkl_token::get_metadata());
            move_to(_admin, PoolInfo<AssetType> {
                user_infos: table::new<address, UserInfo>(),
                pre_mkl: store,
                total_pre_mkl_deposit_amount: 0,
                asset_vault: coin::zero<AssetType>(),
                total_asset_deposit_amount: 0
            });
        };

        if (!exists<LiquidityAuctionEvents>(address_of(_admin))) {
            move_to(_admin, LiquidityAuctionEvents {
                deposit_pre_mkl_events: new_event_handle<DepositPreMklEvent>(_admin),
                deposit_asset_events: new_event_handle<DepositAssetEvent>(_admin),
                withdraw_asset_events: new_event_handle<WithdrawAssetEvent>(_admin)
            });
        };
    }

    public fun get_lba_schedule(): (u64, u64, u64) {
        (LBA_START_AT_SEC, LBA_END_AT_SEC, LBA_END_AT_SEC + LP_VESTING_DURATION_SEC)
    }

    public fun deposit_pre_mkl<AssetType>(_user: &signer, _pre_mkl_deposit_amount: u64)
    acquires PoolInfo, LiquidityAuctionEvents {
        assert!(_pre_mkl_deposit_amount >= 10000, E_AMOUNT_TOO_SMALL);
        let now = timestamp::now_seconds();
        assert!(LBA_START_AT_SEC <= now && now <= LBA_START_AT_SEC + LBA_DEPOSIT_DURATION_SEC, E_LBA_DEPOSIT_NOW_ALLOWED);

        let user_address = address_of(_user);
        let pool_info = borrow_global_mut<PoolInfo<AssetType>>(@merkle);
        let user_info = table::borrow_mut_with_default(&mut pool_info.user_infos, user_address, UserInfo {
            pre_mkl_deposit_amount: 0,
            asset_deposit_amount: 0,
            phase1_asset_deposit_amount: 0,
            lp_withdraw_amount: 0,
            last_claimed_at: LBA_END_AT_SEC
        });
        user_info.pre_mkl_deposit_amount = user_info.pre_mkl_deposit_amount + _pre_mkl_deposit_amount;
        pool_info.total_pre_mkl_deposit_amount = pool_info.total_pre_mkl_deposit_amount + _pre_mkl_deposit_amount;

        let pre_mkl = pre_mkl_token::withdraw_from_user(
            address_of(_user),
            _pre_mkl_deposit_amount
        );
        fungible_asset::deposit(pool_info.pre_mkl, pre_mkl);

        event::emit_event(&mut borrow_global_mut<LiquidityAuctionEvents>(@merkle).deposit_pre_mkl_events, DepositPreMklEvent {
            pre_mkl_deposit_amount: _pre_mkl_deposit_amount,
            total_pre_mkl_deposit_amount: user_info.pre_mkl_deposit_amount
        });
    }

    public fun deposit_asset<AssetType>(_user: &signer, _asset_deposit_amount: u64)
    acquires PoolInfo, LiquidityAuctionEvents {
        assert!(_asset_deposit_amount >= 10000, E_AMOUNT_TOO_SMALL);
        let now = timestamp::now_seconds();
        assert!(LBA_START_AT_SEC <= now && now <= LBA_START_AT_SEC + LBA_DEPOSIT_DURATION_SEC, E_LBA_DEPOSIT_NOW_ALLOWED);

        let user_address = address_of(_user);
        let pool_info = borrow_global_mut<PoolInfo<AssetType>>(@merkle);
        let user_info = table::borrow_mut_with_default(&mut pool_info.user_infos, user_address, UserInfo {
            pre_mkl_deposit_amount: 0,
            asset_deposit_amount: 0,
            phase1_asset_deposit_amount: 0,
            lp_withdraw_amount: 0,
            last_claimed_at: LBA_END_AT_SEC
        });
        user_info.asset_deposit_amount = user_info.asset_deposit_amount + _asset_deposit_amount;
        user_info.phase1_asset_deposit_amount = user_info.asset_deposit_amount;
        pool_info.total_asset_deposit_amount = pool_info.total_asset_deposit_amount + _asset_deposit_amount;

        let asset = coin::withdraw<AssetType>(_user, _asset_deposit_amount);
        coin::merge(&mut pool_info.asset_vault, asset);

        event::emit_event(&mut borrow_global_mut<LiquidityAuctionEvents>(@merkle).deposit_asset_events, DepositAssetEvent {
            asset_type: type_info::type_of<AssetType>(),
            asset_deposit_amount: _asset_deposit_amount,
            phase1_asset_deposit_amount: user_info.phase1_asset_deposit_amount
        });
    }

    public fun withdraw_asset<AssetType>(_user: &signer, _asset_withdraw_amount: u64)
    acquires PoolInfo, LiquidityAuctionEvents {
        let now = timestamp::now_seconds();
        assert!(LBA_START_AT_SEC <= now && now <= LBA_END_AT_SEC, E_LBA_WITHDRAW_NOW_ALLOWED);

        let user_address = address_of(_user);
        let pool_info = borrow_global_mut<PoolInfo<AssetType>>(@merkle);
        assert!(table::contains(&pool_info.user_infos, user_address), E_INVALID_USER);

        let user_info = table::borrow_mut(&mut pool_info.user_infos, user_address);
        let withdraw_amount = _asset_withdraw_amount;
        if (_asset_withdraw_amount > user_info.asset_deposit_amount) {
            withdraw_amount = user_info.asset_deposit_amount;
        };
        let withdrawed_amount = user_info.phase1_asset_deposit_amount - user_info.asset_deposit_amount;
        if (now <= LBA_START_AT_SEC + LBA_DEPOSIT_DURATION_SEC) {
            // phase 1, no limits
            user_info.phase1_asset_deposit_amount = user_info.phase1_asset_deposit_amount - withdraw_amount;
        } else if (now <= LBA_START_AT_SEC + LBA_DEPOSIT_DURATION_SEC + DAY_SECONDS) {
            // phase 2, 50%
            let withdrawable = user_info.phase1_asset_deposit_amount / 2;
            if (withdrawable < withdrawed_amount + withdraw_amount) {
                withdraw_amount = withdrawable - withdrawed_amount;
            };
        } else if (now <= LBA_END_AT_SEC) {
            // phase 3, linear decrease
            let time_left = LBA_END_AT_SEC - now;
            let withdrawable = (user_info.phase1_asset_deposit_amount / 2) * time_left / DAY_SECONDS;
            if (withdrawable < withdrawed_amount + withdraw_amount) {
                withdraw_amount = if (withdrawed_amount < withdrawable) {
                    withdrawable - withdrawed_amount
                } else {
                    0
                };
            };
        };
        assert!(withdraw_amount > 0, E_WITHDRAW_AMOUNT_EXCEEDED);
        let asset = coin::extract(&mut pool_info.asset_vault, withdraw_amount);
        aptos_account::deposit_coins(user_address, asset);
        user_info.asset_deposit_amount = user_info.asset_deposit_amount - withdraw_amount;
        assert!(user_info.asset_deposit_amount == 0 || user_info.asset_deposit_amount >= 10000, E_AMOUNT_TOO_SMALL);
        pool_info.total_asset_deposit_amount = pool_info.total_asset_deposit_amount - withdraw_amount;

        event::emit_event(&mut borrow_global_mut<LiquidityAuctionEvents>(@merkle).withdraw_asset_events, WithdrawAssetEvent {
            asset_type: type_info::type_of<AssetType>(),
            asset_withdraw_amount: withdraw_amount,
            asset_total_amount: user_info.asset_deposit_amount,
            phase1_asset_deposit_amount: user_info.phase1_asset_deposit_amount
        });

        if (user_info.asset_deposit_amount == 0 && user_info.pre_mkl_deposit_amount == 0) {
            table::remove(&mut pool_info.user_infos, user_address);
        };
    }

    // <--- Post LBA --->
    public fun run_tge_sequence<AssetType>(_admin: &signer)
    acquires PoolInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if (!coin::is_coin_initialized<MKL>()) {
            // Create an mkl token coin object and pair it with a fungible asset.
            // Previously initialized with a fungible asset, but due to Coin <> FA migration, we need to initialize once again.
            mkl_token::initialize_module(_admin);
        };
        // Mint mkl token for each pool
        mkl_token::run_token_generation_event(_admin);

        // extract preMKL and zUSDC from resource
        // deposit to admin for register LP pool
        let pool_info = borrow_global_mut<PoolInfo<AssetType>>(@merkle);
        let pre_mkl = pre_mkl_token::withdraw_from_freezed_pre_mkl_store(&pool_info.pre_mkl, pool_info.total_pre_mkl_deposit_amount);
        if (!coin::is_account_registered<MKL>(address_of(_admin))) {
            coin::register<MKL>(_admin);
        };
        let mkl = pre_mkl_token::burn_pre_mkl_claim_mkl(pre_mkl);
        let mkl_amount = fungible_asset::amount(&mkl);
        primary_fungible_store::deposit(address_of(_admin), mkl);
        let asset = coin::extract_all(&mut pool_info.asset_vault);
        let asset_amount = coin::value(&asset);
        aptos_account::deposit_coins(address_of(_admin), asset);

        // make amm lp pool with mkl, zUSDC
        if (!liquidity_pool::is_pool_exists<MKL, AssetType, Uncorrelated>()) {
            router::register_pool<MKL, AssetType, Uncorrelated>(_admin);
        };
        scripts::add_liquidity<MKL, AssetType, Uncorrelated>(
            _admin,
            mkl_amount,
            mkl_amount,
            asset_amount,
            asset_amount
        );

        let total_lp_amount = coin::balance<LP<MKL, AssetType, Uncorrelated>>(address_of(_admin));
        let lp_token = coin::withdraw<LP<MKL, AssetType, Uncorrelated>>(_admin, total_lp_amount);

        let mkl_cap = mkl_token::mint_claim_capability<mkl_token::GROWTH_POOL>(_admin);
        let mkl_reward = mkl_token::claim_mkl_with_cap(&mkl_cap, MKL_REWARD_AMOUNT);
        let (resource_signer, _) = account::create_resource_account(_admin, bcs::to_bytes(&transaction_context::generate_auid_address()));
        let fungible_store = primary_fungible_store::ensure_primary_store_exists(address_of(&resource_signer), mkl_token::get_metadata());
        fungible_asset::deposit(fungible_store, mkl_reward);

        move_to(_admin, LpInfo<AssetType> {
            lp_vault: lp_token,
            total_lp_amount,
            mkl_reward_vault: fungible_store
        });
    }

    public fun withdraw_remaining_reward<AssetType>(_admin: &signer)
    acquires LpInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let lp_info = borrow_global_mut<LpInfo<AssetType>>(@merkle);
        let amount = fungible_asset::balance(lp_info.mkl_reward_vault);
        let mkl = mkl_token::withdraw_from_freezed_mkl_store(&lp_info.mkl_reward_vault, amount);
        primary_fungible_store::deposit(address_of(_admin), mkl);
    }

    public fun get_user_initial_lp_amount<AssetType>(_user_address: address): u64
    acquires PoolInfo, LpInfo {
        let lp_info = borrow_global<LpInfo<AssetType>>(@merkle);
        let pool_info = borrow_global<PoolInfo<AssetType>>(@merkle);
        if (!table::contains(&pool_info.user_infos, _user_address)) {
            return 0
        };

        let user_info = table::borrow(&pool_info.user_infos, _user_address);
        let mkl_portion = safe_mul_div(lp_info.total_lp_amount, user_info.pre_mkl_deposit_amount, (pool_info.total_pre_mkl_deposit_amount * 2));
        let asset_portion = safe_mul_div(lp_info.total_lp_amount, user_info.asset_deposit_amount, (pool_info.total_asset_deposit_amount * 2));
        mkl_portion + asset_portion
    }

    public fun get_vested_lp_amount(_initial_lp_amount: u64): u64 {
        let now = timestamp::now_seconds();
        if (now < LBA_END_AT_SEC + LP_VESTING_DURATION_SEC / 2) {
            return 0
        };
        let amount = _initial_lp_amount / 3;
        let duration = min(now - (LBA_END_AT_SEC + LP_VESTING_DURATION_SEC / 2), LP_VESTING_DURATION_SEC / 2);
        amount = amount + safe_mul_div(_initial_lp_amount - amount, duration, LP_VESTING_DURATION_SEC / 2);
        amount
    }

    public fun get_user_withdrawable_lp_amount<AssetType>(_user_address: address): u64
    acquires PoolInfo, LpInfo {
        let initial_lp_amount = get_user_initial_lp_amount<AssetType>(_user_address);
        let vested_lp_amount = get_vested_lp_amount(initial_lp_amount);

        let pool_info = borrow_global<PoolInfo<AssetType>>(@merkle);
        let user_info = table::borrow(&pool_info.user_infos, _user_address);
        vested_lp_amount - user_info.lp_withdraw_amount
    }

    public fun withdraw_lp<AssetType>(_user: &signer, _lp_withdraw_amount: u64)
    acquires PoolInfo, LpInfo {
        assert!(_lp_withdraw_amount > 0, E_AMOUNT_TOO_SMALL);
        claim_mkl_reward<AssetType>(_user);
        let withdrawable_lp_amount = get_user_withdrawable_lp_amount<AssetType>(address_of(_user));

        if (_lp_withdraw_amount > withdrawable_lp_amount) {
            _lp_withdraw_amount = withdrawable_lp_amount;
        };
        let pool_info = borrow_global_mut<PoolInfo<AssetType>>(@merkle);
        let user_info = table::borrow_mut(&mut pool_info.user_infos, address_of(_user));
        user_info.lp_withdraw_amount = user_info.lp_withdraw_amount + _lp_withdraw_amount;
        let lp_info = borrow_global_mut<LpInfo<AssetType>>(@merkle);
        aptos_account::deposit_coins(address_of(_user), coin::extract(&mut lp_info.lp_vault, _lp_withdraw_amount));
    }

    public fun get_claimable_mkl_reward<AssetType>(_user_address: address): u64
    acquires PoolInfo, LpInfo {
        let initial_lp_amount = get_user_initial_lp_amount<AssetType>(_user_address);
        let lp_info = borrow_global<LpInfo<AssetType>>(@merkle);
        let pool_info = borrow_global<PoolInfo<AssetType>>(@merkle);
        if (!table::contains(&pool_info.user_infos, _user_address)) {
            return 0
        };
        let user_info = table::borrow(&pool_info.user_infos, _user_address);
        let lp_amount = initial_lp_amount - user_info.lp_withdraw_amount;
        let now = timestamp::now_seconds();
        let duration = min(
            LP_VESTING_DURATION_SEC,
            min(
                now,
                LBA_END_AT_SEC + LP_VESTING_DURATION_SEC) - min(
                now,
                min(
                    user_info.last_claimed_at,
                    LBA_END_AT_SEC + LP_VESTING_DURATION_SEC)
            )
        );

        safe_mul_div(safe_mul_div(MKL_REWARD_AMOUNT, duration, LP_VESTING_DURATION_SEC), lp_amount, lp_info.total_lp_amount)
    }

    public fun claim_mkl_reward<AssetType>(_user: &signer)
    acquires PoolInfo, LpInfo {
        let user_address = address_of(_user);
        let claimable_mkl_reward = get_claimable_mkl_reward<AssetType>(user_address);

        let pool_info = borrow_global_mut<PoolInfo<AssetType>>(@merkle);
        let user_info = table::borrow_mut(&mut pool_info.user_infos, user_address);
        user_info.last_claimed_at = timestamp::now_seconds();

        let lp_info = borrow_global<LpInfo<AssetType>>(@merkle);
        let mkl = mkl_token::withdraw_from_freezed_mkl_store(&lp_info.mkl_reward_vault, claimable_mkl_reward);
        primary_fungible_store::deposit(user_address, mkl);
    }

    // <--- test --->
    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use std::features;
    #[test_only]
    use test_helpers::test_pool;

    #[test_only]
    struct USDC {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_new_accounts_default_to_fa_apt_store_feature()], vector[]);

        let (bc, fc, mc) = coin::initialize<USDC>(host,
            string::utf8(b"USDC"),
            string::utf8(b"USDC"),
            6,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<USDC>(host);
        coin::deposit(address_of(host), coin::mint<USDC>(10000000000, &mc));
        coin::destroy_mint_cap(mc);

        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);
        timestamp::fast_forward_seconds(pre_mkl_token::pre_mkl_tge_at());

        initialize_module<USDC>(host);

        let pre_mkl = pre_mkl_token::claim_pre_mkl_with_cap(&pre_mkl_token::mint_claim_capability(host), 10000000);
        pre_mkl_token::deposit_user_pre_mkl_for_testing(host, pre_mkl);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize(host: &signer, aptos_framework: &signer)
    acquires PoolInfo {
        call_test_setting(host, aptos_framework);
        let pool_info = borrow_global<PoolInfo<USDC>>(address_of(host));
        assert!(fungible_asset::balance(pool_info.pre_mkl) == 0, 0);
        assert!(coin::value(&pool_info.asset_vault) == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_LBA_DEPOSIT_NOW_ALLOWED, location = Self)]
    fun T_E_LBA_DEPOSIT_NOW_ALLOWED(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        deposit_pre_mkl<USDC>(host, 100000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_deposit_mkl(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_pre_mkl<USDC>(host, 1000000);

        let pool_info = borrow_global<PoolInfo<USDC>>(address_of(host));
        let user_info = table::borrow(&pool_info.user_infos, address_of(host));
        assert!(user_info.pre_mkl_deposit_amount == 1000000, 0);
        assert!(user_info.asset_deposit_amount == 0, 0);
        assert!(user_info.phase1_asset_deposit_amount == 0, 0);
        assert!(fungible_asset::balance(pool_info.pre_mkl) == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_deposit_asset(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);

        let pool_info = borrow_global<PoolInfo<USDC>>(address_of(host));
        let user_info = table::borrow(&pool_info.user_infos, address_of(host));
        assert!(user_info.pre_mkl_deposit_amount == 0, 0);
        assert!(user_info.asset_deposit_amount == 1000000, 0);
        assert!(user_info.phase1_asset_deposit_amount == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_deposit_withdraw_asset(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        withdraw_asset<USDC>(host, 100000);

        let pool_info = borrow_global<PoolInfo<USDC>>(address_of(host));
        let user_info = table::borrow(&pool_info.user_infos, address_of(host));
        assert!(user_info.pre_mkl_deposit_amount == 0, 0);
        assert!(user_info.asset_deposit_amount == 900000, 0);
        assert!(user_info.phase1_asset_deposit_amount == 900000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_LBA_WITHDRAW_NOW_ALLOWED, location = Self)]
    fun T_E_LBA_WITHDRAW_NOW_ALLOWED(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        timestamp::fast_forward_seconds(DAY_SECONDS * 8);
        withdraw_asset<USDC>(host, 100000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_withdraw_bigger_than_deposit(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        let prev_balance = coin::balance<USDC>(address_of(host));
        withdraw_asset<USDC>(host, 1000001);
        assert!(coin::balance<USDC>(address_of(host)) - prev_balance == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_deposit_withdraw_asset_half(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        timestamp::fast_forward_seconds(LBA_DEPOSIT_DURATION_SEC);
        withdraw_asset<USDC>(host, 500000);

        let pool_info = borrow_global<PoolInfo<USDC>>(address_of(host));
        let user_info = table::borrow(&pool_info.user_infos, address_of(host));
        assert!(user_info.pre_mkl_deposit_amount == 0, 0);
        assert!(user_info.asset_deposit_amount == 500000, 0);
        assert!(user_info.phase1_asset_deposit_amount == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_withdraw_bigger_than_deposit_half(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        timestamp::fast_forward_seconds(LBA_DEPOSIT_DURATION_SEC);
        let prev_balance = coin::balance<USDC>(address_of(host));
        withdraw_asset<USDC>(host, 500001);
        assert!(coin::balance<USDC>(address_of(host)) - prev_balance == 500000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_deposit_withdraw_asset_linear_decrease(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        timestamp::fast_forward_seconds(LBA_DEPOSIT_DURATION_SEC + DAY_SECONDS * 3 / 2);
        withdraw_asset<USDC>(host, 250000);

        let pool_info = borrow_global<PoolInfo<USDC>>(address_of(host));
        let user_info = table::borrow(&pool_info.user_infos, address_of(host));
        assert!(user_info.pre_mkl_deposit_amount == 0, 0);
        assert!(user_info.asset_deposit_amount == 750000, 0);
        assert!(user_info.phase1_asset_deposit_amount == 1000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_withdraw_bigger_than_deposit_linear(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        timestamp::fast_forward_seconds(LBA_DEPOSIT_DURATION_SEC + DAY_SECONDS * 3 / 2);
        let prev_balance = coin::balance<USDC>(address_of(host));
        withdraw_asset<USDC>(host, 250001);
        assert!(coin::balance<USDC>(address_of(host)) - prev_balance == 250000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_WITHDRAW_AMOUNT_EXCEEDED, location = Self)]
    fun T_E_WITHDRAW_AMOUNT_EXCEEDED_linear_decrease2(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - pre_mkl_token::pre_mkl_tge_at());
        deposit_asset<USDC>(host, 1000000);
        timestamp::fast_forward_seconds(LBA_DEPOSIT_DURATION_SEC);
        withdraw_asset<USDC>(host, 500000);
        timestamp::fast_forward_seconds(DAY_SECONDS * 3 / 2);
        withdraw_asset<USDC>(host, 10000);
    }

    // <--- Post LBA test --->
    #[test_only]
    fun set_lp_info<AssetType>(_admin: &signer, _liquidswap: &signer) {
        timestamp::fast_forward_seconds(LBA_END_AT_SEC - timestamp::now_seconds());

        let (bc, fc, mc) = coin::initialize<LP<MKL, AssetType, Uncorrelated>>(
            _liquidswap,
            string::utf8(b"LP"),
            string::utf8(b"LP"),
            6,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<LP<MKL, AssetType, Uncorrelated>>(_admin);

        mkl_token::initialize_module(_admin);
        mkl_token::run_token_generation_event(_admin);
        let mkl_cap = mkl_token::mint_claim_capability<mkl_token::GROWTH_POOL>(_admin);
        let mkl_reward = mkl_token::claim_mkl_with_cap(&mkl_cap, MKL_REWARD_AMOUNT);
        let (resource_signer, _) = account::create_resource_account(_admin, bcs::to_bytes(&transaction_context::generate_auid_address()));
        let fungible_store = primary_fungible_store::ensure_primary_store_exists(address_of(&resource_signer), mkl_token::get_metadata());
        fungible_asset::deposit(fungible_store, mkl_reward);

        move_to(_admin, LpInfo<AssetType> {
            lp_vault: coin::mint<LP<MKL, AssetType, Uncorrelated>>(10000000000, &mc),
            total_lp_amount: 10000000000,
            mkl_reward_vault: fungible_store
        });
        coin::destroy_mint_cap(mc);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, liquidswap = @liquidswap_lp)]
    fun T_set_lp_info(host: &signer, aptos_framework: &signer, liquidswap: &signer) {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - timestamp::now_seconds());
        set_lp_info<USDC>(host, liquidswap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE, liquidswap = @liquidswap_lp)]
    fun T_withdraw_lp(host: &signer, aptos_framework: &signer, coffee: &signer, liquidswap: &signer)
    acquires PoolInfo, LpInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - timestamp::now_seconds());
        deposit_pre_mkl<USDC>(host, 9000000);
        deposit_asset<USDC>(host, 10000);

        let pre_mkl = pre_mkl_token::claim_pre_mkl_with_cap(&pre_mkl_token::mint_claim_capability(host), 1000000);
        primary_fungible_store::deposit(address_of(coffee), pre_mkl);
        deposit_pre_mkl<USDC>(coffee, 1000000);
        set_lp_info<USDC>(host, liquidswap);

        let user_initial_lp_amount = get_user_initial_lp_amount<USDC>(address_of(coffee));
        assert!(user_initial_lp_amount == 500000000, 0);

        let withdrawable_lp_amount = get_user_withdrawable_lp_amount<USDC>(address_of(coffee));
        assert!(withdrawable_lp_amount == 0, 0);

        timestamp::fast_forward_seconds(LBA_END_AT_SEC + LP_VESTING_DURATION_SEC / 2 - timestamp::now_seconds());
        withdrawable_lp_amount = get_user_withdrawable_lp_amount<USDC>(address_of(coffee));
        assert!(withdrawable_lp_amount == user_initial_lp_amount / 3, 0);

        withdraw_lp<USDC>(coffee, user_initial_lp_amount / 3);
        assert!(coin::balance<LP<MKL, USDC, Uncorrelated>>(address_of(coffee)) == user_initial_lp_amount / 3, 0);

        withdrawable_lp_amount = get_user_withdrawable_lp_amount<USDC>(address_of(coffee));
        assert!(withdrawable_lp_amount == 0, 0);

        timestamp::fast_forward_seconds(LBA_END_AT_SEC + LP_VESTING_DURATION_SEC - timestamp::now_seconds());
        withdrawable_lp_amount = get_user_withdrawable_lp_amount<USDC>(address_of(coffee));
        assert!(withdrawable_lp_amount == user_initial_lp_amount - user_initial_lp_amount / 3, 0);
    }


    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE, liquidswap = @liquidswap_lp)]
    fun T_withdraw_lp_E_WITHDRAW_AMOUNT_EXCEEDED(host: &signer, aptos_framework: &signer, coffee: &signer, liquidswap: &signer)
    acquires PoolInfo, LpInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - timestamp::now_seconds());
        deposit_pre_mkl<USDC>(host, 9000000);
        deposit_asset<USDC>(host, 10000);

        let pre_mkl = pre_mkl_token::claim_pre_mkl_with_cap(&pre_mkl_token::mint_claim_capability(host), 1000000);
        primary_fungible_store::deposit(address_of(coffee), pre_mkl);
        deposit_pre_mkl<USDC>(coffee, 1000000);
        set_lp_info<USDC>(host, liquidswap);

        let user_initial_lp_amount = get_user_initial_lp_amount<USDC>(address_of(coffee));
        timestamp::fast_forward_seconds(LBA_END_AT_SEC + LP_VESTING_DURATION_SEC / 2 - timestamp::now_seconds());
        let user_withdrawable = get_user_withdrawable_lp_amount<USDC>(address_of(coffee));
        let prev_amount = coin::balance<LP<MKL, USDC, Uncorrelated>>(address_of(coffee));
        withdraw_lp<USDC>(coffee, user_initial_lp_amount);
        assert!(coin::balance<LP<MKL, USDC, Uncorrelated>>(address_of(coffee)) - prev_amount == user_withdrawable, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE, liquidswap = @liquidswap_lp)]
    fun T_claim_mkl_reward(host: &signer, aptos_framework: &signer, coffee: &signer, liquidswap: &signer)
    acquires PoolInfo, LpInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - timestamp::now_seconds());
        deposit_pre_mkl<USDC>(host, 9000000);
        deposit_asset<USDC>(host, 10000);

        let pre_mkl = pre_mkl_token::claim_pre_mkl_with_cap(&pre_mkl_token::mint_claim_capability(host), 1000000);
        primary_fungible_store::deposit(address_of(coffee), pre_mkl);
        deposit_pre_mkl<USDC>(coffee, 1000000);
        set_lp_info<USDC>(host, liquidswap);

        let mkl_reward = get_claimable_mkl_reward<USDC>(address_of(coffee));
        assert!(mkl_reward == 0, 0);

        timestamp::fast_forward_seconds(LBA_END_AT_SEC + LP_VESTING_DURATION_SEC / 2 - timestamp::now_seconds());
        mkl_reward = get_claimable_mkl_reward<USDC>(address_of(coffee));
        assert!(mkl_reward == 25000000000, 0);

        // claim
        claim_mkl_reward<USDC>(coffee);
        (primary_fungible_store::balance(address_of(coffee), mkl_token::get_metadata()), 25000000000, 0);

        timestamp::fast_forward_seconds(LBA_END_AT_SEC + LP_VESTING_DURATION_SEC - timestamp::now_seconds());
        mkl_reward = get_claimable_mkl_reward<USDC>(address_of(coffee));
        assert!(mkl_reward == 25000000000, 0);

        timestamp::fast_forward_seconds(8640000);
        mkl_reward = get_claimable_mkl_reward<USDC>(address_of(coffee));
        assert!(mkl_reward == 25000000000, 0);

        claim_mkl_reward<USDC>(coffee);
        (primary_fungible_store::balance(address_of(coffee), mkl_token::get_metadata()), 50000000000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_withdraw_lp_claim_mkl_reward(host: &signer, aptos_framework: &signer)
    acquires PoolInfo, LpInfo, LiquidityAuctionEvents {
        call_test_setting(host, aptos_framework);
        test_pool::initialize_liquidity_pool();

        mkl_token::initialize_module(host);
        timestamp::fast_forward_seconds(LBA_START_AT_SEC + 1 - timestamp::now_seconds());
        deposit_pre_mkl<USDC>(host, 10000000);
        deposit_asset<USDC>(host, 10000000);

        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 1 - timestamp::now_seconds());
        timestamp::fast_forward_seconds(LBA_END_AT_SEC + 100 - timestamp::now_seconds());
        run_tge_sequence<USDC>(host);

        let user_lp_initial_amount = get_user_initial_lp_amount<USDC>(address_of(host));
        let lp_info = borrow_global<LpInfo<USDC>>(address_of(host));
        let initial_user_reward_amount = safe_mul_div(
            MKL_REWARD_AMOUNT,
            user_lp_initial_amount,
            lp_info.total_lp_amount
        );
        assert!(coin::value(&lp_info.lp_vault) > 0 && coin::value(&lp_info.lp_vault) == lp_info.total_lp_amount, 0);
        assert!(fungible_asset::balance(lp_info.mkl_reward_vault) > 0, 0);

        claim_mkl_reward<USDC>(host);
        let prev_balance = primary_fungible_store::balance(address_of(host), mkl_token::get_metadata());
        assert!(prev_balance > 0, 0);

        timestamp::fast_forward_seconds(LBA_END_AT_SEC + LP_VESTING_DURATION_SEC / 2 + 100 - timestamp::now_seconds());
        withdraw_lp<USDC>(host, get_user_initial_lp_amount<USDC>(address_of(host)) / 4);
        assert!(coin::balance<LP<MKL, USDC, Uncorrelated>>(address_of(host)) > 0, 0);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) > prev_balance, 0);

        timestamp::fast_forward_seconds(LBA_END_AT_SEC + LP_VESTING_DURATION_SEC + 100 - timestamp::now_seconds());
        claim_mkl_reward<USDC>(host);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) < initial_user_reward_amount, 0);
    }
}