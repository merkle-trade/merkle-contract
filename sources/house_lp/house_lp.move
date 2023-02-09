module merkle::house_lp {
    use std::signer;
    use std::option;
    use std::vector;
    use std::string::{Self, String};

    use aptos_std::table;
    use aptos_std::type_info;

    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability, FreezeCapability};

    use merkle::price_oracle;
    use merkle::decimals;
    use merkle::math_u64;
    use merkle::safe_math_u64;
    use merkle::distributor;

    friend merkle::trading;

    const MKLP_DECIMALS: u8 = 6;
    const BASIS_POINTS_DIVISOR: u64 = 10000;

    // <-- ERROR CODE ----->
    const E_WITHDRAW_TIME_LIMIT: u64 = 1;
    const E_DEPOSIT_TOO_SMALL: u64 = 2;

    struct MKLP {}

    struct HouseLPConfig has key, store {
        mint_capability: MintCapability<MKLP>,
        burn_capability: BurnCapability<MKLP>,
        freeze_capability: FreezeCapability<MKLP>,
        tvl_addition: u64,  // default 0
        tvl_deduction: u64,  // default 0
        withdraw_time_limit: u64,  // default 0
        total_weight: u64,
    }

    struct HouseLPBalances has key, store {
        coin_keys: vector<String>,
        coin_balances: table::Table<String, u64>,
        fee_balances: table::Table<String, u64>,
        coin_decimals: table::Table<String, u8>,
    }

    struct HouseLP<phantom CoinT> has key, store {
        // fee configs
        fee_basis_point: u64,  // decimals 4 -> 10000 = 100% default 0
        tax_basis_point: u64,  // decimals 4 -> 10000 = 100% default 0
        weight: u64,
        dynamic_fee_enabled: bool,

        // deposit infos
        mklp_amount: u64,
        coin: Coin<CoinT>,
        last_deposit_time: table::Table<address, u64>,  // second
    }

    public entry fun register<CoinT>(host: &signer, _weight: u64) acquires HouseLPConfig, HouseLPBalances {
        let host_addr = signer::address_of(host);
        assert!(@merkle == host_addr, 0);
        assert!(coin::is_coin_initialized<CoinT>(), 1);

        let decimals = coin::decimals<CoinT>();

        if (!exists<HouseLPConfig>(host_addr)) {
            let (burn_capability, freeze_capability, mint_capability) = coin::initialize<MKLP>(
                host,
                string::utf8(b"MerkleLP"),
                string::utf8(b"MKLP"),
                MKLP_DECIMALS,
                true,
            );
            move_to(host, HouseLPConfig {
                mint_capability,
                burn_capability,
                freeze_capability,
                tvl_addition: 0,
                tvl_deduction: 0,
                withdraw_time_limit: 0, // seconds
                total_weight: 0,
            });
            move_to(host, HouseLPBalances {
                coin_keys: vector::empty(),
                coin_balances: table::new(),
                fee_balances: table::new(),
                coin_decimals: table::new(),
            });
        };

        let house_lp_config = borrow_global_mut<HouseLPConfig>(@merkle);
        let house_lp_balances = borrow_global_mut<HouseLPBalances>(@merkle);
        let coin_key = type_info::type_name<CoinT>();
        if (!table::contains(&mut house_lp_balances.coin_balances, coin_key)) {
            table::add(&mut house_lp_balances.coin_balances, coin_key, 0);
            table::add(&mut house_lp_balances.fee_balances, coin_key, 0);
            table::add(&mut house_lp_balances.coin_decimals, coin_key, decimals);
            vector::push_back(&mut house_lp_balances.coin_keys, coin_key);
        };

        if (!exists<HouseLP<CoinT>>(host_addr)) {
            move_to(host, HouseLP<CoinT> {
                fee_basis_point: 0,
                tax_basis_point: 0,
                weight: _weight,
                dynamic_fee_enabled: true,
                mklp_amount: 0,
                coin: coin::zero(),
                last_deposit_time: table::new(),
            });
            house_lp_config.total_weight = house_lp_config.total_weight + _weight;
        }
    }

    fun get_usd_fee_basis_point<CoinT>(house_lp_config: &HouseLPConfig, house_lp: &HouseLP<CoinT>, usd_amount: u64, increase: bool): u64 {
        if (house_lp.dynamic_fee_enabled == false) {
            return house_lp.fee_basis_point
        };
        let initial_amount = house_lp.mklp_amount;
        let next_amount = 0;
        if (increase) {
            next_amount = initial_amount + usd_amount;
        } else if (usd_amount < initial_amount) {
            next_amount = initial_amount - usd_amount;
        };
        let supply = (option::extract<u128>(&mut coin::supply<MKLP>()) as u64);
        let target_amount = supply * house_lp.weight / house_lp_config.total_weight;
        if (target_amount == 0) {
            return house_lp.fee_basis_point
        };
        let initial_diff = math_u64::abs(target_amount, initial_amount);
        let next_diff = math_u64::abs(target_amount, next_amount);

        if (next_diff < initial_diff) {
            let rebate_bps = initial_diff * house_lp.tax_basis_point / target_amount / BASIS_POINTS_DIVISOR;
            if (house_lp.fee_basis_point > rebate_bps) return house_lp.fee_basis_point - rebate_bps else return 0
        };
        let average_diff = (initial_diff + next_diff) / 2;
        if (average_diff > target_amount) {
            average_diff = target_amount;
        };
        let tax_bps = average_diff * house_lp.tax_basis_point / target_amount / BASIS_POINTS_DIVISOR;
        return house_lp.fee_basis_point + tax_bps
    }

    public entry fun deposit_with_stake<CoinT>(host: &signer, amount: u64) acquires HouseLPConfig, HouseLPBalances, HouseLP {
        let host_addr = signer::address_of(host);
        let mklp_delta = 0;
        if (coin::is_account_registered<MKLP>(host_addr)) {
            mklp_delta = coin::balance<MKLP>(host_addr)
        };

        // deposit
        deposit<CoinT>(host, amount);
        mklp_delta = coin::balance<MKLP>(host_addr) - mklp_delta;

        // stake
        distributor::stake<MKLP>(host, mklp_delta);
    }

    public entry fun deposit<CoinT>(_host: &signer, _amount: u64) acquires HouseLPConfig, HouseLPBalances, HouseLP {
        let house_lp_config = borrow_global_mut<HouseLPConfig>(@merkle);
        let house_lp_balances = borrow_global_mut<HouseLPBalances>(@merkle);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);

        let host_addr = signer::address_of(_host);
        let tvl = get_vaults_tvl(house_lp_config, house_lp_balances, true);
        let coin_key = type_info::type_name<CoinT>();
        let price = price_oracle::read(coin_key, false);

        let deposit_coin = coin::withdraw<CoinT>(_host, _amount);
        coin::merge(&mut house_lp.coin, deposit_coin);

        // mint
        if (!coin::is_account_registered<MKLP>(host_addr)) {
            coin::register<MKLP>(_host);
        };
        let coin_decimals = table::borrow(&mut house_lp_balances.coin_decimals, coin_key);
        let oracle_decimals = price_oracle::get_price_decimals();

        let usd_amount = decimals::multiply_with_decimals(price, _amount, oracle_decimals, *coin_decimals, oracle_decimals);
        let fee_basis_point = get_usd_fee_basis_point<CoinT>(house_lp_config, house_lp, usd_amount, true);
        let usd_amount_after_fee = safe_math_u64::safe_mul_div(usd_amount, (BASIS_POINTS_DIVISOR - fee_basis_point), BASIS_POINTS_DIVISOR);
        let token_amount_after_fee = safe_math_u64::safe_mul_div(_amount, (BASIS_POINTS_DIVISOR - fee_basis_point), BASIS_POINTS_DIVISOR);

        let supply = (option::extract<u128>(&mut coin::supply<MKLP>()) as u64);
        let mintAmount = decimals::change_decimals(usd_amount_after_fee, oracle_decimals, MKLP_DECIMALS);

        if (tvl > 0 && supply > 0) {
            mintAmount = safe_math_u64::safe_mul_div(usd_amount_after_fee, supply, tvl); // usdAmount * supply / tvl
        };
        assert!(mintAmount > 0, E_DEPOSIT_TOO_SMALL);

        let mklp = coin::mint<MKLP>(mintAmount, &house_lp_config.mint_capability);
        coin::deposit(host_addr, mklp);

        let coin_balance = table::borrow_mut(&mut house_lp_balances.coin_balances, coin_key);
        *coin_balance = *coin_balance + _amount;

        let fee_balance = table::borrow_mut(&mut house_lp_balances.fee_balances, coin_key);
        *fee_balance = *fee_balance + (_amount - token_amount_after_fee);

        let last_deposit_time = table::borrow_mut_with_default(&mut house_lp.last_deposit_time, host_addr, 0);
        *last_deposit_time = timestamp::now_seconds();

        house_lp.mklp_amount = house_lp.mklp_amount + mintAmount;
    }

    public entry fun withdraw_with_unstake<CoinT>(host: &signer, amount: u64) acquires HouseLPConfig, HouseLPBalances, HouseLP {
        // unstake
        distributor::unstake<MKLP>(host, amount);

        // withdraw
        withdraw<CoinT>(host, amount);
    }

    public entry fun withdraw<CoinT>(_host: &signer, _amount: u64) acquires HouseLPConfig, HouseLPBalances, HouseLP {
        let house_lp_config = borrow_global_mut<HouseLPConfig>(@merkle);
        let house_lp_balances = borrow_global_mut<HouseLPBalances>(@merkle);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);

        let host_addr = signer::address_of(_host);
        let tvl = get_vaults_tvl(house_lp_config, house_lp_balances, false);
        let coin_key = type_info::type_name<CoinT>();
        let price = price_oracle::read(coin_key, false);

        // check last deposit time
        let last_deposit_time = table::borrow_mut_with_default(&mut house_lp.last_deposit_time, host_addr, timestamp::now_seconds());
        assert!(timestamp::now_seconds() - *last_deposit_time >= house_lp_config.withdraw_time_limit, E_WITHDRAW_TIME_LIMIT);

        // return coin amount
        let coin_decimals = table::borrow(&mut house_lp_balances.coin_decimals, coin_key);
        let oracle_decimals = price_oracle::get_price_decimals();
        let supply = (option::extract<u128>(&mut coin::supply<MKLP>()) as u64);

        let tvl_amount = decimals::multiply_with_decimals(tvl, _amount, oracle_decimals, MKLP_DECIMALS, MKLP_DECIMALS); // tvl * amount
        let usd_amount = decimals::divide_with_decimals(tvl_amount, supply, MKLP_DECIMALS, MKLP_DECIMALS, oracle_decimals); // tvl * amount / supply
        let return_amount = decimals::divide_with_decimals(usd_amount, price, oracle_decimals, oracle_decimals, *coin_decimals); // tvl * amount / supply / _price

        let fee_basis_point = get_usd_fee_basis_point<CoinT>(house_lp_config, house_lp, usd_amount, false);
        let return_amount_after_fee = safe_math_u64::safe_mul_div(return_amount, (BASIS_POINTS_DIVISOR - fee_basis_point), BASIS_POINTS_DIVISOR);

        // burn
        let mklp = coin::withdraw<MKLP>(_host, _amount);
        coin::burn(mklp, &house_lp_config.burn_capability);

        let coin_balance = table::borrow_mut_with_default(&mut house_lp_balances.coin_balances, coin_key, 0);
        *coin_balance = *coin_balance - return_amount_after_fee;

        let fee_balance = table::borrow_mut(&mut house_lp_balances.fee_balances, coin_key);
        *fee_balance = *fee_balance + (return_amount - return_amount_after_fee);

        house_lp.mklp_amount = house_lp.mklp_amount - _amount;

        let withdraw_coin = coin::extract(&mut house_lp.coin, return_amount_after_fee);
        coin::deposit(host_addr, withdraw_coin);
    }

    public(friend) fun pnl_deposit_to_lp<CoinT>(coin: Coin<CoinT>) acquires HouseLPBalances, HouseLP {
        let house_lp_balances = borrow_global_mut<HouseLPBalances>(@merkle);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);

        let amount = coin::value(&coin);
        let coin_key = type_info::type_name<CoinT>();
        let coin_balance = table::borrow_mut_with_default(&mut house_lp_balances.coin_balances, coin_key, 0);

        *coin_balance = *coin_balance + amount;
        coin::merge(&mut house_lp.coin, coin);
    }

    public(friend) fun pnl_withdraw_from_lp<CoinT>(amount: u64): Coin<CoinT> acquires HouseLPBalances,  HouseLP {
        let house_lp_balances = borrow_global_mut<HouseLPBalances>(@merkle);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);
        let coin_key = type_info::type_name<CoinT>();
        let coin_balance = table::borrow_mut_with_default(&mut house_lp_balances.coin_balances, coin_key, 0);

        *coin_balance = *coin_balance - amount;
        coin::extract(&mut house_lp.coin, amount)
    }

    public fun get_vaults_tvl(house_lp_config: &HouseLPConfig, house_lp_balances: &HouseLPBalances, _miximize: bool): u64 {
        let coin_keys_len = vector::length(&house_lp_balances.coin_keys);
        let tvl = house_lp_config.tvl_addition;
        let i = 0;
        let oracle_decimals = price_oracle::get_price_decimals();

        while (i < coin_keys_len) {
            let coin_key = *vector::borrow(&house_lp_balances.coin_keys, i);
            let coin_balance = table::borrow(&house_lp_balances.coin_balances, coin_key);
            let fee_balance = table::borrow(&house_lp_balances.fee_balances, coin_key);
            let balance = if (*coin_balance > *fee_balance) *coin_balance - *fee_balance else 0;

            let price = price_oracle::read(coin_key, _miximize);
            let coin_decimals = table::borrow(&house_lp_balances.coin_decimals, coin_key);

            tvl = tvl + decimals::multiply_with_decimals(balance, price, *coin_decimals, oracle_decimals, oracle_decimals);
            i = i + 1;
        };
        if (tvl < house_lp_config.tvl_deduction) {
            return 0
        };
        tvl - house_lp_config.tvl_deduction
    }

    public entry fun update_tvl_addition(host: &signer, tvl_addition: u64) acquires HouseLPConfig {
        assert!(@merkle == signer::address_of(host), 0);
        let house_lp_config = borrow_global_mut<HouseLPConfig>(@merkle);
        house_lp_config.tvl_addition = tvl_addition;
    }

    public entry fun update_tvl_deduction(host: &signer, tvl_deduction: u64) acquires HouseLPConfig {
        assert!(@merkle == signer::address_of(host), 0);
        let house_lp_config = borrow_global_mut<HouseLPConfig>(@merkle);
        house_lp_config.tvl_deduction = tvl_deduction;
    }

    public entry fun update_fee_basis_point<CoinT>(host: &signer, fee_basis_point: u64) acquires HouseLP {
        assert!(@merkle == signer::address_of(host), 0);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);
        house_lp.fee_basis_point = fee_basis_point;
    }

    public entry fun update_tax_basis_point<CoinT>(host: &signer, tax_basis_point: u64) acquires HouseLP {
        assert!(@merkle == signer::address_of(host), 0);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);
        house_lp.tax_basis_point = tax_basis_point;
    }

    public entry fun update_house_lp_weight<CoinT>(host: &signer, weight: u64) acquires HouseLP {
        assert!(@merkle == signer::address_of(host), 0);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);
        house_lp.weight = weight;
    }

    public entry fun update_house_lp_dynamic_fee_enabled<CoinT>(host: &signer, dynamic_fee_enabled: bool) acquires HouseLP {
        assert!(@merkle == signer::address_of(host), 0);
        let house_lp = borrow_global_mut<HouseLP<CoinT>>(@merkle);
        house_lp.dynamic_fee_enabled = dynamic_fee_enabled;
    }

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    use merkle::fee_distributor;

    #[test_only]
    use merkle::merkle_distributor;

    #[test_only]
    struct USDC has key {}

    #[test_only]
    const TEST_USDC_DECIMALS: u8 = 6;

    #[test_only]
    struct USDCInfo has key, store {
        burn_cap: BurnCapability<USDC>,
        freeze_cap: FreezeCapability<USDC>,
        mint_cap: MintCapability<USDC>,
    }

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) acquires USDCInfo {
        let price_decimals = (price_oracle::get_price_decimals() as u64);
        let host_addr = signer::address_of(host);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(host_addr);

        price_oracle::register_oracle<USDC>(host, 10 * math_u64::exp(10, price_decimals));

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<USDC>(
            host,
            string::utf8(b"USDC"),
            string::utf8(b"USDC"),
            (TEST_USDC_DECIMALS as u8),
            false,
        );
        move_to(host, USDCInfo {
            burn_cap,
            freeze_cap,
            mint_cap
        });
        let usdc_info = borrow_global<USDCInfo>(host_addr);
        coin::register<USDC>(host);
        let mint_coin = coin::mint(1000 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), &usdc_info.mint_cap);
        coin::deposit(host_addr, mint_coin);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_register(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        assert!(exists<HouseLPConfig>(host_addr) == true, 0);
        let house_lp_balances = borrow_global_mut<HouseLPBalances>(host_addr);
        let coin_key = type_info::type_name<USDC>();
        assert!(table::contains(&mut house_lp_balances.coin_balances, coin_key) == true, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_deposit(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        let price_decimals = price_oracle::get_price_decimals();
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        let coin_key = type_info::type_name<USDC>();
        let price = price_oracle::read(coin_key, true);
        let deposit_amount = 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64));

        deposit<USDC>(host, deposit_amount);

        let house_lp = borrow_global_mut<HouseLP<USDC>>(host_addr);
        let house_lp_balances = borrow_global_mut<HouseLPBalances>(host_addr);
        let deposit_usd = decimals::multiply_with_decimals(deposit_amount, price, TEST_USDC_DECIMALS, price_decimals, TEST_USDC_DECIMALS);
        let fee = deposit_usd * house_lp.fee_basis_point / BASIS_POINTS_DIVISOR;

        assert!(coin::balance<MKLP>(host_addr) == decimals::change_decimals(deposit_usd - fee, TEST_USDC_DECIMALS, MKLP_DECIMALS), 0);
        assert!(coin::balance<USDC>(host_addr) == 900 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
        assert!(coin::value(&house_lp.coin) == 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 2);
        assert!(option::extract<u128>(&mut coin::supply<MKLP>()) == ((decimals::change_decimals(deposit_usd - fee, TEST_USDC_DECIMALS, MKLP_DECIMALS)) as u128), 1);
        assert!(vector::length(&house_lp_balances.coin_keys) == 1, 2);

        let vault_info = vector::borrow(&house_lp_balances.coin_keys, 0);
        let coin_key = type_info::type_name<USDC>();
        assert!(*vault_info == coin_key, 3);
        assert!(table::contains(&mut house_lp_balances.coin_balances, *vault_info) == true, 4);

        let coin_balance = table::borrow_mut_with_default(&mut house_lp_balances.coin_balances, *vault_info, 0);
        assert!(*coin_balance == deposit_amount, 5);

        let fee_balance = table::borrow_mut_with_default(&mut house_lp_balances.fee_balances, *vault_info, 0);
        assert!(*fee_balance == fee, 6);

        let house_lp = borrow_global_mut<HouseLP<USDC>>(@merkle);
        assert!(house_lp.mklp_amount == decimals::change_decimals(deposit_usd - fee, TEST_USDC_DECIMALS, MKLP_DECIMALS), 7);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_deposit_with_stake(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        distributor::initialize(host);
        distributor::register_reward<USDC>(host);
        distributor::register_staking_coin<MKLP>(host);
        fee_distributor::register_pool<MKLP>(host, 0);
        fee_distributor::set_alloc_point<MKLP>(host, 0, 1000000);
        merkle_distributor::register_pool<MKLP>(host);
        merkle_distributor::set_reward_per_time(host, 100);
        merkle_distributor::set_alloc_point<MKLP>(host, 1000000);

        deposit_with_stake<USDC>(host, 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));

        let house_lp = borrow_global_mut<HouseLP<USDC>>(@merkle);
        assert!(coin::balance<MKLP>(host_addr) == 0, 0);
        assert!(coin::balance<USDC>(host_addr) == 900 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
        assert!(coin::value(&house_lp.coin) == 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 2);
    }


    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_withdraw(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);
        let deposit_amount = 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64));
        let _fee_basis_point = 0;
        {
            let house_lp = borrow_global_mut<HouseLP<USDC>>(host_addr);
            _fee_basis_point = house_lp.fee_basis_point;
        };

        deposit<USDC>(host, deposit_amount);

        let withdraw_mklp = 600 * math_u64::exp(10, (MKLP_DECIMALS as u64));
        withdraw<USDC>(host, withdraw_mklp);

        {
            let house_lp = borrow_global_mut<HouseLP<USDC>>(host_addr);
            assert!(coin::balance<MKLP>(host_addr) == 400 * math_u64::exp(10, (MKLP_DECIMALS as u64)), 0);
            assert!(coin::balance<USDC>(host_addr) == 960 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
            assert!(coin::value(&house_lp.coin) == 40 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 2);
        };


        withdraw<USDC>(host, coin::balance<MKLP>(host_addr));
        let house_lp = borrow_global_mut<HouseLP<USDC>>(host_addr);
        assert!(coin::balance<MKLP>(host_addr) == 0, 4);
        assert!(coin::balance<USDC>(host_addr) == 1000 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
        assert!(coin::value(&house_lp.coin) == 0, 2);
        assert!(option::extract<u128>(&mut coin::supply<MKLP>()) == 0, 6);

        let house_lp_balances = borrow_global_mut<HouseLPBalances>(@merkle);
        let coin_key = *vector::borrow(&house_lp_balances.coin_keys, 0);
        let coin_balance = table::borrow_mut_with_default(&mut house_lp_balances.coin_balances, coin_key, 0);
        let fee_balance = table::borrow_mut_with_default(&mut house_lp_balances.fee_balances, coin_key, 0);
        assert!(*coin_balance == *fee_balance, 7);

        let house_lp = borrow_global_mut<HouseLP<USDC>>(@merkle);
        assert!(house_lp.mklp_amount == 0, 8);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_withdraw_with_unstake(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        distributor::initialize(host);
        distributor::register_reward<USDC>(host);
        distributor::register_staking_coin<MKLP>(host);
        fee_distributor::register_pool<MKLP>(host, 0);
        fee_distributor::set_alloc_point<MKLP>(host, 0, 1000000);
        merkle_distributor::register_pool<MKLP>(host);
        merkle_distributor::set_reward_per_time(host, 100);
        merkle_distributor::set_alloc_point<MKLP>(host, 1000000);

        deposit_with_stake<USDC>(host, 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));

        withdraw_with_unstake<USDC>(host, 400 * math_u64::exp(10, (MKLP_DECIMALS as u64)));
        let house_lp = borrow_global<HouseLP<USDC>>(@merkle);
        assert!(coin::balance<MKLP>(host_addr) == 0, 0);
        assert!(coin::balance<USDC>(host_addr) == 940 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
        assert!(coin::value(&house_lp.coin) == 60 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 2);

        withdraw_with_unstake<USDC>(host, 600 * math_u64::exp(10, (MKLP_DECIMALS as u64)));
        house_lp = borrow_global<HouseLP<USDC>>(@merkle);
        assert!(coin::balance<MKLP>(host_addr) == 0, 3);
        assert!(coin::balance<USDC>(host_addr) == 1000 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 4);
        assert!(coin::value(&house_lp.coin) == 0, 5);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_get_tvl(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let price_decimals = (price_oracle::get_price_decimals() as u64);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);
        let host_addr = signer::address_of(host);

        deposit<USDC>(host, 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));
        {
            let house_lp_config = borrow_global_mut<HouseLPConfig>(host_addr);
            let house_lp_balances = borrow_global_mut<HouseLPBalances>(host_addr);
            assert!(get_vaults_tvl(house_lp_config, house_lp_balances, true) == 1000 * math_u64::exp(10, price_decimals), 0);
        };

        withdraw<USDC>(host, 400 * math_u64::exp(10, (MKLP_DECIMALS as u64)));
        {
            let house_lp_config = borrow_global_mut<HouseLPConfig>(host_addr);
            let house_lp_balances = borrow_global_mut<HouseLPBalances>(host_addr);
            assert!(get_vaults_tvl(house_lp_config, house_lp_balances, true) == 600 * math_u64::exp(10, price_decimals), 1);
        };

        withdraw<USDC>(host, 600 * math_u64::exp(10, (MKLP_DECIMALS as u64)));
        {
            let house_lp_config = borrow_global_mut<HouseLPConfig>(host_addr);
            let house_lp_balances = borrow_global_mut<HouseLPBalances>(host_addr);
            assert!(get_vaults_tvl(house_lp_config, house_lp_balances, true) == 0, 2);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update_configs(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
    let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        let house_lp_config = borrow_global<HouseLPConfig>(host_addr);
        let house_lp = borrow_global<HouseLP<USDC>>(host_addr);
        assert!(house_lp_config.tvl_addition == 0, 0);
        assert!(house_lp_config.tvl_deduction == 0, 1);
        assert!(house_lp.fee_basis_point == 0, 2);
        assert!(house_lp.tax_basis_point == 0, 3);

        update_tvl_addition(host, 10);
        update_tvl_deduction(host, 11);
        update_fee_basis_point<USDC>(host, 1000);
        update_tax_basis_point<USDC>(host, 1100);


        house_lp_config = borrow_global<HouseLPConfig>(host_addr);
        house_lp = borrow_global<HouseLP<USDC>>(host_addr);
        assert!(house_lp_config.tvl_addition == 10, 4);
        assert!(house_lp_config.tvl_deduction == 11, 5);
        assert!(house_lp.fee_basis_point == 1000, 6);
        assert!(house_lp.tax_basis_point == 1100, 7);

        assert!(house_lp.weight == 10, 8);
        assert!(house_lp.dynamic_fee_enabled == true, 9);

        update_house_lp_weight<USDC>(host, 20);
        update_house_lp_dynamic_fee_enabled<USDC>(host, false);

        house_lp = borrow_global<HouseLP<USDC>>(host_addr);
        assert!(house_lp.weight == 20, 10);
        assert!(house_lp.dynamic_fee_enabled == false, 11);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_profit_loss(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        let usdc_info = borrow_global<USDCInfo>(host_addr);
        let mint_coin = coin::mint(100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), &usdc_info.mint_cap);
        pnl_deposit_to_lp(mint_coin);
        {
            let house_lp = borrow_global<HouseLP<USDC>>(@merkle);
            assert!(coin::value(&house_lp.coin) == 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 0);
        };

        let withdraw_coin = pnl_withdraw_from_lp<USDC>(100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));
        assert!(coin::value(&withdraw_coin) == 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
        {
            let house_lp = borrow_global<HouseLP<USDC>>(@merkle);
            assert!(coin::value(&house_lp.coin) == 0, 2);
        };

        coin::burn(withdraw_coin, &usdc_info.burn_cap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_profit_withdraw(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        deposit<USDC>(host, 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));
        assert!(coin::balance<MKLP>(host_addr) == 1000 * math_u64::exp(10, (MKLP_DECIMALS as u64)), 0);

        let usdc_info = borrow_global<USDCInfo>(host_addr);
        let mint_coin = coin::mint(1000 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), &usdc_info.mint_cap);
        pnl_deposit_to_lp(mint_coin);

        {
            let house_lp = borrow_global<HouseLP<USDC>>(@merkle);
            assert!(coin::value(&house_lp.coin) == 1100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
        };

        withdraw<USDC>(host, 1000 * math_u64::exp(10, (MKLP_DECIMALS as u64)));

        let house_lp = borrow_global<HouseLP<USDC>>(@merkle);
        assert!(coin::balance<MKLP>(host_addr) == 0, 2);
        assert!(coin::balance<USDC>(host_addr) == 2000 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 3);
        assert!(coin::value(&house_lp.coin) == 0, 4);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_loss_withdraw(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        deposit<USDC>(host, 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));
        assert!(coin::balance<MKLP>(host_addr) == 1000 * math_u64::exp(10, (MKLP_DECIMALS as u64)), 0);

        let usdc_info = borrow_global<USDCInfo>(host_addr);
        let withdraw_coin = pnl_withdraw_from_lp<USDC>(30 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));
        {
            let house_lp = borrow_global<HouseLP<USDC>>(@merkle);
            assert!(coin::value(&house_lp.coin) == 70 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 1);
        };

        withdraw<USDC>(host, 1000 * math_u64::exp(10, (MKLP_DECIMALS as u64)));

        let house_lp = borrow_global<HouseLP<USDC>>(@merkle);
        assert!(coin::balance<MKLP>(host_addr) == 0, 2);
        assert!(coin::balance<USDC>(host_addr) == 970 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), 3);
        assert!(coin::value(&house_lp.coin) == 0, 4);

        coin::burn(withdraw_coin, &usdc_info.burn_cap);
    }
    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_deposit_small_rate(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        deposit<USDC>(host, 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));
        assert!(coin::balance<MKLP>(host_addr) == 1000 * math_u64::exp(10, (MKLP_DECIMALS as u64)), 0);

        let usdc_info = borrow_global<USDCInfo>(host_addr);
        let mint_coin = coin::mint(1000 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), &usdc_info.mint_cap);
        pnl_deposit_to_lp(mint_coin);

        deposit<USDC>(host, 10);
        assert!(coin::balance<MKLP>(host_addr) > 1000 * math_u64::exp(10, (MKLP_DECIMALS as u64)), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 2)]
    fun test_deposit_small_rate_should_fail(host: &signer, aptos_framework: &signer) acquires HouseLPConfig, HouseLPBalances, HouseLP, USDCInfo {
        let host_addr = signer::address_of(host);
        call_test_setting(host, aptos_framework);
        register<USDC>(host, 10);

        deposit<USDC>(host, 100 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)));
        assert!(coin::balance<MKLP>(host_addr) == 1000 * math_u64::exp(10, (MKLP_DECIMALS as u64)), 0);

        let usdc_info = borrow_global<USDCInfo>(host_addr);
        let mint_coin = coin::mint(1000 * math_u64::exp(10, (TEST_USDC_DECIMALS as u64)), &usdc_info.mint_cap);
        pnl_deposit_to_lp(mint_coin);

        deposit<USDC>(host, 1);
    }
}
