module merkle::gear {

    use std::bcs;
    use std::option;
    use std::signer::address_of;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::simple_map;
    use aptos_std::table;
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use aptos_token_objects::property_map;
    use aptos_framework::object::{Self, TransferRef, DeleteRef};
    use aptos_framework::account::{Self, SignerCapability, new_event_handle};
    use aptos_framework::timestamp;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_token_objects::royalty;

    use merkle::pair_types;
    use merkle::season;
    use merkle::gear_factory;
    use merkle::random;
    use merkle::gear_calc;
    use merkle::shard_token;
    use merkle::safe_math::{min, safe_mul_div};

    friend merkle::lootbox;
    friend merkle::lootbox_v2;
    friend merkle::managed_gear;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When the owner of the gear is different
    const E_GEAR_OWNER_UNMATCHED: u64 = 2;
    /// When not equipped gear
    const E_GEAR_NOT_EQUIPPED: u64 = 3;
    /// When a Gear lacks durability
    const E_GEAR_DURABILITY_NOT_ENOUGH: u64 = 4;
    /// When an invalid repair target durability comes in
    const E_INVALID_TARGET_DURABILITY: u64 = 5;
    /// When salvage is unavailable because gear is equipped
    const E_SALVAGE_UNAVAILABLE_GEAR_EQUIPPED: u64 = 6;
    /// When gear already equipped
    const E_GEAR_ALREADY_EQUIPPED: u64 = 7;
    /// When gear durability is not 100%
    const E_FORGE_GEAR_DURABILITY_NOT_100: u64 = 8;
    /// When tier is not same
    const E_FORGE_GEAR_TIER_NOT_MATCHED: u64 = 9;
    /// When forge is unavailable because gear is equipped
    const E_FORGE_UNAVAILABLE_GEAR_EQUIPPED: u64 = 10;
    /// When forge target gear is same
    const E_FORGE_SAME_GEAR: u64 = 11;
    /// When gear already expired
    const E_GEAR_ALREADY_EXPIRED: u64 = 12;
    /// When mint failed with invalid parameters
    const E_GEAR_MINT_FAILED: u64 = 13;

    const COLLECTION_NAME: vector<u8> = b"Merkle Gear";
    const PROPERTY_UID: vector<u8> = b"uid";
    const PROPERTY_GEAR_TYPE: vector<u8> = b"gear_type";  // 0, 1, 2 (A, B, C)
    const PROPERTY_GEAR_CODE: vector<u8> = b"gear_code";  // 100, 200, 300, 400, 401, 500, 501
    const PROPERTY_TIER: vector<u8> = b"tier"; // tier 0 ~ 4
    const PROPERTY_DURABILITY: vector<u8> = b"durability";
    const PROPERTY_PRIMARY_EFFECT: vector<u8> = b"primary_effect";
    const PROPERTY_SEASON: vector<u8> = b"season";
    const PROPERTY_EVENT: vector<u8> = b"event";

    const GEAR_EXPIRY_START: u64 = 9;
    const GEAR_EXPIRY_SEASON_DURATION: u64 = 6;
    const DURABILITY_PRECISION: u64 = 1000000;
    const TYPE_MINING_TOOL: u64 = 0;
    const TYPE_SUIT: u64 = 1;
    const TYPE_HELMET: u64 = 2;

    struct MerkleGearCollection has key {
        property_keys: vector<String>,
        property_types: vector<String>,
        signer_cap: SignerCapability,
        collection_mutator_ref: collection::MutatorRef,
        royalty_mutator_ref: royalty::MutatorRef,
        max_durability_duration_sec: u64,
        uid: u64,
        gears: table::Table<u64, address>, // k = uid, v = gear address,
    }

    struct MerkleGearToken has key {
        delete_ref: DeleteRef,
        mutator_ref: token::MutatorRef,
        burn_ref: token::BurnRef,
        transfer_ref: TransferRef,
        property_mutator_ref: property_map::MutatorRef,
        gear_affixes: vector<GearAffix>
    }

    struct GearAffix has store, copy, drop {
        gear_affix_type: u64, // MA = 0, MB = 1 ..
        gear_affix_code: u64, // 1, 2 ..
        target: string::String,
        effect: u64
    }

    struct UserGear has key {
        equipped: simple_map::SimpleMap<u64, address>, // k: gear_type, v: gear
        equipped_time: simple_map::SimpleMap<u64, u64>, // k: gear_type, v: gear
    }

    struct GearDetail has copy, drop {
        uid: u64,
        gear_address: address,
        name: string::String,
        uri: string::String,
        gear_type: u64,
        gear_code: u64,
        tier: u64,
        durability: u64,
        primary_effect: u64,
        gear_affixes: vector<GearAffix>,
        owner: address,
        soul_bound: bool,
        season: u64
    }

    struct EquippedGearView has copy, drop {
        gear_address: address,
        name: string::String,
        uri: string::String,
        gear_type: u64,
        equipped_time: u64
    }

    // events
    struct GearEvents has key {
        mint_events: EventHandle<MintEvent>,
        salvage_events: EventHandle<SalvageEvent>,
        repair_events: EventHandle<RepairEvent>,
        equip_events: EventHandle<EquipEvent>,
        unequip_events: EventHandle<UnequipEvent>,
        gear_effect_events: EventHandle<GearEffectEvent>
    }

    struct GearEventsV2 has key {
        forge_events: EventHandle<ForgeEvent>
    }

    struct MintEvent has drop, store {
        uid: u64,
        gear_address: address,
        season: u64,
        user: address,
        name: string::String,
        uri: string::String,
        gear_type: u64,
        gear_code: u64,
        tier: u64,
        primary_effect: u64,
        gear_affixes: vector<GearAffix>
    }

    struct EquipEvent has drop, store {
        uid: u64,
        gear_address: address,
        user: address,
        durability: u64
    }

    struct UnequipEvent has drop, store {
        uid: u64,
        gear_address: address,
        user: address,
        durability: u64
    }

