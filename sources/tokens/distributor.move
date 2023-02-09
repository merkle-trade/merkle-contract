module merkle::distributor {

    // <-- CONSTANT ----->

    const PRECISION: u64 = 1000 * 1000;
    const TOKEN_PRECISION: u64 = 100 * 1000 * 1000;
    const MAX_LOCKUP_TIMESTMAP: u64 = 31536 * 4000;
    const VESTING_TIMESTMAP: u64 = 7884 * 2000;

    // <-- USE ----->
    use std::string::String;
    use std::vector;
    use std::signer::address_of;

    use aptos_std::table;
    use aptos_std::type_info::type_name;
    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, Coin};

    use merkle::fee_distributor;
    use merkle::merkle_coin::MerkleCoin;
    use merkle::merkle_distributor;
    use merkle::safe_math_u64::safe_mul_div;

    #[test_only]
    use merkle::merkle_coin;
    #[test_only]
    use aptos_framework::account::create_account_for_test;

    friend merkle::trading;

    /// When indicated `DistributorInfo` does not exist
    const E_DISTRIBUTOR_INFO_NOT_EXIST: u64 = 1;
    /// When indicated `DistributorInfo` already exist
    const E_DISTRIBUTOR_INFO_ALREADY_EXIST: u64 = 2;
    /// When indicated `StakingInfo` already exist
    const E_STAKING_COIN_ALREADY_EXIST: u64 = 3;
    /// When indicated 'signer` is not merkle
    const E_UNATHORIZED: u64 = 4;
    /// When indicated 'reward_infos` is over max
    const E_OVER_REWARD_COUNT: u64 = 5;
    /// When unstake insufficient amount
    const E_INSUFFICIENT_AMOUNT: u64 = 6;
    /// When indicated `RewardInfo` does not exist
    const E_REWARD_INFO_NOT_EXIST: u64 = 7;
    /// When indicated lock is not end
    const E_LOCK_NOT_END: u64 = 7;

    /// Capability required to call admin function.
    struct AdminCapability has copy, store, drop {}

    /// Vote-escrowed MerkleCoin
    struct VeMerkle has store {}

    /// Yield MerkleCoin
    struct YMerkle has store {}

    struct DistributorInfo has key {
        admin: address,
        user_infos: table::Table<address, UserInfo>,
        reward_infos: vector<String>
    }

    struct UserInfo has store {
        /// stkaing token to staked amount
        staking_amount: table::Table<String, u64>,
        /// reward id to harvested balance (claimable)
        harvested_reward: table::Table<u64, u64>,
        /// vesting ymkl
        vesting_infos: vector<VestingInfo>,
        /// user lock info
        locked_merkle: u64,
        locked_y_merkle: u64,
        lock_end_timestamp: u64,
        /// user's token amount
        ve_merkle_balance: u64,
        y_merkle_balance: u64
    }

    struct VestingInfo has store {
        total_amount: u64,
        claimed_amount: u64,
        vesting_start_time: u64
    }

    struct RewardBox<phantom RewardCoinType> has key {
        balance: Coin<RewardCoinType>
    }

    struct StakingCoinBox<phantom StakingCoinType> has key {
        balance: Coin<StakingCoinType>
    }

    /// Initialize staking
    /// @Parameters
    /// _host: Signer, host of distributor
    public entry fun initialize(
        _host: &signer
    ) {
        assert!(address_of(_host) == @merkle, E_UNATHORIZED);
        assert!(!exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_ALREADY_EXIST);
        move_to(
            _host,
            DistributorInfo {
                admin: address_of(_host),
                user_infos: table::new(),
                reward_infos: vector::empty()
            });
        fee_distributor::initialize(_host);
        merkle_distributor::initialize(_host);
        register_staking_coin<MerkleCoin>(_host);
        move_to(
            _host,
            RewardBox<MerkleCoin> {
                balance: coin::zero()
            });
    }

    /// Register staking pool
    /// @Parameters
    /// _host: Signer, host of distributor
    public entry fun register_staking_coin<StakingCoinType>(
        _host: &signer,
    ) {
        assert!(address_of(_host) == @merkle, E_UNATHORIZED);
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        assert!(!exists<StakingCoinBox<StakingCoinType>>(@merkle), E_STAKING_COIN_ALREADY_EXIST);

        move_to(
            _host,
            StakingCoinBox<StakingCoinType> {
                balance: coin::zero()
            });
    }

    /// Register reward
    /// @Parameters
    /// _host: Signer, host of distributor
    public entry fun register_reward<RewardCoinType>(
        _host: &signer
    ) acquires DistributorInfo {
        assert!(address_of(_host) == @merkle, E_UNATHORIZED);
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);

        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);

        assert!(vector::length(&mut distributor_ref_mut.reward_infos) <= 5, E_OVER_REWARD_COUNT);

        move_to(
            _host,
            RewardBox<RewardCoinType> {
                balance: coin::zero()
            });

        vector::push_back(
            &mut distributor_ref_mut.reward_infos,
            type_name<RewardCoinType>()
        );

        fee_distributor::register_reward_info(
            vector::length(&mut distributor_ref_mut.reward_infos) - 1
        );
    }

    /// Stake coin to distributor pool.
    /// @Parameters
    /// _user: Signer, staker
    /// _amount: Coin amount to stake
    public entry fun stake<StakingCoinType>(
        _user: &signer,
        _amount: u64
    ) acquires DistributorInfo, StakingCoinBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);

        let user_address = address_of(_user);
        if (!table::contains(&mut distributor_ref_mut.user_infos, user_address)) {
            table::add(
                &mut distributor_ref_mut.user_infos,
                user_address,
                UserInfo {
                    staking_amount: table::new(),
                    harvested_reward: table::new(),
                    vesting_infos: vector::empty(),
                    locked_merkle: 0,
                    locked_y_merkle: 0,
                    lock_end_timestamp: 0,
                    ve_merkle_balance: 0,
                    y_merkle_balance: 0
                }
            );
        };

        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, user_address);
        let len = vector::length(&mut distributor_ref_mut.reward_infos);
        stake_internal<StakingCoinType>(user_info, user_address, _amount, len);

        // Transfer coin from user to stkaing coin box
        {
            let staking_coin_box_ref_mut = borrow_global_mut<StakingCoinBox<StakingCoinType>>(@merkle);
            coin::merge(&mut staking_coin_box_ref_mut.balance, coin::withdraw(_user, _amount));
        };
    }

    /// Internal function fo staking coin to distributor pool.
    /// @Parameters
    /// _user_info_ref_mut: UserInfo mutable reference
    /// _user_address: Staker address
    /// _amount: Coin amount to stake
    /// _reward_length: Registered reward length
    fun stake_internal<StakingCoinType>(
        _user_info_ref_mut: &mut UserInfo,
        _user_address: address,
        _amount: u64,
        _reward_length: u64
    ) {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let user_staking_amount =
            table::borrow_mut_with_default(&mut _user_info_ref_mut.staking_amount, type_name<StakingCoinType>(), 0);
        *user_staking_amount = *user_staking_amount + _amount;

        merkle_distributor::stake<StakingCoinType>(_user_address, _amount);
        let reward_id = 0;
        while (_reward_length > reward_id) {
            let harvested_reward =
                table::borrow_mut_with_default(&mut _user_info_ref_mut.harvested_reward, reward_id, 0);
            *harvested_reward =
                *harvested_reward + fee_distributor::stake<StakingCoinType>(_user_address, reward_id, _amount);
            reward_id = reward_id + 1;
        };
    }

    /// Unstake coin from distributor pool.
    /// @Parameters
    /// _user: Signer, staker
    /// _amount: Coin amount to unstake
    public entry fun unstake<StakingCoinType>(
        _user: &signer,
        _amount: u64
    ) acquires DistributorInfo, StakingCoinBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);

        let user_address = address_of(_user);
        let _user_info_ref_mut = table::borrow_mut(&mut distributor_ref_mut.user_infos, user_address);
        merkle_distributor::unstake<StakingCoinType>(user_address, _amount);
        unstake_internal<StakingCoinType>(_user_info_ref_mut, user_address, _amount, vector::length(&mut distributor_ref_mut.reward_infos));

        // Transfer coin from stkaing coin box to user
        {
            let staking_coin_box_ref_mut = borrow_global_mut<StakingCoinBox<StakingCoinType>>(@merkle);
            coin::deposit<StakingCoinType>(user_address, coin::extract(&mut staking_coin_box_ref_mut.balance, _amount));
        };
    }

    /// Internal function fo unstaking coin from distributor pool.
    /// @Parameters
    /// _user_info_ref_mut: UserInfo mutable reference
    /// _user_address: Staker address
    /// _amount: Coin amount to unstake
    /// _reward_length: Registered reward length
    fun unstake_internal<StakingCoinType>(
        _user_info_ref_mut: &mut UserInfo,
        _user_address: address,
        _amount: u64,
        _reward_length: u64
    ) {
        let user_staking_amount =
            table::borrow_mut(&mut _user_info_ref_mut.staking_amount, type_name<StakingCoinType>());
        assert!(*user_staking_amount >= _amount, E_INSUFFICIENT_AMOUNT);
        *user_staking_amount = *user_staking_amount - _amount;

        let reward_id = 0;
        while (_reward_length > reward_id) {
            let harvested_reward =
                table::borrow_mut_with_default(&mut _user_info_ref_mut.harvested_reward, reward_id, 0);
            *harvested_reward =
                *harvested_reward + fee_distributor::unstake<StakingCoinType>(_user_address, reward_id, _amount);
            reward_id = reward_id + 1;
        }
    }

    /// Harvest reward from pool
    /// @Parameters
    /// _user: Signer, user who harvest reward
    public entry fun harvest<StakingCoinType, RewardCoinType>(
        _user: &signer
    ) acquires DistributorInfo, RewardBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut = borrow_global_mut<DistributorInfo>(@merkle);
        let (is_exist, reward_id) =
            vector::index_of(&distributor_ref_mut.reward_infos, &type_name<RewardCoinType>());
        assert!(is_exist, E_REWARD_INFO_NOT_EXIST);

        let user_address = address_of(_user);
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, user_address);

        let harvested_reward: u64;
        // Harvest from fee distributor & add already harvested reward
        {
            harvested_reward = fee_distributor::harvest<StakingCoinType>(user_address, reward_id);
            if (table::contains(&mut user_info.harvested_reward, reward_id)) {
                harvested_reward = harvested_reward + table::remove(&mut user_info.harvested_reward, reward_id);
            };
        };

        // coin deposit to user
        {
            let reward_box_ref_mut = borrow_global_mut<RewardBox<RewardCoinType>>(@merkle);
            coin::deposit<RewardCoinType>(user_address, coin::extract(&mut reward_box_ref_mut.balance, harvested_reward));
        };
    }

    /// Deposit fee to distributor
    /// Only call by merkle::trading
    /// @Parameters
    /// _fee_coin: Fee coin
    public(friend) fun deposit_fee<RewardCoinType>(
        _fee_coin: Coin<RewardCoinType>
    ) acquires DistributorInfo, RewardBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);
        let (is_exist, reward_id) =
            vector::index_of(&distributor_ref_mut.reward_infos, &type_name<RewardCoinType>());
        assert!(is_exist, E_REWARD_INFO_NOT_EXIST);

        // Deposit coin to distributor & box
        {
            fee_distributor::deposit_fee(reward_id, coin::value(&_fee_coin));
            let reward_box_ref_mut = borrow_global_mut<RewardBox<RewardCoinType>>(@merkle);
            coin::merge<RewardCoinType>(&mut reward_box_ref_mut.balance, _fee_coin);
        };
    }

    /// Deposit reward merkle to distributor
    /// Only call by merkle::trading
    /// @Parameters
    /// _fee_coin: Fee coin
    public entry fun deposit_reward_merkle(
        _merkle_coin: Coin<MerkleCoin>
    ) acquires RewardBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let reward_box_ref_mut = borrow_global_mut<RewardBox<MerkleCoin>>(@merkle);
        coin::merge<MerkleCoin>(&mut reward_box_ref_mut.balance, _merkle_coin);
    }

    /// Lock merkle/yMerkle to get & stake veMerkle
    /// @Parameters
    /// _user: Signer, user who lock merkle to pool
    /// _merkle_amount_delta: Amount of merkle to lock
    /// _y_merkle_amount_delta: Amount of yMerkle to lock
    /// _lock_end_time: Lock end time.
    public entry fun lock_merkle(
        _user: &signer,
        _merkle_amount_delta: u64,
        _y_merkle_amount_delta: u64,
        _lock_end_time: u64,
    ) acquires DistributorInfo, StakingCoinBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut = borrow_global_mut<DistributorInfo>(@merkle);

        // Deposit merkle to staking coin box
        if (_merkle_amount_delta > 0) {
            let staking_coin_box_ref_mut = borrow_global_mut<StakingCoinBox<MerkleCoin>>(@merkle);
            coin::merge(&mut staking_coin_box_ref_mut.balance, coin::withdraw(_user, _merkle_amount_delta));
        };

        // Borrow UserInfo by address
        let user_address = address_of(_user);
        if (!table::contains(&mut distributor_ref_mut.user_infos, user_address)) {
            table::add(
                &mut distributor_ref_mut.user_infos,
                user_address,
                UserInfo {
                    staking_amount: table::new(),
                    harvested_reward: table::new(),
                    vesting_infos: vector::empty(),
                    locked_merkle: 0,
                    locked_y_merkle: 0,
                    lock_end_timestamp: 0,
                    ve_merkle_balance: 0,
                    y_merkle_balance: 0
                }
            );
        };
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, user_address);

        // Calculate veMerkle delta
        let ve_merkle_delta = 0;
        {
            let lock_time_delta = _lock_end_time - user_info.lock_end_timestamp;
            if (lock_time_delta > 0) {
                let original_amount = user_info.locked_merkle + user_info.locked_y_merkle;
                if (original_amount > 0) {
                    ve_merkle_delta = safe_mul_div(original_amount, lock_time_delta, MAX_LOCKUP_TIMESTMAP);
                };
            };

            ve_merkle_delta = ve_merkle_delta + safe_mul_div(
                _merkle_amount_delta + _y_merkle_amount_delta,
                _lock_end_time - timestamp::now_seconds(),
                MAX_LOCKUP_TIMESTMAP
            );
        };

        // Stake reward/merkle pool
        let harvested_y_mkl = merkle_distributor::stake<VeMerkle>(user_address, ve_merkle_delta);
        stake_internal<VeMerkle>(
            user_info,
            user_address,
            ve_merkle_delta,
            vector::length(&mut distributor_ref_mut.reward_infos)
        );

        // Store user_info state
        {
            user_info.lock_end_timestamp = _lock_end_time;
            user_info.y_merkle_balance = user_info.y_merkle_balance + harvested_y_mkl - _y_merkle_amount_delta;
            user_info.locked_merkle = user_info.locked_merkle + _merkle_amount_delta;
            user_info.locked_y_merkle = user_info.locked_y_merkle + _y_merkle_amount_delta;
            user_info.ve_merkle_balance = user_info.ve_merkle_balance + ve_merkle_delta;
        };
    }

    /// Unstake veMerkle & unlock merkle/yMerkle.
    /// @Parameters
    /// _user: Signer, user who lock merkle to pool
    public entry fun unlock_merkle(
        _user: &signer
    ) acquires DistributorInfo, StakingCoinBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut = borrow_global_mut<DistributorInfo>(@merkle);

        // Borrow UserInfo by address
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(_user));

        // Check whether lock is end
        assert!(user_info.lock_end_timestamp < timestamp::now_seconds(), E_LOCK_NOT_END);

        // Unstake veMerkle from reward/merkle pool
        let unstaking_amount = user_info.ve_merkle_balance;
        let harvested_y_mkl =
            merkle_distributor::unstake<VeMerkle>(address_of(_user), unstaking_amount);
        unstake_internal<VeMerkle>(
            user_info,
            address_of(_user),
            unstaking_amount,
            vector::length(&mut distributor_ref_mut.reward_infos)
        );

        // Repay unlocked merkle to user
        {
            let staking_coin_box_ref_mut = borrow_global_mut<StakingCoinBox<MerkleCoin>>(@merkle);
            coin::deposit<MerkleCoin>(
                address_of(_user),
                coin::extract(&mut staking_coin_box_ref_mut.balance, user_info.locked_merkle)
            );
        };

        // Store user_info state
        {
            user_info.locked_merkle = 0;
            user_info.y_merkle_balance = user_info.y_merkle_balance + user_info.locked_y_merkle + harvested_y_mkl;
            user_info.locked_y_merkle = 0;
            user_info.ve_merkle_balance = 0;
        };
    }

    /// Entry vesting yMerkle to merkle
    /// @Parameters
    /// _user: Signer, user who vest yMerkle to merkle
    /// _amount: Amount of yMerkle to vest
    public entry fun entry_vesting(
        _user: &signer,
        _amount: u64
    ) acquires DistributorInfo {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut = borrow_global_mut<DistributorInfo>(@merkle);

        // Borrow UserInfo by address
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(_user));

        // Push new vesting info
        vector::push_back(
            &mut user_info.vesting_infos,
            VestingInfo {
                total_amount: _amount,
                claimed_amount: 0,
                vesting_start_time: timestamp::now_seconds()
            }
        );

        // Store user_info state
        user_info.y_merkle_balance = user_info.y_merkle_balance - _amount;
    }

    /// Exit vesting.
    /// @Parameters
    /// _user: Signer, user who vest yMerkle to merkle
    /// _index: Indeox of user's vesting info
    public entry fun exit_vesting(
        _user: &signer,
        _vesting_index: u64
    ) acquires DistributorInfo {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut = borrow_global_mut<DistributorInfo>(@merkle);

        // Borrow UserInfo/VestingInfo
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(_user));
        let vesting_info = vector::remove(&mut user_info.vesting_infos, _vesting_index);

        user_info.y_merkle_balance = user_info.y_merkle_balance + vesting_info.total_amount - vesting_info.claimed_amount;

        // Drop vesting info
        let VestingInfo {
            total_amount: _,
            claimed_amount: _,
            vesting_start_time: _
        } = vesting_info;
    }

    /// Claim vested merkle.
    /// @Parameters
    /// _user: Signer, user who vest yMerkle to merkle
    /// _index: Indeox of user's vesting info
    public entry fun claim_vesting(
        _user: &signer,
        _index: u64
    ) acquires DistributorInfo, RewardBox {
        assert!(exists<DistributorInfo>(@merkle), E_DISTRIBUTOR_INFO_NOT_EXIST);
        let distributor_ref_mut = borrow_global_mut<DistributorInfo>(@merkle);

        // Borrow UserInfo/VestingInfo
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(_user));
        let vesting_info = vector::borrow_mut(&mut user_info.vesting_infos, _index);

        // Calculate claimable merkle amount
        let claimable_amount = safe_mul_div(
            vesting_info.total_amount,
            (timestamp::now_seconds() - vesting_info.vesting_start_time),
            VESTING_TIMESTMAP
        ) - vesting_info.claimed_amount;

        vesting_info.claimed_amount = vesting_info.claimed_amount + claimable_amount;

        // Deposit claimable merkle to user
        {
            let reward_box = borrow_global_mut<RewardBox<MerkleCoin>>(@merkle);
            coin::deposit<MerkleCoin>(
                address_of(_user),
                coin::extract(&mut reward_box.balance, claimable_amount)
            );
        };
    }
    #[test_only]
    use std::string::utf8;

    #[test_only]
    struct TestPair has key, store, drop {}

    #[test_only]
    struct TEST_USDC has store, drop {}

    #[test_only]
    struct TEST_MKLP has store, drop {}

    #[test_only]
    fun create_test_coins<T>(
        host: &signer,
        name: vector<u8>,
        decimals: u8,
        amount: u64
    ) {
        let (bc, fc, mc) = coin::initialize<T>(host,
            utf8(name),
            utf8(name),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<T>(host);
        coin::deposit(address_of(host), coin::mint<T>(amount, &mc));
        coin::destroy_mint_cap(mc);
    }

    #[test_only]
    public entry fun call_test_setting(host: &signer, aptos_framework: &signer) acquires DistributorInfo {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        create_account_for_test(address_of(host));
        merkle_coin::initialize(host);
        coin::register<MerkleCoin>(host);
        merkle_coin::mint(host, address_of(host), 10000000 * 100000000);
        create_test_coins<TEST_MKLP>(host, b"MKLP", 8, 10000000 * 100000000);
        create_test_coins<TEST_USDC>(host, b"USDC", 8, 10000000 * 100000000);
        initialize(host);
        register_staking_coin<TEST_MKLP>(host);
        register_reward<TEST_USDC>(host);
        fee_distributor::register_pool<TEST_MKLP>(host, 0);
        fee_distributor::set_alloc_point<TEST_MKLP>(host, 0, 1000000);
        merkle_distributor::register_pool<VeMerkle>(host);
        merkle_distributor::set_reward_per_time(host, 100);
        merkle_distributor::set_alloc_point<VeMerkle>(host, 100);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test initialize
    public entry fun T_initialize(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test register staking coin
    public entry fun T_register_staking_coin(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize(host);
        register_staking_coin<TEST_MKLP>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test register reward
    public entry fun T_register_reward(host: &signer, aptos_framework: &signer) acquires DistributorInfo {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize(host);
        register_reward<TEST_USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test stake
    public entry fun T_stake(host: &signer, aptos_framework: &signer) acquires DistributorInfo, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        stake<TEST_MKLP>(host, 1000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test stake
    public entry fun T_unstake(host: &signer, aptos_framework: &signer) acquires DistributorInfo, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        stake<TEST_MKLP>(host, 1000000);
        unstake<TEST_MKLP>(host, 1000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test harvest
    public entry fun T_harvest(host: &signer, aptos_framework: &signer) acquires DistributorInfo, StakingCoinBox, RewardBox {
        call_test_setting(host, aptos_framework);
        stake<TEST_MKLP>(host, 1000000);
        harvest<TEST_MKLP, TEST_USDC>(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test deposit fee
    public entry fun T_deposit_fee(host: &signer, aptos_framework: &signer) acquires DistributorInfo, RewardBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        deposit_fee<TEST_USDC>(coin::withdraw<TEST_USDC>(host, input));
        let reward_box_ref_mut = borrow_global_mut<RewardBox<TEST_USDC>>(@merkle);
        assert!(coin::value(&reward_box_ref_mut.balance) == input, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test deposit fee
    public entry fun T_deposit_reward_merkle(host: &signer, aptos_framework: &signer) acquires DistributorInfo, RewardBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        deposit_reward_merkle(coin::withdraw<MerkleCoin>(host, input));
        let reward_box_ref_mut = borrow_global_mut<RewardBox<MerkleCoin>>(@merkle);
        assert!(coin::value(&reward_box_ref_mut.balance) == input, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test harvest
    public entry fun T_harvest_with_deposit_fee(host: &signer, aptos_framework: &signer) acquires DistributorInfo, StakingCoinBox, RewardBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        stake<TEST_MKLP>(host, input);
        deposit_fee<TEST_USDC>(coin::withdraw(host, input));
        let before_balance = coin::balance<TEST_USDC>(address_of(host));
        harvest<TEST_MKLP, TEST_USDC>(host);
        let after_balance = coin::balance<TEST_USDC>(address_of(host));
        assert!(after_balance == before_balance + input, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test lock
    public entry fun T_lock_merkle(host: &signer, aptos_framework: &signer) acquires DistributorInfo, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        lock_merkle(host, input, 0, 100);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(host));
        assert!(user_info.locked_merkle == input, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 7)]
    /// Fail test unlock
    public entry fun T_unlock_merkle_E_LOCK_NOT_END(host: &signer, aptos_framework: &signer) acquires DistributorInfo, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        lock_merkle(host, 1000000, 0, 100);
        unlock_merkle(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test unlock
    public entry fun T_unlock_merkle(host: &signer, aptos_framework: &signer) acquires DistributorInfo, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        lock_merkle(host, input, 0, 31536 * 1000);
        timestamp::fast_forward_seconds(31536 * 1000 + 1);
        let before_balance = coin::balance<MerkleCoin>(address_of(host));
        unlock_merkle(host);
        let after_balance = coin::balance<MerkleCoin>(address_of(host));
        assert!(after_balance == before_balance + input, 1);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(host));
        assert!(user_info.locked_merkle == 0, 1);
        assert!(user_info.y_merkle_balance != 0, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test entry vesting
    public entry fun T_entry_vesting(host: &signer, aptos_framework: &signer) acquires DistributorInfo, RewardBox, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        deposit_reward_merkle(coin::withdraw<MerkleCoin>(host, input));
        let input = 1000000;
        lock_merkle(host, input, 0, 31536 * 1000);
        timestamp::fast_forward_seconds(31536 * 1000 + 1);
        unlock_merkle(host);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(host));
        entry_vesting(host, user_info.y_merkle_balance);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test exit vesting
    public entry fun T_exit_vesting(host: &signer, aptos_framework: &signer) acquires DistributorInfo, RewardBox, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        deposit_reward_merkle(coin::withdraw<MerkleCoin>(host, input));
        let input = 1000000;
        lock_merkle(host, input, 0, 31536 * 1000);
        timestamp::fast_forward_seconds(31536 * 1000 + 1);
        unlock_merkle(host);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(host));
        entry_vesting(host, user_info.y_merkle_balance);
        exit_vesting(host, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test claim vesting
    public entry fun T_claim_vesting(host: &signer, aptos_framework: &signer) acquires DistributorInfo, RewardBox, StakingCoinBox {
        call_test_setting(host, aptos_framework);
        let input = 1000000;
        deposit_reward_merkle(coin::withdraw<MerkleCoin>(host, input));
        let input = 1000000;
        lock_merkle(host, input, 0, 31536 * 1000);
        timestamp::fast_forward_seconds(31536 * 1000 + 1);
        unlock_merkle(host);
        let distributor_ref_mut =
            borrow_global_mut<DistributorInfo>(@merkle);
        let user_info = table::borrow_mut(&mut distributor_ref_mut.user_infos, address_of(host));
        entry_vesting(host, user_info.y_merkle_balance);
        timestamp::fast_forward_seconds(31536 * 1000 + 10000);
        let before_balance = coin::balance<MerkleCoin>(address_of(host));
        claim_vesting(host, 0);
        let after_balance = coin::balance<MerkleCoin>(address_of(host));
        assert!(after_balance != before_balance, 1);
    }
}
