module merkle::claimable_fa_store {
    use std::bcs;
    use std::signer::address_of;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::transaction_context;

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When deposit invalid fungible asset
    const E_INVALID_FA: u64 = 1;

    struct ClaimableFaStore has key {
        fungible_store: Object<FungibleStore>,
        signer_cap: SignerCapability,
    }

    struct ClaimCapability has store, drop {
        resource_account: address
    }

    struct AdminCapability has store, drop {
        resource_account: address,
        extend_ref: object::ExtendRef,
        delete_ref: object::DeleteRef,
    }

    // <--- funding store --->
    public fun add_claimable_fa_store(_user: &signer, _metadata: Object<Metadata>): AdminCapability {
        let (resource_signer, resource_signer_cap) = account::create_resource_account(_user, bcs::to_bytes(&transaction_context::generate_auid_address()));
        let constructor_ref = object::create_object(address_of(&resource_signer));
        let fungible_store = primary_fungible_store::ensure_primary_store_exists(address_of(&resource_signer), _metadata);

        move_to(&resource_signer, ClaimableFaStore {
            fungible_store,
            signer_cap: resource_signer_cap,
        });
        AdminCapability {
            resource_account: address_of(&resource_signer),
            extend_ref: object::generate_extend_ref(&constructor_ref),
            delete_ref: object::generate_delete_ref(&constructor_ref)
        }
    }

    public fun deposit_funding_store_with_admin_cap(_user: &signer, _admin_cap: &AdminCapability, _amount: u64)
    acquires ClaimableFaStore {
        deposit_funding_store(_user, _admin_cap.resource_account, _amount);
    }

    public fun deposit_funding_store(_user: &signer, _resource_account: address, _amount: u64)
    acquires ClaimableFaStore {
        let claimable_fa_store = borrow_global<ClaimableFaStore>(_resource_account);
        let metadata = fungible_asset::store_metadata(claimable_fa_store.fungible_store);
        let fungible_asset = primary_fungible_store::withdraw(_user, metadata, _amount);
        fungible_asset::deposit(claimable_fa_store.fungible_store, fungible_asset);
    }

    public fun deposit_funding_store_fa(_admin_cap: &AdminCapability, _fa: FungibleAsset)
    acquires ClaimableFaStore {
        let claimable_fa_store = borrow_global<ClaimableFaStore>(_admin_cap.resource_account);
        assert!(fungible_asset::metadata_from_asset(&_fa) == fungible_asset::store_metadata(claimable_fa_store.fungible_store), E_INVALID_FA);
        fungible_asset::deposit(claimable_fa_store.fungible_store, _fa);
    }

    public fun claim_funding_store(_claim_cap: &ClaimCapability, _amount: u64): FungibleAsset
    acquires ClaimableFaStore {
        let claimable_fa_store = borrow_global<ClaimableFaStore>(_claim_cap.resource_account);
        let signer = account::create_signer_with_capability(&claimable_fa_store.signer_cap);
        fungible_asset::withdraw(&signer, claimable_fa_store.fungible_store, _amount)
    }

    public fun mint_claim_capability(_admin_cap: &AdminCapability): ClaimCapability {
        assert!(exists<ClaimableFaStore>(_admin_cap.resource_account), E_NOT_AUTHORIZED);
        ClaimCapability { resource_account: _admin_cap.resource_account }
    }

    public fun get_metadata_by_uid(_claim_cap: &ClaimCapability): Object<Metadata>
    acquires ClaimableFaStore {
        let claimable_fa_store = borrow_global<ClaimableFaStore>(_claim_cap.resource_account);
        fungible_asset::store_metadata(claimable_fa_store.fungible_store)
    }

    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use merkle::mkl_token;

    #[test_only]
    struct TEST_USDC {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };

        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    fun T_add_funding_store(host: &signer, aptos_framework: &signer, coffee: &signer) {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(coffee));
        let admin_cap = add_claimable_fa_store(coffee, mkl_token::get_metadata());
        assert!(exists<ClaimableFaStore>(admin_cap.resource_account), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_deposit_funding_store(host: &signer, aptos_framework: &signer)
    acquires ClaimableFaStore {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 86400 * 30);
        let admin_cap = add_claimable_fa_store(host, mkl_token::get_metadata());

        let amount = 1000000;
        let cap = mkl_token::mint_claim_capability<mkl_token::COMMUNITY_POOL>(host);
        let mkl = mkl_token::claim_mkl_with_cap(&cap, amount);
        primary_fungible_store::deposit(address_of(host), mkl);
        deposit_funding_store(host, admin_cap.resource_account, amount);

        let claimable_fa_store = borrow_global<ClaimableFaStore>(admin_cap.resource_account);
        assert!(fungible_asset::balance(claimable_fa_store.fungible_store) == amount, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_claim_funding_store(host: &signer, aptos_framework: &signer)
    acquires ClaimableFaStore {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 86400 * 30);
        let admin_cap = add_claimable_fa_store(host, mkl_token::get_metadata());

        let amount = 1000000;
        let mkl_cap = mkl_token::mint_claim_capability<mkl_token::COMMUNITY_POOL>(host);
        let mkl = mkl_token::claim_mkl_with_cap(&mkl_cap, amount);
        primary_fungible_store::deposit(address_of(host), mkl);
        deposit_funding_store(host, admin_cap.resource_account, amount);

        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 0, 0);
        let claim_cap = mint_claim_capability(&admin_cap);
        let claimed_mkl = claim_funding_store(&claim_cap, amount);
        assert!(fungible_asset::amount(&claimed_mkl) == amount, 0);
        primary_fungible_store::deposit(address_of(host), claimed_mkl);
        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == amount, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_mint_claim_capability_not_authorized(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
        add_claimable_fa_store(host, mkl_token::get_metadata());
        mint_claim_capability(&AdminCapability {
            resource_account: @0xC0FFEE,
            extend_ref: object::generate_extend_ref(&object::create_object(@0xC0FFEE)),
            delete_ref: object::generate_delete_ref(&object::create_object(@0xC0FFEE))
        });
    }
}