module merkle::capability {

    use std::signer::address_of;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::aptos_account;
    use merkle::managed_trading;
    use merkle::trading;
    use merkle::price_oracle;

    struct CapabilityProviderCandidate has key {
        candidates: vector<address>,
        trading_capability_providers: vector<trading::CapabilityProvider>,
        price_oracle_capability_providers: vector<price_oracle::CapabilityProvider>,
    }

    struct CapabilityProviderStore has key {
        trading_capability_provider: trading::CapabilityProvider,
        price_oracle_capability_provider: price_oracle::CapabilityProvider,
    }

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    public fun initialize_module(_host: &signer) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<CapabilityProviderCandidate>(address_of(_host))) {
            move_to(_host, CapabilityProviderCandidate {
                candidates: vector::empty<address>(),
                trading_capability_providers: vector::empty<trading::CapabilityProvider>(),
                price_oracle_capability_providers: vector::empty<price_oracle::CapabilityProvider>(),
            });
        };
    }

    public fun register_capability_provider_candidate(_host: &signer, _addr: address) acquires CapabilityProviderCandidate {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        let capability_provider_candidate = borrow_global_mut<CapabilityProviderCandidate>(address_of(_host));
        if (exists<CapabilityProviderStore>(_addr)) {
            return
        };
        if (!vector::contains(&capability_provider_candidate.candidates, &_addr)) {
            vector::push_back(
                &mut capability_provider_candidate.candidates,
                _addr
            );
            vector::push_back(
                &mut capability_provider_candidate.trading_capability_providers,
                trading::generate_capability_provider(_host)
            );
            vector::push_back(
                &mut capability_provider_candidate.price_oracle_capability_providers,
                price_oracle::generate_capability_provider(_host)
            );
        };
    }

    public fun claim_capability_provider(_user: &signer) acquires CapabilityProviderCandidate {
        let user_address = address_of(_user);
        if (exists<CapabilityProviderStore>(user_address)) {
            return
        };
        let capability_provider_candidate = borrow_global_mut<CapabilityProviderCandidate>(@merkle);
        let (exist, idx) = vector::index_of(&capability_provider_candidate.candidates, &user_address);
        assert!(exist, E_NOT_AUTHORIZED);
        vector::remove(&mut capability_provider_candidate.candidates, idx);
        move_to(_user, CapabilityProviderStore {
            trading_capability_provider: vector::pop_back(&mut capability_provider_candidate.trading_capability_providers),
            price_oracle_capability_provider: vector::pop_back(&mut capability_provider_candidate.price_oracle_capability_providers)
        });
    }

    public fun set_addresses_executor_candidate<CollateralType>(_host: &signer, candidates: vector<address>) acquires CapabilityProviderStore {
        assert!(exists<CapabilityProviderStore>(address_of(_host)), E_NOT_AUTHORIZED);
        let cap_store = borrow_global<CapabilityProviderStore>(address_of(_host));
        vector::for_each(candidates, |candidate| {
            if (!account::exists_at(candidate)) {
                aptos_account::create_account(candidate);
            };
            managed_trading::set_address_executor_candidate_v2<CollateralType>(_host, candidate, &cap_store.trading_capability_provider);
            price_oracle::register_allowed_update_v2(_host, candidate, &cap_store.price_oracle_capability_provider);
        });
    }

    public fun claim_executor_cap<CollateralType>(_host: &signer) {
        managed_trading::claim_executor_cap_v2<CollateralType>(_host);
        price_oracle::claim_allowed_update(_host);
    }
}