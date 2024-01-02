module merkle::managed_gear {

    use merkle::gear;
    use merkle::gear_factory;

    public entry fun initialize_module(_admin: &signer) {
        gear::initialize_module(_admin);
        gear_factory::initialize_module(_admin);
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