    struct SalvageEvent has drop, store {
        uid: u64,
        gear_address: address,
        shard_amount: u64,
        user: address
    }

    struct RepairEvent has drop, store {
        uid: u64,
        gear_address: address,
        shard_amount: u64,
        user: address
    }

    struct GearEffectEvent has drop, store {
        uid: u64,
        gear_address: address,
        pair_type: TypeInfo,
        user: address,
        effect: u64,
        gear_type: u64,
        gear_code: u64
    }

    struct ForgeEvent has drop, store {
        user: address,
        gear1_uid: u64,
        gear1_address: address,
        gear2_uid: u64,
        gear2_address: address,
        required_shard: u64,
        gear_tier: u64,
        result_tier: u64,
    }

    struct AdminCapability has copy, store, drop {}

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if(exists<MerkleGearCollection>(address_of(_admin))) {
            return
        };

        let (resource_signer, resource_signer_cap) = account::create_resource_account(_admin, vector::empty<u8>());
        let collection_constructor_ref = collection::create_unlimited_collection(
            &resource_signer,
            string::utf8(b""),
            string::utf8(COLLECTION_NAME),
            option::none(),
            string::utf8(b""),
        );
        let collection_mutator_ref = collection::generate_mutator_ref(&collection_constructor_ref);
        let extend_ref = object::generate_extend_ref(&collection_constructor_ref);
        let royalty_mutator_ref = royalty::generate_mutator_ref(extend_ref);

        move_to(_admin, MerkleGearCollection {
            property_keys: vector<String>[
                string::utf8(PROPERTY_UID),
                string::utf8(PROPERTY_GEAR_TYPE),
                string::utf8(PROPERTY_GEAR_CODE),
                string::utf8(PROPERTY_TIER),
                string::utf8(PROPERTY_DURABILITY),
                string::utf8(PROPERTY_PRIMARY_EFFECT),
                string::utf8(PROPERTY_SEASON),
            ],
            property_types: vector<String>[
                string::utf8(b"u64"),
                string::utf8(b"u64"),
                string::utf8(b"u64"),
                string::utf8(b"u64"),
                string::utf8(b"u64"),
                string::utf8(b"u64"),
                string::utf8(b"u64"),
            ],
            signer_cap: resource_signer_cap,
            collection_mutator_ref,
            royalty_mutator_ref,
            max_durability_duration_sec: 1814400,
            uid: 0,
            gears: table::new()
        });

