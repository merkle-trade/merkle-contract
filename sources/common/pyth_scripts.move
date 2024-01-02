module merkle::pyth_scripts {
    use std::vector;
    use aptos_framework::coin;

    use pyth::i64;
    use pyth::pyth;
    use pyth::price;
    use pyth::price_identifier;

    /// When the pyth price feed does not exist
    const E_PYTH_PRICE_FEED_DOES_NOT_EXIST: u64 = 0;

    /// update pyth price data
    public fun update_pyth(host: &signer, pyth_vaa: vector<u8>) {
        let update_data = vector::empty<vector<u8>>();
        vector::push_back(&mut update_data, pyth_vaa);

        // Pay the fee
        let coins = coin::withdraw(host, pyth::get_update_fee(&update_data));
        pyth::update_price_feeds(update_data, coins);
    }

    /// Deserialize the pyth vaa data to get the price_identifier and use it to get the price and timestamp.
    /// return value (price, exp, update timestamp)
    public fun get_price_from_vaa_no_older_than(pyth_price_identifier: vector<u8>, secs: u64): (u64, u64, u64) {
        let price_id = price_identifier::from_byte_vec(pyth_price_identifier);
        let pyth_price = pyth::get_price_no_older_than(price_id, secs);
        let i64_expo = price::get_expo(&pyth_price);
        let expo = (if(i64::get_is_negative(&i64_expo))
            i64::get_magnitude_if_negative(&i64_expo) else i64::get_magnitude_if_positive(&i64_expo));

        (
            i64::get_magnitude_if_positive(&price::get_price(&pyth_price)),
            expo,
            price::get_timestamp(&pyth_price)
        )
    }

    public fun get_price_for_random(pyth_price_identifier: vector<u8>): u64 {
        let price_id = price_identifier::from_byte_vec(pyth_price_identifier);
        assert!(pyth::price_feed_exists(price_id), E_PYTH_PRICE_FEED_DOES_NOT_EXIST);
        i64::get_magnitude_if_positive(&price::get_price(&pyth::get_price_unsafe(price_id)))
    }
}