module merkle::pMKL {
    use std::signer::address_of;
    use std::vector;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use merkle::blocked_user;
    use merkle::mkl_token;
    use merkle::pre_mkl_token;

    use merkle::safe_math::safe_mul_div;
    use merkle::esmkl_token;
    use merkle::season;

    friend merkle::trading;
    friend merkle::lootbox;
    friend merkle::lootbox_v2;

    const DAY_SECONDS: u64 = 60 * 60 * 24; // 1 day

    /// TGE season number
    const TGE_SEASON_NUMBER: u64 = 15;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When cannot claimable
    const E_NO_CLAIMABLE: u64 = 2;
    /// When claim already expired
    const E_CLAIM_EXPIRED: u64 = 3;

    // pMKL
    // decimals: 6
    struct PMKLInfo has key {
        season_pmkl: table::Table<u64, SeasonPMKLInfo>, // key = season
    }

    struct SeasonPMKLInfo has store {
        supply: u64,
        user_balance: table::Table<address, u64>,
        user_claimed: table::Table<address, u64>
    }

    struct RewardInfo has key {
        season_reward: table::Table<u64, u64>, // key = season, value = reward
    }

    struct CapabilityStore has key {
        esmkl_cap: esmkl_token::MintCapability,
        pre_mkl_cap: pre_mkl_token::ClaimCapability,
    }

    // return type
    struct SeasonUserPMKLInfoView has drop {
        season_number: u64,
        total_supply: u64,
        user_balance: u64
    }

    // return type
    struct SeasonPMKLSupplyView has drop {
        season_number: u64,
        total_supply: u64
    }

    // events
    struct PMKLEvents has key {
        mint_events: EventHandle<MintEvent>,
        claim_events: EventHandle<ClaimEvent>
    }

    struct MintEvent has drop, store {
        /// season number
        season_number: u64,
        /// user address
        user: address,
        /// minted pmkl
        amount: u64
    }

    struct ClaimEvent has drop, store {
        /// season number
        season_number: u64,
        /// user address
        user: address,
        /// minted pmkl
        amount: u64
    }

