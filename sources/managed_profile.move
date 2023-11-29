module merkle::managed_profile {
    use merkle::profile;

    public entry fun add_new_class(_admin: &signer, _required_level: u64, _required_xp: u64) {
        profile::add_new_class(_admin, _required_level, _required_xp);
    }

    public entry fun update_class(_admin: &signer, _class: u64, _required_level: u64, _required_xp: u64) {
        profile::update_class(_admin, _class, _required_level, _required_xp);
    }

    public entry fun boost_event_initialized(_admin: &signer) {
        profile::boost_event_initialized(_admin);
    }

    #[view]
    public fun get_user_profile(_user_address: address): (u64, u64, u64, u64, u64) {
        // (xp, level, class, required_xp, boost)
        let (xp, level, class, required_xp) = profile::get_level_info(_user_address);
        let boost = profile::get_boost(_user_address);
        (xp, level, class, required_xp, boost)
    }
}