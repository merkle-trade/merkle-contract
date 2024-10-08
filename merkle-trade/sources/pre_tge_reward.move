module merkle::pre_tge_reward {

    use std::signer::address_of;
    use std::vector;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use merkle::blocked_user;

    use merkle::pre_mkl_token;
    use merkle::mkl_token;

    const DAY_SECONDS: u64 = 60 * 60 * 24; // 1 day

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When cannot claimable
    const E_NO_CLAIMABLE: u64 = 2;
    /// When claim already expired
    const E_CLAIM_EXPIRED: u64 = 3;

    struct PreTgeRewards has key {
        user_pre_tge_reward: table::Table<address, PreTgeRewardInfo>
    }

    struct PreTgeRewardInfo has store, drop {
        point_reward: u64,
        point_reward_claimed: bool,
        lp_reward: u64,
        lp_reward_claimed: bool,
    }

    struct MklClaimCapacityStore has key {
        pre_mkl_cap: pre_mkl_token::ClaimCapability,
        mkl_cap: mkl_token::ClaimCapability<mkl_token::COMMUNITY_POOL>
    }

    // <-- Events ----->
    struct PreTgeRewardEvents has key {
        point_claim_events: EventHandle<ClaimEvent>,
        lp_claim_events: EventHandle<ClaimEvent>
    }

    struct ClaimEvent has drop, store {
        /// user address
        user: address,
        /// minted pmkl
        amount: u64
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);

        if (!exists<PreTgeRewards>(address_of(_admin))) {
            move_to(_admin, PreTgeRewards {
                user_pre_tge_reward: table::new(),
            })
        };
        if (!exists<PreTgeRewardEvents>(address_of(_admin))) {
            move_to(_admin, PreTgeRewardEvents {
                point_claim_events: new_event_handle<ClaimEvent>(_admin),
                lp_claim_events: new_event_handle<ClaimEvent>(_admin),
            })
        };
        if (!exists<MklClaimCapacityStore>(address_of(_admin))) {
            move_to(_admin, MklClaimCapacityStore {
                pre_mkl_cap: pre_mkl_token::mint_claim_capability(_admin),
                mkl_cap: mkl_token::mint_claim_capability<mkl_token::COMMUNITY_POOL>(_admin)
            });
        };
    }

    fun check_season_expire() {
        let now = timestamp::now_seconds();
        assert!(now >= pre_mkl_token::pre_mkl_tge_at(), E_NO_CLAIMABLE);
        assert!(now <= mkl_token::mkl_tge_at() + DAY_SECONDS * 7 * 12, E_CLAIM_EXPIRED); // claim expired, 12 weeks
    }

    public fun claim_point_reward(_user: &signer)
    acquires PreTgeRewards, MklClaimCapacityStore, PreTgeRewardEvents {
        check_season_expire();
        let user_address = address_of(_user);
        let pre_tge_rewards = borrow_global_mut<PreTgeRewards>(@merkle);
        let user_pre_tge_reward_info = table::borrow_mut(&mut pre_tge_rewards.user_pre_tge_reward, user_address);
        assert!(!user_pre_tge_reward_info.point_reward_claimed, E_NO_CLAIMABLE);

        claim_internal(user_address, user_pre_tge_reward_info.point_reward);
        user_pre_tge_reward_info.point_reward_claimed = true;

        // emit event
        event::emit_event(&mut borrow_global_mut<PreTgeRewardEvents>(@merkle).point_claim_events, ClaimEvent {
            user: user_address,
            amount: user_pre_tge_reward_info.point_reward
        });
    }

    public fun claim_lp_reward(_user: &signer)
    acquires PreTgeRewards, MklClaimCapacityStore, PreTgeRewardEvents {
        check_season_expire();
        let user_address = address_of(_user);
        let pre_tge_rewards = borrow_global_mut<PreTgeRewards>(@merkle);
        let user_pre_tge_reward_info = table::borrow_mut(&mut pre_tge_rewards.user_pre_tge_reward, user_address);
        assert!(!user_pre_tge_reward_info.lp_reward_claimed, E_NO_CLAIMABLE);

        claim_internal(user_address, user_pre_tge_reward_info.lp_reward);
        user_pre_tge_reward_info.lp_reward_claimed = true;

        // emit event
        event::emit_event(&mut borrow_global_mut<PreTgeRewardEvents>(@merkle).lp_claim_events, ClaimEvent {
            user: user_address,
            amount: user_pre_tge_reward_info.lp_reward
        });
    }

    fun claim_internal(_user_address: address, _amount: u64)
    acquires MklClaimCapacityStore {
        blocked_user::is_blocked(_user_address);
        let now = timestamp::now_seconds();
        let claim_capability_store = borrow_global<MklClaimCapacityStore>(@merkle);
        if (now < mkl_token::mkl_tge_at()) {
            pre_mkl_token::claim_user_pre_mkl(&claim_capability_store.pre_mkl_cap, _user_address, _amount);
        } else {
            let mkl = mkl_token::claim_mkl_with_cap(&claim_capability_store.mkl_cap, _amount);
            primary_fungible_store::deposit(_user_address, mkl);
        };
    }

    public fun set_point_reward(_admin: &signer, _user_address: address, _reward: u64)
    acquires PreTgeRewards {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let pre_tge_rewards = borrow_global_mut<PreTgeRewards>(@merkle);
        let user_pre_tge_reward_info = table::borrow_mut_with_default(&mut pre_tge_rewards.user_pre_tge_reward, _user_address,
            PreTgeRewardInfo {
            point_reward: 0,
            point_reward_claimed: false,
            lp_reward: 0,
            lp_reward_claimed: false
        });
        user_pre_tge_reward_info.point_reward = _reward;
    }

    public fun set_bulk_point_reward(_admin: &signer, _user_address: vector<address>, _reward: vector<u64>)
    acquires PreTgeRewards {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let pre_tge_rewards = borrow_global_mut<PreTgeRewards>(@merkle);
        let idx = 0;
        while (idx < vector::length(&_user_address)) {
            let addr = vector::borrow(&_user_address, idx);
            let amount = vector::borrow(&_reward, idx);
            let user_pre_tge_reward_info = table::borrow_mut_with_default(&mut pre_tge_rewards.user_pre_tge_reward, *addr,
                PreTgeRewardInfo {
                    point_reward: 0,
                    point_reward_claimed: false,
                    lp_reward: 0,
                    lp_reward_claimed: false
                });
            user_pre_tge_reward_info.point_reward = *amount;
            idx = idx + 1;
        };
    }

    public fun set_lp_reward(_admin: &signer, _user_address: address, _reward: u64)
    acquires PreTgeRewards {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let pre_tge_rewards = borrow_global_mut<PreTgeRewards>(@merkle);
        let user_pre_tge_reward_info = table::borrow_mut_with_default(&mut pre_tge_rewards.user_pre_tge_reward, _user_address,
            PreTgeRewardInfo {
                point_reward: 0,
                point_reward_claimed: false,
                lp_reward: 0,
                lp_reward_claimed: false
            });
        user_pre_tge_reward_info.lp_reward = _reward;
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
    use merkle::pMKL;

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);
        initialize_module(host);
        pMKL::initialize_module(host);
        pre_mkl_token::initialize_module(host);
        pre_mkl_token::run_token_generation_event(host);
        mkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_claim_point_reward(host: &signer, aptos_framework: &signer, user: &signer)
    acquires MklClaimCapacityStore, PreTgeRewardEvents, PreTgeRewards {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 100);
        let amount = 1000000;
        set_point_reward(host, address_of(user), amount);
        {
            let pre_tge_rewards = borrow_global_mut<PreTgeRewards>(@merkle);
            let user_pre_tge_reward_info = table::borrow(&pre_tge_rewards.user_pre_tge_reward, address_of(user));
            assert!(user_pre_tge_reward_info.point_reward == amount, 0);
            assert!(user_pre_tge_reward_info.point_reward_claimed == false, 0);
        };
        claim_point_reward(user);
        {
            let pre_tge_rewards = borrow_global_mut<PreTgeRewards>(@merkle);
            let user_pre_tge_reward_info = table::borrow(&pre_tge_rewards.user_pre_tge_reward, address_of(user));
            assert!(user_pre_tge_reward_info.point_reward == amount, 0);
            assert!(user_pre_tge_reward_info.point_reward_claimed == true, 0);
        };
        assert!(primary_fungible_store::balance(address_of(user), mkl_token::get_metadata()) == amount, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NO_CLAIMABLE)]
    fun T_claim_point_reward_no_claimable(host: &signer, aptos_framework: &signer, user: &signer)
    acquires MklClaimCapacityStore, PreTgeRewardEvents, PreTgeRewards {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 100);
        let amount = 1000000;
        set_point_reward(host, address_of(user), amount);
        claim_point_reward(user);
        claim_point_reward(user);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_CLAIM_EXPIRED)]
    fun T_claim_point_reward_no_expired(host: &signer, aptos_framework: &signer, user: &signer)
    acquires MklClaimCapacityStore, PreTgeRewardEvents, PreTgeRewards {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 100);
        let amount = 1000000;
        set_point_reward(host, address_of(user), amount);
        timestamp::fast_forward_seconds(DAY_SECONDS * 365);
        claim_point_reward(user);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_claim_lp_reward(host: &signer, aptos_framework: &signer, user: &signer)
    acquires MklClaimCapacityStore, PreTgeRewardEvents, PreTgeRewards {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 100);
        let amount = 1000000;
        set_lp_reward(host, address_of(user), amount);
        {
            let pre_tge_rewards = borrow_global<PreTgeRewards>(@merkle);
            let user_pre_tge_reward_info = table::borrow(&pre_tge_rewards.user_pre_tge_reward, address_of(user));
            assert!(user_pre_tge_reward_info.lp_reward == amount, 0);
            assert!(user_pre_tge_reward_info.lp_reward_claimed == false, 0);
        };
        claim_lp_reward(user);
        {
            let pre_tge_rewards = borrow_global<PreTgeRewards>(@merkle);
            let user_pre_tge_reward_info = table::borrow(&pre_tge_rewards.user_pre_tge_reward, address_of(user));
            assert!(user_pre_tge_reward_info.lp_reward == amount, 0);
            assert!(user_pre_tge_reward_info.lp_reward_claimed == true, 0);
        };
        assert!(primary_fungible_store::balance(address_of(user), mkl_token::get_metadata()) == amount, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_NO_CLAIMABLE)]
    fun T_claim_lp_reward_no_claimable(host: &signer, aptos_framework: &signer, user: &signer)
    acquires MklClaimCapacityStore, PreTgeRewardEvents, PreTgeRewards {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 100);
        let amount = 1000000;
        set_lp_reward(host, address_of(user), amount);
        claim_lp_reward(user);
        claim_lp_reward(user);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_CLAIM_EXPIRED)]
    fun T_claim_lp_reward_no_expired(host: &signer, aptos_framework: &signer, user: &signer)
    acquires MklClaimCapacityStore, PreTgeRewardEvents, PreTgeRewards {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at() + 100);
        let amount = 1000000;
        set_lp_reward(host, address_of(user), amount);
        timestamp::fast_forward_seconds(DAY_SECONDS * 365);
        claim_lp_reward(user);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_claim_point_reward_pre_mkl(host: &signer, aptos_framework: &signer, user: &signer)
    acquires MklClaimCapacityStore, PreTgeRewardEvents, PreTgeRewards {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(pre_mkl_token::pre_mkl_tge_at() + 100);
        let amount = 1000000;
        set_point_reward(host, address_of(user), amount);
        {
            let pre_tge_rewards = borrow_global<PreTgeRewards>(@merkle);
            let user_pre_tge_reward_info = table::borrow(&pre_tge_rewards.user_pre_tge_reward, address_of(user));
            assert!(user_pre_tge_reward_info.point_reward == amount, 0);
            assert!(user_pre_tge_reward_info.point_reward_claimed == false, 0);
        };
        claim_point_reward(user);
        {
            let pre_tge_rewards = borrow_global<PreTgeRewards>(@merkle);
            let user_pre_tge_reward_info = table::borrow(&pre_tge_rewards.user_pre_tge_reward, address_of(user));
            assert!(user_pre_tge_reward_info.point_reward == amount, 0);
            assert!(user_pre_tge_reward_info.point_reward_claimed == true, 0);
        };
        assert!(primary_fungible_store::balance(address_of(user), pre_mkl_token::get_metadata()) == amount, 0);
        assert!(primary_fungible_store::balance(address_of(user), mkl_token::get_metadata()) == 0, 0);
    }
}