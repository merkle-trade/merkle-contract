module merkle::managed_vesting {
    use merkle::vesting;

    public entry fun initialize_module(_admin: &signer) {
        vesting::initialize_module(_admin);
    }
}