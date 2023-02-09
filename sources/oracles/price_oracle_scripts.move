module merkle::price_oracle_scripts {
    use merkle::price_oracle;

    use aptos_std::type_info;

    public entry fun register_oracle<CoinT>(host: &signer, init_value: u64) {
        price_oracle::register_oracle<CoinT>(host, init_value);
    }

    public entry fun update<CoinT>(host: &signer, value: u64) {
        let coin_key = type_info::type_name<CoinT>();
        price_oracle::update(host, coin_key, value);
    }

    /// Update OracleInfo
    public entry fun update_price_oracle_info_max_price_update_delay<OracleT: copy+store+drop>(host: &signer, max_price_update_delay: u64) {
        price_oracle::update_price_oracle_info_max_price_update_delay<OracleT>(host, max_price_update_delay);
    }

    public entry fun update_price_oracle_info_price_duration<OracleT: copy+store+drop>(host: &signer, price_duration: u64) {
        price_oracle::update_price_oracle_info_price_duration<OracleT>(host, price_duration);
    }

    public entry fun update_price_oracle_info_spread_basis_points_if_chain_error<OracleT: copy+store+drop>(host: &signer, spread_basis_points_if_chain_error: u64) {
        price_oracle::update_price_oracle_info_spread_basis_points_if_chain_error<OracleT>(host, spread_basis_points_if_chain_error);
    }

    public entry fun update_price_oracle_info_spread_basis_points_if_inactive<OracleT: copy+store+drop>(host: &signer, spread_basis_points_if_inactive: u64) {
        price_oracle::update_price_oracle_info_spread_basis_points_if_inactive<OracleT>(host, spread_basis_points_if_inactive);
    }

    public entry fun update_price_oracle_info_max_deviation_basis_points<OracleT: copy+store+drop>(host: &signer, max_deviation_basis_points: u64) {
        price_oracle::update_price_oracle_info_max_deviation_basis_points<OracleT>(host, max_deviation_basis_points);
    }

    public entry fun update_price_oracle_info_switchboard_oracle_addresses<OracleT: copy+store+drop>(host: &signer, idx: u64, switchboard_oracle_address: address) {
        price_oracle::update_price_oracle_info_switchboard_oracle_addresses<OracleT>(host, idx, switchboard_oracle_address);
    }

    public entry fun update_price_oracle_info_is_spread_enabled<OracleT: copy+store+drop>(host: &signer, is_spread_enabled: bool) {
        price_oracle::update_price_oracle_info_is_spread_enabled<OracleT>(host, is_spread_enabled);
    }

    /* test */
    #[test_only]
    struct TESTUSD has copy,store,drop {}
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use merkle::oracle_feed;

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        let host_addr = signer::address_of(host);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(host_addr);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_register_oracle(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);

        register_oracle<TESTUSD>(host, 10);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update(host: &signer, aptos_framework: &signer) {
        let coin_key = type_info::type_name<TESTUSD>();
        call_test_setting(host, aptos_framework);

        oracle_feed::register_oracle<TESTUSD>(host, 10);
        update<TESTUSD>(host, 20);
        assert!(oracle_feed::read(coin_key) == 20, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update_price_oracle_info(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
        price_oracle::register_oracle<TESTUSD>(host, 10);

        update_price_oracle_info_max_price_update_delay<TESTUSD>(host, 7200 * 1000 * 1000);
        update_price_oracle_info_price_duration<TESTUSD>(host, 600 * 1000 * 1000);
        update_price_oracle_info_spread_basis_points_if_chain_error<TESTUSD>(host, 3);
        update_price_oracle_info_spread_basis_points_if_inactive<TESTUSD>(host, 3);
        update_price_oracle_info_max_deviation_basis_points<TESTUSD>(host, 300);
        update_price_oracle_info_switchboard_oracle_addresses<TESTUSD>(host, 0, @merkle);
        update_price_oracle_info_is_spread_enabled<TESTUSD>(host, false);
    }
}