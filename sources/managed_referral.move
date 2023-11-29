module merkle::managed_referral {
    use std::vector;
    use std::signer::address_of;
    use merkle::referral::{Self, AdminCapability};
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    struct AdminCapabilityStore has key, drop {
        admin_cap: AdminCapability,
    }

    struct AdminCapabilityCandidate has key, copy, drop {
        admin_cap_candidate: vector<address>,
        admin_caps: vector<AdminCapability>,
    }

    /// Register the AdminCapability to be claimed by other addresses.
    /// Only allowed for admin.
    public entry fun set_address_admin_candidate(
        _admin: &signer,
        candidate: address
    ) acquires AdminCapabilityCandidate {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<AdminCapabilityStore>(address_of(_admin))) {
            move_to(_admin, AdminCapabilityStore{
                admin_cap: referral::generate_admin_cap(_admin)
            });
        };
        let admin_cap = referral::generate_admin_cap(_admin);

        if (!exists<AdminCapabilityCandidate>(address_of(_admin))) {
            move_to(_admin, AdminCapabilityCandidate {
                admin_cap_candidate: vector::empty(),
                admin_caps: vector::empty()
            });
        };
        let candidates = borrow_global_mut<AdminCapabilityCandidate>(address_of(_admin));
        vector::push_back(&mut candidates.admin_cap_candidate, candidate);
        vector::push_back(&mut candidates.admin_caps, admin_cap);
    }

    /// Allows an admin candidate to claim AdminCapability.
    /// Only allowed for admin candidate.
    public entry fun claim_admin_cap(
        _host: &signer,
    ) acquires AdminCapabilityCandidate {
        let candidate = borrow_global_mut<AdminCapabilityCandidate>(@merkle);
        let (exist, idx) = vector::index_of(&candidate.admin_cap_candidate, &address_of(_host));
        if (exist) {
            vector::remove(&mut candidate.admin_cap_candidate, idx);
            let store = vector::pop_back(&mut candidate.admin_caps);
            if (!exists<AdminCapabilityStore>(address_of(_host))) {
                move_to(_host, AdminCapabilityStore {
                    admin_cap: store
                })
            };
        };
    }

    /// Burn AdminCapability
    /// Only allowed for executor candidate.
    public entry fun burn_admin_cap(
        _host: &signer,
        target_address: address
    ) acquires AdminCapabilityStore {
        // If target_address is @merkle, the modules may no longer be available
        // Admin can remove its own AdminCapability, or admin can remove admin's AdminCapabilityStore.
        assert!(target_address != @merkle &&
            (target_address == address_of(_host) || address_of(_host) == @merkle), E_NOT_AUTHORIZED);
        move_from<AdminCapabilityStore>(target_address);
    }

    public entry fun initialize<AssetT>(_admin: &signer) {
        referral::initialize<AssetT>(_admin);
    }

    public entry fun claim_all<AssetT>(_user: &signer) {
        referral::claim_all<AssetT>(_user);
    }

    public entry fun set_epoch_period_sec(_admin: &signer, _value: u64) {
        referral::set_epoch_period_sec(_admin, _value);
    }

    public entry fun set_expire_period_sec(_admin: &signer, _value: u64) {
        referral::set_expire_period_sec(_admin, _value);
    }

    public entry fun set_user_hold_rebate<AssetT>(_admin: &signer, _user: address, _value: bool) {
        referral::set_user_hold_rebate<AssetT>(_admin, _user, _value);
    }

    public entry fun set_user_rebate_rate<AssetT>(_admin: &signer, _user: address, _value: u64) {
        referral::set_user_rebate_rate<AssetT>(_admin, _user, _value);
    }

    public entry fun set_user_rebate_rate_admin_cap<AssetT>(_admin: &signer, _user: address, _value: u64)
    acquires AdminCapabilityStore {
        let admin_cap_store = borrow_global<AdminCapabilityStore>(address_of(_admin));
        referral::set_user_rebate_rate_admin_cap<AssetT>(&admin_cap_store.admin_cap, _user, _value);
    }

    #[view]
    public fun get_epoch_info(): (u64, u64, u64) {
        referral::get_epoch_info()
    }
}