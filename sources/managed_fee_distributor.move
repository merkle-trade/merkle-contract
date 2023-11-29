module merkle::managed_fee_distributor {
    use merkle::fee_distributor;

    // Entry functions for fee_distributor
    // AssetT is collateral type

    public entry fun initialize<AssetT>(
        _host: &signer
    ) {
        fee_distributor::initialize<AssetT>(_host);
    }

    public entry fun withdraw_fee_dev<AssetT>(_host: &signer, _amount: u64) {
        fee_distributor::withdraw_fee_dev<AssetT>(_host, _amount);
    }

    public entry fun withdraw_fee_stake<AssetT>(_host: &signer, _amount: u64) {
        fee_distributor::withdraw_fee_stake<AssetT>(_host, _amount);
    }

    public entry fun set_lp_weight<AssetT>(_host: &signer, _lp_weight: u64) {
        fee_distributor::set_lp_weight<AssetT>(_host, _lp_weight);
    }

    public entry fun set_stake_weight<AssetT>(_host: &signer, _stake_weight: u64) {
        fee_distributor::set_stake_weight<AssetT>(_host, _stake_weight);
    }

    public entry fun set_dev_weight<AssetT>(_host: &signer, _dev_weight: u64) {
        fee_distributor::set_dev_weight<AssetT>(_host, _dev_weight);
    }
}