module merkle::managed_season {
    use merkle::season;

    public entry fun initialize_module(_admin: &signer) {
        season::initialize_module(_admin);
    }

    public entry fun add_new_season(_admin: &signer, _end_sec: u64) {
        season::add_new_season(_admin, _end_sec);
    }

    public entry fun set_season_end_sec(_admin: &signer, _season_number: u64, _end_sec: u64) {
        season::set_season_end_sec(_admin, _season_number, _end_sec);
    }

    #[view]
    public fun current_season_number(): u64 {
        season::get_current_season_number()
    }

    #[view]
    public fun get_current_season_info(): season::SeasonView {
        season::get_current_season_info()
    }

    #[view]
    public fun get_season_info(_season_number: u64): season::SeasonView {
        season::get_season_info(_season_number)
    }
}