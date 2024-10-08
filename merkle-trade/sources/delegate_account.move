module merkle::delegate_account {
    use std::signer::address_of;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::aptos_account;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::event::EventHandle;

    friend merkle::trading;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Too many registered delegate addresses, unregister first and retry
    const E_TOO_MANY_REGISTERED_ACCOUNT: u64 = 2;

    /// delegated vault event action type
    const T_VAULT_DEPOSIT: u64 = 1;
    const T_VAULT_WITHDRAW: u64 = 2;

    struct DelegateAccount<phantom AssetT> has key {
        addresses: vector<address>,
        vault: coin::Coin<AssetT>
    }

    struct DelegateAccountVaultEvents has key {
        delegate_account_vault_events: EventHandle<DelegateAccountVaultEvent>,
    }

    struct DelegateAccountVaultEvent has drop, store {
        user: address,
        amount: u64,
        event_type: u64,
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<DelegateAccountVaultEvents>(address_of(_admin))) {
            move_to(_admin, DelegateAccountVaultEvents {
                delegate_account_vault_events: new_event_handle<DelegateAccountVaultEvent>(_admin)
            });
        };
    }

    public fun is_active<AssetT>(_user_address: address): bool acquires DelegateAccount{
        if (!exists<DelegateAccount<AssetT>>(_user_address)) {
            return false
        };
        let delegate_account = borrow_global<DelegateAccount<AssetT>>(_user_address);
        vector::length(&delegate_account.addresses) > 0
    }

    public fun is_registered<AssetT>(_user_address: address, _delegate_account: address): bool acquires DelegateAccount {
        if (!is_active<AssetT>(_user_address)) {
            return false
        };

        let delegate_account = borrow_global<DelegateAccount<AssetT>>(_user_address);
        vector::contains(&delegate_account.addresses, &_delegate_account)
    }

    public fun register<AssetT>(_host: &signer, _delegate_account: address) acquires DelegateAccount {
        let user_address = address_of(_host);
        if (!exists<DelegateAccount<AssetT>>(user_address)) {
            move_to(_host, DelegateAccount<AssetT> {
                addresses: vector::empty(),
                vault: coin::zero<AssetT>()
            });
        };
        let delegate_account = borrow_global_mut<DelegateAccount<AssetT>>(user_address);
        if (!vector::contains(&delegate_account.addresses, &_delegate_account)) {
            assert!(vector::length(&delegate_account.addresses) < 10, E_TOO_MANY_REGISTERED_ACCOUNT);
            vector::push_back(&mut delegate_account.addresses, _delegate_account);
        };
        if (!account::exists_at(_delegate_account)) {
            aptos_account::create_account(_delegate_account);
        };
    }

    public fun deposit<AssetT>(_host: &signer, _delegate_account: address, _amount: u64)
    acquires DelegateAccount, DelegateAccountVaultEvents {
        let user_address = address_of(_host);
        register<AssetT>(_host, _delegate_account);

        let delegate_account = borrow_global_mut<DelegateAccount<AssetT>>(user_address);
        let asset = coin::withdraw<AssetT>(_host, _amount);
        coin::merge(&mut delegate_account.vault, asset);

        event::emit_event(
            &mut borrow_global_mut<DelegateAccountVaultEvents>(@merkle).delegate_account_vault_events,
            DelegateAccountVaultEvent {
                user: user_address,
                amount: _amount,
                event_type: T_VAULT_DEPOSIT
            }
        );
    }

    public fun withdraw<AssetT>(_host: &signer, _amount: u64) acquires DelegateAccount, DelegateAccountVaultEvents {
        let user_address = address_of(_host);
        let delegate_account = borrow_global_mut<DelegateAccount<AssetT>>(user_address);
        let asset = coin::extract(&mut delegate_account.vault, _amount);
        coin::deposit(user_address, asset);

        event::emit_event(
            &mut borrow_global_mut<DelegateAccountVaultEvents>(@merkle).delegate_account_vault_events,
            DelegateAccountVaultEvent {
                user: user_address,
                amount: _amount,
                event_type: T_VAULT_WITHDRAW
            }
        );
    }

    public fun unregister<AssetT>(_host: &signer) acquires DelegateAccount {
        let user_address = address_of(_host);
        let delegate_account = borrow_global_mut<DelegateAccount<AssetT>>(user_address);
        let asset = coin::extract_all(&mut delegate_account.vault);
        coin::deposit(user_address, asset);
        while(vector::length(&delegate_account.addresses) > 0) {
            vector::pop_back(&mut delegate_account.addresses);
        };
    }

    public(friend) fun deposit_from_trading<AssetT>(_user_address: address, _asset: coin::Coin<AssetT>)
    acquires DelegateAccount {
        let delegate_account = borrow_global_mut<DelegateAccount<AssetT>>(_user_address);
        coin::merge(&mut delegate_account.vault, _asset);
    }

    public(friend) fun withdraw_to_trading<AssetT>(_user_address: address, _amount: u64): coin::Coin<AssetT>
    acquires DelegateAccount {
        let delegate_account = borrow_global_mut<DelegateAccount<AssetT>>(_user_address);
        coin::extract(&mut delegate_account.vault, _amount)
    }

    #[test_only]
    struct TEST_USDC has store, drop {}

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::aptos_coin;

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

        initialize_module(host);
        create_test_coins<TEST_USDC>(host, b"USDC", 6, 1000000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, delegate_account = @0xC0FFEE)]
    fun T_register(host: &signer, aptos_framework: &signer, delegate_account: &signer) acquires DelegateAccount {
        call_test_setting(host, aptos_framework);
        assert!(is_active<TEST_USDC>(address_of(host)) == false, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account)) == false, 0);
        register<TEST_USDC>(host, address_of(delegate_account));
        assert!(is_active<TEST_USDC>(address_of(host)) == true, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account)) == true, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, delegate_account = @0xC0FFEE)]
    fun T_unregister(host: &signer, aptos_framework: &signer, delegate_account: &signer)
    acquires DelegateAccount {
        call_test_setting(host, aptos_framework);
        register<TEST_USDC>(host, address_of(delegate_account));
        assert!(is_active<TEST_USDC>(address_of(host)) == true, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account)) == true, 0);
        unregister<TEST_USDC>(host);
        assert!(is_active<TEST_USDC>(address_of(host)) == false, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account)) == false, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, delegate_account = @0xC0FFEE)]
    fun T_deposit(host: &signer, aptos_framework: &signer, delegate_account: &signer)
    acquires DelegateAccount, DelegateAccountVaultEvents {
        call_test_setting(host, aptos_framework);
        assert!(is_active<TEST_USDC>(address_of(host)) == false, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account)) == false, 0);
        let before_amount = coin::balance<TEST_USDC>(address_of(host));
        deposit<TEST_USDC>(host, address_of(delegate_account), 10000);
        assert!(is_active<TEST_USDC>(address_of(host)) == true, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account)) == true, 0);
        assert!(before_amount - coin::balance<TEST_USDC>(address_of(host)) == 10000, 0);

        let delegate_account = borrow_global<DelegateAccount<TEST_USDC>>(address_of(host));
        let amount = coin::value(&delegate_account.vault);
        assert!(amount == 10000, 0)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, delegate_account = @0xC0FFEE)]
    fun T_withdraw(host: &signer, aptos_framework: &signer, delegate_account: &signer)
    acquires DelegateAccount, DelegateAccountVaultEvents {
        call_test_setting(host, aptos_framework);
        coin::balance<TEST_USDC>(address_of(host));
        deposit<TEST_USDC>(host, address_of(delegate_account), 10000);
        let before_amount = coin::balance<TEST_USDC>(address_of(host));
        withdraw<TEST_USDC>(host, 10000);
        assert!(coin::balance<TEST_USDC>(address_of(host)) - before_amount == 10000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, delegate_account = @0xC0FFEE, delegate_account2 = @0xCAFE)]
    fun T_register_multiple_addresses(host: &signer, aptos_framework: &signer, delegate_account: &signer, delegate_account2: &signer)
    acquires DelegateAccount {
        call_test_setting(host, aptos_framework);
        register<TEST_USDC>(host, address_of(delegate_account));
        register<TEST_USDC>(host, address_of(delegate_account2));
        assert!(is_active<TEST_USDC>(address_of(host)) == true, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account)) == true, 0);
        assert!(is_registered<TEST_USDC>(address_of(host), address_of(delegate_account2)) == true, 0);
        register<TEST_USDC>(host, address_of(delegate_account));
        let delegate_account = borrow_global<DelegateAccount<TEST_USDC>>(address_of(host));
        assert!(vector::length(&delegate_account.addresses) == 2, 0);
    }
    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_TOO_MANY_REGISTERED_ACCOUNT, location = Self)]
    fun T_register_too_many_registered(host: &signer, aptos_framework: &signer)
    acquires DelegateAccount {
        call_test_setting(host, aptos_framework);
        register<TEST_USDC>(host, @0xA);
        register<TEST_USDC>(host, @0xB);
        register<TEST_USDC>(host, @0xC);
        register<TEST_USDC>(host, @0xD);
        register<TEST_USDC>(host, @0xE);
        register<TEST_USDC>(host, @0xF);
        register<TEST_USDC>(host, @0xAA);
        register<TEST_USDC>(host, @0xBB);
        register<TEST_USDC>(host, @0xCC);
        register<TEST_USDC>(host, @0xDD);
        {
            let delegate_account = borrow_global<DelegateAccount<TEST_USDC>>(address_of(host));
            assert!(vector::length(&delegate_account.addresses) == 10, 0);
        };
        register<TEST_USDC>(host, @0xEE);
    }
}