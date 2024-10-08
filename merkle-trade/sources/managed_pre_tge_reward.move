module merkle::managed_pre_tge_reward {
    use merkle::pre_tge_reward;

    public entry fun initialize_module(_admin: &signer) {
        pre_tge_reward::initialize_module(_admin);
    }

    public entry fun claim_point_reward(_user: &signer) {
        pre_tge_reward::claim_point_reward(_user);
    }

    public entry fun claim_lp_reward(_user: &signer) {
        pre_tge_reward::claim_lp_reward(_user);
    }

    public entry fun set_point_reward(_admin: &signer, _user_address: address, _reward: u64) {
        pre_tge_reward::set_point_reward(_admin, _user_address, _reward);
    }

    public entry fun set_bulk_point_reward(_admin: &signer, _user_address: vector<address>, _reward: vector<u64>) {
        pre_tge_reward::set_bulk_point_reward(_admin, _user_address, _reward);
    }

    public entry fun set_lp_reward(_admin: &signer, _user_address: address, _reward: u64) {
        pre_tge_reward::set_lp_reward(_admin, _user_address, _reward);
    }
}