    public fun initialize_module(_admin: &signer) acquires RewardInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<PMKLInfo>(address_of(_admin))) {
            move_to(_admin, PMKLInfo {
                season_pmkl: table::new()
            });
        };

        if (!exists<PMKLEvents>(address_of(_admin))) {
            move_to(_admin, PMKLEvents {
                mint_events: new_event_handle<MintEvent>(_admin),
                claim_events: new_event_handle<ClaimEvent>(_admin)
            })
        };

        if (!exists<RewardInfo>(address_of(_admin))) {
            move_to(_admin, RewardInfo {
                season_reward: table::new()
            });
            let season_number = 1;
            // Until Season 14, claim from pre_tge_reward
            // After that, claim from pmkl_token
            let rewards_after_season = vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 423000000000, 412000000000, 401000000000, 390000000000, 390000000000];
            let reward_info = borrow_global_mut<RewardInfo>(address_of(_admin));
            vector::for_each(rewards_after_season, |reward| {
                let reward: u64 = reward;
                table::upsert(&mut reward_info.season_reward, season_number, reward);
                season_number = season_number + 1;
            });
        };

        if (!exists<CapabilityStore>(address_of(_admin))) {
            move_to(_admin, CapabilityStore {
                esmkl_cap: esmkl_token::mint_mint_capability(_admin),
                pre_mkl_cap: pre_mkl_token::mint_claim_capability(_admin)
            })
        };
    }

    public fun set_season_reward(_admin: &signer, _season_number: u64, _reward_amount: u64) acquires RewardInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let reward_info = borrow_global_mut<RewardInfo>(address_of(_admin));
        table::upsert(&mut reward_info.season_reward, _season_number, _reward_amount);
    }

    public(friend) fun mint_pmkl(_user_address: address, _amount: u64) acquires PMKLInfo, PMKLEvents {
        let season_pmkl_info = borrow_global_mut<PMKLInfo>(@merkle);
        let season_number = season::get_current_season_number();
        if (!table::contains(&season_pmkl_info.season_pmkl, season_number)) {
            table::add(&mut season_pmkl_info.season_pmkl, season_number, SeasonPMKLInfo {
                supply: 0,
                user_balance: table::new<address, u64>(),
                user_claimed: table::new<address, u64>(),
            });
        };
        let pmkl_info = table::borrow_mut(&mut season_pmkl_info.season_pmkl, season_number);
        pmkl_info.supply = pmkl_info.supply + _amount;
        if (!table::contains(&pmkl_info.user_balance, _user_address)) {
            table::add(&mut pmkl_info.user_balance, _user_address, 0);
        };
        let user_balance = table::borrow_mut(&mut pmkl_info.user_balance, _user_address);
        *user_balance = *user_balance + _amount;

        // emit event
        event::emit_event(&mut borrow_global_mut<PMKLEvents>(@merkle).mint_events, MintEvent {
            season_number,
            user: _user_address,
            amount: _amount
        });
    }

    fun get_user_season_pmkl_info(_season_pmkl_info: &SeasonPMKLInfo, _reward_info: &RewardInfo, _user_address: address, _season_number: u64): (u64, u64, u64) {
        let reward_amount = table::borrow_with_default(&_reward_info.season_reward, _season_number, &0);
        let user_pmkl_balance = table::borrow_with_default(&_season_pmkl_info.user_balance, _user_address, &0);
        let user_pmkl_claimed = table::borrow_with_default(&_season_pmkl_info.user_claimed, _user_address, &0);
        (*reward_amount, *user_pmkl_balance, *user_pmkl_claimed)
    }


    public fun claim_season_esmkl(_user: &signer, _season_number: u64)
    acquires PMKLInfo, PMKLEvents, RewardInfo, CapabilityStore {
        let user_address = address_of(_user);
        blocked_user::is_blocked(user_address);
        let now = timestamp::now_seconds();
        assert!(season::get_current_season_number() > TGE_SEASON_NUMBER, E_NO_CLAIMABLE);
        assert!(now - season::get_season_end_sec(_season_number) <= DAY_SECONDS * 7 * 4, E_CLAIM_EXPIRED); // claim expired, 4 weeks

        let pmkl_info = borrow_global_mut<PMKLInfo>(@merkle);
        let reward_info = borrow_global<RewardInfo>(@merkle);
        let season_pmkl_info = table::borrow_mut(&mut pmkl_info.season_pmkl, _season_number);
        let (reward_amount, user_pmkl_balance, user_pmkl_claimed) = get_user_season_pmkl_info(
            season_pmkl_info,
            reward_info,
            user_address,
            _season_number
        );
        let claim_amount = safe_mul_div(reward_amount, user_pmkl_balance - user_pmkl_claimed, season_pmkl_info.supply);

        assert!(claim_amount > 0, E_NO_CLAIMABLE);
        table::upsert(&mut season_pmkl_info.user_claimed, user_address, user_pmkl_balance);

        let capability_store = borrow_global<CapabilityStore>(@merkle);
        if (now < mkl_token::mkl_tge_at()) {
            pre_mkl_token::claim_user_pre_mkl(&capability_store.pre_mkl_cap, address_of(_user), claim_amount);
        } else {
            if (_season_number <= 18) {
                // until Season 18 rewards are given in preMKL and convert user's all preMKL to MKL.
                pre_mkl_token::claim_user_pre_mkl(&capability_store.pre_mkl_cap, address_of(_user), claim_amount);
                // swap all preMKL to MKL
                let swapped_mkl = pre_mkl_token::swap_pre_mkl_to_mkl(_user);
                primary_fungible_store::deposit(user_address, swapped_mkl);
            } else {
                let esmkl = esmkl_token::mint_esmkl_with_cap(&capability_store.esmkl_cap, claim_amount);
                esmkl_token::deposit_user_esmkl(_user, esmkl);
            };
        };

        // emit event
        event::emit_event(&mut borrow_global_mut<PMKLEvents>(@merkle).claim_events, ClaimEvent {
            season_number: _season_number,
            user: user_address,
            amount: claim_amount
        });
    }

    // <--- view --->
    public fun get_current_season_info(): SeasonPMKLSupplyView acquires PMKLInfo {
        let season_number = season::get_current_season_number();
        get_season_info(season_number)
    }

    public fun get_season_user_pmkl(_user_address: address, _season_number: u64): SeasonUserPMKLInfoView acquires PMKLInfo {
        let season_pmkl_info = borrow_global<PMKLInfo>(@merkle);
        if (!table::contains(&season_pmkl_info.season_pmkl, _season_number)) {
            return SeasonUserPMKLInfoView {
                season_number: _season_number,
                total_supply: 0,
                user_balance: 0
            }
        };
        let pmkl_info = table::borrow(&season_pmkl_info.season_pmkl, _season_number);
        if (!table::contains(&pmkl_info.user_balance, _user_address)) {
            return SeasonUserPMKLInfoView {
                season_number: _season_number,
                total_supply: pmkl_info.supply,
                user_balance: 0
            }
        };
        let user_balance = *table::borrow(&pmkl_info.user_balance, _user_address);
        SeasonUserPMKLInfoView {
            season_number: _season_number,
            total_supply: pmkl_info.supply,
            user_balance
        }
    }

    public fun get_season_info(_season_number: u64): SeasonPMKLSupplyView acquires PMKLInfo {
        let season_pmkl_info = borrow_global<PMKLInfo>(@merkle);
        if (!table::contains(&season_pmkl_info.season_pmkl, _season_number)) {
            return SeasonPMKLSupplyView {
                season_number: _season_number,
                total_supply: 0,
            }
        };
        let pmkl_info = table::borrow(&season_pmkl_info.season_pmkl, _season_number);
        SeasonPMKLSupplyView {
            season_number: _season_number,
            total_supply: pmkl_info.supply,
        }
    }

    public fun get_user_season_claimable(_user_address: address, _season_number: u64): u64
    acquires PMKLInfo, RewardInfo {
        if (_season_number < TGE_SEASON_NUMBER ||
            _season_number >= season::get_current_season_number() ||
            timestamp::now_seconds() - season::get_season_end_sec(_season_number) > DAY_SECONDS * 7 * 4) {
            return 0
        };
        let pmkl_info = borrow_global<PMKLInfo>(@merkle);
        if (!table::contains(&pmkl_info.season_pmkl, _season_number)) {
            return 0
        };
        let reward_info = borrow_global<RewardInfo>(@merkle);
        let season_pmkl_info = table::borrow(&pmkl_info.season_pmkl, _season_number);
        let (reward_amount, user_pmkl_balance, user_pmkl_claimed) = get_user_season_pmkl_info(
            season_pmkl_info,
            reward_info,
            _user_address,
            _season_number
        );
        safe_mul_div(reward_amount, user_pmkl_balance - user_pmkl_claimed, season_pmkl_info.supply)
    }

    // <--- test --->
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use merkle::mkl_token::{MKL};

    #[test_only]
    public fun get_user_pmkl_balance(_user_address: address, _season: u64): u64 acquires PMKLInfo {
        get_season_user_pmkl(_user_address, _season).user_balance
    }

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) acquires RewardInfo {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        season::initialize_module(host);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
        esmkl_token::initialize_module(host);
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_initialize_module(host: &signer, aptos_framework: &signer) acquires RewardInfo {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_mint_pmkl(host: &signer, aptos_framework: &signer) acquires PMKLInfo, PMKLEvents, RewardInfo {
        call_test_setting(host, aptos_framework);
        mint_pmkl(address_of(host), 100);
        mint_pmkl(address_of(aptos_framework), 200);
        let season_pmkl_info = borrow_global<PMKLInfo>(address_of(host));
        let season_number = season::get_current_season_number();
        let pmkl_info = table::borrow(&season_pmkl_info.season_pmkl, season_number);
        assert!(pmkl_info.supply == 300, 0);
        assert!(*table::borrow(&pmkl_info.user_balance, address_of(host)) == 100, 0);

        let user_pmkl_info = get_season_user_pmkl(address_of(host), season_number);
        assert!(user_pmkl_info.total_supply == 300, 0);
        assert!(user_pmkl_info.season_number == 1, 0);
        assert!(user_pmkl_info.user_balance == 100, 0);

        let current_season_info = get_current_season_info();
        assert!(current_season_info.total_supply == 300, 0);
        assert!(current_season_info.season_number == 1, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_next_season(host: &signer, aptos_framework: &signer) acquires PMKLInfo, PMKLEvents, RewardInfo {
        call_test_setting(host, aptos_framework);
        season::add_new_season(host, 24 * 60 * 60 * 28 * 2);

        mint_pmkl(address_of(host), 100);
        mint_pmkl(address_of(aptos_framework), 200);
        timestamp::fast_forward_seconds(24 * 60 * 60 * 28 + 1);
        mint_pmkl(address_of(host), 300);
        mint_pmkl(address_of(aptos_framework), 400);

        let season_number = season::get_current_season_number();
        let user_pmkl_info = get_season_user_pmkl(address_of(host), season_number);
        assert!(user_pmkl_info.total_supply == 700, 0);
        assert!(user_pmkl_info.season_number == 2, 0);
        assert!(user_pmkl_info.user_balance == 300, 0);

        let user_pmkl_info = get_season_user_pmkl(address_of(host), season_number - 1);
        assert!(user_pmkl_info.total_supply == 300, 0);
        assert!(user_pmkl_info.season_number == 1, 0);
        assert!(user_pmkl_info.user_balance == 100, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_get_user_season_claimable(host: &signer, aptos_framework: &signer) acquires PMKLInfo, PMKLEvents, RewardInfo {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 10);
        coin::register<MKL>(host);
        let season_duration = DAY_SECONDS * 7 * 2;
        let season_start_at = mkl_token::mkl_tge_at() - (TGE_SEASON_NUMBER - 1) * season_duration;
        season::set_season_end_sec(host, 1, season_start_at);
        let idx = 1;
        while(idx <= TGE_SEASON_NUMBER + 5) {
            season::add_new_season(host, season_start_at + idx * season_duration);
            idx = idx + 1;
        };
        // season 17
        mint_pmkl(address_of(host), 100); // 25%
        mint_pmkl(@0x001, 300);
        // season 19
        timestamp::fast_forward_seconds(season::get_season_end_sec(18) - timestamp::now_seconds() + 1);
        mint_pmkl(address_of(host), 100); // 25%
        mint_pmkl(@0x001, 300);
        timestamp::fast_forward_seconds(season_duration);

        let reward = borrow_global<RewardInfo>(address_of(host));
        let season_19_reward = *table::borrow(&reward.season_reward, 19);
        assert!(get_user_season_claimable(address_of(host), 17) == 0, 0);
        assert!(get_user_season_claimable(address_of(host), 19) == season_19_reward / 4, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    public fun T_claim_season_esmkl(host: &signer, aptos_framework: &signer, coffee: &signer)
    acquires PMKLInfo, PMKLEvents, RewardInfo, CapabilityStore {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(coffee));
        coin::register<MKL>(host);
        coin::register<MKL>(coffee);

        let season_start_at = mkl_token::mkl_tge_at() - 1000;
        season::set_season_end_sec(host, 1, season_start_at);
        let idx = 1;
        while(idx < TGE_SEASON_NUMBER + 17) {
            if (idx >= 18) {
                season::add_new_season(host, mkl_token::mkl_tge_at() + idx * 10);
            } else {
                season::add_new_season(host, season_start_at + idx * 10);
            };
            idx = idx + 1;
        };
        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);

        // current season 16
        timestamp::fast_forward_seconds(season::get_season_end_sec(15) - timestamp::now_seconds() + 1);
        mint_pmkl(address_of(host), 100); // 20%
        mint_pmkl(address_of(coffee), 400);
        // season 17
        timestamp::fast_forward_seconds(season::get_season_end_sec(16) - timestamp::now_seconds() + 1);

        claim_season_esmkl(host, 16);
        claim_season_esmkl(coffee, 16);

        let reward = borrow_global<RewardInfo>(address_of(host));
        let season_16_reward = *table::borrow(&reward.season_reward, 16);

        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == 0, 0);
        assert!(primary_fungible_store::balance(address_of(coffee), mkl_token::get_metadata()) == 0, 0);
        assert!(primary_fungible_store::balance(address_of(host), esmkl_token::get_metadata()) == 0, 0);
        assert!(primary_fungible_store::balance(address_of(coffee), esmkl_token::get_metadata()) == 0, 0);
        assert!(primary_fungible_store::balance(address_of(host), pre_mkl_token::get_metadata()) == season_16_reward / 5, 0);
        assert!(primary_fungible_store::balance(address_of(coffee), pre_mkl_token::get_metadata()) == season_16_reward / 5 * 4, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, coffee = @0xC0FFEE)]
    public fun T_claim_season_premkl(host: &signer, aptos_framework: &signer, coffee: &signer)
    acquires PMKLInfo, PMKLEvents, RewardInfo, CapabilityStore {
        call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(coffee));
        coin::register<MKL>(host);
        coin::register<MKL>(coffee);

        let season_start_at = mkl_token::mkl_tge_at() - 1000;
        season::set_season_end_sec(host, 1, season_start_at);
        let idx = 1;
        while(idx < TGE_SEASON_NUMBER + 10) {
            if (idx >= 17) {
                season::add_new_season(host, mkl_token::mkl_tge_at() + idx * 10);
            } else {
                season::add_new_season(host, season_start_at + idx * 10);
            };
            idx = idx + 1;
        };
        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);

        // current season 16
        timestamp::fast_forward_seconds(season::get_season_end_sec(15) - timestamp::now_seconds() + 1);
        mint_pmkl(address_of(host), 100); // 20%
        mint_pmkl(address_of(coffee), 400);
        // season 17
        timestamp::fast_forward_seconds(season::get_season_end_sec(16) - timestamp::now_seconds() + 1);
        claim_season_esmkl(host, 16); // pre_mkl
        claim_season_esmkl(coffee, 16); // pre_mkl

        // current season 18
        timestamp::fast_forward_seconds(season::get_season_end_sec(17) - timestamp::now_seconds() + 1);
        mint_pmkl(address_of(host), 200); // 40%
        mint_pmkl(address_of(coffee), 300);
        // season 19
        timestamp::fast_forward_seconds(season::get_season_end_sec(18) - timestamp::now_seconds() + 1);
        claim_season_esmkl(host, 18); // mkl (pre_mkl -> mkl)
        claim_season_esmkl(coffee, 18); // mkl (pre_mkl -> mkl)

        // current season 19
        mint_pmkl(address_of(host), 400); // 80%
        mint_pmkl(address_of(coffee), 100);
        // season 20
        timestamp::fast_forward_seconds(season::get_season_end_sec(19) - timestamp::now_seconds() + 1);
        claim_season_esmkl(host, 19); // esmkl
        claim_season_esmkl(coffee, 19); // esmkl

        let reward = borrow_global<RewardInfo>(address_of(host));
        let season_16_reward = *table::borrow(&reward.season_reward, 16);
        let season_18_reward = *table::borrow(&reward.season_reward, 18);
        let season_19_reward = *table::borrow(&reward.season_reward, 19);

        assert!(primary_fungible_store::balance(address_of(host), mkl_token::get_metadata()) == season_18_reward / 5 * 2 + season_16_reward / 5, 0);
        assert!(primary_fungible_store::balance(address_of(coffee), mkl_token::get_metadata()) == season_18_reward / 5 * 3 + season_16_reward / 5 * 4, 0);
        assert!(primary_fungible_store::balance(address_of(host), esmkl_token::get_metadata()) == season_19_reward / 5 * 4, 0);
        assert!(primary_fungible_store::balance(address_of(coffee), esmkl_token::get_metadata()) == season_19_reward / 5, 0);
        assert!(primary_fungible_store::balance(address_of(host), pre_mkl_token::get_metadata()) == 0, 0);
        assert!(primary_fungible_store::balance(address_of(coffee), pre_mkl_token::get_metadata()) == 0, 0);
    }
}