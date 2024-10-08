module merkle::managed_pMKL {
    use merkle::pMKL;

    public entry fun initialize_module(_admin: &signer) {
        pMKL::initialize_module(_admin);
    }

    public entry fun set_season_reward(_admin: &signer, _season_number: u64, _reward_amount: u64) {
        pMKL::set_season_reward(_admin, _season_number, _reward_amount);
    }

    public entry fun claim_season_esmkl(_user: &signer, _season_number: u64) {
        pMKL::claim_season_esmkl(_user, _season_number);
    }

    #[view]
    public fun get_season_user_pmkl(_user: address, _season_number: u64): pMKL::SeasonUserPMKLInfoView {
        pMKL::get_season_user_pmkl(_user, _season_number)
    }

    #[view]
    public fun get_current_season_info(): pMKL::SeasonPMKLSupplyView {
        pMKL::get_current_season_info()
    }

    #[view]
    public fun get_season_info(_season_number: u64): pMKL::SeasonPMKLSupplyView {
        pMKL::get_season_info(_season_number)
    }

    #[view]
    public fun get_user_season_claimable(_user_address: address, _season_number: u64): u64 {
        pMKL::get_user_season_claimable(_user_address, _season_number)
    }
}