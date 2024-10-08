module merkle::vault {
    use std::signer::address_of;
    use aptos_std::coin::{Self, Coin};

    friend merkle::trading;
    friend merkle::house_lp;
    friend merkle::fee_distributor;
    friend merkle::referral;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    /// Struct to hold the coins needed by each module
    /// @Type Parameters
    /// VaultT: vault type ex) CollateralVault
    /// AssetT: collateral type ex) lzUSDC
    struct Vault<phantom VaultT, phantom AssetT> has key {
        coin_store: Coin<AssetT>,
    }

    /// register vault
    /// Only allowed for admin.
    /// @Type Parameters
    /// VaultT: vault type ex) CollateralVault
    /// AssetT: collateral type ex) lzUSDC
    public fun register_vault<VaultT, AssetT>(_host: &signer) {
        let host_addr = address_of(_host);
        assert!(host_addr == @merkle, E_NOT_AUTHORIZED);
        if (!exists<Vault<VaultT, AssetT>>(host_addr)) {
            move_to(_host, Vault<VaultT, AssetT> {
                coin_store: coin::zero()
            })
        };
    }

    // <-- Vault ----->
    public (friend) fun deposit_vault<VaultT, AssetT>(_coin: Coin<AssetT>) acquires Vault {
        let vault = borrow_global_mut<Vault<VaultT, AssetT>>(@merkle);
        coin::merge(&mut vault.coin_store, _coin);
    }

    public (friend) fun withdraw_vault<VaultT, AssetT>(_amount: u64): Coin<AssetT> acquires Vault {
        if (_amount == 0) {
            return coin::zero<AssetT>()
        };
        let vault = borrow_global_mut<Vault<VaultT, AssetT>>(@merkle);
        coin::extract(&mut vault.coin_store, _amount)
    }

    public fun vault_balance<VaultT, AssetT>(): u64 acquires Vault {
        let vault = borrow_global_mut<Vault<VaultT, AssetT>>(@merkle);
        coin::value(&vault.coin_store)
    }

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use merkle::vault_type;
    #[test_only]
    struct TEST_USDC has store, drop {}

    #[test_only]
    fun create_test_coins<T>(
        host: &signer,
        name: vector<u8>,
        decimals: u8,
        amount: u64
    ) {
        let (bc, fc, mc) = coin::initialize<T>(host,
            string::utf8(name),
            string::utf8(name),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<T>(host);
        coin::deposit(address_of(host), coin::mint<T>(amount, &mc));
        coin::destroy_mint_cap(mc);
    }

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };

        register_vault<vault_type::CollateralVault, TEST_USDC>(host);
        register_vault<vault_type::HouseLPVault, TEST_USDC>(host);
        register_vault<vault_type::FeeHouseLPVault, TEST_USDC>(host);
        register_vault<vault_type::FeeStakingVault, TEST_USDC>(host);
        register_vault<vault_type::FeeDevVault, TEST_USDC>(host);

        create_test_coins<TEST_USDC>(host, b"USDC", 8, 10000000 * 100000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test initialize
    fun T_register(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };

        register_vault<vault_type::CollateralVault, TEST_USDC>(host);

        // nothing happen
        register_vault<vault_type::CollateralVault, TEST_USDC>(host);
    }

    #[test(host = @0xC0FFEE, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED, location = Self)]
    /// Test initialize
    fun T_register_not_allowed(host: &signer, aptos_framework: &signer){
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };

        register_vault<vault_type::CollateralVault, TEST_USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test initialize
    fun T_deposit(host: &signer, aptos_framework: &signer) acquires Vault {
        call_test_setting(host, aptos_framework);
        let deposit_coin = coin::withdraw<TEST_USDC>(host, 10000);
        deposit_vault<vault_type::CollateralVault, TEST_USDC>(deposit_coin);

        let balance = vault_balance<vault_type::CollateralVault, TEST_USDC>();
        assert!(balance == 10000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test initialize
    fun T_withdraw(host: &signer, aptos_framework: &signer) acquires Vault {
        call_test_setting(host, aptos_framework);
        let deposit_coin = coin::withdraw<TEST_USDC>(host, 10000);
        deposit_vault<vault_type::CollateralVault, TEST_USDC>(deposit_coin);
        let withdraw_coin = withdraw_vault<vault_type::CollateralVault, TEST_USDC>(6000);
        assert!(coin::value(&withdraw_coin) == 6000, 0);
        let withdraw_coin_zero = withdraw_vault<vault_type::CollateralVault, TEST_USDC>(0);
        assert!(coin::value(&withdraw_coin_zero) == 0, 0);
        coin::deposit(address_of(host), withdraw_coin);
        coin::deposit(address_of(host), withdraw_coin_zero);
        let balance = vault_balance<vault_type::CollateralVault, TEST_USDC>();
        assert!(balance == 4000, 0);
    }
}