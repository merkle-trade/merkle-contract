module merkle::managed_lootbox_v2 {
    use std::vector;
    use std::signer::address_of;
    use merkle::referral;
    use merkle::lootbox_v2::{Self, AdminCapability};

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
                admin_cap: lootbox_v2::generate_admin_cap(_admin)
            });
        };
        let admin_cap = lootbox_v2::generate_admin_cap(_admin);

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

    public entry fun initialize_module(_admin: &signer) {
        lootbox_v2::initialize_module(_admin);
    }

    entry fun open_lootbox(_user: &signer, _tier: u64, _season: u64) {
        lootbox_v2::open_lootbox_rand(_user, _tier, _season);
    }

    entry fun open_ftu_lootbox_with_referrer<CollateralType>(_user: &signer, _referrer: address) {
        referral::register_referrer<CollateralType>(address_of(_user), _referrer);
        let referrer = referral::get_referrer_address<CollateralType>(address_of(_user));
        lootbox_v2::open_ftu_lootbox(_user, referrer);
    }

    public entry fun mint_mission_lootboxes_admin(_admin: &signer, _user_addr: address, _lootbox: u64, _amount: u64)
    acquires AdminCapabilityStore {
        let admin_cap_store = borrow_global<AdminCapabilityStore>(address_of(_admin));
        lootbox_v2::mint_mission_lootboxes_admin(&admin_cap_store.admin_cap, _user_addr, _lootbox, _amount);
    }

    #[view]
    public fun get_user_lootboxes(_user_address: address, _season: u64): vector<u64> {
        // (bronze, silver, gold, platinum, diamond)
        lootbox_v2::get_user_lootboxes(_user_address, _season)
    }

    #[view]
    public fun get_user_all_lootboxes(_user_address: address): vector<lootbox_v2::LootBoxEvent> {
        lootbox_v2::get_user_all_lootboxes(_user_address)
    }
}