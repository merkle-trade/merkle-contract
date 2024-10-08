module merkle::mkl_token {
    friend merkle::staking;
    friend merkle::liquidity_auction;

    use std::option;
    use std::vector;
    use std::signer::address_of;
    use std::string::{Self, String};
    use aptos_std::type_info;
    use aptos_framework::account::{new_event_handle};
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata, FungibleAsset};
    use aptos_framework::object::{Self, Object};

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When not enough claimable
    const E_NOT_ENOUGH_CLAIMABLE: u64 = 1;
    /// When esmkl is not claimable
    const E_NOT_CLAIMABLE: u64 = 2;

    const MKL_SYMBOL: vector<u8> = b"MKL";
    const PRECISION: u64 = 1000000;

    // <-- MKL Distribution ----->
    const MKL_GENERATE_AT_SEC: u64 = 1725537600; // 2024-09-05T12:00:00.000Z
    const DAY_SECONDS: u64 = 86400;

    struct MKL {}

    struct COMMUNITY_POOL {}
    struct GROWTH_POOL {}
    struct CORE_TEAM_POOL {}
    struct INVESTOR_POOL {}
    struct ADVISOR_POOL {}

    struct MklConfig has key, drop {
        mint_ref: fungible_asset::MintRef,
        transfer_ref: fungible_asset::TransferRef,
        burn_ref: fungible_asset::BurnRef
    }
    struct MklCoinConfig has key {
        mc: coin::MintCapability<MKL>,
        bc: coin::BurnCapability<MKL>,
        fc: coin::FreezeCapability<MKL>,
    }
    struct PoolStore<phantom PoolType> has key {
        mkl: Object<FungibleStore>, // object address for fungible store
        monthly_unlock_amounts: vector<u64>
    }
    struct ClaimCapability<phantom PoolType> has store, drop {}

    // <-- Events ----->
    struct MerkleTokenEvents has key {
        mkl_claim_events: EventHandle<MklClaimEvent>,
    }
    struct MklClaimEvent has drop, store {
        pool_type: String,
        mkl_amount: u64,
    }

    public fun initialize_module(_admin: &signer)
    acquires MklConfig {
        assert!(@merkle == address_of(_admin), E_NOT_AUTHORIZED);

        if (!exists<MklCoinConfig>(address_of(_admin))) {
            let (bc, fc, mc) = coin::initialize<MKL>(_admin,
                string::utf8(MKL_SYMBOL),
                string::utf8(MKL_SYMBOL),
                6,
                false);
            let fa = coin::coin_to_fungible_asset(coin::zero<MKL>()); // initialize FA and connect Coin <> FA pair
            let (burn_ref, burn_ref_recipt) = coin::get_paired_burn_ref(&bc);
            fungible_asset::burn(&burn_ref, fa);
            coin::return_paired_burn_ref(burn_ref, burn_ref_recipt);

            move_to(
                _admin,
                MklCoinConfig {
                    mc,
                    bc,
                    fc
                }
            );
        };
        if (exists<MklConfig>(address_of(_admin))) {
            move_from<MklConfig>(address_of(_admin));
        };

        if (!exists<MerkleTokenEvents>(address_of(_admin))) {
            move_to(_admin, MerkleTokenEvents {
                mkl_claim_events: new_event_handle<MklClaimEvent>(_admin)
            })
        };
    }

    public fun get_metadata(): Object<Metadata> {
        option::extract(&mut coin::paired_metadata<MKL>())
    }

    fun create_pool_fungible_store<PoolType>(_admin: &signer, _mint_ref: &fungible_asset::MintRef, _amount: u64, _monthly_unlock_amounts: vector<u64>): PoolStore<PoolType> {
        let constructor_ref = object::create_object(address_of(_admin));
        let store = fungible_asset::create_store(&constructor_ref, get_metadata());
        fungible_asset::deposit(store, fungible_asset::mint(_mint_ref, _amount));
        PoolStore<PoolType> {
            mkl: store,
            monthly_unlock_amounts: _monthly_unlock_amounts
        }
    }

    public fun run_token_generation_event(_admin: &signer) acquires MklCoinConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let community_amount: u64 = 46_000_000_000000; // 46,000,000 * 10^6
        let growth_amount: u64 = 17_000_000_000000; // 17,000,000 * 10^6
        let core_team_amount: u64 = 20_000_000_000000; // 20,000,000 * 10^6
        let investor_amount: u64 = 14_000_000_000000; // 14,000,000 * 10^6
        let advisor_amount: u64 = 3_000_000_000000; // 3,000,000 * 10^6

        // mkl vaults
        let mkl_coin_config = borrow_global<MklCoinConfig>(address_of(_admin));
        let (mint_ref, mint_ref_receipt) = coin::get_paired_mint_ref(&mkl_coin_config.mc);
        move_to(_admin, create_pool_fungible_store<COMMUNITY_POOL>(_admin, &mint_ref, community_amount, vector[0, 9500000000000, 10400509123825, 11284809083421, 12153191643744, 13005943317981, 13843345462082, 14665674367589, 15473201352797, 16266192852271, 17044910504755, 17809611239494, 18560547361008, 19297966632335, 20022112356777, 20733223458180, 21431534559757, 22117276061506, 22790674216224, 23451951204156, 24101325206306, 24739010476417, 25365217411667, 25980152622081, 26584018998708, 27177015780556, 27759338620331, 28331179648990, 28892727539132, 29444167567253, 29985681674867, 30517448528544, 31039643578855, 31552439118260, 32056004337956, 32550505383697, 33036105410616, 33512964637049, 33981240397407, 34441087194078, 34892656748409, 35336098050763, 35771557409674, 36199178500124, 36619102410947, 37031467691374, 37436410396754, 37834064133437, 38224560102860, 38608027144833, 38984591780051, 39354378251835, 39717508567126, 40074102536743, 40424277814906, 40768149938062, 41105832363002, 41437436504292, 41763071771040, 42082845602986, 42396863505957, 42705229086674, 43008044086939, 43305408417198, 43597420189513, 43884175749927, 44165769710253, 44442294979293, 44713842793490, 44980502747032, 45242362821410, 45499509414449, 45752027368814, 46000000000000]));
        move_to(_admin, create_pool_fungible_store<GROWTH_POOL>(_admin, &mint_ref, growth_amount, vector[0, 4000000000000, 4250000000000, 4500000000000, 4750000000000, 5000000000000, 5250000000000, 5500000000000, 5750000000000, 6000000000000, 6250000000000, 6500000000000, 6750000000000, 7000000000000, 7250000000000, 7500000000000, 7750000000000, 8000000000000, 8250000000000, 8500000000000, 8750000000000, 9000000000000, 9250000000000, 9500000000000, 9750000000000, 10000000000000, 10250000000000, 10500000000000, 10750000000000, 11000000000000, 11250000000000, 11500000000000, 11750000000000, 12000000000000, 12250000000000, 12500000000000, 12750000000000, 13000000000000, 13250000000000, 13500000000000, 13750000000000, 14000000000000, 14250000000000, 14500000000000, 14750000000000, 15000000000000, 15250000000000, 15500000000000, 15750000000000, 16000000000000, 16250000000000, 16500000000000, 16750000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000, 17000000000000]));
        move_to(_admin, create_pool_fungible_store<CORE_TEAM_POOL>(_admin, &mint_ref, core_team_amount, vector[0, 0, 0, 0, 0, 0, 0, 555555555556, 1111111111111, 1666666666667, 2222222222222, 2777777777778, 3333333333333, 3888888888889, 4444444444444, 5000000000000, 5555555555556, 6111111111111, 6666666666667, 7222222222222, 7777777777778, 8333333333333, 8888888888889, 9444444444444, 10000000000000, 10555555555556, 11111111111111, 11666666666667, 12222222222222, 12777777777778, 13333333333333, 13888888888889, 14444444444444, 15000000000000, 15555555555556, 16111111111111, 16666666666667, 17222222222222, 17777777777778, 18333333333333, 18888888888889, 19444444444444, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000, 20000000000000]));
        move_to(_admin, create_pool_fungible_store<INVESTOR_POOL>(_admin, &mint_ref, investor_amount, vector[0, 0, 0, 0, 0, 0, 0, 583333333333, 1166666666667, 1750000000000, 2333333333333, 2916666666667, 3500000000000, 4083333333333, 4666666666667, 5250000000000, 5833333333333, 6416666666667, 7000000000000, 7583333333333, 8166666666667, 8750000000000, 9333333333333, 9916666666667, 10500000000000, 11083333333333, 11666666666667, 12250000000000, 12833333333333, 13416666666667, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000, 14000000000000]));
        move_to(_admin, create_pool_fungible_store<ADVISOR_POOL>(_admin, &mint_ref, advisor_amount, vector[0, 0, 0, 0, 0, 0, 0, 125000000000, 250000000000, 375000000000, 500000000000, 625000000000, 750000000000, 875000000000, 1000000000000, 1125000000000, 1250000000000, 1375000000000, 1500000000000, 1625000000000, 1750000000000, 1875000000000, 2000000000000, 2125000000000, 2250000000000, 2375000000000, 2500000000000, 2625000000000, 2750000000000, 2875000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000, 3000000000000]));
        coin::return_paired_mint_ref(mint_ref, mint_ref_receipt);
    }

    public fun get_unlock_amount<PoolType>(): u64 acquires PoolStore {
        if (timestamp::now_seconds() < MKL_GENERATE_AT_SEC || !exists<PoolStore<PoolType>>(@merkle)) {
            return 0
        };
        let pool_store = borrow_global<PoolStore<PoolType>>(@merkle);
        let elapsed_time = timestamp::now_seconds() - MKL_GENERATE_AT_SEC;
        let month_duration_sec = (DAY_SECONDS * 365 / 12);
        let idx = elapsed_time / month_duration_sec + 1;
        if (idx >= vector::length(&pool_store.monthly_unlock_amounts)) {
            return *vector::borrow(&pool_store.monthly_unlock_amounts, vector::length(&pool_store.monthly_unlock_amounts) - 1)
        };
        *vector::borrow(&pool_store.monthly_unlock_amounts, idx)
    }

    public fun get_allocation<PoolType>(): u64 acquires PoolStore {
        let pool_store = borrow_global<PoolStore<PoolType>>(@merkle);
        *vector::borrow(&pool_store.monthly_unlock_amounts, vector::length(&pool_store.monthly_unlock_amounts) - 1)
    }

    public fun claim_mkl_with_cap<PoolType>(_cap: &ClaimCapability<PoolType>, _amount: u64): FungibleAsset
    acquires PoolStore, MerkleTokenEvents, MklCoinConfig {
        if (_amount == 0) {
            return fungible_asset::zero(get_metadata())
        };
        let now = timestamp::now_seconds();
        assert!(now >= mkl_tge_at(), E_NOT_CLAIMABLE);
        let alloc = get_allocation<PoolType>();
        let unlock_amount = get_unlock_amount<PoolType>();
        let pool_store = borrow_global<PoolStore<PoolType>>(@merkle);
        let balance = fungible_asset::balance(pool_store.mkl);
        assert!(alloc - balance + _amount <= unlock_amount, E_NOT_ENOUGH_CLAIMABLE); // check claimable

        // emit event
        event::emit_event(&mut borrow_global_mut<MerkleTokenEvents>(@merkle).mkl_claim_events, MklClaimEvent {
            pool_type: string::utf8(type_info::struct_name(&type_info::type_of<PoolType>())),
            mkl_amount: _amount,
        });

        let mkl_coin_config = borrow_global<MklCoinConfig>(@merkle);
        let (transfer_ref, transfer_ref_receipt) = coin::get_paired_transfer_ref(&mkl_coin_config.fc);
        let fa = fungible_asset::withdraw_with_ref(&transfer_ref, pool_store.mkl, _amount);
        coin::return_paired_transfer_ref(transfer_ref, transfer_ref_receipt);
        fa
    }

    public fun mint_claim_capability<PoolType>(_admin: &signer): ClaimCapability<PoolType> {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        ClaimCapability<PoolType> {}
    }

    public(friend) fun freeze_mkl_store(_store: &Object<FungibleStore>, frozen: bool)
    acquires MklCoinConfig {
        let mkl_coin_config = borrow_global<MklCoinConfig>(@merkle);
        let (transfer_ref, transfer_ref_receipt) = coin::get_paired_transfer_ref(&mkl_coin_config.fc);
        fungible_asset::set_frozen_flag(&transfer_ref, *_store, frozen);
        coin::return_paired_transfer_ref(transfer_ref, transfer_ref_receipt);
    }

    public(friend) fun deposit_to_freezed_mkl_store(_store: &Object<FungibleStore>, _fa: FungibleAsset)
    acquires MklCoinConfig {
        let mkl_coin_config = borrow_global<MklCoinConfig>(@merkle);
        let (transfer_ref, transfer_ref_receipt) = coin::get_paired_transfer_ref(&mkl_coin_config.fc);
        fungible_asset::deposit_with_ref(&transfer_ref, *_store, _fa);
        coin::return_paired_transfer_ref(transfer_ref, transfer_ref_receipt);
    }

    public(friend) fun withdraw_from_freezed_mkl_store(_store: &Object<FungibleStore>, _amount: u64): FungibleAsset
    acquires MklCoinConfig {
        let mkl_coin_config = borrow_global<MklCoinConfig>(@merkle);
        let (transfer_ref, transfer_ref_receipt) = coin::get_paired_transfer_ref(&mkl_coin_config.fc);
        let fa = fungible_asset::withdraw_with_ref(&transfer_ref, *_store, _amount);
        coin::return_paired_transfer_ref(transfer_ref, transfer_ref_receipt);
        fa
    }

    public fun mkl_tge_at(): u64{
        MKL_GENERATE_AT_SEC
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
    use aptos_framework::primary_fungible_store;

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) acquires MklCoinConfig, MklConfig {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::update_global_time_for_test_secs(mkl_tge_at() + 100);
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        initialize_module(host);
        run_token_generation_event(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) acquires MklCoinConfig, MklConfig {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module_exist_resource(host: &signer, aptos_framework: &signer) acquires MklCoinConfig, MklConfig {
        call_test_setting(host, aptos_framework);
        initialize_module(host);
    }

    #[test(host = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_initialize_module_error_not_authorized(host: &signer) acquires MklConfig {
        initialize_module(host);
    }

    #[test(admin = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_set_schedule_info_error_not_authorized(admin: &signer) acquires MklCoinConfig {
        run_token_generation_event(admin);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_claim_mkl(host: &signer, aptos_framework: &signer) acquires MerkleTokenEvents, PoolStore, MklCoinConfig, MklConfig {
        call_test_setting(host, aptos_framework);
        let cap = mint_claim_capability<COMMUNITY_POOL>(host);
        let mkl = claim_mkl_with_cap<COMMUNITY_POOL>(&cap, 100000);
        assert!(fungible_asset::amount(&mkl) == 100000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NOT_ENOUGH_CLAIMABLE)]
    fun T_claim_mkl_error_not_enough_claimable(host: &signer, aptos_framework: &signer, user: &signer) acquires PoolStore, MerkleTokenEvents, MklCoinConfig, MklConfig {
        call_test_setting(host, aptos_framework);
        let cap = mint_claim_capability<COMMUNITY_POOL>(host);
        aptos_account::create_account(address_of(user));
        let u64_max = 18446744073709551615;
        primary_fungible_store::deposit(address_of(host), claim_mkl_with_cap<COMMUNITY_POOL>(&cap, u64_max));
    }

    #[test(admin = @0x0)]
    #[expected_failure(abort_code = E_NOT_AUTHORIZED)]
    fun T_generate_admin_cap_error_not_authorized(admin: &signer) {
        mint_claim_capability<COMMUNITY_POOL>(admin);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_mkl_pool_util_function(host: &signer, aptos_framework: &signer) acquires PoolStore, MklCoinConfig, MklConfig {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_tge_at() + 365 * DAY_SECONDS * 6);
        assert!(get_allocation<COMMUNITY_POOL>() == fungible_asset::balance(borrow_global<PoolStore<COMMUNITY_POOL>>(@merkle).mkl), 0);
        assert!(get_allocation<COMMUNITY_POOL>() == get_unlock_amount<COMMUNITY_POOL>(), 0);

        assert!(get_allocation<GROWTH_POOL>() == fungible_asset::balance(borrow_global<PoolStore<GROWTH_POOL>>(@merkle).mkl), 0);
        assert!(get_allocation<GROWTH_POOL>() == get_unlock_amount<GROWTH_POOL>(), 0);

        assert!(get_allocation<CORE_TEAM_POOL>() == fungible_asset::balance(borrow_global<PoolStore<CORE_TEAM_POOL>>(@merkle).mkl), 0);
        assert!(get_allocation<CORE_TEAM_POOL>() == get_unlock_amount<CORE_TEAM_POOL>(), 0);

        assert!(get_allocation<INVESTOR_POOL>() == fungible_asset::balance(borrow_global<PoolStore<INVESTOR_POOL>>(@merkle).mkl), 0);
        assert!(get_allocation<INVESTOR_POOL>() == get_unlock_amount<INVESTOR_POOL>(), 0);

        assert!(get_allocation<ADVISOR_POOL>() == fungible_asset::balance(borrow_global<PoolStore<ADVISOR_POOL>>(@merkle).mkl), 0);
        assert!(get_allocation<ADVISOR_POOL>() == get_unlock_amount<ADVISOR_POOL>(), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_mkl_pool_util_function2(host: &signer, aptos_framework: &signer) acquires PoolStore, MklCoinConfig, MklConfig {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds((mkl_tge_at() + 35 * DAY_SECONDS) - timestamp::now_seconds());
        assert!(get_unlock_amount<COMMUNITY_POOL>() == 10400509123825, 0);
        assert!(get_unlock_amount<GROWTH_POOL>() == 4250000000000, 0);
        assert!(get_unlock_amount<CORE_TEAM_POOL>() == 0, 0);
        assert!(get_unlock_amount<INVESTOR_POOL>() == 0, 0);
        assert!(get_unlock_amount<ADVISOR_POOL>() == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_CLAIMABLE, location = Self)]
    fun T_claim_E_NOT_CLAIMABLE(host: &signer, aptos_framework: &signer)
    acquires PoolStore, MerkleTokenEvents, MklCoinConfig, MklConfig {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);
        initialize_module(host);

        let cap = mint_claim_capability<COMMUNITY_POOL>(host);
        let mkl = claim_mkl_with_cap<COMMUNITY_POOL>(&cap, 100000);
        assert!(fungible_asset::amount(&mkl) == 100000, 0);
        primary_fungible_store::deposit(address_of(host), mkl);
    }
}