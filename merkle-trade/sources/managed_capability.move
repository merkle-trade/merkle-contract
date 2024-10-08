module merkle::managed_capability {
    use merkle::capability;

    public entry fun initialize_module(_host: &signer) {
        capability::initialize_module(_host);
    }

    public entry fun register_capability_provider_candidate(_host: &signer, _addr: address) {
        capability::register_capability_provider_candidate(_host, _addr);
    }

    public entry fun claim_capability_provider(_user: &signer) {
        capability::claim_capability_provider(_user);
    }

    public entry fun set_addresses_executor_candidate<CollateralType>(_host: &signer, candidates: vector<address>) {
        capability::set_addresses_executor_candidate<CollateralType>(_host, candidates);
    }

    public entry fun claim_executor_cap<CollateralType>(_host: &signer) {
        capability::claim_executor_cap<CollateralType>(_host);
    }
}