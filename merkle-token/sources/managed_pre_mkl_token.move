module merkle::managed_pre_mkl_token {
    use std::signer::address_of;
    use std::vector::for_each;
    use aptos_framework::primary_fungible_store;
    use merkle::staking;
    use merkle::pre_mkl_token;

    public entry fun initialize_module(_admin: &signer) {
        pre_mkl_token::initialize_module(_admin);
    }

    public entry fun run_token_generation_event(_admin: &signer) {
        pre_mkl_token::run_token_generation_event(_admin);
    }

    public entry fun deploy_pre_mkl_from_growth_fund(_admin: &signer, _user_address: address, _amount: u64) {
        pre_mkl_token::deploy_pre_mkl_from_growth_fund(_admin, _user_address, _amount);
    }

    public entry fun swap_pre_mkl_to_mkl(_user: &signer) {
        let fa = pre_mkl_token::swap_pre_mkl_to_mkl(_user);
        primary_fungible_store::deposit(address_of(_user), fa);
    }

    public entry fun user_sawp_user_pre_mkl_to_mkl(_user: &signer) {
        pre_mkl_token::user_swap_premkl_to_mkl(_user);
        staking::user_swap_vemkl_premkl_to_mkl(_user);
    }

    public entry fun admin_sawp_user_pre_mkl_to_mkl(_admin: &signer, _user_addresses: vector<address>) {
        for_each(_user_addresses, |user_address| {
            pre_mkl_token::admin_swap_premkl_to_mkl(_admin, user_address);
            staking::admin_swap_vemkl_premkl_to_mkl(_admin, user_address);
        });
    }
}