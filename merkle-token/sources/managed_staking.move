module merkle::managed_staking {
    use std::signer::address_of;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use merkle::coin_utils;
    use merkle::esmkl_token;
    use merkle::mkl_token;
    use merkle::pre_mkl_token;
    use merkle::staking;

    public entry fun initialize_module(_admin: &signer) {
        staking::initialize_module(_admin);
    }

    public entry fun lock_mkl(_user: &signer, _amount: u64, _unlock_time: u64) {
        let now = timestamp::now_seconds();
        if (now >= mkl_token::mkl_tge_at()) {
            // mkl
            if (primary_fungible_store::balance(address_of(_user), pre_mkl_token::get_metadata()) > 0) {
                // swap all pre_mkl to mkl
                let swapped_mkl = pre_mkl_token::swap_pre_mkl_to_mkl(_user);
                primary_fungible_store::deposit(address_of(_user), swapped_mkl);
            };
            coin_utils::convert_all_coin_to_fungible_asset<mkl_token::MKL>(_user);
            let fa = primary_fungible_store::withdraw(_user, mkl_token::get_metadata(), _amount);
            staking::lock(_user, fa, _unlock_time);
        } else {
            // premkl
            let fa = pre_mkl_token::withdraw_from_user(address_of(_user), _amount);
            staking::lock(_user, fa, _unlock_time);
        };
    }

    public entry fun lock_esmkl(_user: &signer, _amount: u64, _unlock_time: u64) {
        let fa = esmkl_token::withdraw_user_esmkl(_user, _amount);
        staking::lock(_user, fa, _unlock_time);
    }

    public entry fun unlock(_user: &signer, _vemkl_address: address) {
        staking::unlock(_user, _vemkl_address);
    }

    public entry fun increase_lock_mkl(_user: &signer, _vemkl_address: address, _amount: u64, _unlock_at: u64) {
        let now = timestamp::now_seconds();
        if (now >= mkl_token::mkl_tge_at()) {
            if (primary_fungible_store::balance(address_of(_user), pre_mkl_token::get_metadata()) > 0) {
                // swap all pre_mkl to mkl
                let swapped_mkl = pre_mkl_token::swap_pre_mkl_to_mkl(_user);
                primary_fungible_store::deposit(address_of(_user), swapped_mkl);
            };

            // mkl
            let fa = if (_amount > 0) {
                coin_utils::convert_all_coin_to_fungible_asset<mkl_token::MKL>(_user);
                primary_fungible_store::withdraw(_user, mkl_token::get_metadata(), _amount)
            } else {
                fungible_asset::zero(mkl_token::get_metadata())
            };
            staking::increase_lock(_user, _vemkl_address, fa, _unlock_at);
        } else {
            // premkl
            let fa = pre_mkl_token::withdraw_from_user(address_of(_user), _amount);
            staking::increase_lock(_user, _vemkl_address, fa, _unlock_at);
        };
    }

    public entry fun increase_lock_esmkl(_user: &signer, _vemkl_address: address, _amount: u64, _unlock_at: u64) {
        let fa = if (_amount > 0) {
            esmkl_token::withdraw_user_esmkl(_user, _amount)
        } else {
            fungible_asset::zero(esmkl_token::get_metadata())
        };
        staking::increase_lock(_user, _vemkl_address, fa, _unlock_at);
    }

    public entry fun set_max_lock_duration(_admin: &signer, _duration: u64) {
        staking::set_max_lock_duration(_admin, _duration);
    }

    public entry fun set_min_lock_duration(_admin: &signer, _duration: u64) {
        staking::set_min_lock_duration(_admin, _duration);
    }

    public entry fun set_epoch_duration(_admin: &signer, _duration: u64) {
        staking::set_epoch_duration(_admin, _duration);
    }
}