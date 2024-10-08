module merkle::random {
    use std::signer::address_of;
    use aptos_std::aptos_hash;
    use aptos_std::smart_table;
    use aptos_std::table;
    use aptos_framework::timestamp;
    use merkle::price_oracle;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    struct RandomSalt has key {
        salt: u64
    }

    struct RandomPaddingStore has copy, store, drop {
        addresses: vector<address>
    }

    struct RandomPadding has key {
        num: u64,
        store: smart_table::SmartTable<u64, RandomPaddingStore>,
        table: table::Table<u64, RandomPaddingStore>
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<RandomSalt>(address_of(_admin))) {
            move_to(_admin, RandomSalt {
                salt: 0
            });
        };

        if (!exists<RandomPadding>(address_of(_admin))) {
            move_to(_admin, RandomPadding {
                num: 0,
                store: smart_table::new(),
                table: table::new()
            });
        };
    }

    public fun get_random_between(from: u64, to: u64): u64 acquires RandomSalt{
        let random_salt = borrow_global_mut<RandomSalt>(@merkle);
        random_salt.salt = random_salt.salt + 1;
        let pyth_salt = price_oracle::get_price_for_random();
        (
            aptos_hash::sip_hash_from_value(
                &((pyth_salt + timestamp::now_seconds() + timestamp::now_microseconds()) + random_salt.salt)
            ) % (to - from + 1)
        ) + from
    }

    public fun add_random_padding() acquires RandomPadding {
        let random_safety = borrow_global_mut<RandomPadding>(@merkle);
        let padding_store = RandomPaddingStore {
            addresses: vector[
                @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA,
                @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA,
                @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA, @0xA,
            ],
        };
        let idx = 0;
        while (idx < 5) {
            random_safety.num = (random_safety.num + 1) % 10;
            smart_table::upsert(&mut random_safety.store, random_safety.num, padding_store);
            idx = idx + 1;
        };
    }
}