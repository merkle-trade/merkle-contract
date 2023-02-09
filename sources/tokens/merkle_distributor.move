module merkle::merkle_distributor {

    // <-- CONSTANT ----->

    const PRECISION: u64 = 1000 * 1000;

    // <-- USE ----->
    use std::signer;
    use std::string::{String};

    use aptos_std::table;
    use aptos_std::type_info::type_name;
    use std::signer::address_of;
    use aptos_framework::timestamp;
    use merkle::safe_math_u64::safe_mul_div;

    friend merkle::distributor;

    /// When indicated `StakingInfo` does not exist
    const E_STAKING_INFO_NOT_EXIST: u64 = 1;
    /// When indicated `StakingInfo` already exist
    const E_STAKING_INFO_ALREADY_EXIST: u64 = 2;
    /// When indicated `PoolInfo` does not exist
    const E_POOL_INFO_NOT_EXIST: u64 = 3;
    /// When indicated 'signer` is not merkle
    const E_UNATHORIZED: u64 = 4;


    /// Capability required to call admin function.
    struct AdminCapability has copy, store, drop {}

    // token
    friend merkle::trading;

    struct StakingInfo has key {
        admin: address,
        reward_per_time: u64,
        total_alloc_point: u64,
        pool_infos: table::Table<String, PoolInfo>,
    }

    struct PoolInfo has store {
        total_staking: u64,
        last_reward_timestmap: u64,
        acc_reward_per_share: u64,
        alloc_point: u64,
        user_infos: table::Table<address, UserInfo>
    }

    struct UserInfo has store, drop {
        staking_amount: u64,
        last_acc_reward_per_share: u64
    }

    /// Initialize staking
    public(friend) fun initialize(
        _host: &signer
    ) {
        assert!(!exists<StakingInfo>(@merkle), E_STAKING_INFO_ALREADY_EXIST);
        move_to(
            _host,
            StakingInfo {
                admin: address_of(_host),
                reward_per_time: 0,
                total_alloc_point: 0,
                pool_infos: table::new()
            });
    }

    /// Register staking pool
    public fun register_pool<StakingCoinType>(
        _host: &signer
    ) acquires StakingInfo {
        assert!(address_of(_host) == @merkle, E_UNATHORIZED);
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let pool_infos =
            &mut borrow_global_mut<StakingInfo>(@merkle).pool_infos;
        table::add(
            pool_infos,
            type_name<StakingCoinType>(),
            PoolInfo {
                total_staking: 0,
                last_reward_timestmap: timestamp::now_seconds(),
                acc_reward_per_share: 0,
                alloc_point: 0,
                user_infos: table::new()
            });
    }

    /// Set alloc point of pool
    public fun set_alloc_point<StakingCoinType>(
        _signer: &signer,
        _new_alloc_point: u64
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);

        let staking_ref_mut =
            borrow_global_mut<StakingInfo>(@merkle);
        assert!(staking_ref_mut.admin == signer::address_of(_signer), E_UNATHORIZED);
        let pool_ref_mut =
            table::borrow_mut(
                &mut staking_ref_mut.pool_infos,
                type_name<StakingCoinType>()
            );
        // todo accrue()
        staking_ref_mut.total_alloc_point =
            staking_ref_mut.total_alloc_point - pool_ref_mut.alloc_point + _new_alloc_point;
        pool_ref_mut.alloc_point = _new_alloc_point;
    }

    /// Change admin of this module
    public entry fun change_admin(
        _signer: &signer,
        _new_admin: address
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let staking_ref_mut =
            borrow_global_mut<StakingInfo>(@merkle);

        assert!(staking_ref_mut.admin == address_of(_signer), E_UNATHORIZED);
        staking_ref_mut.admin = _new_admin;
    }

    /// Set reward per time
    public entry fun set_reward_per_time(
        _signer: &signer,
        _reward_per_time: u64
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);

        let staking_ref_mut =
            borrow_global_mut<StakingInfo>(@merkle);
        assert!(staking_ref_mut.admin == signer::address_of(_signer), E_UNATHORIZED);
        staking_ref_mut.reward_per_time = _reward_per_time;
    }

    public(friend) fun stake<StakingCoinType>(
        _user: address,
        _amount: u64
    ): u64 acquires StakingInfo {
        if (!exists<StakingInfo>(@merkle)) { return 0 };
        let staking_ref_mut =
            borrow_global_mut<StakingInfo>(@merkle);
        if (!table::contains(&mut staking_ref_mut.pool_infos, type_name<StakingCoinType>())) { return 0 };
        let pool_ref_mut =
            table::borrow_mut(&mut staking_ref_mut.pool_infos, type_name<StakingCoinType>());

        pool_ref_mut.total_staking = pool_ref_mut.total_staking + _amount;
        update_pool(
            pool_ref_mut,
            staking_ref_mut.reward_per_time,
            staking_ref_mut.total_alloc_point
        );

        let user_info = table::borrow_mut_with_default(
            &mut pool_ref_mut.user_infos,
            _user,
            UserInfo {
                staking_amount: 0,
                last_acc_reward_per_share: pool_ref_mut.acc_reward_per_share
            }
        );

        let harvest_amount =
            harvest_internal(user_info, pool_ref_mut.acc_reward_per_share);
        user_info.staking_amount = user_info.staking_amount + _amount;
        harvest_amount
    }

    public(friend) fun unstake<StakingCoinType>(
        _user: address,
        _amount: u64
    ): u64 acquires StakingInfo {
        if (!exists<StakingInfo>(@merkle)) { return 0 };
        let staking_ref_mut =
            borrow_global_mut<StakingInfo>(@merkle);
        if (!table::contains(&mut staking_ref_mut.pool_infos, type_name<StakingCoinType>())) { return 0 };
        let pool_ref_mut =
            table::borrow_mut(&mut staking_ref_mut.pool_infos, type_name<StakingCoinType>());

        update_pool(
            pool_ref_mut,
            staking_ref_mut.reward_per_time,
            staking_ref_mut.total_alloc_point
        );
        pool_ref_mut.total_staking = pool_ref_mut.total_staking - _amount;

        let user_info = table::borrow_mut(&mut pool_ref_mut.user_infos, _user);

        let harvest_amount =
            harvest_internal(user_info, pool_ref_mut.acc_reward_per_share);
        user_info.staking_amount = user_info.staking_amount - _amount;
        harvest_amount
    }

    public(friend) fun harvest<StakingCoinType>(
        _user: address
    ): u64 acquires StakingInfo {
        if (!exists<StakingInfo>(@merkle)) { return 0 };
        let staking_ref_mut =
            borrow_global_mut<StakingInfo>(@merkle);
        if (!table::contains(&mut staking_ref_mut.pool_infos, type_name<StakingCoinType>())) { return 0 };
        let pool_ref_mut =
            table::borrow_mut(&mut staking_ref_mut.pool_infos, type_name<StakingCoinType>());

        update_pool(
            pool_ref_mut,
            staking_ref_mut.reward_per_time,
            staking_ref_mut.total_alloc_point
        );

        let user_info = table::borrow_mut(&mut pool_ref_mut.user_infos, _user);

        harvest_internal(user_info, pool_ref_mut.acc_reward_per_share)
    }

    fun update_pool(
        _pool_ref_mut: &mut PoolInfo,
        _reward_per_time: u64,
        _total_alloc_point: u64
    ) {
        let current_time = timestamp::now_seconds();
        if (_pool_ref_mut.total_staking == 0) {
            _pool_ref_mut.last_reward_timestmap = current_time;
            return
        };

        let time_gap = current_time - _pool_ref_mut.last_reward_timestmap;
        let reward_delta =
            safe_mul_div(_reward_per_time, time_gap, PRECISION);
        let alloc_acc_reward_delta =
            safe_mul_div(reward_delta, _pool_ref_mut.alloc_point, _total_alloc_point);
        _pool_ref_mut.acc_reward_per_share =
            safe_mul_div(alloc_acc_reward_delta, PRECISION, _pool_ref_mut.total_staking);
        _pool_ref_mut.last_reward_timestmap = timestamp::now_seconds();
    }

    fun harvest_internal(
        _user_info_ref_mut: &mut UserInfo,
        _acc_reward_per_share: u64,
    ): u64 {
        if (_user_info_ref_mut.staking_amount == 0) { return 0 };
        let harvested_amount =
            safe_mul_div(
                _acc_reward_per_share - _user_info_ref_mut.last_acc_reward_per_share,
                _user_info_ref_mut.staking_amount,
                PRECISION
            );
        _user_info_ref_mut.last_acc_reward_per_share = _acc_reward_per_share;
        harvested_amount
    }
}
