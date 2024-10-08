module merkle::managed_gear {

    use std::signer::address_of;
    use std::vector;
    use merkle::gear;
    use merkle::gear_factory;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    struct AdminCapabilityCandidate has key {
        candidates: vector<address>,
        admin_capabilities: vector<gear::AdminCapability>
    }

    struct AdminCapabilityStore has key {
        admin_cap: gear::AdminCapability
    }

    public entry fun initialize_module(_admin: &signer) {
        gear::initialize_module(_admin);
        gear_factory::initialize_module(_admin);
    }

    public entry fun initialize_module_v2(_admin: &signer) {
        gear::initialize_module_v2(_admin);
        if (!exists<AdminCapabilityCandidate>(address_of(_admin))) {
            move_to(_admin, AdminCapabilityCandidate {
                candidates: vector::empty<address>(),
                admin_capabilities: vector::empty<gear::AdminCapability>()
            })
        };
    }

    public entry fun register_gear(
        _admin: &signer,
        _tier: u64,
        _name: vector<u8>,
        _uri: vector<u8>,
        _gear_type: u64,
        _gear_code: u64,
        _min_primary_effect: u64,
        _max_primary_effect: u64,
    ) {
        gear_factory::register_gear(
            _admin,
            _tier,
            _name,
            _uri,
            _gear_type,
            _gear_code,
            _min_primary_effect,
            _max_primary_effect,
        );
    }

    public entry fun register_affix(
        _admin: &signer,
        _tier: u64,
        _gear_type: u64,
        _gear_code: u64,
        _affix_type: u64,
        _affix_code: u64,
        _min_affix_effect: u64,
        _max_affix_effect: u64,
    ) {
        gear_factory::register_affix(
            _admin,
            _tier,
            _gear_type,
            _gear_code,
            _affix_type,
            _affix_code,
            _min_affix_effect,
            _max_affix_effect,
        );
    }

    public entry fun gear_equip(_user: &signer, _gear_address: address) {
        gear::equip(_user, _gear_address);
    }

    public entry fun gear_unequip(_user: &signer, _gear_address: address) {
        gear::unequip(_user, _gear_address);
    }

    entry fun salvage(_user: &signer, _gear_address: address) {
        gear::salvage_rand(_user, _gear_address);
    }

    public entry fun repair(_user: &signer, _gear_address: address, _target_durability: u64) {
        gear::repair(_user, _gear_address, _target_durability);
    }

    entry fun forge(_user: &signer, _gear1_address: address, _gear2_address: address) {
        gear::forge_rand(_user, _gear1_address, _gear2_address);
    }

    entry fun mint_event_with_admin_cap_rand(_admin: &signer, _user_address: address, _tier: u64, _gear_type: u64, _gear_code: u64)
    acquires AdminCapabilityStore {
        let admin_capability_store = borrow_global<AdminCapabilityStore>(address_of(_admin));
        gear::mint_event_rand(&admin_capability_store.admin_cap, _user_address, _tier, _gear_type, _gear_code);
    }

    public entry fun register_admin_capabilty_candidate(_host: &signer, _addr: address) acquires AdminCapabilityCandidate {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);

        let admin_capability_candidates = borrow_global_mut<AdminCapabilityCandidate>(@merkle);
        vector::push_back(&mut admin_capability_candidates.candidates, _addr);
        vector::push_back(&mut admin_capability_candidates.admin_capabilities, gear::generate_admin_cap(_host));
    }

    public entry fun claim_admin_capability(_user: &signer) acquires AdminCapabilityCandidate {
        let user_address = address_of(_user);
        let admin_capability_candidates = borrow_global_mut<AdminCapabilityCandidate>(@merkle);
        let (exist, idx) = vector::index_of(&admin_capability_candidates.candidates, &user_address);
        assert!(exist, E_NOT_AUTHORIZED);
        vector::remove(&mut admin_capability_candidates.candidates, idx);
        move_to(_user, AdminCapabilityStore {
            admin_cap: vector::pop_back(&mut admin_capability_candidates.admin_capabilities)
        });
    }

    #[view]
    public fun get_gear_detail(_gear_address: address): gear::GearDetail {
        gear::get_gear_detail(_gear_address)
    }

    #[view]
    public fun get_equipped_gears(_user: address): vector<gear::EquippedGearView> {
        gear::get_equipped_gears(_user)
    }

    #[view]
    public fun get_salvage_shard_range(_gear_address: address): (u64, u64) {
        gear::get_salvage_shard_range(_gear_address)
    }

    #[view]
    public fun get_repair_shards(_gear_address: address, _target_durability: u64): u64 {
        gear::get_repair_shards(_gear_address, _target_durability)
    }
}