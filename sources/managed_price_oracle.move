module merkle::managed_price_oracle {
    use merkle::price_oracle;

    // Entry functions for house_lp
    // PairType is pair type

    public entry fun register_oracle<PairType>(host: &signer) {
        price_oracle::register_oracle<PairType>(host);
    }

    public entry fun register_allowed_update<PairType>(host: &signer, addr: address) {
        price_oracle::register_allowed_update<PairType>(host, addr);
    }

    public entry fun remove_allowed_update<PairType>(host: &signer, addr: address) {
        price_oracle::remove_allowed_update<PairType>(host, addr);
    }

    public entry fun update<PairType>(host: &signer, value: u64, pyth_vaa: vector<u8>) {
        price_oracle::update<PairType>(host, value, pyth_vaa);
    }

    public entry fun set_max_price_update_delay<PairType>(host: &signer, max_price_update_delay: u64) {
        price_oracle::set_max_price_update_delay<PairType>(host, max_price_update_delay);
    }

    public entry fun set_spread_basis_points_if_update_delay<PairType>(host: &signer, spread_basis_points_if_chain_error: u64) {
        price_oracle::set_spread_basis_points_if_update_delay<PairType>(host, spread_basis_points_if_chain_error);
    }

    public entry fun set_max_deviation_basis_points<PairType>(host: &signer, max_deviation_basis_points: u64) {
        price_oracle::set_max_deviation_basis_points<PairType>(host, max_deviation_basis_points);
    }

    public entry fun set_switchboard_oracle_address<PairType>(host: &signer, switchboard_oracle_address: address) {
        price_oracle::set_switchboard_oracle_address<PairType>(host, switchboard_oracle_address);
    }

    public entry fun set_is_spread_enabled<PairType>(host: &signer, is_spread_enabled: bool) {
        price_oracle::set_is_spread_enabled<PairType>(host, is_spread_enabled);
    }

    public entry fun set_update_pyth_enabled<PairType>(host: &signer, check_pyth_enabled: bool) {
        price_oracle::set_update_pyth_enabled<PairType>(host, check_pyth_enabled);
    }

    public entry fun set_pyth_price_identifier<PairType>(host: &signer, pyth_price_identifier: vector<u8>) {
        price_oracle::set_pyth_price_identifier<PairType>(host, pyth_price_identifier);
    }
}