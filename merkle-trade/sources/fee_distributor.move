module merkle::fee_distributor {

    use std::signer::address_of;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account::new_event_handle;
    use aptos_framework::aptos_account;
    use merkle::referral;

    use merkle::vault;
    use merkle::vault_type;
    use merkle::safe_math::{safe_mul_div};

    friend merkle::house_lp;

    /// When the asset register with house_lp is not a coin
    const E_COIN_NOT_INITIALIZED: u64 = 0;
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When stake asset already exists
    const E_STAKE_ASSET_ALREDY_EXIST: u64 = 2;

    /// Precision buffer for divide
    const PRECISION: u64 = 1000000;
    /// Precision for rebate calculation
    const REBATE_PRECISION: u64 = 1000000;

    /// weight of fee distributed to lp, stake, dev
    struct FeeDistributorInfo<phantom AssetT> has key {
        lp_weight: u64,
        stake_weight: u64,
        dev_weight: u64,
        total_weight: u64
    }

    /// Events
    struct FeeDistributorEvents has key {
        deposit_fee_event: EventHandle<DepositFeeEvent>
    }

    /// event emitted whenever a fee is deposited
    struct DepositFeeEvent has store, drop {
        lp_amount: u64,
        stake_amount: u64,
        dev_amount: u64,
    }

    /// initialize function, Need to call it through the entry function per collateral.
    /// @Type Parameters
    /// AssetT: collateral type
    public fun initialize<AssetT>(
        _host: &signer
    ) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        assert!(coin::is_coin_initialized<AssetT>(), E_COIN_NOT_INITIALIZED);

        if (!exists<FeeDistributorInfo<AssetT>>(@merkle)) {
            move_to(_host, FeeDistributorInfo<AssetT> {
                lp_weight: 0,
                stake_weight: 0,
                dev_weight: 0,
                total_weight: 0,
            });
        };
        if (!exists<FeeDistributorEvents>(@merkle)) {
            move_to(_host, FeeDistributorEvents {
                deposit_fee_event: new_event_handle<DepositFeeEvent>(_host)
            })
        };
    }

    #[deprecated]
    public fun deposit_fee<AssetT>(
        _fee: Coin<AssetT>
    ) acquires FeeDistributorInfo, FeeDistributorEvents {
        let fee_distributor_info = borrow_global_mut<FeeDistributorInfo<AssetT>>(@merkle);
        let fee_amount = coin::value(&_fee);

        // Calculate the LP weight and put it in the vault.
        let lp_amount = safe_mul_div(
            fee_amount,
            fee_distributor_info.lp_weight,
            fee_distributor_info.total_weight
        );
        let lp_fee = coin::extract(&mut _fee, lp_amount);
        vault::deposit_vault<vault_type::FeeHouseLPVault, AssetT>(lp_fee);

        // Calculate the Stake weight and put it in the vault.
        let stake_amount = safe_mul_div(
            fee_amount,
            fee_distributor_info.stake_weight,
            fee_distributor_info.total_weight
        );
        let stake_fee = coin::extract(&mut _fee, stake_amount);
        vault::deposit_vault<vault_type::FeeStakingVault, AssetT>(stake_fee);

        // To avoid having a small amount of money left over,
        // put the rest in the dev vault, except for the LP and Stake.
        vault::deposit_vault<vault_type::FeeDevVault, AssetT>(_fee);

        // emit event
        event::emit_event(
            &mut borrow_global_mut<FeeDistributorEvents>(@merkle).deposit_fee_event,
            DepositFeeEvent {
                lp_amount,
                stake_amount,
                dev_amount: fee_amount - lp_amount - stake_amount
            }
        );
    }

    // return rebate fee coin object
    public fun deposit_fee_with_rebate<AssetT>(
        _fee: Coin<AssetT>,
        _user: address,
    ) acquires FeeDistributorInfo, FeeDistributorEvents {
        let fee_distributor_info = borrow_global_mut<FeeDistributorInfo<AssetT>>(@merkle);
        let fee_amount = coin::value(&_fee);

        // Calculate the LP weight and put it in the vault.
        let lp_amount = safe_mul_div(
            fee_amount,
            fee_distributor_info.lp_weight,
            fee_distributor_info.total_weight
        );
        let lp_fee = coin::extract(&mut _fee, lp_amount);
        vault::deposit_vault<vault_type::FeeHouseLPVault, AssetT>(lp_fee);

        // calculate rebate amount
        let rebate_rate = referral::get_rebate_rate<AssetT>(_user);
        let rebate_amount = safe_mul_div(
            fee_amount,
            rebate_rate,
            REBATE_PRECISION
        );
        if (rebate_amount > 0) {
            let rebate_fee = coin::extract(&mut _fee, rebate_amount);
            referral::add_unclaimed_amount(_user, rebate_fee);
            if (referral::is_ancestor_enabled<AssetT>(_user)) {
                let ancestor_rate = referral::get_ancestor_rebate_rate();
                let ancestor_amount = safe_mul_div(
                    fee_amount,
                    ancestor_rate,
                    REBATE_PRECISION
                );
                let ancestor_fee = coin::extract(&mut _fee, ancestor_amount);
                referral::add_ancestor_amount(_user, ancestor_fee);
                rebate_amount = rebate_amount + ancestor_amount;
            };
        };

        // Calculate the Stake weight and put it in the vault.
        let stake_amount = safe_mul_div(
            fee_amount - lp_amount - rebate_amount,
            fee_distributor_info.stake_weight,
            fee_distributor_info.stake_weight + fee_distributor_info.dev_weight
        );

        let stake_fee = coin::extract(&mut _fee, stake_amount);
        vault::deposit_vault<vault_type::FeeStakingVault, AssetT>(stake_fee);

        // To avoid having a small amount of money left over,
        // put the rest in the dev vault, except for the LP and Stake.
        let dev_amount = coin::value(&_fee);
        vault::deposit_vault<vault_type::FeeDevVault, AssetT>(_fee);

        // emit event
        event::emit_event(
            &mut borrow_global_mut<FeeDistributorEvents>(@merkle).deposit_fee_event,
            DepositFeeEvent {
                lp_amount,
                stake_amount,
                dev_amount
            }
        );
    }

    /// Function used to claim a fee from a house LP.
    /// There are no situations where we want to take only part of the value,
    /// so we pass all the values each time we call it.
    /// @Type Parameters
    /// AssetT: collateral type
    public (friend) fun withdraw_fee_houselp_all<AssetT>(): Coin<AssetT> {
        vault::withdraw_vault<vault_type::FeeHouseLPVault, AssetT>(
            vault::vault_balance<vault_type::FeeHouseLPVault, AssetT>()
        )
    }

    /// Function to withdraw fees accumulated in the dev vault.
    /// Only allowed for admin.
    /// @Type Parameters
    /// AssetT: collateral type
    public fun withdraw_fee_dev<AssetT>(_host: &signer, _amount: u64) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        aptos_account::deposit_coins(address_of(_host), vault::withdraw_vault<vault_type::FeeDevVault, AssetT>(_amount));
    }

    /// Function to withdraw fees accumulated in the stake vault.
    /// This function exists because we don't currently have staking.
    /// It will be removed in the future.
    /// Only allowed for admin.
    /// @Type Parameters
    /// AssetT: collateral type
    public fun withdraw_fee_stake<AssetT>(_host: &signer, _amount: u64) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        aptos_account::deposit_coins(address_of(_host), vault::withdraw_vault<vault_type::FeeStakingVault, AssetT>(_amount));
    }

    /// @Type Parameters
    /// AssetT: collateral type
    public fun set_lp_weight<AssetT>(_host: &signer, _lp_weight: u64) acquires FeeDistributorInfo {
        let host_addr = address_of(_host);
        assert!(host_addr == @merkle, E_NOT_AUTHORIZED);

        let fee_distributor_info = borrow_global_mut<FeeDistributorInfo<AssetT>>(host_addr);
        fee_distributor_info.lp_weight = _lp_weight;
        fee_distributor_info.total_weight = fee_distributor_info.lp_weight + fee_distributor_info.stake_weight + fee_distributor_info.dev_weight;
    }

    /// @Type Parameters
    /// AssetT: collateral type
    public fun set_stake_weight<AssetT>(_host: &signer, _stake_weight: u64) acquires FeeDistributorInfo {
        let host_addr = address_of(_host);
        assert!(host_addr == @merkle, E_NOT_AUTHORIZED);

        let fee_distributor_info = borrow_global_mut<FeeDistributorInfo<AssetT>>(host_addr);
        fee_distributor_info.stake_weight = _stake_weight;
        fee_distributor_info.total_weight = fee_distributor_info.lp_weight + fee_distributor_info.stake_weight + fee_distributor_info.dev_weight;
    }

    /// @Type Parameters
    /// AssetT: collateral type
    public fun set_dev_weight<AssetT>(_host: &signer, _dev_weight: u64) acquires FeeDistributorInfo {
        let host_addr = address_of(_host);
        assert!(host_addr == @merkle, E_NOT_AUTHORIZED);

        let fee_distributor_info = borrow_global_mut<FeeDistributorInfo<AssetT>>(host_addr);
        fee_distributor_info.dev_weight = _dev_weight;
        fee_distributor_info.total_weight = fee_distributor_info.lp_weight + fee_distributor_info.stake_weight + fee_distributor_info.dev_weight;
    }

    #[test_only]
    use std::string;

    #[test_only]
    use std::signer;

    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    use aptos_framework::coin::{MintCapability, BurnCapability, FreezeCapability};

    #[test_only]
    use merkle::safe_math::exp;

    #[test_only]
    const TEST_ASSET_DECIMALS: u8 = 6;

    #[test_only]
    struct USDC {}

    #[test_only]
    struct FAIL_USDC {}

    #[test_only]
    struct AssetInfo<phantom AssetT> has key, store {
        burn_cap: BurnCapability<AssetT>,
        freeze_cap: FreezeCapability<AssetT>,
        mint_cap: MintCapability<AssetT>,
    }

    #[test_only]
    fun call_test_setting(
        host: &signer, aptos_framework: &signer
    ) acquires AssetInfo, FeeDistributorInfo {
        let host_addr = signer::address_of(host);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
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
        coin::register<USDC>(host);
        let mint_coin = coin::mint(1000 * exp(10, (TEST_ASSET_DECIMALS as u64)), &usdc_info.mint_cap);
        coin::deposit(host_addr, mint_coin);

        initialize<USDC>(host);
        set_lp_weight<USDC>(host, 6);
        set_dev_weight<USDC>(host, 2);
        set_stake_weight<USDC>(host, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_initialize(
        host: &signer, aptos_framework: &signer
    ) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_deposit_fee(
        host: &signer, aptos_framework: &signer
    ) acquires AssetInfo, FeeDistributorInfo, FeeDistributorEvents {
        call_test_setting(host, aptos_framework);
        let usdc = coin::withdraw<USDC>(host, 100000);
        deposit_fee<USDC>(usdc);
        assert!(vault::vault_balance<vault_type::FeeHouseLPVault, USDC>() == 60000, 0);
        assert!(vault::vault_balance<vault_type::FeeStakingVault, USDC>() == 20000, 0);
        assert!(vault::vault_balance<vault_type::FeeDevVault, USDC>() == 20000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_withdraw_deposit_fee(
        host: &signer, aptos_framework: &signer
    ) acquires AssetInfo, FeeDistributorInfo, FeeDistributorEvents {
        call_test_setting(host, aptos_framework);
        let usdc = coin::withdraw<USDC>(host, 100000);
        deposit_fee<USDC>(usdc);
        let before_amount = coin::balance<USDC>(address_of(host));
        withdraw_fee_dev<USDC>(host, 20000);
        let after_amount1 = coin::balance<USDC>(address_of(host));
        assert!(after_amount1 - before_amount == 20000, 0);
        withdraw_fee_stake<USDC>(host, 20000);
        let after_amount2 = coin::balance<USDC>(address_of(host));
        assert!(after_amount2 - after_amount1 == 20000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xCAFFEE)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun test_withdraw_deposit_fee_failed(
        host: &signer, aptos_framework: &signer, user: &signer
    ) acquires AssetInfo, FeeDistributorInfo, FeeDistributorEvents {
        call_test_setting(host, aptos_framework);
        let usdc = coin::withdraw<USDC>(host, 100000);
        deposit_fee<USDC>(usdc);
        withdraw_fee_dev<USDC>(user, 20000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_register_twice(host: &signer, aptos_framework: &signer) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
        initialize<USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_register(host: &signer, aptos_framework: &signer) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
        initialize<USDC>(aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_withdraw_fee_stake(host: &signer, aptos_framework: &signer) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
        withdraw_fee_stake<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_set_lp_weight(host: &signer, aptos_framework: &signer) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
        set_lp_weight<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_set_stake_weight(host: &signer, aptos_framework: &signer) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
        set_stake_weight<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    fun T_E_NOT_AUTHORIZED_set_dev_weight(host: &signer, aptos_framework: &signer) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
        set_dev_weight<USDC>(aptos_framework, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_COIN_NOT_INITIALIZED, location = Self)]
    fun T_E_COIN_NOT_INITIALIZED_register(host: &signer, aptos_framework: &signer) acquires AssetInfo, FeeDistributorInfo {
        call_test_setting(host, aptos_framework);
        initialize<FAIL_USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE, user2= @0xC0FFEE2)]
    fun T_deposit_Fee_with_rebate(host: &signer, aptos_framework: &signer, user: &signer, user2: &signer)
    acquires AssetInfo, FeeDistributorInfo, FeeDistributorEvents {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        aptos_account::create_account(address_of(user2));
        coin::register<USDC>(user);
        coin::register<USDC>(user2);
        referral::initialize<USDC>(host);
        vault::register_vault<vault_type::RebateVault, USDC>(host);

        let admin_cap = referral::generate_admin_cap(host);
        referral::enable_ancestor_admin_cap(&admin_cap, address_of(host));
        referral::register_referrer<USDC>(address_of(user), address_of(host)); // user -> host 5%
        referral::register_referrer<USDC>(address_of(user2), address_of(user)); // user2 -> user 5%, user2 -> host 5%

        let usdc = coin::withdraw<USDC>(host, 100000);
        deposit_fee_with_rebate<USDC>(usdc, address_of(user2));
        let usdc = coin::withdraw<USDC>(host, 100000);
        deposit_fee_with_rebate<USDC>(usdc, address_of(user));

        assert!(vault::vault_balance<vault_type::FeeHouseLPVault, USDC>() == 120000, 0); // 60%
        assert!(vault::vault_balance<vault_type::FeeStakingVault, USDC>() == 32500, 0);
        assert!(vault::vault_balance<vault_type::FeeDevVault, USDC>() == 32500, 0);

        let balance_before = coin::balance<USDC>(address_of(user));
        referral::claim_all<USDC>(user);
        assert!(coin::balance<USDC>(address_of(user)) - balance_before == 5000, 0);

        balance_before = coin::balance<USDC>(address_of(host));
        referral::claim_all<USDC>(host);
        assert!(coin::balance<USDC>(address_of(host)) - balance_before == 10000, 0);
    }
}