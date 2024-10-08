module merkle::gear_calc {
    use std::vector;
    use merkle::safe_math::safe_mul_div;

    const SHARD_PRECISION: u64 = 1000000;
    const DURABILITY_PRECISION: u64 = 1000000;
    const SHARD_FACTOR: u64 = 10;

    const GEAR_RELATIVE_VALUE: vector<u64> = vector[100000000, 307692308, 946745562, 2913063268, 8963271594];

    const FORGE_REQUIRED_SHARDS: vector<u64> = vector[
        9000000, // 9
        18000000, // 18
        36000000, // 36
        72000000, // 72
        144000000 // 144
    ];
    const FORGE_MAINTAIN_RATE: vector<u64> = vector[857100, 857100, 857100, 857100, 1000000]; // 1000000 = 100%
    const FORGE_BREAK_RATE: vector<u64> = vector[0, 0, 0, 0, 0]; // 1000000 = 100%

    public fun calc_salvage_shard_range(_tier: u64, _durability: u64): (u64, u64) {
        let shard_discount_factor = 300000; // 30%
        let shard_random_factor = 100000; // 10%

        let relative_value = *vector::borrow(&GEAR_RELATIVE_VALUE, _tier);
        let min_shard = safe_mul_div(safe_mul_div(
            relative_value * SHARD_FACTOR,
            (SHARD_PRECISION - shard_discount_factor - shard_random_factor),
            SHARD_PRECISION * 100
        ), _durability, 100 * DURABILITY_PRECISION);
        let max_shard = safe_mul_div(safe_mul_div(
            relative_value * SHARD_FACTOR,
            (SHARD_PRECISION - shard_discount_factor + shard_random_factor),
            SHARD_PRECISION * 100
        ), _durability, 100 * DURABILITY_PRECISION);
        (min_shard, max_shard)
    }

    public fun calc_repair_required_shards(_tarcalc_durability: u64, _current_durability: u64, _tier: u64): u64 {
        let repair_amount = _tarcalc_durability - _current_durability;
        safe_mul_div(
            *vector::borrow(&GEAR_RELATIVE_VALUE, _tier) * SHARD_FACTOR,
            repair_amount,
            100 * DURABILITY_PRECISION * 100
        )
    }

    public fun calc_lootbox_shard_range(_tier: u64): (u64, u64) {
        let lootbox_factor: vector<u64> = vector[
            3 * SHARD_PRECISION,
            6 * SHARD_PRECISION,
            12 * SHARD_PRECISION,
            24 * SHARD_PRECISION,
            48 * SHARD_PRECISION
        ];
        let lootbox_shard_factor = 70000; // 7%
        let lootbox_shard_random_factor = 100000; // 10%
        let lootbox_factor_value = *vector::borrow(&lootbox_factor, _tier);

        let min_shard = safe_mul_div(
            safe_mul_div(
                lootbox_factor_value * SHARD_FACTOR,
                lootbox_shard_factor,
                SHARD_PRECISION
            ),
            (SHARD_PRECISION - lootbox_shard_random_factor),
            SHARD_PRECISION
        );
        let max_shard = safe_mul_div(
            safe_mul_div(
                lootbox_factor_value * SHARD_FACTOR,
                lootbox_shard_factor,
                SHARD_PRECISION
            ),
            (SHARD_PRECISION + lootbox_shard_random_factor),
            SHARD_PRECISION
        );

        (min_shard, max_shard)
    }

    public fun get_forge_required_shard(_tier: u64): u64 {
        *vector::borrow(&FORGE_REQUIRED_SHARDS, _tier)
    }

    public fun get_forge_rates(_tier: u64): (u64, u64) {
        // return maintain rate, break rate
        (
            *vector::borrow(&FORGE_MAINTAIN_RATE, _tier),
            *vector::borrow(&FORGE_BREAK_RATE, _tier)
        )
    }

    // <--- test --->
    #[test]
    public fun T_calc_salvage_shard_range() {
        let (min, max) = calc_salvage_shard_range(0, 100 * DURABILITY_PRECISION);
        assert!(min == 6000000, 0);
        assert!(max == 8000000, 0);
        let (min, max) = calc_salvage_shard_range(1, 100 * DURABILITY_PRECISION);
        assert!(min == 18461538, 0);
        assert!(max == 24615384, 0);
        let (min, max) = calc_salvage_shard_range(2, 100 * DURABILITY_PRECISION);
        assert!(min == 56804733, 0);
        assert!(max == 75739644, 0);
        let (min, max) = calc_salvage_shard_range(3, 100 * DURABILITY_PRECISION);
        assert!(min == 174783796, 0);
        assert!(max == 233045061, 0);
        let (min, max) = calc_salvage_shard_range(4, 100 * DURABILITY_PRECISION);
        assert!(min == 537796295, 0);
        assert!(max == 717061727, 0);
        let (min, max) = calc_salvage_shard_range(0, 50 * DURABILITY_PRECISION);
        assert!(min == 3000000, 0);
        assert!(max == 4000000, 0);
    }

    #[test]
    public fun T_calc_repair_required_shards() {
        let shard = calc_repair_required_shards(100000000, 0, 0);
        assert!(shard == 10000000, 0);
        let shard = calc_repair_required_shards(100000000, 0, 1);
        assert!(shard == 30769230, 0);
        let shard = calc_repair_required_shards(100000000, 0, 2);
        assert!(shard == 94674556, 0);
        let shard = calc_repair_required_shards(100000000, 0, 3);
        assert!(shard == 291306326, 0);
        let shard = calc_repair_required_shards(100000000, 0, 4);
        assert!(shard == 896327159, 0);
    }

    #[test]
    public fun T_calc_lootbox_shard_range() {
        let (min, max) = calc_lootbox_shard_range(0);
        assert!(min == 1890000, 0);
        assert!(max == 2310000, 0);
        let (min, max) = calc_lootbox_shard_range(1);
        assert!(min == 3780000, 0);
        assert!(max == 4620000, 0);
        let (min, max) = calc_lootbox_shard_range(2);
        assert!(min == 7560000, 0);
        assert!(max == 9240000, 0);
        let (min, max) = calc_lootbox_shard_range(3);
        assert!(min == 15120000, 0);
        assert!(max == 18480000, 0);
        let (min, max) = calc_lootbox_shard_range(4);
        assert!(min == 30240000, 0);
        assert!(max == 36960000, 0);
    }
}