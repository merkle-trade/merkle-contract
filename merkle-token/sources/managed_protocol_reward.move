module merkle::managed_protocol_reward {
    use merkle::protocol_reward;

    public entry fun initialize_module<AssetType>(_admin: &signer) {
        protocol_reward::initialize_module<AssetType>(_admin);
    }

    public entry fun claim_rewards<AssetType>(_user: &signer, _epoch_start_at: u64) {
        protocol_reward::claim_rewards<AssetType>(_user, _epoch_start_at);
    }

    public entry fun register_vemkl_protocol_rewards<AssetType>(_admin: &signer, _epoch_start_at: u64, _amount: u64) {
        protocol_reward::register_vemkl_protocol_rewards<AssetType>(_admin, _epoch_start_at, _amount);
    }

    #[view]
    public fun user_reward_amount<AssetType>(_user_address: address, _epoch_start_at: u64): u64 {
        protocol_reward::user_reward_amount<AssetType>(_user_address, _epoch_start_at)
    }
}