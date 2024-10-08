module merkle::managed_house_lp {
    use merkle::house_lp;

    // Entry functions for house_lp
    // AssetT is collateral type

    public entry fun register<AssetT>(host: &signer) {
        house_lp::register<AssetT>(host);
    }

    public entry fun deposit_without_mint<AssetT>(_user: &signer, _amount: u64) {
        house_lp::deposit_without_mint<AssetT>(_user, _amount);
    }

    public entry fun deposit<AssetT>(_user: &signer, _amount: u64) {
        house_lp::deposit<AssetT>(_user, _amount);
    }

    #[deprecated]
    public entry fun withdraw<AssetT>(_user: &signer, _amount: u64) {
        house_lp::withdraw<AssetT>(_user, _amount); // deprecated
    }

    public entry fun register_redeem_plan<AssetT>(_user: &signer, _amount: u64) {
        house_lp::register_redeem_plan<AssetT>(_user, _amount);
    }

    public entry fun redeem<AssetT>(_user: &signer) {
        house_lp::redeem<AssetT>(_user);
    }

    public entry fun cancel_redeem_plan<AssetT>(_user: &signer) {
        house_lp::cancel_redeem_plan<AssetT>(_user);
    }

    public entry fun set_house_lp_deposit_fee<AssetT>(_host: &signer, _deposit_fee: u64) {
        house_lp::set_house_lp_deposit_fee<AssetT>(_host, _deposit_fee);
    }

    public entry fun set_house_lp_withdraw_fee<AssetT>(_host: &signer, _withdraw_fee: u64) {
        house_lp::set_house_lp_withdraw_fee<AssetT>(_host, _withdraw_fee);
    }

    public entry fun set_house_lp_withdraw_division<AssetT>(_host: &signer, _withdraw_division: u64) {
        house_lp::set_house_lp_withdraw_division<AssetT>(_host, _withdraw_division);
    }

    public entry fun set_house_lp_minimum_deposit<AssetT>(_host: &signer, _minimum_deposit: u64) {
        house_lp::set_house_lp_minimum_deposit<AssetT>(_host, _minimum_deposit);
    }

    public entry fun set_house_lp_soft_break<AssetT>(_host: &signer, _soft_break: u64) {
        house_lp::set_house_lp_soft_break<AssetT>(_host, _soft_break);
    }

    public entry fun set_house_lp_hard_break<AssetT>(_host: &signer, _hard_break: u64) {
        house_lp::set_house_lp_hard_break<AssetT>(_host, _hard_break);
    }
}
