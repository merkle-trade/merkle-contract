module merkle::managed_profile {
    use merkle::profile;

    public entry fun initialize_module(_admin: &signer) {
        profile::initialize_module(_admin);
    }

    public entry fun add_new_class(_admin: &signer, _required_level: u64, _required_xp: u64) {
        profile::add_new_class(_admin, _required_level, _required_xp);
    }

    public entry fun update_class(_admin: &signer, _class: u64, _required_level: u64, _required_xp: u64) {
        profile::update_class(_admin, _class, _required_level, _required_xp);
    }

    public entry fun apply_soft_reset_level(_admin: &signer, users: vector<address>, rewards: vector<vector<u64>>) {
        profile::apply_soft_reset_level(_admin, users, rewards);
    }

    public entry fun set_user_soft_reset_level(_admin: &signer, _user: address, _value: u64) {
        profile::set_user_soft_reset_level(_admin, _user, _value);
    }

    public entry fun boost_event_initialized(_admin: &signer) {
        profile::boost_event_initialized(_admin);
    }

    public entry fun set_soft_reset_rate(_admin: &signer, _set_soft_reset_rate: u64) {
        profile::set_soft_reset_rate(_admin, _set_soft_reset_rate);
    }

    #[view]
    public fun get_user_profile(_user_address: address): (u64, u64, u64, u64, u64) {
        // (xp, level, class, required_xp, boost)
        let (xp, level, class, required_xp) = profile::get_level_info(_user_address);
        let boost = profile::get_boost(_user_address);
        (xp, level, class, required_xp, boost)
    }
}