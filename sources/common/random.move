module merkle::random {
    use std::signer::address_of;
    use aptos_std::aptos_hash;
    use aptos_framework::timestamp;
    use merkle::price_oracle;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    struct RandomSalt has key {
        salt: u64
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<RandomSalt>(address_of(_admin))) {
            move_to(_admin, RandomSalt {
                salt: 0
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
}