module merkle::managed_custom_vesting {
    use merkle::custom_vesting;

    public entry fun create_custom_vesting<PoolType>(
        _admin: &signer,
        _user_address: address,
        _start_at_sec: u64,
        _end_at_sec: u64,
        _initial_amount: u64,
        _total_amount: u64
    ) {
        custom_vesting::create_custom_vesting<PoolType>(
            _admin,
            _user_address,
            _start_at_sec,
            _end_at_sec,
            _initial_amount,
            _total_amount
        );
    }

    public entry fun claim(_user: &signer, _object_address: address) {
        custom_vesting::claim(_user, _object_address);
    }

    public entry fun pause(_admin: &signer, _object_address: address) {
        custom_vesting::pause(_admin, _object_address);
    }

    public entry fun unpause(_admin: &signer, _object_address: address) {
        custom_vesting::unpause(_admin, _object_address);
    }

    public entry fun cancel(_admin: &signer, _object_address: address) {
        custom_vesting::cancel(_admin, _object_address);
    }
}