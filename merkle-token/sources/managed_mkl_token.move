module merkle::managed_mkl_token {
    use aptos_framework::fungible_asset::{Self, FungibleStore};
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use merkle::mkl_token::{Self, COMMUNITY_POOL, GROWTH_POOL, CORE_TEAM_POOL, INVESTOR_POOL, ADVISOR_POOL};

    public entry fun initialize_module(_admin: &signer) {
        mkl_token::initialize_module(_admin);
    }

    public entry fun run_token_generation_event(_admin: &signer) {
        mkl_token::run_token_generation_event(_admin);
    }

    #[view]
    public fun get_circulating_supply(): u64 {
        mkl_token::get_unlock_amount<COMMUNITY_POOL>() +
            mkl_token::get_unlock_amount<GROWTH_POOL>() +
            mkl_token::get_unlock_amount<CORE_TEAM_POOL>() +
            mkl_token::get_unlock_amount<INVESTOR_POOL>() +
            mkl_token::get_unlock_amount<ADVISOR_POOL>()
    }

    #[view]
    public fun mkl_user_balance(_host_address: address): u64 {
        primary_fungible_store::balance(_host_address, mkl_token::get_metadata())
    }

    #[view]
    public fun mkl_object_balance(_object_address: address): u64 {
        fungible_asset::balance(object::address_to_object<FungibleStore>(_object_address))
    }
}