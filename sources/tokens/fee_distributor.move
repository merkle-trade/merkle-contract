module merkle::fee_distributor {

    // <-- CONSTANT ----->

    const PRECISION: u64 = 1000 * 1000;

    // <-- USE ----->
    use aptos_std::table;
    use std::signer::address_of;
    use merkle::safe_math_u64::safe_mul_div;
    use aptos_std::type_info::type_name;
    use std::string::String;

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
        reward_infos: table::Table<u64, RewardInfo>
    }

    struct RewardInfo has store {
        acc_reward: u64,
        total_alloc_point: u64,
        pool_infos: table::Table<String, PoolInfo>,
    }

    struct PoolInfo has store {
        total_staking: u64,
        last_acc_reward: u64,
        acc_reward_per_share: u64,
        alloc_point: u64,
        user_infos: table::Table<address, UserInfo>
    }

    struct UserInfo has store {
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
                reward_infos: table::new()
            });
    }

    /// Register reward info
    public(friend) fun register_reward_info(
        _reward_id: u64
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);

        let reward_infos =
            &mut borrow_global_mut<StakingInfo>(@merkle).reward_infos;
        table::add(reward_infos, _reward_id, RewardInfo {
            acc_reward: 0,
            total_alloc_point: 0,
            pool_infos: table::new()
        });
    }

    /// Register staking pool
    public entry fun register_pool<StakingCoinType>(
        _host: &signer,
        _reward_id: u64
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let staking_info =
            borrow_global_mut<StakingInfo>(@merkle);

        assert!(address_of(_host) == staking_info.admin, E_UNATHORIZED);

        let reward_infos =
            &mut borrow_global_mut<StakingInfo>(@merkle).reward_infos;
        let pool_infos =
            &mut table::borrow_mut(reward_infos, _reward_id).pool_infos;
        table::add(
            pool_infos,
            type_name<StakingCoinType>(),
            PoolInfo {
                total_staking: 0,
                last_acc_reward: 0,
                acc_reward_per_share: 0,
                alloc_point: 0,
                user_infos: table::new()
            });
    }

    /// Set alloc point of pool
    public entry fun set_alloc_point<StakingCoinType>(
        _signer: &signer,
        _reward_id: u64,
        _new_alloc_point: u64
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);

        let staking_info =
            borrow_global_mut<StakingInfo>(@merkle);
        assert!(staking_info.admin == address_of(_signer), E_UNATHORIZED);

        let reward_info =
            table::borrow_mut(&mut staking_info.reward_infos, _reward_id);
        let pool_ref_mut =
            table::borrow_mut(&mut reward_info.pool_infos, type_name<StakingCoinType>());
        // todo accrue()
        reward_info.total_alloc_point =
            reward_info.total_alloc_point - pool_ref_mut.alloc_point + _new_alloc_point;
        pool_ref_mut.alloc_point = _new_alloc_point;
    }

    /// Change admin of this module
    public entry fun change_admin(
        _signer: &signer,
        _new_admin: address,
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let staking_info =
            borrow_global_mut<StakingInfo>(@merkle);

        assert!(staking_info.admin == address_of(_signer), E_UNATHORIZED);
        staking_info.admin = _new_admin;
    }

    public(friend) fun stake<StakingCoinType>(
        _user: address,
        _reward_id: u64,
        _amount: u64
    ): u64 acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let reward_infos =
            &mut borrow_global_mut<StakingInfo>(@merkle).reward_infos;

        let reward_info =
            table::borrow_mut(reward_infos, _reward_id);

        if (!table::contains(&mut reward_info.pool_infos, type_name<StakingCoinType>())) { return 0 };
        let pool_ref_mut =
            table::borrow_mut(&mut reward_info.pool_infos, type_name<StakingCoinType>());

        pool_ref_mut.total_staking = pool_ref_mut.total_staking + _amount;
        update_pool(pool_ref_mut, reward_info.acc_reward, reward_info.total_alloc_point);

        if (!table::contains(&mut pool_ref_mut.user_infos, _user)) {
            table::add(
                &mut pool_ref_mut.user_infos,
                _user,
                UserInfo {
                    staking_amount: 0,
                    last_acc_reward_per_share: pool_ref_mut.acc_reward_per_share
                }
            );
        };
        let user_info = table::borrow_mut(
            &mut pool_ref_mut.user_infos,
            _user,
        );

        let harvest_amount =
            harvest_internal(user_info, _reward_id, pool_ref_mut.acc_reward_per_share);
        user_info.staking_amount = user_info.staking_amount + _amount;
        harvest_amount
    }

    public(friend) fun unstake<StakingCoinType>(
        _user: address,
        _reward_id: u64,
        _amount: u64
    ): u64 acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let reward_infos =
            &mut borrow_global_mut<StakingInfo>(@merkle).reward_infos;

        let reward_info =
            table::borrow_mut(reward_infos, _reward_id);
        if (!table::contains(&mut reward_info.pool_infos, type_name<StakingCoinType>())) { return 0 };
        let pool_ref_mut =
            table::borrow_mut(&mut reward_info.pool_infos, type_name<StakingCoinType>());

        pool_ref_mut.total_staking = pool_ref_mut.total_staking - _amount;
        update_pool(pool_ref_mut, reward_info.acc_reward, reward_info.total_alloc_point);

        let user_info = table::borrow_mut(&mut pool_ref_mut.user_infos, _user);

        let harvest_amount =
            harvest_internal(user_info, _reward_id, pool_ref_mut.acc_reward_per_share);
        user_info.staking_amount = user_info.staking_amount - _amount;
        harvest_amount
    }

    public(friend) fun deposit_fee(
        _reward_id: u64,
        _amount: u64
    ) acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let reward_infos =
            &mut borrow_global_mut<StakingInfo>(@merkle).reward_infos;

        let reward_info =
            table::borrow_mut(reward_infos, _reward_id);
        reward_info.acc_reward = reward_info.acc_reward + _amount;
    }

    public(friend) fun harvest<StakingCoinType>(
        _user: address,
        _reward_id: u64
    ): u64 acquires StakingInfo {
        assert!(exists<StakingInfo>(@merkle), E_STAKING_INFO_NOT_EXIST);
        let reward_infos =
            &mut borrow_global_mut<StakingInfo>(@merkle).reward_infos;

        let reward_info =
            table::borrow_mut(reward_infos, _reward_id);
        if (!table::contains(&mut reward_info.pool_infos, type_name<StakingCoinType>())) { return 0 };
        let pool_ref_mut =
            table::borrow_mut(&mut reward_info.pool_infos, type_name<StakingCoinType>());

        update_pool(pool_ref_mut, reward_info.acc_reward, reward_info.total_alloc_point);

        let user_info = table::borrow_mut(&mut pool_ref_mut.user_infos, _user);

        harvest_internal(user_info, _reward_id, pool_ref_mut.acc_reward_per_share)
    }

    fun update_pool(
        _pool_ref_mut: &mut PoolInfo,
        _acc_reward: u64,
        _total_alloc_point: u64
    ) {
        if (_pool_ref_mut.total_staking == 0) {
            _pool_ref_mut.last_acc_reward = _acc_reward;
            return
        };

        let acc_reward_delta = _acc_reward - _pool_ref_mut.last_acc_reward;
        let alloc_acc_reward_delta =
            safe_mul_div(acc_reward_delta, _pool_ref_mut.alloc_point, _total_alloc_point);
        _pool_ref_mut.last_acc_reward = _acc_reward;
        _pool_ref_mut.acc_reward_per_share =
            safe_mul_div(alloc_acc_reward_delta, PRECISION, _pool_ref_mut.total_staking);
    }

    fun harvest_internal(
        _user_info_ref_mut: &mut UserInfo,
        _reward_id: u64,
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
