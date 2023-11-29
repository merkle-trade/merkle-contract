module merkle::switchboard_scripts {
    use switchboard::aggregator;
    use switchboard::math;

    /// Get price and round_confirmed_timestamp from switchboard
    public fun get_switchboard_price(addr: address): (u64, u64) {
        let (
            result,
            round_confirmed_timestamp,
            _,
            _,
            _,
        ) = aggregator::latest_round(addr);
        // let latest_value = aggregator::latest_value(addr);
        let (value, _, neg) = math::unpack(result);
        if (neg) {
            // If neg is true, then the value is invalid, so return 0 to make it inapplicable.
            return (0, 0)
        };
        ((value as u64), round_confirmed_timestamp)
    }
}