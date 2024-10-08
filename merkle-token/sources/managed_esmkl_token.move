module merkle::managed_esmkl_token {
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset::{Self, FungibleStore};

    use merkle::esmkl_token;

    public entry fun initialize_module(_admin: &signer) {
        esmkl_token::initialize_module(_admin);
    }

    public entry fun restore_cfa_store_admin_cap(_admin: &signer) {
        esmkl_token::restore_cfa_store_admin_cap(_admin);
    }

    public entry fun restore_cfa_store_claim_cap(_admin: &signer, _object_address: address) {
        esmkl_token::restore_cfa_store_claim_cap(_admin, _object_address);
    }

    public entry fun vest(_user: &signer, _amount: u64) {
        esmkl_token::vest(_user, _amount);
    }

    public entry fun claim(_user: &signer, _object_address: address) {
        esmkl_token::claim(_user, _object_address);
    }

    public entry fun cancel(_user: &signer, _object_address: address) {
        esmkl_token::cancel(_user, _object_address);
    }

    #[view]
    public fun esmkl_user_balance(_host_address: address): u64 {
        primary_fungible_store::balance(_host_address, esmkl_token::get_metadata())
    }

    #[view]
    public fun esmkl_object_balance(_object_address: address): u64 {
        fungible_asset::balance(object::address_to_object<FungibleStore>(_object_address))
    }
}