        move_to(_admin, GearEvents {
            mint_events: new_event_handle<MintEvent>(_admin),
            salvage_events: new_event_handle<SalvageEvent>(_admin),
            repair_events: new_event_handle<RepairEvent>(_admin),
            equip_events: new_event_handle<EquipEvent>(_admin),
            unequip_events: new_event_handle<UnequipEvent>(_admin),
            gear_effect_events: new_event_handle<GearEffectEvent>(_admin)
        })
    }

    public fun initialize_module_v2(_admin: &signer) {
        if (!exists<GearEventsV2>(address_of(_admin))) {
            move_to(_admin, GearEventsV2 {
                forge_events: new_event_handle<ForgeEvent>(_admin)
            });
        };
    }

    public (friend) fun mint_rand(_user: &signer, _tier: u64) acquires MerkleGearCollection, GearEvents {
        // mint current season gear
        // get gear property
        let (
            name,
            uri,
            gear_type,
            gear_code,
            primary_effect,
            gear_affixes_types,
            gear_affixes_codes,
            gear_affixes_targets,
            gear_affixes_effects
        ) = gear_factory::generate_gear_property_rand(_tier);
        let idx = 0;
        let gear_affixes: vector<GearAffix> = vector[];
        while(idx < vector::length(&gear_affixes_effects)) {
            vector::push_back(&mut gear_affixes, GearAffix {
                gear_affix_type: *vector::borrow(&gear_affixes_types, idx),
                gear_affix_code: *vector::borrow(&gear_affixes_codes, idx),
                target: *vector::borrow(&gear_affixes_targets, idx),
                effect: *vector::borrow(&gear_affixes_effects, idx),
            });
            idx = idx + 1;
        };
        mint_internal(
            address_of(_user),
            _tier,
            name,
            uri,
            gear_type,
            gear_code,
            primary_effect,
            gear_affixes,
            season::get_current_season_number()
        );
    }

    public (friend) fun mint_v2_rand(_user: &signer, _tier: u64, _season: u64) acquires MerkleGearCollection, GearEvents {
        // mint specific season gear for past season lootbox open
        // get gear property
        let (
            name,
            uri,
            gear_type,
            gear_code,
            primary_effect,
            gear_affixes_types,
            gear_affixes_codes,
            gear_affixes_targets,
            gear_affixes_effects
        ) = gear_factory::generate_gear_property_rand(_tier);
        let idx = 0;
        let gear_affixes: vector<GearAffix> = vector[];
        while(idx < vector::length(&gear_affixes_effects)) {
            vector::push_back(&mut gear_affixes, GearAffix {
                gear_affix_type: *vector::borrow(&gear_affixes_types, idx),
                gear_affix_code: *vector::borrow(&gear_affixes_codes, idx),
                target: *vector::borrow(&gear_affixes_targets, idx),
                effect: *vector::borrow(&gear_affixes_effects, idx),
            });
            idx = idx + 1;
        };
        mint_internal(
            address_of(_user),
            _tier,
            name,
            uri,
            gear_type,
            gear_code,
            primary_effect,
            gear_affixes,
            _season
        );
    }

    public (friend) fun mint_basic(_user_address: address, _tier: u64, _gear_type: u64)
    acquires MerkleGearCollection, GearEvents, MerkleGearToken {
        // get gear property
        let (
            name,
            uri,
            gear_type,
            gear_code,
            primary_effect,
            gear_affixes_types,
            gear_affixes_codes,
            gear_affixes_targets,
            gear_affixes_effects
        ) = gear_factory::get_basic_gear_property(_tier, _gear_type);
        let idx = 0;
        let gear_affixes: vector<GearAffix> = vector[];
        while(idx < vector::length(&gear_affixes_effects)) {
            vector::push_back(&mut gear_affixes, GearAffix {
                gear_affix_type: *vector::borrow(&gear_affixes_types, idx),
                gear_affix_code: *vector::borrow(&gear_affixes_codes, idx),
                target: *vector::borrow(&gear_affixes_targets, idx),
                effect: *vector::borrow(&gear_affixes_effects, idx),
            });
            idx = idx + 1;
        };
        let gear_address = mint_internal(
            _user_address,
            _tier,
            name,
            uri,
            gear_type,
            gear_code,
            primary_effect,
            gear_affixes,
            season::get_current_season_number()
        );
        let merkle_gear_token = borrow_global<MerkleGearToken>(gear_address);
        object::disable_ungated_transfer(&merkle_gear_token.transfer_ref); // soul bound
    }

    public (friend) fun mint_event_rand(_admin_cap: &AdminCapability, _user_address: address, _tier: u64, _gear_type: u64, _gear_code: u64)
    acquires MerkleGearCollection, GearEvents, MerkleGearToken {
        assert!(_tier > 0, E_GEAR_MINT_FAILED);
        // event ipfs image link
        let uris = simple_map::new_from(vector[0, 1, 2],
            vector[
                simple_map::new_from(vector[200, 300, 400, 500], vector[b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-a200.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-a300.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-a400.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-a500.png"]),
                simple_map::new_from(vector[200, 300, 400, 500], vector[b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-b200.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-b300.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-b400.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-b500.png"]),
                simple_map::new_from(vector[200, 300, 400, 500], vector[b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-c200.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-c300.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-c400.png", b"ipfs://bafybeigo34rnzwx76yvqoplbdnlawn6y4bhjaj4m7zbyiji3v2snmhqs4y/s13-c500.png"]),
            ]
        );

        // get primary effect
        let (name,
            _,
            gear_type,
            gear_code,
            primary_effect, _, _, _, _) = gear_factory::generate_specific_gear_property_without_affixes_rand(_tier, _gear_type, _gear_code);

        // get affixes
        let (gear_affixes_types,
            gear_affixes_codes,
            gear_affixes_targets,
            gear_affixes_effects) = gear_factory::generate_gear_affix_rand(_tier, gear_type, gear_code, vector[
            string::utf8(b"ETH_USD"), string::utf8(b"ARB_USD"), string::utf8(b"OP_USD"),
        ]);

        // get ipfs uri
        let uri = simple_map::borrow(simple_map::borrow(&uris, &_gear_type), &_gear_code);

        // adjust affixes for event
        let idx = 0;
        let gear_affixes: vector<GearAffix> = vector[];
        while(idx < vector::length(&gear_affixes_effects)) {
            if (idx == vector::length(&gear_affixes_effects) - 1) {
                let lastAffix = GearAffix {
                    gear_affix_type: *vector::borrow(&gear_affixes_types, idx),
                    gear_affix_code: *vector::borrow(&gear_affixes_codes, idx),
                    target: string::utf8(b"ETH_USD"),
                    effect: *vector::borrow(&gear_affixes_effects, idx),
                };
                vector::push_back(&mut gear_affixes, lastAffix);
                lastAffix.target = string::utf8(b"ARB_USD");
                vector::push_back(&mut gear_affixes, lastAffix);
                lastAffix.target = string::utf8(b"OP_USD");
                vector::push_back(&mut gear_affixes, lastAffix);
            } else {
                vector::push_back(&mut gear_affixes, GearAffix {
                    gear_affix_type: *vector::borrow(&gear_affixes_types, idx),
                    gear_affix_code: *vector::borrow(&gear_affixes_codes, idx),
                    target: *vector::borrow(&gear_affixes_targets, idx),
                    effect: *vector::borrow(&gear_affixes_effects, idx),
                });
            };
            idx = idx + 1;
        };

        // mint gear with gear properties
        let gear_address = mint_internal(
            _user_address,
            _tier,
            name,
            string::utf8(*uri),
            gear_type,
            gear_code,
            primary_effect,
            gear_affixes,
            season::get_current_season_number()
        );
        // set soul bound
        let merkle_gear_token = borrow_global<MerkleGearToken>(gear_address);
        object::disable_ungated_transfer(&merkle_gear_token.transfer_ref);

        // add event flag
        property_map::add(
            &merkle_gear_token.property_mutator_ref,
            string::utf8(PROPERTY_EVENT),
            string::utf8(b"0x1::string::String"),
            bcs::to_bytes(&string::utf8(b"ETH"))
        );
    }

    inline fun mint_internal(
        _user_address: address,
        _tier: u64,
        _name: string::String,
        _uri: string::String,
        _gear_type: u64,
        _gear_code: u64,
        _primary_effect: u64,
        _gear_affixes: vector<GearAffix>,
        _season: u64
    ): address acquires MerkleGearCollection, GearEvents {
        let merkle_gear_collection = borrow_global_mut<MerkleGearCollection>(@merkle);
        let creator = account::create_signer_with_capability(&merkle_gear_collection.signer_cap);
        let current_season = season::get_current_season_number();
        let royalty = if(current_season > 6) option::some(royalty::create(4, 100, @merkle)) else option::none();
        let constructor_ref = token::create(
            &creator,
            string::utf8(COLLECTION_NAME),
            string::utf8(b""),
            _name,
            royalty,
            _uri,
        );

        let object_signer = object::generate_signer(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);
        let mutator_ref = token::generate_mutator_ref(&constructor_ref);
        let burn_ref = token::generate_burn_ref(&constructor_ref);
        let property_mutator_ref = property_map::generate_mutator_ref(&constructor_ref);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&transfer_ref);
        object::transfer_with_ref(linear_transfer_ref, _user_address);

        let properties = property_map::prepare_input(
            merkle_gear_collection.property_keys,
            merkle_gear_collection.property_types,
            vector[
                bcs::to_bytes<u64>(&merkle_gear_collection.uid), // uid
                bcs::to_bytes<u64>(&_gear_type), // type
                bcs::to_bytes<u64>(&_gear_code), // code
                bcs::to_bytes<u64>(&_tier), // tier
                bcs::to_bytes<u64>(&(100 * DURABILITY_PRECISION)), // durability
                bcs::to_bytes<u64>(&_primary_effect), // primary_effect
                bcs::to_bytes<u64>(&_season) // season
            ]
        );
        property_map::init(&constructor_ref, properties);
        let merkle_gear_token = MerkleGearToken {
            delete_ref,
            transfer_ref,
            mutator_ref,
            burn_ref,
            property_mutator_ref,
            gear_affixes: _gear_affixes
        };
        move_to(&object_signer, merkle_gear_token);
        table::add(&mut merkle_gear_collection.gears, merkle_gear_collection.uid, address_of(&object_signer));

        event::emit_event(&mut borrow_global_mut<GearEvents>(@merkle).mint_events, MintEvent {
            uid: merkle_gear_collection.uid,
            gear_address: address_of(&object_signer),
            season: _season,
            user: _user_address,
            name: _name,
            uri: _uri,
            gear_type: _gear_type,
            gear_code: _gear_code,
            tier: _tier,
            primary_effect: _primary_effect,
            gear_affixes: _gear_affixes,
        });
        merkle_gear_collection.uid = merkle_gear_collection.uid + 1;
        address_of(&object_signer)
    }

    public fun equip(_user: &signer, _gear_address: address) acquires UserGear, MerkleGearToken, MerkleGearCollection, GearEvents {
        let merkle_gear_collection = borrow_global_mut<MerkleGearCollection>(@merkle);
        if (!exists<UserGear>(address_of(_user))) {
            move_to(_user, UserGear {
                equipped: simple_map::create(),
                equipped_time: simple_map::create(),
            })
        };
        let user_gear = borrow_global_mut<UserGear>(address_of(_user));
        let gear_detail = get_gear_detail(_gear_address);
        let current_season = season::get_current_season_number();
        assert!(gear_detail.owner == address_of(_user), E_GEAR_OWNER_UNMATCHED);
        assert!(gear_detail.durability > 0, E_GEAR_DURABILITY_NOT_ENOUGH);
        assert!(
            current_season < GEAR_EXPIRY_START || current_season - gear_detail.season < GEAR_EXPIRY_SEASON_DURATION,
            E_GEAR_ALREADY_EXPIRED
        ); // Users can use their gear until season 8, even if it has expired

        let merkle_gear_token = borrow_global<MerkleGearToken>(_gear_address);
        if (simple_map::contains_key(&user_gear.equipped, &gear_detail.gear_type)) {
            assert!(*simple_map::borrow(&user_gear.equipped, &gear_detail.gear_type) != _gear_address, E_GEAR_ALREADY_EQUIPPED);
            unequip_internal(
                &mut user_gear.equipped,
                &mut user_gear.equipped_time,
                gear_detail,
                merkle_gear_collection.max_durability_duration_sec,
                &merkle_gear_token.property_mutator_ref
            );
        };
        object::disable_ungated_transfer(&merkle_gear_token.transfer_ref); // soul bound
        simple_map::add(&mut user_gear.equipped, gear_detail.gear_type, _gear_address);
        simple_map::add(&mut user_gear.equipped_time, gear_detail.gear_type, timestamp::now_seconds());

        event::emit_event(&mut borrow_global_mut<GearEvents>(@merkle).equip_events, EquipEvent {
            uid: gear_detail.uid,
            gear_address: _gear_address,
            user: address_of(_user),
            durability: gear_detail.durability
        });
    }

    fun is_equiped(_user_address: address, _gear_type: u64, _gear_address: address): bool acquires UserGear {
        if (!exists<UserGear>(_user_address)) {
            return false
        };
        let user_gear = borrow_global_mut<UserGear>(_user_address);
        if (simple_map::contains_key(&user_gear.equipped, &_gear_type)) {
            let equipped_gear_address = simple_map::borrow(&user_gear.equipped, &_gear_type);
            return *equipped_gear_address == _gear_address
        };
        false
    }

    public fun unequip(_user: &signer, _gear_address: address) acquires  UserGear, MerkleGearToken, MerkleGearCollection, GearEvents {
        let merkle_gear_collection = borrow_global_mut<MerkleGearCollection>(@merkle);
        {
            let gear_detail = get_gear_detail(_gear_address);
            assert!(is_equiped(address_of(_user), gear_detail.gear_type, _gear_address), E_GEAR_NOT_EQUIPPED);

            let user_gear = borrow_global_mut<UserGear>(address_of(_user));
            let merkle_gear_token = borrow_global<MerkleGearToken>(_gear_address);
            unequip_internal(
                &mut user_gear.equipped,
                &mut user_gear.equipped_time,
                gear_detail,
                merkle_gear_collection.max_durability_duration_sec,
                &merkle_gear_token.property_mutator_ref
            );
        };
    }

    fun unequip_internal(
        _equipped: &mut simple_map::SimpleMap<u64, address>,
        _equipped_time: &mut simple_map::SimpleMap<u64, u64>,
        _gear_detail: GearDetail,
        _max_durability_duration_sec: u64,
        _property_mutator_ref: &property_map::MutatorRef
    ) acquires GearEvents {
        let elapsed_time = timestamp::now_seconds() - *simple_map::borrow(_equipped_time, &_gear_detail.gear_type);
        let durability = _gear_detail.durability;
        let durability_decrease_amount = 10 * DURABILITY_PRECISION
            + safe_mul_div(elapsed_time, 100 * DURABILITY_PRECISION, _max_durability_duration_sec);
        if (durability > durability_decrease_amount) {
            durability = durability - durability_decrease_amount;
        } else {
            durability = 0;
        };
        property_map::update(
            _property_mutator_ref,
            &string::utf8(PROPERTY_DURABILITY),
            string::utf8(b"u64"),
            bcs::to_bytes<u64>(&durability)
        );
        simple_map::remove(_equipped, &_gear_detail.gear_type);
        simple_map::remove(_equipped_time, &_gear_detail.gear_type);

        event::emit_event(&mut borrow_global_mut<GearEvents>(@merkle).unequip_events, UnequipEvent {
            uid: _gear_detail.uid,
            gear_address: _gear_detail.gear_address,
            user: _gear_detail.owner,
            durability
        });
    }

    public fun get_salvage_shard_range(_gear_address: address): (u64, u64) acquires MerkleGearToken {
        let gear_detail = get_gear_detail(_gear_address);
        gear_calc::calc_salvage_shard_range(gear_detail.tier, gear_detail.durability)
    }

    public(friend) fun salvage_rand(_user: &signer, _gear_address: address) acquires UserGear, MerkleGearToken, MerkleGearCollection, GearEvents {
        // check owner
        let gear_detail = get_gear_detail(_gear_address);
        assert!(gear_detail.owner == address_of(_user), E_GEAR_OWNER_UNMATCHED);

        // check equipped
        assert!(!is_equiped(address_of(_user), gear_detail.gear_type, _gear_address), E_SALVAGE_UNAVAILABLE_GEAR_EQUIPPED);

        // mint shard
        let (min_shard, max_shard) = gear_calc::calc_salvage_shard_range(gear_detail.tier, gear_detail.durability);
        let shard_amount = random::get_random_between(min_shard, max_shard);
        shard_token::mint(address_of(_user), shard_amount);

        // burn gear
        burn_gear(_gear_address);

        // emit event
        event::emit_event(&mut borrow_global_mut<GearEvents>(@merkle).salvage_events, SalvageEvent {
            uid: gear_detail.uid,
            gear_address: _gear_address,
            shard_amount,
            user: address_of(_user)
        });
        let merkle_gear_collection = borrow_global_mut<MerkleGearCollection>(@merkle);
        table::remove(&mut merkle_gear_collection.gears, gear_detail.uid);
    }

    public fun get_repair_shards(_gear_address: address, _target_durability: u64): u64 acquires MerkleGearCollection, MerkleGearToken, UserGear {
        let gear_detail = get_gear_detail(_gear_address);
        let equipped = is_equiped(gear_detail.owner, gear_detail.gear_type, _gear_address);
        let current_durability = gear_detail.durability;

        if (equipped) {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(@merkle);
            let user_gear = borrow_global<UserGear>(gear_detail.owner);
            let elapsed_time = timestamp::now_seconds()
                - *simple_map::borrow(&user_gear.equipped_time, &gear_detail.gear_type);
            let used_durability = safe_mul_div(elapsed_time, 100 * DURABILITY_PRECISION, merkle_gear_collection.max_durability_duration_sec);
            current_durability = current_durability - min(current_durability, used_durability);
        };

        assert!(
            current_durability <= _target_durability && _target_durability <= 100 * DURABILITY_PRECISION,
            E_INVALID_TARGET_DURABILITY
        );
        gear_calc::calc_repair_required_shards(_target_durability, current_durability, gear_detail.tier)
    }

    public fun repair(_user: &signer, _gear_address: address, _target_durability: u64) acquires MerkleGearToken, MerkleGearCollection, UserGear, GearEvents {
        assert!(_target_durability == 100 * DURABILITY_PRECISION, E_INVALID_TARGET_DURABILITY);
        let required_shard = get_repair_shards(_gear_address, _target_durability);
        if (!exists<UserGear>(address_of(_user))) {
            move_to(_user, UserGear {
                equipped: simple_map::create(),
                equipped_time: simple_map::create(),
            })
        };
        let gear_detail = get_gear_detail(_gear_address);
        assert!(gear_detail.owner == address_of(_user), E_GEAR_OWNER_UNMATCHED);

        shard_token::burn(address_of(_user), required_shard);
        let merkle_gear_token = borrow_global<MerkleGearToken>(_gear_address);
        property_map::update(
            &merkle_gear_token.property_mutator_ref,
            &string::utf8(PROPERTY_DURABILITY),
            string::utf8(b"u64"),
            bcs::to_bytes<u64>(&_target_durability)
        );

        let equipped = is_equiped(address_of(_user), gear_detail.gear_type, _gear_address);
        if (equipped) {
            let user_gear = borrow_global_mut<UserGear>(address_of(_user));
            simple_map::upsert(&mut user_gear.equipped_time, gear_detail.gear_type, timestamp::now_seconds());
        };

        event::emit_event(&mut borrow_global_mut<GearEvents>(@merkle).repair_events, RepairEvent {
            uid: gear_detail.uid,
            gear_address: _gear_address,
            shard_amount: required_shard,
            user: address_of(_user)
        });
    }

    public fun get_gear_detail(_gear_address: address): GearDetail acquires MerkleGearToken {
        let merkle_gear_token = borrow_global<MerkleGearToken>(_gear_address);
        let merkle_gear = object::object_from_delete_ref<MerkleGearToken>(&merkle_gear_token.delete_ref);
        return GearDetail {
            uid: property_map::read_u64(&merkle_gear, &string::utf8(PROPERTY_UID)),
            gear_address: _gear_address,
            name: token::name(merkle_gear),
            uri: token::uri(merkle_gear),
            gear_type: property_map::read_u64(&merkle_gear, &string::utf8(PROPERTY_GEAR_TYPE)),
            gear_code: property_map::read_u64(&merkle_gear, &string::utf8(PROPERTY_GEAR_CODE)),
            tier: property_map::read_u64(&merkle_gear, &string::utf8(PROPERTY_TIER)),
            durability: property_map::read_u64(&merkle_gear, &string::utf8(PROPERTY_DURABILITY)),
            primary_effect: property_map::read_u64(&merkle_gear, &string::utf8(PROPERTY_PRIMARY_EFFECT)),
            gear_affixes: merkle_gear_token.gear_affixes,
            owner: object::owner(merkle_gear),
            soul_bound: !object::ungated_transfer_allowed(merkle_gear),
            season: property_map::read_u64(&merkle_gear, &string::utf8(PROPERTY_SEASON)),
        }
    }

    fun get_gear_effect<PairType>(_gear_detail: GearDetail, _equipped_time: u64, _max_durability_duration_sec: u64): u64 {
        // check durability
        let elapsed_time = timestamp::now_seconds() - _equipped_time;
        let used_durability = safe_mul_div(elapsed_time, 100 * DURABILITY_PRECISION, _max_durability_duration_sec);
        let current_season = season::get_current_season_number();
        if (
            _gear_detail.durability <= used_durability ||
            (current_season - _gear_detail.season >= GEAR_EXPIRY_SEASON_DURATION && current_season >= GEAR_EXPIRY_START)
        ) {
            // Users can use their gear until season 8, even if it has expired
            return 0
        };
        // calculate effect
        let effect = _gear_detail.primary_effect;
        let idx = 0;
        while(idx < vector::length(&_gear_detail.gear_affixes)) {
            let gear_affix = vector::borrow(&_gear_detail.gear_affixes, idx);
            if (pair_types::check_target<PairType>(gear_affix.target)) {
                effect = effect + gear_affix.effect;
                // ------------------------------------------------------
                // check season number 13 (ETH Fest season)
                // this logic only for ETH Fest season
                if (current_season == 13 && (
                    type_info::struct_name(&type_info::type_of<PairType>()) == b"ETH_USD" ||
                        type_info::struct_name(&type_info::type_of<PairType>()) == b"ARB_USD" ||
                        type_info::struct_name(&type_info::type_of<PairType>()) == b"OP_USD"
                )) {
                    effect = effect + 30000; // +3%
                }
                // ------------------------------------------------------
            };
            idx = idx + 1;
        };
        effect
    }

    fun use_gear<PairType>(_gear_detail: GearDetail, _effect: u64) acquires GearEvents {
        event::emit_event(&mut borrow_global_mut<GearEvents>(@merkle).gear_effect_events, GearEffectEvent {
            uid: _gear_detail.uid,
            pair_type: type_info::type_of<PairType>(),
            gear_address: _gear_detail.gear_address,
            user: _gear_detail.owner,
            effect: _effect,
            gear_type: _gear_detail.gear_type,
            gear_code: _gear_detail.gear_code
        });
    }

    fun get_gear_type_boost_effect<PairType>(_user: address, _gear_type: u64, _use_gear: bool): u64 acquires UserGear, MerkleGearToken, MerkleGearCollection, GearEvents {
        if (!exists<UserGear>(_user)) {
            return 0
        };
        let merkle_gear_collection = borrow_global<MerkleGearCollection>(@merkle);
        let user_gear = borrow_global_mut<UserGear>(_user);
        if (!simple_map::contains_key(&user_gear.equipped, &_gear_type)) {
            return 0
        };
        let gear_address = simple_map::borrow(&user_gear.equipped, &_gear_type);
        let equipped_time = simple_map::borrow(&user_gear.equipped_time, &_gear_type);
        let gear_detail = get_gear_detail(*gear_address);
        let gear_effect = get_gear_effect<PairType>(
            gear_detail,
            *equipped_time,
            merkle_gear_collection.max_durability_duration_sec
        );
        if (_use_gear && gear_effect > 0) {
            use_gear<PairType>(gear_detail, gear_effect)
        };
        gear_effect
    }

    public fun get_pmkl_boost_effect<PairType>(_user: address, _use_gear: bool): u64 acquires UserGear, MerkleGearToken, MerkleGearCollection, GearEvents {
        get_gear_type_boost_effect<PairType>(_user, TYPE_MINING_TOOL, _use_gear)
    }

    public fun get_fee_discount_effect<PairType>(_user: address, _use_gear: bool): u64 acquires UserGear, MerkleGearToken, MerkleGearCollection, GearEvents {
        get_gear_type_boost_effect<PairType>(_user, TYPE_SUIT, _use_gear)
    }

    public fun get_xp_boost_effect<PairType>(_user: address, _use_gear: bool): u64 acquires UserGear, MerkleGearToken, MerkleGearCollection, GearEvents {
        get_gear_type_boost_effect<PairType>(_user, TYPE_HELMET, _use_gear)
    }

    public fun get_equipped_gears(_user: address): vector<EquippedGearView> acquires UserGear, MerkleGearToken {
        if (!exists<UserGear>(_user)) {
            return vector[]
        };
        let user_gear = borrow_global<UserGear>(_user);
        let equipped_gear: vector<EquippedGearView> = vector[];

        let (_, gear_addresses) = simple_map::to_vec_pair(user_gear.equipped);
        let idx = 0;
        while(idx < vector::length(&gear_addresses)) {
            let gear_address = vector::borrow(&gear_addresses, idx);
            let gear_detail = get_gear_detail(*gear_address);

            vector::push_back(&mut equipped_gear, EquippedGearView {
                gear_address: *gear_address,
                name: gear_detail.name,
                uri: gear_detail.uri,
                gear_type: gear_detail.gear_type,
                equipped_time: *simple_map::borrow(&user_gear.equipped_time, &gear_detail.gear_type)
            });
            idx = idx + 1;
        };
        equipped_gear
    }

    public fun forge_rand(_user: &signer, _gear1_address: address, _gear2_address: address)
    acquires MerkleGearToken, UserGear, MerkleGearCollection, GearEvents, GearEventsV2 {
        let gear1_detail = get_gear_detail(_gear1_address);
        let gear2_detail = get_gear_detail(_gear2_address);
        validate_forge(address_of(_user), gear1_detail, gear2_detail);

        // calc result tier
        let gear_tier = gear1_detail.tier;
        let result_tier = gear_tier;
        let (maintain_rate, break_rate) = gear_calc::get_forge_rates(gear_tier);
        let break_num = random::get_random_between(1, 1000000);
        if (break_num <= break_rate) {
            // break
            result_tier = gear_tier - 1;
        } else {
            let maintain_num = random::get_random_between(1, 1000000);
            if (maintain_num > maintain_rate && gear_tier < 4) {
                // upgrade
                result_tier = gear_tier + 1;
            };
            // maintain
        };
        // mint gear
        mint_rand(_user, result_tier);

        // shard burn
        let required_shard = gear_calc::get_forge_required_shard(gear_tier);
        shard_token::burn(address_of(_user), required_shard);

        // emit event
        event::emit_event(&mut borrow_global_mut<GearEventsV2>(@merkle).forge_events, ForgeEvent {
            user: address_of(_user),
            gear1_uid: gear1_detail.uid,
            gear1_address: _gear1_address,
            gear2_uid: gear2_detail.uid,
            gear2_address: _gear2_address,
            required_shard,
            gear_tier,
            result_tier,
        });

        // gear burn
        burn_gear(_gear1_address);
        burn_gear(_gear2_address);
    }

    fun validate_forge(_user_address: address, _gear1_detail: GearDetail, _gear2_detail: GearDetail)
    acquires UserGear {
        // gear tier check
        assert!(_gear1_detail.tier == _gear2_detail.tier, E_FORGE_GEAR_TIER_NOT_MATCHED);
        // same gear check
        assert!(_gear1_detail.uid != _gear2_detail.uid, E_FORGE_SAME_GEAR);
        // gear1 check
        {
            // check owner
            assert!(_gear1_detail.owner == _user_address, E_GEAR_OWNER_UNMATCHED);
            // check durability
            assert!(_gear1_detail.durability == 100 * DURABILITY_PRECISION, E_FORGE_GEAR_DURABILITY_NOT_100);
            // check equipped
            assert!(
                !is_equiped(_user_address, _gear1_detail.gear_type, _gear1_detail.gear_address),
                E_FORGE_UNAVAILABLE_GEAR_EQUIPPED
            );
        };

        // gear2 check
        {
            // check owner
            assert!(_gear2_detail.owner == _user_address, E_GEAR_OWNER_UNMATCHED);
            // check durability
            assert!(_gear2_detail.durability == 100 * DURABILITY_PRECISION, E_FORGE_GEAR_DURABILITY_NOT_100);
            // check equipped
            assert!(
                !is_equiped(_user_address, _gear2_detail.gear_type, _gear2_detail.gear_address),
                E_FORGE_UNAVAILABLE_GEAR_EQUIPPED
            );
        };
    }

    fun burn_gear(_gear_address: address) acquires MerkleGearToken {
        let merkle_gear_token = move_from<MerkleGearToken>(_gear_address);
        let MerkleGearToken {
            delete_ref: _,
            mutator_ref: _,
            burn_ref,
            transfer_ref: _,
            property_mutator_ref,
            gear_affixes: _,
        } = merkle_gear_token;
        property_map::burn(property_mutator_ref);
        token::burn(burn_ref);
    }

    public fun generate_admin_cap(_admin: &signer): AdminCapability {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        AdminCapability {}
    }

    // <--- test --->

    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use std::features;
    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    struct TEST_USDC {}

    #[test_only]
    public fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };

        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        initialize_module(host);
        initialize_module_v2(host);
        random::initialize_module(host);
        gear_factory::initialize_module(host);
        gear_factory::register_gear(
            host,
            0,
            b"g11",
            b"",
            0,
            0,
            100000,
            200000,
        );
        gear_factory::register_gear(
            host,
            0,
            b"g12",
            b"",
            1,
            0,
            100000,
            200000,
        );
        gear_factory::register_gear(
            host,
            0,
            b"g13",
            b"",
            2,
            0,
            100000,
            200000,
        );
        gear_factory::register_gear(
            host,
            1,
            b"g21",
            b"",
            0,
            0,
            100000,
            200000,
        );
        gear_factory::register_gear(
            host,
            1,
            b"g22",
            b"",
            1,
            0,
            100000,
            200000,
        );
        gear_factory::register_gear(
            host,
            1,
            b"g23",
            b"",
            2,
            0,
            100000,
            200000,
        );
        season::initialize_module(host);
        shard_token::initialize_module(host);
    }

    #[test_only]
    public fun T_mint_equip_gear(host: &signer, aptos_framework: &signer): (u64, u64, u64) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        let boosts: simple_map::SimpleMap<u64, u64> = simple_map::new<u64, u64>();
        mint_rand(host, 0);
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            let gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
            equip(host, gear_address);
            let gear_detail = get_gear_detail(gear_address);
            simple_map::upsert(&mut boosts, gear_detail.gear_type, gear_detail.primary_effect);
        };
        timestamp::update_global_time_for_test(98256);

        mint_rand(host, 0);
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            let gear_address = *table::borrow(&merkle_gear_collection.gears, 1);
            equip(host, gear_address);
            let gear_detail = get_gear_detail(gear_address);
            simple_map::upsert(&mut boosts, gear_detail.gear_type, gear_detail.primary_effect);
        };
        timestamp::update_global_time_for_test(984561);

        mint_rand(host, 0);
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            let gear_address = *table::borrow(&merkle_gear_collection.gears, 2);
            equip(host, gear_address);
            let gear_detail = get_gear_detail(gear_address);
            simple_map::upsert(&mut boosts, gear_detail.gear_type, gear_detail.primary_effect);
        };
        (*simple_map::borrow(&boosts, &0), *simple_map::borrow(&boosts, &1), *simple_map::borrow(&boosts, &2))
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_mint(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken {
        call_test_setting(host, aptos_framework);
        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };

        let gear_detail = get_gear_detail(gear_address);
        assert!(gear_detail.owner == address_of(host), 0);
        assert!(gear_detail.tier == 0, 0);
        assert!(gear_detail.season == 1, 0);
        assert!(gear_detail.durability == 100 * DURABILITY_PRECISION, 0);
        assert!(gear_detail.soul_bound == false, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_equip(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);

        let gears = get_equipped_gears(address_of(host));
        let gear = vector::borrow(&gears, 0);
        let gear_detail = get_gear_detail(gear_address);
        let effect = get_gear_type_boost_effect<TEST_USDC>(address_of(host), gear_detail.gear_type, true);
        assert!(gear_detail.soul_bound == true, 0);
        assert!(gear_detail.gear_type == gear.gear_type, 0);
        assert!(gear_detail.name == gear.name, 0);
        assert!(gear.equipped_time == 10, 0);
        assert!(effect == gear_detail.primary_effect, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_unequip(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);
        unequip(host, gear_address);

        let gears = get_equipped_gears(address_of(host));
        let gear_detail = get_gear_detail(gear_address);
        assert!(vector::is_empty(&gears), 0);
        assert!(gear_detail.soul_bound == true, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 327683, location = object)]
    fun T_transfer_check(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);

        mint_rand(host, 0);
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            let gear_address = table::borrow(&merkle_gear_collection.gears, 0);
            let merkle_gear_token = borrow_global<MerkleGearToken>(*gear_address);
            let token = object::object_from_delete_ref<MerkleGearToken>(&merkle_gear_token.delete_ref);
            object::transfer(host, token, address_of(aptos_framework));
        };
        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 1);
        };
        equip(host, gear_address);
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            let gear_address = table::borrow(&merkle_gear_collection.gears, 1);
            let merkle_gear_token = borrow_global<MerkleGearToken>(*gear_address);
            let token = object::object_from_delete_ref<MerkleGearToken>(&merkle_gear_token.delete_ref);
            object::transfer(host, token, address_of(aptos_framework));
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_use_durability_repair(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        shard_token::mint(address_of(host), 10000_000000);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);
        unequip(host, gear_address);
        {
            let gear_detail = get_gear_detail(gear_address);
            assert!(gear_detail.durability == 90 * DURABILITY_PRECISION, 0);
        };
        equip(host, gear_address);
        timestamp::fast_forward_seconds(86400*21*3/10); // 30%
        unequip(host, gear_address);
        {
            let gear_detail = get_gear_detail(gear_address);
            assert!(gear_detail.durability == 50 * DURABILITY_PRECISION, 0);
        };
        let shard_balance = shard_token::get_shard_balance(address_of(host));
        let repair_shard_amount = get_repair_shards(gear_address, 100 * DURABILITY_PRECISION);
        repair(host, gear_address, 100 * DURABILITY_PRECISION);
        assert!(shard_balance - repair_shard_amount == shard_token::get_shard_balance(address_of(host)), 0);
        {
            let gear_detail = get_gear_detail(gear_address);
            assert!(gear_detail.durability == 100 * DURABILITY_PRECISION, 0);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_INVALID_TARGET_DURABILITY, location = Self)]
    fun T_partial_repair_fail(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        shard_token::mint(address_of(host), 10000_000000);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);
        repair(host, gear_address, 99 * DURABILITY_PRECISION);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_salvage(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        shard_token::mint(address_of(host), 10000_000000);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        let (min, max) = get_salvage_shard_range(gear_address);
        let shard_balance = shard_token::get_shard_balance(address_of(host));
        salvage_rand(host, gear_address);
        assert!(shard_token::get_shard_balance(address_of(host)) - shard_balance >= min, 0);
        assert!(shard_token::get_shard_balance(address_of(host)) - shard_balance <= max, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_SALVAGE_UNAVAILABLE_GEAR_EQUIPPED, location = Self)]
    fun T_salvage_fail(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        shard_token::mint(address_of(host), 10000_000000);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);
        salvage_rand(host, gear_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_GEAR_DURABILITY_NOT_ENOUGH, location = Self)]
    fun T_use_gear_until_durability_0(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);
        timestamp::fast_forward_seconds(24 * 60 * 60 * 21 + 2);
        unequip(host, gear_address);
        equip(host, gear_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_GEAR_ALREADY_EQUIPPED, location = Self)]
    fun T_gear_already_equipped(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);

        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);
        equip(host, gear_address);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_use_gear_effect_with_0_durability(host: &signer, aptos_framework: &signer) acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear {
        call_test_setting(host, aptos_framework);
        mint_rand(host, 0);
        let gear_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear_address = *table::borrow(&merkle_gear_collection.gears, 0);
        };
        equip(host, gear_address);
        timestamp::fast_forward_seconds(24 * 60 * 60 * 21 + 2);
        let gear_detail = get_gear_detail(gear_address);
        let effect = get_gear_type_boost_effect<TEST_USDC>(address_of(host), gear_detail.gear_type, true);
        assert!(effect == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_forge(host: &signer, aptos_framework: &signer)
    acquires MerkleGearCollection, GearEvents, MerkleGearToken, UserGear, GearEventsV2 {
        call_test_setting(host, aptos_framework);
        timestamp::fast_forward_seconds(10);
        shard_token::mint(address_of(host), 100000000);

        mint_rand(host, 0);
        mint_rand(host, 0);
        let gear1_address;
        let gear2_address;
        {
            let merkle_gear_collection = borrow_global<MerkleGearCollection>(address_of(host));
            gear1_address = *table::borrow(&merkle_gear_collection.gears, 0);
            gear2_address = *table::borrow(&merkle_gear_collection.gears, 1);
        };
        forge_rand(host, gear1_address, gear2_address);
    }
}