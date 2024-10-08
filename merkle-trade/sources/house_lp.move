module merkle::house_lp {
    use std::signer::address_of;
    use std::option;
    use std::string;
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_framework::timestamp;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability, FreezeCapability};
    use merkle::vault_type::HouseLPVault;

    use merkle::fee_distributor;
    use merkle::safe_math::{safe_mul_div};
    use merkle::vault;
    use merkle::vault_type;

    friend merkle::trading;

    const MKLP_DECIMALS: u8 = 6;
    const FEE_POINTS_DIVISOR: u64 = 1000000;
    const WITHDRAW_DIVISION_DIVISOR: u64 = 1000000;
    const LP_PRICE_PRECISION: u64 = 1000000;
    const BREAK_PRECISION: u64 = 100000;
    const DAY_SECONDS: u64 = 86400;
    const MININUM_REDEEM_REGISTER_AMOUNT: u64 = 100000;

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When over withdrawal limit
    const E_WITHDRAW_LIMIT: u64 = 1;
    /// When the deposit amount is too small and the MKLP mint amount is 0
    const E_DEPOSIT_TOO_SMALL: u64 = 2;
    /// When Houselp runs out of the collateral it contains
    const E_HOUSE_LP_AMOUNT_NOT_ENOUGH: u64 = 3;
    /// When the asset register with house_lp is not a coin
    const E_COIN_NOT_INITIALIZED: u64 = 4;
    /// When MDD crosses the hard break threshold
    const E_HARD_BREAK_EXCEEDED: u64 = 5;
    /// When MKLP Already initialized, since only 1 collateral asset will be use for now
    const E_MKLP_ALREADY_INITIALIZED: u64 = 6;
    /// When cannot redeem
    const E_UNREDEEMABLE: u64 = 7;
    /// When cannot cancel
    const E_UNCANCELABLE: u64 = 8;
    /// When less than minimum redeem amount
    const E_MINIMUM_REDEEM_LIMIT: u64 = 9;
    /// When call deprecated function
    const E_DEPRECATED: u64 = 1000;

    // <-- Fee Type ------->
    const T_FEE_TYPE_DEPOSIT_FEE: u64 = 1;
    const T_FEE_TYPE_WITHDRAW_FEE: u64 = 2;
    const T_FEE_TYPE_PNL_FEE: u64 = 3;
    const T_FEE_TYPE_TRADING_FEE: u64 = 4;

    struct MKLP<phantom AssetT> {}

    /// Struct that stores the capability and withdraw_division associated with MKLP.
    struct HouseLPConfig<phantom AssetT> has key {
        mint_capability: MintCapability<MKLP<AssetT>>,
        burn_capability: BurnCapability<MKLP<AssetT>>,
        freeze_capability: FreezeCapability<MKLP<AssetT>>,
        withdraw_division: u64,  // 1000000 = 100% default 200000
        minimum_deposit: u64,
        soft_break: u64, // 100000 = 100%
        hard_break: u64 // 100000 = 100%
    }

    /// Struct to store the fee percentage for each asset
    struct HouseLP<phantom AssetT> has key {
        deposit_fee: u64,  // 1000000 = 100% default 0
        withdraw_fee: u64,  // 1000000 = 100% default 0
        highest_price: u64
    }

    struct RedeemPlan<phantom AssetT> has key {
        mklp: Coin<MKLP<AssetT>>,
        started_at: u64,
        redeem_count: u64,
        initial_amount: u64,
        withdraw_amount: u64
    }

    /// whole events in houselp for merkle
    struct HouseLPEvents has key {
        /// Event handle for deposit events.
        deposit_events: EventHandle<DepositEvent>,
        /// Event handle for withdraw events.
        withdraw_events: EventHandle<WithdrawEvent>,
        /// Event handle for fee events.
        fee_events: EventHandle<FeeEvent>,
    }

    struct DepositEvent has drop, store {
        /// deposit asset type
        asset_type: TypeInfo,
        /// address of deposit user.
        user: address,
        /// amount of deposit asset
        deposit_amount: u64,
        /// amount of mint asset
        mint_amount: u64,
        /// amount of deposit fee
        deposit_fee: u64
    }

    /// ---------------------------- DEPRECATED
    struct WithdrawEvent has drop, store {
        /// withdraw asset type
        asset_type: TypeInfo,
        /// address of withdraw user.
        user: address,
        /// amount of withdraw asset
        withdraw_amount: u64,
        /// amount of mint asset
        burn_amount: u64,
        /// amount of withdraw fee
        withdraw_fee: u64
    }

    struct FeeEvent has drop, store {
        /// deposit fee type
        fee_type: u64,
        /// deposit asset type
        asset_type: TypeInfo,
        /// amount of fee
        amount: u64,
        /// sign of amount true = positive, false = negative
        amount_sign: bool,
    }

    struct HouseLPRedeemEvents has key {
        redeem_events: EventHandle<RedeemEvent>,
        redeem_cancel_events: EventHandle<RedeemCancelEvent>,
    }

    struct RedeemEvent has drop, store {
        /// user address
        user: address,
        /// withdraw asset type
        asset_type: TypeInfo,
        /// burn amount
        burn_amount: u64,
        /// withdraw amount
        withdraw_amount: u64,
        /// left redeem amount
        redeem_amount_left: u64,
        /// amount of withdraw fee
        withdraw_fee: u64,
        /// start at second
        started_at_sec: u64
    }

    struct RedeemCancelEvent has drop, store {
        /// user address
        user: address,
        /// return mklp amount
        return_amount: u64,
        /// initial redeem amount
        initial_amount: u64,
        /// start at second
        started_at_sec: u64
    }

    /// withdrawal limits per user
    /// ---------------------------- DEPRECATED
    struct UserWithdrawInfo has key {
        withdraw_limit: u64,
        withdraw_amount: u64,
        last_withdraw_reset_timestamp: u64
    }

    /// register function, Need to call it through the entry function per collateral.
    /// @Type Parameters
    /// AssetT: collateral type
    public fun register<AssetT>(host: &signer) {
        let host_addr = address_of(host);
        assert!(@merkle == host_addr, E_NOT_AUTHORIZED);
        assert!(coin::is_coin_initialized<AssetT>(), E_COIN_NOT_INITIALIZED);

        if (!exists<HouseLPConfig<AssetT>>(host_addr)) {
            let (burn_capability, freeze_capability, mint_capability) = coin::initialize<MKLP<AssetT>>(
                host,
                string::utf8(b"Merkle LP"),
                string::utf8(b"MKLP"),
                MKLP_DECIMALS,
                true,
            );
            move_to(host, HouseLPConfig<AssetT> {
                mint_capability,
                burn_capability,
                freeze_capability,
                withdraw_division: 200000,  // 20%
                minimum_deposit: 0,
                soft_break: 20000,  // 20%
                hard_break: 30000,  // 30%
            });
        };
        if (!exists<HouseLP<AssetT>>(host_addr)) {
            move_to(host, HouseLP<AssetT> {
                deposit_fee: 0,
                withdraw_fee: 1000,  // 0.1%
                highest_price: 0,
            });
        };
        if (!exists<HouseLPEvents>(host_addr)) {
            move_to(host, HouseLPEvents {
                deposit_events: new_event_handle<DepositEvent>(host),
                withdraw_events: new_event_handle<WithdrawEvent>(host),
                fee_events: new_event_handle<FeeEvent>(host),
            });
        };
        if(!exists<HouseLPRedeemEvents>(host_addr)) {
            move_to(host, HouseLPRedeemEvents {
                redeem_events: new_event_handle<RedeemEvent>(host),
                redeem_cancel_events: new_event_handle<RedeemCancelEvent>(host),
            });
        };
    }

    public fun deposit_without_mint<AssetT>(_user: &signer, _amount: u64) acquires HouseLP, HouseLPEvents {
        assert!(address_of(_user) == @merkle, E_NOT_AUTHORIZED);

        let deposit_coin = coin::withdraw<AssetT>(_user, _amount);
        // Put the deposited collateral into the vault.
        vault::deposit_vault<vault_type::HouseLPVault, AssetT>(deposit_coin);
        update_highest_price<AssetT>();

        let deposit_event = DepositEvent {
            asset_type: type_info::type_of<AssetT>(),
            user: address_of(_user),
            deposit_amount: _amount,
            mint_amount: 0,
            deposit_fee: 0
        };
        event::emit_event(&mut borrow_global_mut<HouseLPEvents>(@merkle).deposit_events, deposit_event);
    }

    /// Functions to deposit collateral and receive MKLP
    /// @Type Parameters
    /// AssetT: collateral type
    public fun deposit<AssetT>(_user: &signer, _amount: u64) acquires HouseLPConfig, HouseLP, HouseLPEvents {
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        let house_lp = borrow_global_mut<HouseLP<AssetT>>(@merkle);
        let user_addr = address_of(_user);
        // If too small a value is deposited
        assert!(_amount >= house_lp_config.minimum_deposit, E_DEPOSIT_TOO_SMALL);
        let deposit_coin = coin::withdraw<AssetT>(_user, _amount);

        // Put the fees accumulated in fee_distributor into house_lp.
        deposit_trading_fee(fee_distributor::withdraw_fee_houselp_all<AssetT>());
        // Put the deposited collateral into the vault.
        vault::deposit_vault<vault_type::HouseLPVault, AssetT>(deposit_coin);

        // mint MKLP
        if (!coin::is_account_registered<MKLP<AssetT>>(user_addr)) {
            coin::register<MKLP<AssetT>>(_user);
        };

        let house_lp_coin_balance = vault::vault_balance<vault_type::HouseLPVault, AssetT>();
        let supply = (option::extract<u128>(&mut coin::supply<MKLP<AssetT>>()) as u64);
        let fee = safe_mul_div(_amount, house_lp.deposit_fee, FEE_POINTS_DIVISOR);
        _amount = _amount - fee;
        let mintAmount: u64;
        if (supply == 0) {
            mintAmount = _amount;
        } else {
            mintAmount = safe_mul_div(supply, _amount, (house_lp_coin_balance - (_amount + fee)));
        };
        // If too small a value is deposited and the amount of mint is zero, assert.
        assert!(mintAmount > 0, E_DEPOSIT_TOO_SMALL);
        let mklp = coin::mint<MKLP<AssetT>>(mintAmount, &house_lp_config.mint_capability);
        coin::deposit(user_addr, mklp);

        update_highest_price<AssetT>();

        // emit event
        if (fee > 0) {
            event::emit_event(&mut borrow_global_mut<HouseLPEvents>(@merkle).fee_events, FeeEvent {
                fee_type: T_FEE_TYPE_DEPOSIT_FEE,
                asset_type: type_info::type_of<AssetT>(),
                amount: fee,
                amount_sign: true
            });
        };
        let deposit_event = DepositEvent {
            asset_type: type_info::type_of<AssetT>(),
            user: user_addr,
            deposit_amount: _amount,
            mint_amount: mintAmount,
            deposit_fee: fee
        };
        event::emit_event(&mut borrow_global_mut<HouseLPEvents>(@merkle).deposit_events, deposit_event);
    }

    #[deprecated]
    public fun withdraw<AssetT>(_user: &signer, _amount: u64) {
        abort E_DEPRECATED
    }

    public fun register_redeem_plan<AssetT>(_user: &signer, _amount: u64) {
        assert!(_amount >= MININUM_REDEEM_REGISTER_AMOUNT, E_MINIMUM_REDEEM_LIMIT);
        move_to(_user, RedeemPlan<AssetT> {
            mklp: coin::withdraw<MKLP<AssetT>>(_user, _amount),
            started_at: timestamp::now_seconds(),
            redeem_count: 0,
            initial_amount: _amount,
            withdraw_amount: 0
        });
    }

    public fun redeem<AssetT>(_user: &signer)
    acquires RedeemPlan, HouseLPConfig, HouseLP, HouseLPEvents, HouseLPRedeemEvents {
        let redeem_plan = borrow_global_mut<RedeemPlan<AssetT>>(address_of(_user));
        assert!((timestamp::now_seconds() - redeem_plan.started_at) / DAY_SECONDS == redeem_plan.redeem_count, E_UNREDEEMABLE);

        // Put the fees accumulated in fee_distributor into house_lp.
        deposit_trading_fee(fee_distributor::withdraw_fee_houselp_all<AssetT>());

        // extract mklp
        let mklp = coin::extract(&mut redeem_plan.mklp, redeem_plan.initial_amount / 5);
        if (redeem_plan.redeem_count == 4) {
             // Extract all remaining MKLP
            coin::merge(&mut mklp, coin::extract_all(&mut redeem_plan.mklp));
        };
        let mklp_amount = coin::value(&mklp);

        // calculate withdraw amount
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        let house_lp = borrow_global_mut<HouseLP<AssetT>>(@merkle);
        let coin_balance = vault::vault_balance<vault_type::HouseLPVault, AssetT>();
        let supply = (option::extract<u128>(&mut coin::supply<MKLP<AssetT>>()) as u64);
        let return_amount = safe_mul_div(coin_balance, mklp_amount, supply);
        let fee = safe_mul_div(return_amount, house_lp.withdraw_fee, FEE_POINTS_DIVISOR);
        return_amount = return_amount - fee;
        assert!(coin_balance >= return_amount, E_HOUSE_LP_AMOUNT_NOT_ENOUGH);

        // withdraw asset
        let withdraw_coin = vault::withdraw_vault<vault_type::HouseLPVault, AssetT>(return_amount);
        let withdraw_amount = coin::value(&withdraw_coin);
        redeem_plan.withdraw_amount = redeem_plan.withdraw_amount + withdraw_amount;
        aptos_account::deposit_coins(address_of(_user), withdraw_coin);
        redeem_plan.redeem_count = redeem_plan.redeem_count + 1;

        // burn MKLP
        coin::burn(mklp, &house_lp_config.burn_capability);
        update_highest_price<AssetT>();

        event::emit_event(&mut borrow_global_mut<HouseLPRedeemEvents>(@merkle).redeem_events, RedeemEvent {
            user: address_of(_user),
            asset_type: type_info::type_of<AssetT>(),
            burn_amount: mklp_amount,
            withdraw_amount,
            redeem_amount_left: coin::value(&redeem_plan.mklp),
            withdraw_fee: fee,
            started_at_sec: redeem_plan.started_at
        });

        if (coin::value(&redeem_plan.mklp) == 0) {
            drop_redeem_plan(move_from<RedeemPlan<AssetT>>(address_of(_user)));
        };
    }

    public fun cancel_redeem_plan<AssetT>(_user: &signer)
    acquires RedeemPlan, HouseLPRedeemEvents {
        let redeem_plan = move_from<RedeemPlan<AssetT>>(address_of(_user));
        assert!((timestamp::now_seconds() - redeem_plan.started_at) / DAY_SECONDS >= redeem_plan.redeem_count, E_UNCANCELABLE);

        event::emit_event(&mut borrow_global_mut<HouseLPRedeemEvents>(@merkle).redeem_cancel_events, RedeemCancelEvent {
            user: address_of(_user),
            return_amount: coin::value(&redeem_plan.mklp),
            initial_amount: redeem_plan.initial_amount,
            started_at_sec: redeem_plan.started_at
        });
        if (coin::value(&redeem_plan.mklp) > 0) {
            aptos_account::deposit_coins(address_of(_user), coin::extract_all(&mut redeem_plan.mklp));
        };
        drop_redeem_plan(redeem_plan);
    }

    public fun drop_redeem_plan<AssetT>(_redeem_plan: RedeemPlan<AssetT>) {
        let RedeemPlan<AssetT> {
            mklp,
            started_at: _,
            redeem_count: _,
            initial_amount: _,
            withdraw_amount: _
        } = _redeem_plan;
        coin::destroy_zero(mklp);
    }

    /// Transfer losses from trading to house_lp
    /// @Type Parameters
    /// AssetT: collateral type
    public (friend) fun pnl_deposit_to_lp<AssetT>(coin: Coin<AssetT>) acquires HouseLPEvents, HouseLP, HouseLPConfig {
        // Put the fees accumulated in fee_distributor into house_lp.
        deposit_trading_fee(fee_distributor::withdraw_fee_houselp_all<AssetT>());
        let amount = coin::value(&coin);
        if (amount > 0) {
            // emit event
            event::emit_event(&mut borrow_global_mut<HouseLPEvents>(@merkle).fee_events, FeeEvent {
                fee_type: T_FEE_TYPE_PNL_FEE,
                asset_type: type_info::type_of<AssetT>(),
                amount,
                amount_sign: true
            });
        };
        vault::deposit_vault<vault_type::HouseLPVault, AssetT>(coin);
        update_highest_price<AssetT>();
        assert!(!check_hard_break_exceeded<AssetT>(), E_HARD_BREAK_EXCEEDED);
    }

    /// Withdraw profit from trading from house_lp
    /// @Type Parameters
    /// AssetT: collateral type
    public (friend) fun pnl_withdraw_from_lp<AssetT>(amount: u64): Coin<AssetT> acquires HouseLPEvents, HouseLP, HouseLPConfig {
        // Put the fees accumulated in fee_distributor into house_lp.
        deposit_trading_fee(fee_distributor::withdraw_fee_houselp_all<AssetT>());
        if (amount > 0) {
            // emit event
            event::emit_event(&mut borrow_global_mut<HouseLPEvents>(@merkle).fee_events, FeeEvent {
                fee_type: T_FEE_TYPE_PNL_FEE,
                asset_type: type_info::type_of<AssetT>(),
                amount,
                amount_sign: false
            });
        };
        update_highest_price<AssetT>();
        let asset = vault::withdraw_vault<vault_type::HouseLPVault, AssetT>(amount);
        assert!(!check_hard_break_exceeded<AssetT>(), E_HARD_BREAK_EXCEEDED);
        return asset
    }

    /// check mdd price exceed soft break
    public fun check_soft_break_exceeded<AssetT>(): bool acquires HouseLP, HouseLPConfig {
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        return get_mdd<AssetT>() > house_lp_config.soft_break
    }

    /// check mdd price exceed hard break
    public fun check_hard_break_exceeded<AssetT>(): bool acquires HouseLP, HouseLPConfig {
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        return get_mdd<AssetT>() > house_lp_config.hard_break
    }

    /// mdd = (highest price - current price) / highest price
    fun get_mdd<AssetT>(): u64 acquires HouseLP {
        let supply = (option::extract<u128>(&mut coin::supply<MKLP<AssetT>>()) as u64);
        if (supply == 0) {
            return 0
        };
        let mklp_price = safe_mul_div(
            vault::vault_balance<HouseLPVault, AssetT>(),
            LP_PRICE_PRECISION,
            (option::extract<u128>(&mut coin::supply<MKLP<AssetT>>()) as u64)
        );
        let house_lp = borrow_global_mut<HouseLP<AssetT>>(@merkle);
        if (house_lp.highest_price == 0) {
            return BREAK_PRECISION
        };
        return safe_mul_div(
            house_lp.highest_price - mklp_price,
            BREAK_PRECISION,
            house_lp.highest_price
        )
    }

    /// Deposit fee to house_lp
    fun deposit_trading_fee<AssetT>(coin: Coin<AssetT>) acquires HouseLPEvents {
        // emit event
        if (coin::value(&coin) > 0) {
            event::emit_event(&mut borrow_global_mut<HouseLPEvents>(@merkle).fee_events, FeeEvent {
                fee_type: T_FEE_TYPE_TRADING_FEE,
                asset_type: type_info::type_of<AssetT>(),
                amount: coin::value(&coin),
                amount_sign: true
            });
        };
        vault::deposit_vault<vault_type::HouseLPVault, AssetT>(coin);
    }

    /// Update highest price if needed
    fun update_highest_price<AssetT>() acquires HouseLP {
        let supply = (option::extract<u128>(&mut coin::supply<MKLP<AssetT>>()) as u64);
        if (supply == 0) {
            return
        };
        let mklp_price = safe_mul_div(
            vault::vault_balance<HouseLPVault, AssetT>(),
            LP_PRICE_PRECISION,
            supply
        );
        let house_lp = borrow_global_mut<HouseLP<AssetT>>(@merkle);
        if (mklp_price > house_lp.highest_price) {
            house_lp.highest_price = mklp_price;
        };
    }

    /// @Type Parameters
    /// AssetT: collateral type
    public fun set_house_lp_deposit_fee<AssetT>(_host: &signer, _deposit_fee: u64) acquires HouseLP {
        assert!(@merkle == address_of(_host), E_NOT_AUTHORIZED);
        let house_lp = borrow_global_mut<HouseLP<AssetT>>(@merkle);
        house_lp.deposit_fee = _deposit_fee;
    }

    /// @Type Parameters
    /// AssetT: collateral type
    public fun set_house_lp_withdraw_fee<AssetT>(_host: &signer, _withdraw_fee: u64) acquires HouseLP {
        assert!(@merkle == address_of(_host), E_NOT_AUTHORIZED);
        let house_lp = borrow_global_mut<HouseLP<AssetT>>(@merkle);
        house_lp.withdraw_fee = _withdraw_fee;
    }

    public fun set_house_lp_withdraw_division<AssetT>(_host: &signer, _withdraw_division: u64) acquires HouseLPConfig {
        assert!(@merkle == address_of(_host), E_NOT_AUTHORIZED);
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        house_lp_config.withdraw_division = _withdraw_division;
    }

    public fun set_house_lp_minimum_deposit<AssetT>(_host: &signer, _minimum_deposit: u64) acquires HouseLPConfig {
        assert!(@merkle == address_of(_host), E_NOT_AUTHORIZED);
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        house_lp_config.minimum_deposit = _minimum_deposit;
    }

    public fun set_house_lp_soft_break<AssetT>(_host: &signer, _soft_break: u64) acquires HouseLPConfig {
        assert!(@merkle == address_of(_host), E_NOT_AUTHORIZED);
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        house_lp_config.soft_break = _soft_break;
    }

    public fun set_house_lp_hard_break<AssetT>(_host: &signer, _hard_break: u64) acquires HouseLPConfig {
        assert!(@merkle == address_of(_host), E_NOT_AUTHORIZED);
        let house_lp_config = borrow_global_mut<HouseLPConfig<AssetT>>(@merkle);
        house_lp_config.hard_break = _hard_break;
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    use merkle::safe_math::exp;

    #[test_only]
    struct USDC has key {}

    #[test_only]
    struct FAIL_USDC has key {}

    #[test_only]
    const TEST_ASSET_DECIMALS: u8 = 6;

    #[test_only]
    struct AssetInfo<phantom AssetT> has key, store {
        burn_cap: BurnCapability<AssetT>,
        freeze_cap: FreezeCapability<AssetT>,
        mint_cap: MintCapability<AssetT>,
    }

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) acquires AssetInfo, HouseLPConfig, HouseLP {
        let host_addr = address_of(host);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::fast_forward_seconds(DAY_SECONDS * 10);
        account::create_account_for_test(host_addr);
        vault::register_vault<vault_type::CollateralVault, USDC>(host);
        vault::register_vault<vault_type::HouseLPVault, USDC>(host);
        vault::register_vault<vault_type::FeeHouseLPVault, USDC>(host);
        vault::register_vault<vault_type::FeeStakingVault, USDC>(host);
        vault::register_vault<vault_type::FeeDevVault, USDC>(host);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<USDC>(
            host,
            string::utf8(b"USDC"),
            string::utf8(b"USDC"),
            TEST_ASSET_DECIMALS,
            false,
        );
        move_to(host, AssetInfo {
            burn_cap,
            freeze_cap,
            mint_cap
        });
        let usdc_info = borrow_global<AssetInfo<USDC>>(host_addr);
        let mint_coin = coin::mint(100000 * exp(10, (TEST_ASSET_DECIMALS as u64)), &usdc_info.mint_cap);
        aptos_account::deposit_coins(host_addr, mint_coin);

        register<USDC>(host);
        set_house_lp_withdraw_division<USDC>(host, 1000000);
        set_house_lp_deposit_fee<USDC>(host, 0);
        set_house_lp_withdraw_fee<USDC>(host, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_register(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, AssetInfo, HouseLP {
        let host_addr = address_of(host);
        call_test_setting(host, aptos_framework);
        assert!(exists<HouseLPConfig<USDC>>(host_addr) == true, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_deposit(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents {
        let host_addr = address_of(host);
        call_test_setting(host, aptos_framework);

        let usdc_amount = coin::balance<USDC>(host_addr);
        let deposit_amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, deposit_amount);

        assert!(coin::balance<MKLP<USDC>>(host_addr) == deposit_amount, 0);
        assert!(coin::balance<USDC>(host_addr) == usdc_amount - deposit_amount, 1);
        assert!(vault::vault_balance<vault_type::HouseLPVault, USDC>() == deposit_amount, 2);
        assert!(option::extract<u128>(&mut coin::supply<MKLP<USDC>>()) == (deposit_amount as u128), 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_DEPOSIT_TOO_SMALL, location = Self)]
    fun test_deposit_too_small(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents {
        call_test_setting(host, aptos_framework);
        set_house_lp_minimum_deposit<USDC>(host, 100);
        deposit<USDC>(host, 10);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_set_configs(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
    let host_addr = address_of(host);
        call_test_setting(host, aptos_framework);

        let house_lp_config = borrow_global<HouseLPConfig<USDC>>(host_addr);
        let house_lp = borrow_global<HouseLP<USDC>>(host_addr);
        assert!(house_lp_config.withdraw_division == 1000000, 0);
        assert!(house_lp.deposit_fee == 0, 1);
        assert!(house_lp.withdraw_fee == 0, 2);

        set_house_lp_deposit_fee<USDC>(host, 100);
        set_house_lp_withdraw_fee<USDC>(host, 200);
        set_house_lp_withdraw_division<USDC>(host, 333333);


        house_lp_config = borrow_global<HouseLPConfig<USDC>>(host_addr);
        house_lp = borrow_global<HouseLP<USDC>>(host_addr);
        assert!(house_lp.deposit_fee == 100, 6);
        assert!(house_lp.withdraw_fee == 200, 7);
        assert!(house_lp_config.withdraw_division == 333333, 12);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_profit_loss(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents {
        let host_addr = address_of(host);
        call_test_setting(host, aptos_framework);

        let usdc_info = borrow_global<AssetInfo<USDC>>(host_addr);
        let mint_coin = coin::mint(100 * exp(10, (TEST_ASSET_DECIMALS as u64)), &usdc_info.mint_cap);
        pnl_deposit_to_lp(mint_coin);
        assert!(vault::vault_balance<vault_type::HouseLPVault, USDC>() == 100 * exp(10, (TEST_ASSET_DECIMALS as u64)), 0);

        let withdraw_coin = pnl_withdraw_from_lp<USDC>(100 * exp(10, (TEST_ASSET_DECIMALS as u64)));
        assert!(coin::value(&withdraw_coin) == 100 * exp(10, (TEST_ASSET_DECIMALS as u64)), 1);
        assert!(vault::vault_balance<vault_type::HouseLPVault, USDC>() == 0, 2);

        coin::burn(withdraw_coin, &usdc_info.burn_cap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_DEPOSIT_TOO_SMALL, location = Self)]
    fun test_deposit_small_rate_should_fail(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents {
        let host_addr = address_of(host);
        call_test_setting(host, aptos_framework);

        deposit<USDC>(host, 100 * exp(10, (TEST_ASSET_DECIMALS as u64)));
        assert!(coin::balance<MKLP<USDC>>(host_addr) == 100 * exp(10, (MKLP_DECIMALS as u64)), 0);

        let usdc_info = borrow_global<AssetInfo<USDC>>(host_addr);
        let mint_coin = coin::mint(1000 * exp(10, (TEST_ASSET_DECIMALS as u64)), &usdc_info.mint_cap);
        pnl_deposit_to_lp(mint_coin);

        deposit<USDC>(host, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_deposit_fee(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents {
        let host_addr = address_of(host);
        call_test_setting(host, aptos_framework);
        set_house_lp_deposit_fee<USDC>(host, 1000);  // 0.1%

        let deposit_amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        let deposit_fee: u64;
        let coin_value: u64;
        deposit<USDC>(host, deposit_amount);
        {
            let house_lp = borrow_global<HouseLP<USDC>>(host_addr);
            coin_value = vault::vault_balance<vault_type::HouseLPVault, USDC>();
            deposit_fee = deposit_amount * house_lp.deposit_fee / FEE_POINTS_DIVISOR;
            assert!(coin_value == deposit_amount, 0);
            assert!(coin::balance<MKLP<USDC>>(host_addr) == deposit_amount - deposit_fee, 0);
        };
    }
    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_register_twice(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        register<USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_register(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        register<USDC>(aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_set_house_lp_deposit_fee(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        set_house_lp_deposit_fee<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_set_house_lp_withdraw_fee(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        set_house_lp_withdraw_fee<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_set_house_lp_withdraw_division(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        set_house_lp_withdraw_division<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_set_house_lp_minimum_deposit(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        set_house_lp_minimum_deposit<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_COIN_NOT_INITIALIZED, location = Self)]
    fun T_E_COIN_NOT_INITIALIZED_register(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        register<FAIL_USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_HARD_BREAK_EXCEEDED, location = Self)]
    fun test_breaks(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents {
        let host_addr = address_of(host);
        call_test_setting(host, aptos_framework);

        deposit<USDC>(host, 1000 * exp(10, (TEST_ASSET_DECIMALS as u64)));
        assert!(check_soft_break_exceeded<USDC>() == false, 0);

        let pnl = pnl_withdraw_from_lp<USDC>(201 * exp(10, (TEST_ASSET_DECIMALS as u64)));
        coin::deposit(host_addr, pnl);
        assert!(check_soft_break_exceeded<USDC>(), 0);

        let pnl2 = pnl_withdraw_from_lp<USDC>(100 * exp(10, (TEST_ASSET_DECIMALS as u64)));
        coin::deposit(host_addr, pnl2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_DEPRECATED, location = Self)]
    fun test_withdraw_deprecated(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLP, AssetInfo {
        call_test_setting(host, aptos_framework);
        withdraw<USDC>(host, 10);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_register_redeem_plan(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan {
        call_test_setting(host, aptos_framework);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        register_redeem_plan<USDC>(host, amount);
        let redeem_plan = borrow_global<RedeemPlan<USDC>>(address_of(host));
        assert!(coin::value(&redeem_plan.mklp) == amount, 0);
        assert!(redeem_plan.redeem_count == 0, 0);
        assert!(redeem_plan.initial_amount == amount, 0);
        assert!(redeem_plan.withdraw_amount == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_redeem(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));
        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount / 5, 0);

        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount / 5 * 2, 0);

        let redeem_plan = borrow_global<RedeemPlan<USDC>>(address_of(host));
        assert!(coin::value(&redeem_plan.mklp) == amount * 3 / 5, 0);
        assert!(redeem_plan.withdraw_amount == amount * 2 / 5, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_UNREDEEMABLE, location = Self)]
    fun test_redeem_already_redeem_E_UNREDEEMABLE(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));
        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount / 5, 0);
        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host);
        redeem<USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_UNREDEEMABLE, location = Self)]
    fun test_redeem_passed_E_UNREDEEMABLE(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));
        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount / 5, 0);
        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds((DAY_SECONDS + 10) * 2); // passed 2 days
        redeem<USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_redeem_with_withdraw_fee(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);
        set_house_lp_withdraw_fee<USDC>(host, 100);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));

        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount * (FEE_POINTS_DIVISOR - 20) / FEE_POINTS_DIVISOR, 0);
        assert!(!exists<RedeemPlan<USDC>>(address_of(host)), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_cancel(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        let before_mklp_amount_for_cancel = coin::balance<MKLP<USDC>>(address_of(host));
        register_redeem_plan<USDC>(host, amount);
        assert!(coin::balance<MKLP<USDC>>(address_of(host)) == 0, 0);
        cancel_redeem_plan<USDC>(host);
        assert!(coin::balance<MKLP<USDC>>(address_of(host)) == before_mklp_amount_for_cancel, 0);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));
        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host);
        let before_mklp_amount = coin::balance<MKLP<USDC>>(address_of(host));
        timestamp::fast_forward_seconds(DAY_SECONDS * 3 + 10);
        cancel_redeem_plan<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount / 5, 0);
        assert!(coin::balance<MKLP<USDC>>(address_of(host)) - before_mklp_amount == amount * 4 / 5, 0);
        assert!(!exists<RedeemPlan<USDC>>(address_of(host)), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_UNCANCELABLE, location = Self)]
    fun test_E_UNCANCELABLE(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host);
        cancel_redeem_plan<USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    fun test_redeem_deposit_more(host: &signer, aptos_framework: &signer, coffee: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);
        account::create_account_for_test(address_of(coffee));

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        aptos_account::transfer_coins<USDC>(host, address_of(coffee), amount * 5);
        deposit<USDC>(host, amount);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));
        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host);
        deposit<USDC>(coffee, amount);
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS);
        deposit<USDC>(coffee, amount);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS);
        deposit<USDC>(coffee, amount);
        redeem<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount, 0)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_redeem_with_profit(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        let profit = coin::withdraw<USDC>(host, amount * 2);
        deposit<USDC>(host, amount);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));
        register_redeem_plan<USDC>(host, amount); // balance 80, withdraw 20
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host); // balance 60, withdraw 20
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host); // balance 40, withdraw 20
        pnl_deposit_to_lp(coin::extract(&mut profit, amount)); // balance 140
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host); // balance 70, withdraw 70
        timestamp::fast_forward_seconds(DAY_SECONDS);
        pnl_deposit_to_lp(profit); // balance 170
        redeem<USDC>(host); // balance 0, withdraw 0
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount * 3, 0)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_redeem_with_loss(host: &signer, aptos_framework: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);
        account::create_account_for_test(@0x001);

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        deposit<USDC>(host, amount);

        let before_usdc_amount = coin::balance<USDC>(address_of(host));
        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host); // balance 80, withdraw 20
        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host); // balance 60, withdraw 20
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host); // balance 40, withdraw 20
        aptos_account::deposit_coins(@0x001, pnl_withdraw_from_lp<USDC>(amount / 100)); // balance 39
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host); // balance 19.5, withdraw 19.5
        timestamp::fast_forward_seconds(DAY_SECONDS);
        aptos_account::deposit_coins(@0x001, pnl_withdraw_from_lp<USDC>(amount / 100)); // balance 18.5
        redeem<USDC>(host); // balance 0, withdraw 18.5
        assert!(coin::balance<USDC>(address_of(host)) - before_usdc_amount == amount * 98 / 100, 0)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE, coffee2 = @0xC0FFEE2)]
    fun test_redeem_with_multiple_user(host: &signer, aptos_framework: &signer, coffee: &signer, coffee2: &signer)
    acquires HouseLPConfig, HouseLP, AssetInfo, HouseLPEvents, RedeemPlan, HouseLPRedeemEvents {
        call_test_setting(host, aptos_framework);
        account::create_account_for_test(address_of(coffee));
        account::create_account_for_test(address_of(coffee2));

        let amount = 100 * exp(10, (TEST_ASSET_DECIMALS as u64));
        let profit = coin::withdraw<USDC>(host, amount * 3);
        aptos_account::transfer_coins<USDC>(host, address_of(coffee), amount);
        aptos_account::transfer_coins<USDC>(host, address_of(coffee2), amount);

        deposit<USDC>(host, amount); // balance 100, mklp 100
        deposit<USDC>(coffee, amount); // balance 200, mklp 200
        pnl_deposit_to_lp(coin::extract(&mut profit, amount)); // balance 300, mklp 200
        pnl_deposit_to_lp(coin::extract(&mut profit, amount)); // balance 400, mklp 200

        register_redeem_plan<USDC>(host, amount);
        redeem<USDC>(host); // balance 360, withdraw 40
        timestamp::fast_forward_seconds(DAY_SECONDS + 10);
        redeem<USDC>(host); // balance 320, withdraw 40
        timestamp::fast_forward_seconds(DAY_SECONDS);
        deposit<USDC>(coffee2, amount); // balance 420, mklp 210
        redeem<USDC>(host);
        aptos_account::deposit_coins(address_of(coffee2), pnl_withdraw_from_lp<USDC>(amount / 100));
        timestamp::fast_forward_seconds(DAY_SECONDS);
        redeem<USDC>(host);
        timestamp::fast_forward_seconds(DAY_SECONDS);
        aptos_account::deposit_coins(address_of(coffee2), pnl_withdraw_from_lp<USDC>(amount / 100));
        pnl_deposit_to_lp(profit);
        redeem<USDC>(host);
    }
}
