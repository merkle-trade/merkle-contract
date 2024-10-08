module merkle::managed_liquidity_auction {
    use merkle::liquidity_auction;

    public entry fun initialize_module<AssetType>(_admin: &signer) {
        liquidity_auction::initialize_module<AssetType>(_admin);
    }

    public entry fun deposit_pre_mkl<AssetType>(_user: &signer, _mkl_deposit_amount: u64) {
        liquidity_auction::deposit_pre_mkl<AssetType>(_user, _mkl_deposit_amount);
    }

    public entry fun deposit_asset<AssetType>(_user: &signer, _deposit_amount: u64) {
        liquidity_auction::deposit_asset<AssetType>(_user, _deposit_amount);
    }

    public entry fun withdraw_asset<AssetType>(_user: &signer, _withdraw_amount: u64) {
        liquidity_auction::withdraw_asset<AssetType>(_user, _withdraw_amount);
    }

    public entry fun run_tge_sequence<AssetType>(_admin: &signer) {
        liquidity_auction::run_tge_sequence<AssetType>(_admin);
    }

    public entry fun withdraw_remaining_reward<AssetType>(_admin: &signer) {
        liquidity_auction::withdraw_remaining_reward<AssetType>(_admin);
    }

    public entry fun withdraw_lp<AssetType>(_user: &signer, _lp_withdraw_amount: u64) {
        liquidity_auction::withdraw_lp<AssetType>(_user, _lp_withdraw_amount);
    }

    public entry fun claim_mkl_reward<AssetType>(_user: &signer) {
        liquidity_auction::claim_mkl_reward<AssetType>(_user);
    }

    #[view]
    public fun get_lba_schedule(): (u64, u64, u64) {
        liquidity_auction::get_lba_schedule()
    }

    #[view]
    public fun get_claimable_mkl_reward<AssetType>(_user: address): u64 {
        liquidity_auction::get_claimable_mkl_reward<AssetType>(_user)
    }
}