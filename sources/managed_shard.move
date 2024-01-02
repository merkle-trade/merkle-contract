module merkle::managed_shard {
    use merkle::shard_token;

    public entry fun initialize_module(_admin: &signer) {
        shard_token::initialize_module(_admin);
    }


    #[view]
    public fun get_shard_balance(_user: address): u64 {
        shard_token::get_shard_balance(_user)
    }
}