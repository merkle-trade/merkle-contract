module merkle::managed_pMKL {
    use merkle::pMKL;

    public entry fun initialize_module(_admin: &signer) {
        pMKL::initialize_module(_admin);
    }

    #[view]
    public fun get_season_user_pmkl(_user: address, _season: u64): pMKL::SeasonUserPMKLInfoView {
        pMKL::get_season_user_pmkl(_user, _season)
    }

    #[view]
    public fun get_current_season_info(): pMKL::SeasonPMKLSupplyView {
        pMKL::get_current_season_info()
    }
}