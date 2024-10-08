module merkle::protocol_reward {
    use std::signer::address_of;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::from_bcs;
    use aptos_std::simple_map;
    use aptos_std::table;
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_framework::account::new_event_handle;
    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;
    use merkle::safe_math::safe_mul_div;
    use merkle::staking;

    // <-- ERROR CODE ----->
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 0;
    /// When cannot claimable
    const E_NO_CLAIMABLE: u64 = 1;
    /// When claim expired
    const E_CLAIM_EXPIRED: u64 = 2;
    /// When invalid epoch start at
    const E_INVALID_EPOCH_START_AT: u64 = 3;
    /// When withdraw reward but still claimable
    const E_STILL_CLAIMABLE: u64 = 4;

    const DAY_SECONDS: u64 = 60 * 60 * 24; // 1 day

    struct EpochReward<phantom AssetType> has key {
        reward: table::Table<u64, Reward<AssetType>>  // key = epoch started at, value = reward
    }

    struct Reward<phantom AssetType> has store {
        registered_at: u64,
        registered_reward_amount: u64,
        coin: Coin<AssetType>
    }

    struct UserRewardInfo<phantom AssetType> has key {
        claimed_epoch: vector<u64>
    }

    struct ProtocolRewardEvents has key {
        protocol_revenue_events: EventHandle<ProtocolRevenueEvent>,
    }

    struct ProtocolRevenueEvent has drop, store {
        user: address,
        asset_type: TypeInfo,
        amount: u64
    }

    struct ProtocolRewardConfig<phantom AssetType> has key {
        params: simple_map::SimpleMap<String, vector<u8>>,
    }

    public fun initialize_module<AssetType>(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<ProtocolRewardEvents>(address_of(_admin))) {
            move_to(_admin, ProtocolRewardEvents {
                protocol_revenue_events: new_event_handle<ProtocolRevenueEvent>(_admin)
            });
        };

        if(!exists<EpochReward<AssetType>>(address_of(_admin))) {
            move_to(_admin, EpochReward<AssetType> {
                reward: table::new()
            });
        };

        if (!exists<ProtocolRewardConfig<AssetType>>(address_of(_admin))) {
            move_to(_admin, ProtocolRewardConfig<AssetType> {
                params: simple_map::new<String, vector<u8>>()
            })
        };
    }

    public fun user_reward_amount<AssetType>(_user_address: address, _epoch_start_at: u64): u64
    acquires EpochReward, UserRewardInfo, ProtocolRewardConfig {
        if (exists<UserRewardInfo<AssetType>>(_user_address)) {
            let user_reward_info = borrow_global<UserRewardInfo<AssetType>>(_user_address);
            if (vector::contains(&user_reward_info.claimed_epoch, &_epoch_start_at)) {
                return 0
            };
        };
        let epoch_reward = borrow_global_mut<EpochReward<AssetType>>(@merkle);
        if (!table::contains(&epoch_reward.reward, _epoch_start_at)) {
            return 0
        };
        let reward = table::borrow_mut(&mut epoch_reward.reward, _epoch_start_at);
        if (timestamp::now_seconds() - reward.registered_at > get_params_u64_value<AssetType>(b"CLAIMABLE_DURATION", DAY_SECONDS * 14)) {
            return 0
        };
        user_reward_amount_internal(reward, _user_address, _epoch_start_at)
    }

    fun user_reward_amount_internal<AssetType>(_epoch_reward: &Reward<AssetType>, _user_address: address, _epoch_start_at: u64): u64 {
        let (user_ve_power, total_ve_power) = staking::get_epoch_user_vote_power(_user_address, _epoch_start_at);
        if (total_ve_power == 0) {
            return 0
        };
        safe_mul_div(_epoch_reward.registered_reward_amount, user_ve_power, total_ve_power)
    }

    public fun claim_rewards<AssetType>(_user: &signer, _epoch_start_at: u64)
    acquires EpochReward, ProtocolRewardEvents, UserRewardInfo, ProtocolRewardConfig {
        assert!(_epoch_start_at < staking::get_current_epoch_start_time(), E_INVALID_EPOCH_START_AT);
        let epoch_reward = borrow_global_mut<EpochReward<AssetType>>(@merkle);
        if (!exists<UserRewardInfo<AssetType>>(address_of(_user))) {
            move_to(_user, UserRewardInfo<AssetType> {
                claimed_epoch: vector[]
            });
        };
        let user_reward_info = borrow_global_mut<UserRewardInfo<AssetType>>(address_of(_user));
        assert!(
            _epoch_start_at % staking::get_epoch_duration() == 0 &&
                !vector::contains(&user_reward_info.claimed_epoch, &_epoch_start_at) &&
                table::contains(&epoch_reward.reward, _epoch_start_at),
            E_NO_CLAIMABLE
        );
        let reward = table::borrow_mut(&mut epoch_reward.reward, _epoch_start_at);
        assert!(timestamp::now_seconds() - reward.registered_at <= get_params_u64_value<AssetType>(b"CLAIMABLE_DURATION", DAY_SECONDS * 14), E_CLAIM_EXPIRED);
        let reward_amount = user_reward_amount_internal(reward, address_of(_user), _epoch_start_at);
        let reward = coin::extract(&mut reward.coin, reward_amount);
        aptos_account::deposit_coins(address_of(_user), reward);

        vector::push_back(&mut user_reward_info.claimed_epoch, _epoch_start_at);

        // emit event
        event::emit_event(&mut borrow_global_mut<ProtocolRewardEvents>(@merkle).protocol_revenue_events, ProtocolRevenueEvent {
            user: address_of(_user),
            asset_type: type_info::type_of<AssetType>(),
            amount: reward_amount
        });
    }

    public fun register_vemkl_protocol_rewards<AssetType>(_admin: &signer, _epoch_start_at: u64, _amount: u64)
    acquires EpochReward {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        assert!(_epoch_start_at % staking::get_epoch_duration() == 0, E_INVALID_EPOCH_START_AT);
        let epoch_reward = borrow_global_mut<EpochReward<AssetType>>(@merkle);

        if (!table::contains(&epoch_reward.reward, _epoch_start_at)) {
            table::add(&mut epoch_reward.reward, _epoch_start_at, Reward<AssetType> {
                registered_reward_amount: _amount,
                registered_at: timestamp::now_seconds(),
                coin: coin::withdraw<AssetType>(_admin, _amount)
            });
        } else {
            let reward = table::borrow_mut(&mut epoch_reward.reward, _epoch_start_at);
            reward.registered_reward_amount = _amount;
            reward.registered_at = timestamp::now_seconds();
            aptos_account::deposit_coins(address_of(_admin), coin::extract_all(&mut reward.coin));
            coin::merge(&mut reward.coin, coin::withdraw<AssetType>(_admin, _amount));
        };
    }

    public fun withdraw_expired_protocol_reward<AssetType>(_admin: &signer, _epoch_start_at: u64)
    acquires EpochReward {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let epoch_reward = borrow_global_mut<EpochReward<AssetType>>(@merkle);
        let reward = table::borrow_mut(&mut epoch_reward.reward, _epoch_start_at);
        assert!(timestamp::now_seconds() - reward.registered_at > DAY_SECONDS * 14, E_STILL_CLAIMABLE);
        aptos_account::deposit_coins(address_of(_admin), coin::extract_all(&mut reward.coin));
    }

    public fun get_params_u64_value<AssetType>(_key: vector<u8>, _default: u64): u64
    acquires ProtocolRewardConfig {
        if (!exists<ProtocolRewardConfig<AssetType>>(@merkle)) {
            return _default
        };
        let pair_v2_ref_mut = borrow_global_mut<ProtocolRewardConfig<AssetType>>(@merkle);
        if (!simple_map::contains_key(&pair_v2_ref_mut.params, &string::utf8(_key))) {
            return _default
        };
        let value = *simple_map::borrow(&pair_v2_ref_mut.params, &string::utf8(_key));
        from_bcs::to_u64(value)
    }

    public fun set_param<AssetType>(
        _admin: &signer,
        _key: String,
        _value: vector<u8>
    ) acquires ProtocolRewardConfig {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let pair_v2_ref_mut = borrow_global_mut<ProtocolRewardConfig<AssetType>>(@merkle);
        simple_map::upsert(&mut pair_v2_ref_mut.params, _key, _value);
    }

    #[test_only]
    use std::features;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::primary_fungible_store;
    #[test_only]
    use merkle::esmkl_token;
    #[test_only]
    use merkle::mkl_token::{Self, mint_claim_capability, COMMUNITY_POOL};

    #[test_only]
    struct TEST_USDC {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        initialize_module<TEST_USDC>(host);
        staking::initialize_module(host);
        mkl_token::initialize_module(host);
        esmkl_token::initialize_module(host);
        mkl_token::run_token_generation_event(host);

        let decimals = 6;
        let (bc, fc, mc) = coin::initialize<TEST_USDC>(host,
            string::utf8(b"TEST_USDC"),
            string::utf8(b"TEST_USDC"),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<TEST_USDC>(host);
        coin::deposit(address_of(host), coin::mint<TEST_USDC>(1000_000000, &mc));
        coin::destroy_mint_cap(mc);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_initialize_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_register_vemkl_protocol_rewards(host: &signer, aptos_framework: &signer)
    acquires EpochReward {
        call_test_setting(host, aptos_framework);
        let epoch_duration = staking::get_epoch_duration();
        let amount = 1000000;
        timestamp::fast_forward_seconds(epoch_duration + 100);
        register_vemkl_protocol_rewards<TEST_USDC>(host, epoch_duration, amount);

        let epoch_reward = borrow_global<EpochReward<TEST_USDC>>(@merkle);
        let reward = table::borrow(&epoch_reward.reward, epoch_duration);
        assert!(coin::value(&reward.coin) == amount, 0);
        assert!(reward.registered_at == epoch_duration + 100, 0);
        assert!(reward.registered_reward_amount == amount, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_user_reward_amount(host: &signer, aptos_framework: &signer)
    acquires EpochReward, UserRewardInfo, ProtocolRewardConfig {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at());
        let epoch_duration = staking::get_epoch_duration();
        let amount = 1000000;
        let mkl_amount = 1000000;
        timestamp::fast_forward_seconds(epoch_duration + 100);

        let cap = mint_claim_capability<COMMUNITY_POOL>(host);
        let mkl = mkl_token::claim_mkl_with_cap(&cap, mkl_amount);
        primary_fungible_store::deposit(address_of(host), mkl);
        staking::lock(host, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), mkl_amount), mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS + epoch_duration * 10);
        
        timestamp::fast_forward_seconds(epoch_duration * 2);
        let reward_epoch = mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS + epoch_duration * 2;
        assert!(user_reward_amount<TEST_USDC>(address_of(host), reward_epoch) == 0, 0);
        register_vemkl_protocol_rewards<TEST_USDC>(host, reward_epoch, amount);
        assert!(user_reward_amount<TEST_USDC>(address_of(host), reward_epoch) == amount, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_claim_rewards(host: &signer, aptos_framework: &signer)
    acquires EpochReward, ProtocolRewardEvents, UserRewardInfo, ProtocolRewardConfig {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(mkl_token::mkl_tge_at()); // tge at
        let epoch_duration = staking::get_epoch_duration();
        let amount = 1000000;
        let mkl_amount = 1000000;
        timestamp::fast_forward_seconds(epoch_duration + 100); // tge at + 1 epoch + 100

        let cap = mint_claim_capability<COMMUNITY_POOL>(host);
        let mkl = mkl_token::claim_mkl_with_cap(&cap, mkl_amount);
        primary_fungible_store::deposit(address_of(host), mkl);

        staking::lock(host, primary_fungible_store::withdraw(host, mkl_token::get_metadata(), mkl_amount), mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS + epoch_duration * 10);
        timestamp::fast_forward_seconds(epoch_duration * 2); // tge at + 3 epoch + 100
        let reward_epoch = mkl_token::mkl_tge_at() - mkl_token::mkl_tge_at() % DAY_SECONDS + epoch_duration * 2;
        register_vemkl_protocol_rewards<TEST_USDC>(host, reward_epoch, amount);
        assert!(user_reward_amount<TEST_USDC>(address_of(host), reward_epoch) == amount, 0);

        let balance1 = coin::balance<TEST_USDC>(address_of(host));
        claim_rewards<TEST_USDC>(host, reward_epoch);
        assert!(coin::balance<TEST_USDC>(address_of(host)) - balance1 == amount, 0);
    }
}