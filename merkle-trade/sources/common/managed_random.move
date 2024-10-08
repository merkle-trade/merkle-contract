module merkle::managed_random {
    use merkle::random;

    public entry fun initialize_module(_admin: &signer) {
        random::initialize_module(_admin);
    }
}