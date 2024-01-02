module merkle::trading_calc {

    // <-- CONSTANT ----->
    use merkle::safe_math_u64::{abs, safe_mul_div, signed_plus, min};

    const FUNDING_PRECISION: u64 = 100000000;
    const FUNDING_PADDING_PRECISION: u64 = 100000000000;
    const PRECISION: u64 = 1000000;
    const MAKER_TAKER_FEE_PRECISION: u64 = 1000000;
    const DAY_SECONDS: u64 = 86400;

    // <-- PRICE ----->

    /// Calculate new price
    public fun calculate_new_price(
        _original_price: u64,
        _original_size: u64,
        _new_price: u64,
        _size_delta: u64
    ): u64 {
        if (_original_size == 0) { return _new_price };
        if (_size_delta == 0) { return _original_price };
        let padding = (1_000_000_000_000_000_000 as u256); // 1e18

        let new_size: u256 = ((_original_size as u256) + (_size_delta as u256)) * padding;
        let original: u256 = (_original_size as u256) * padding / (_original_price as u256);
        let new: u256 = (_size_delta as u256) * padding / (_new_price as u256);
        ((new_size / (original + new)) as u64)
    }
    
    /// Calculate profit and loss.
    public fun calculate_pnl_without_fee(
        _original_price: u64,
        _new_price: u64,
        _size_delta: u64,
        _is_long: bool
    ): (u64, bool) {
        if (_original_price == _new_price) {
            return (0, true)
        };
        let amount: u64;
        let is_profit: bool;
        let priceGap =
            if (_new_price >= _original_price) { _new_price - _original_price }
            else { _original_price - _new_price };
        if (_is_long == (_new_price >= _original_price)) {
            is_profit = true;
            amount = safe_mul_div(safe_mul_div(priceGap, PRECISION, _original_price), _size_delta, PRECISION);
        } else {
            is_profit = false;
            amount = safe_mul_div(safe_mul_div(priceGap, PRECISION, _original_price), _size_delta, PRECISION);
        };
        (amount, is_profit)
    }

    /// Calculate settle amount
    public fun calculate_settle_amount(
        _pnl: u64,
        _is_pnl_profit: bool,
        _fee: u64,
        _is_fee_profit: bool
    ): (u64, bool) {
        let sum: u64;
        let is_deposit_to_lp = true;
        if (_is_pnl_profit && _is_fee_profit) {
            sum = _pnl + _fee;
            is_deposit_to_lp = false;
        } else if (_is_pnl_profit && !_is_fee_profit) {
            if (_pnl > _fee) {
                sum = _pnl - _fee;
                is_deposit_to_lp = false;
            } else {
                sum = _fee - _pnl;
            }
        } else if (!_is_pnl_profit && _is_fee_profit) {
            if (_pnl > _fee) {
                sum = _pnl - _fee;
            } else {
                sum = _fee - _pnl;
                is_deposit_to_lp = false;
            }
        } else {
            sum = _pnl + _fee;
        };

        (sum, is_deposit_to_lp)
    }

    /// Calculate partial close decrease, increase, withdraw amount
    public fun calculate_partial_close_amounts(
        _collateral: u64,
        _settle_amount: u64,
        _is_deposit_to_lp: bool,
        _exit_fee: u64,
    ): (u64, u64) {
        let withdraw_amount = _collateral;
        let decrease_collateral = _collateral;

        if (_is_deposit_to_lp) {
            if (withdraw_amount > _settle_amount) {
                withdraw_amount = withdraw_amount - _settle_amount;
            } else {
                decrease_collateral = _settle_amount;
                withdraw_amount = 0;
            };
        } else {
            withdraw_amount = withdraw_amount + _settle_amount;
        };

        if (withdraw_amount > _exit_fee) {
            withdraw_amount = withdraw_amount - _exit_fee;
        } else {
            decrease_collateral = decrease_collateral + (_exit_fee - withdraw_amount);
            withdraw_amount = 0;
        };

        (withdraw_amount, decrease_collateral)
    }

    // <-- FEE ----->
    /// Calculate price after price-impact
    public fun calculate_price_impact(
        _price: u64,
        _size_delta: u64,
        _is_long: bool,
        _is_increase: bool,
        _long_open_interest: u64,
        _short_open_interest: u64,
        _skew_factor: u64
    ): u64 {
        if (_skew_factor == 0) {
            return _price
        };
        let market_skew = abs(_long_open_interest, _short_open_interest);
        let market_skew_positive = _long_open_interest > _short_open_interest;
        let after_market_skew: u64;
        let after_market_skew_positive: bool;
        if ((_is_long && _is_increase) || (!_is_long && !_is_increase)) {
            if (market_skew_positive) {
                after_market_skew = market_skew + _size_delta;
                after_market_skew_positive = true;
            } else {
                after_market_skew = abs(market_skew, _size_delta);
                after_market_skew_positive = market_skew < _size_delta;
            };
        } else {
            if (market_skew_positive) {
                after_market_skew = abs(market_skew, _size_delta);
                after_market_skew_positive = market_skew > _size_delta;
            } else {
                after_market_skew = market_skew + _size_delta;
                after_market_skew_positive = false;
            };
        };

        let price_before;
        if (market_skew_positive) {
            price_before = _price + safe_mul_div(_price, market_skew, _skew_factor);
        } else {
            price_before = _price - safe_mul_div(_price, market_skew, _skew_factor);
        };

        let price_after;
        if (after_market_skew_positive) {
            price_after = _price + safe_mul_div(_price, after_market_skew, _skew_factor);
        } else {
            price_after = _price - safe_mul_div(_price, after_market_skew, _skew_factor);
        };
        (price_before + price_after) / 2
    }

    /// Calculate roll-over fee
    public fun calculate_rollover_fee(
        _entry_acc_rollover_fee_per_collateral: u64,
        _exit_acc_rollover_fee_per_collateral: u64,
        _collateral_amount: u64
    ): u64 {
        if (_collateral_amount == 0) {
            return 0
        };
        safe_mul_div(
            _exit_acc_rollover_fee_per_collateral - _entry_acc_rollover_fee_per_collateral,
            _collateral_amount,
            PRECISION
        ) / 100
    }

    /// Calculate funding-fee
    public fun calculate_funding_fee(
        _acc_funding_fee_per_size_latest: u64,
        _acc_funding_fee_per_size_latest_positive: bool,
        _size: u64,
        _is_long: bool,
        _acc_funding_fee_per_size: u64,
        _acc_funding_fee_per_size_positive: bool
    ):(u64, bool) {
        let (funding_fee_per_size, funding_fee_per_size_positive) = signed_plus(
            _acc_funding_fee_per_size_latest,
            _acc_funding_fee_per_size_latest_positive,
            _acc_funding_fee_per_size,
            !_acc_funding_fee_per_size_positive
        );
        let funding_fee = safe_mul_div(_size, funding_fee_per_size, FUNDING_PRECISION);
        (funding_fee, (if (_is_long) !funding_fee_per_size_positive else funding_fee_per_size_positive))
    }

    /// Calculate roll-over fee
    public fun calculate_rollover_fee_delta(
        _entry_timestamp: u64,
        _exit_timestamp: u64,
        _rollover_fee_per_block: u64
    ): u64 {
        (_exit_timestamp - _entry_timestamp) *_rollover_fee_per_block
    }

    /// Calculate maker taker fee
    public fun calculate_maker_taker_fee(
        _long_open_interest: u64,
        _short_open_interest: u64,
        _maker_rate: u64,
        _taker_rate: u64,
        _size_delta: u64,
        _is_long: bool,
        _is_increase: bool
    ): u64 {
        let is_long_skew = _long_open_interest > _short_open_interest;
        let market_skew = abs(_long_open_interest, _short_open_interest);
        let market_skew_positive = _long_open_interest > _short_open_interest;
        let after_market_skew_positive: bool;
        if ((_is_long && _is_increase) || (!_is_long && !_is_increase)) {
            if (market_skew_positive) {
                after_market_skew_positive = true;
            } else {
                after_market_skew_positive = market_skew < _size_delta;
            };
        } else {
            if (market_skew_positive) {
                after_market_skew_positive = market_skew > _size_delta;
            } else {
                after_market_skew_positive = false;
            };
        };

        let fee: u64;
        if (market_skew_positive == after_market_skew_positive) {
            fee = safe_mul_div(_size_delta, (if((_is_long == _is_increase) == is_long_skew) _taker_rate else _maker_rate), MAKER_TAKER_FEE_PRECISION);
        } else {
            let flipped_taker_rate = safe_mul_div(abs(_size_delta, market_skew), PRECISION,  _size_delta);
            let flipped_maker_rate = PRECISION - flipped_taker_rate;
            let taker_fee = safe_mul_div(safe_mul_div(_size_delta, flipped_taker_rate, PRECISION), _taker_rate, MAKER_TAKER_FEE_PRECISION);
            let maker_fee = safe_mul_div(safe_mul_div(_size_delta, flipped_maker_rate, PRECISION), _maker_rate, MAKER_TAKER_FEE_PRECISION);
            fee = taker_fee + maker_fee;
        };
        return fee
    }

    /// calculate funding fee, rollover fee
    public fun calculate_risk_fees(
        _acc_rollover_fee_per_collateral_latest: u64,
        _acc_funding_fee_per_size_latest: u64,
        _acc_funding_fee_per_size_latest_positive: bool,
        _size: u64,
        _collateral: u64,
        _is_long: bool,
        _acc_rollover_fee_per_collateral: u64,
        _acc_funding_fee_per_size: u64,
        _acc_funding_fee_per_size_positive: bool
    ): (u64, bool, u64, bool, u64) {

        let rollover_fee = calculate_rollover_fee(
            _acc_rollover_fee_per_collateral,
            _acc_rollover_fee_per_collateral_latest,
            _collateral
        );
        let (funding_fee, is_funding_fee_positive) = calculate_funding_fee(
            _acc_funding_fee_per_size_latest,
            _acc_funding_fee_per_size_latest_positive,
            _size,
            _is_long,
            _acc_funding_fee_per_size,
            _acc_funding_fee_per_size_positive
        );

        let (risk_fee, is_fee_profit) = signed_plus(
            rollover_fee,
            false,
            funding_fee,
            is_funding_fee_positive
        );
        (rollover_fee, is_funding_fee_positive, funding_fee, is_fee_profit, risk_fee)
    }

    /// calculate funidng rate
    public fun calculate_funding_rate(
        _prev_funding_rate: u64,
        _prev_funding_positive: bool,
        _long_open_interest: u64,
        _short_open_interest: u64,
        _skew_factor: u64,
        _max_funding_velocity: u64,
        _time_delta: u64,
    ): (u64, bool) {
        let is_long_skew = _long_open_interest > _short_open_interest;
        let market_skew = abs(_long_open_interest, _short_open_interest);
        let skew_rate = if(_skew_factor == 0) 0 else safe_mul_div(market_skew, FUNDING_PADDING_PRECISION, _skew_factor);
        skew_rate = min(skew_rate, FUNDING_PADDING_PRECISION);
        let velocity = safe_mul_div(skew_rate, _max_funding_velocity, FUNDING_PADDING_PRECISION);
        let velocity_time_delta = safe_mul_div(velocity, _time_delta, DAY_SECONDS);

        let (funding_rate, is_funding_rate_positive) = signed_plus(
            _prev_funding_rate,
            _prev_funding_positive,
            velocity_time_delta,
            is_long_skew
        );
        (funding_rate, is_funding_rate_positive)
    }

    /// calculate funding fee per size
    public fun calculate_funding_fee_per_size(
        _prev_funding_fee_per_size: u64,
        _prev_funding_fee_per_size_positive: bool,
        _prev_funding_rate: u64,
        _prev_funding_rate_positive: bool,
        _current_funding_rate: u64,
        _current_funding_rate_positive: bool,
        _time_delta: u64
    ): (u64, bool) {
        let (latest_funding_rate, latest_funding_rate_positive) = signed_plus(
            _prev_funding_rate,
            _prev_funding_rate_positive,
            _current_funding_rate,
            _current_funding_rate_positive
        );
        latest_funding_rate = latest_funding_rate / 2;

        let unrecorded_funding_fee_per_size = safe_mul_div(
            latest_funding_rate,
            _time_delta,
            DAY_SECONDS
        );
        let (funding_fee_per_size, funding_fee_per_size_positive) = signed_plus(
            _prev_funding_fee_per_size,
            _prev_funding_fee_per_size_positive,
            unrecorded_funding_fee_per_size,
            latest_funding_rate_positive
        );
        (funding_fee_per_size, funding_fee_per_size_positive)
    }

    public fun calculate_pmkl_amount(
        size: u64,
        maker_fee: u64,
        taker_fee: u64,
        gear_effect: u64,
    ): u64 {
        // 5 * size * (maker_fee + taker_fee) / 2 * gear_effect
        safe_mul_div(
            safe_mul_div(
                5 * size,
                (maker_fee + taker_fee) / 2,
                MAKER_TAKER_FEE_PRECISION
            ),
            PRECISION + gear_effect,
            PRECISION
        )
    }

    #[test]
    /// Success test calculate new price function
    fun T_calculate_new_price() {
        let new_price =
            calculate_new_price(10000, 20000, 20000, 40000);
        assert!(new_price == 15000, 1);
    }

    #[test]
    /// Success test calculate new price function
    fun T_calculate_new_price_2() {
        let new_price =
            calculate_new_price(10000, 20000, 5000, 20000);
        assert!(new_price == 6666, 1);
    }

    #[test]
    /// Success test calculate total pnl function
    fun T_calculate_total_pnl_long_profit() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 20000, 10000, true);
        assert!(is_profit, 1);
        assert!(total_pnl == 10000, 2);
    }

    #[test]
    /// Success test calculate total pnl function
    fun T_calculate_total_pnl_long_loss() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 5000, 10000, true);
        assert!(!is_profit, 1);
        assert!(total_pnl == 5000, 2);
    }

    #[test]
    /// Success test calculate total pnl function
    fun T_calculate_total_pnl_short_profit() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 5000, 10000, false);
        assert!(is_profit, 1);
        assert!(total_pnl == 5000, 2);
    }

    #[test]
    /// Success test calculate total pnl function
    fun T_calculate_total_pnl_short_loss() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 20000, 10000, false);
        assert!(!is_profit, 1);
        assert!(total_pnl == 10000, 2);
    }

    #[test]
    /// Success test calculate price impact long
    fun T_calculate_price_impact_long() {
        let new_price =
            calculate_price_impact(
                10000,
                600,
                true,
                true,
                0,
                0,
                30000
            );
        assert!(new_price == 10100, 0);

        let new_price =
            calculate_price_impact(
                10000,
                600,
                true,
                true,
                600,
                0,
                30000
            );
        assert!(new_price == 10300, 0);

        let new_price =
            calculate_price_impact(
                10000,
                600,
                true,
                false,
                600,
                0,
                30000
            );
        assert!(new_price == 10100, 1);
    }

    #[test]
    /// Success test calculate price impact short
    fun T_calculate_price_impact_short() {
        let new_price =
            calculate_price_impact(
                10000,
                600,
                false,
                true,
                0,
                0,
                30000
            );
        assert!(new_price == 9900, 0);

        let new_price =
            calculate_price_impact(
                10000,
                600,
                false,
                false,
                0,
                600,
                30000
            );
        assert!(new_price == 9900, 1);
    }

    #[test]
    /// Success test calculate roll-over fee
    fun T_calculate_rollover_fee() {
        let rollover_fee =
            calculate_rollover_fee(
                1 * PRECISION,
                2 * PRECISION,
                20000
            );
        assert!(rollover_fee == 200, 1);
    }

    #[test]
    /// calcuate funding rate test
    fun T_calculate_funding_rate() {
        let (funding_rate, funding_rate_positive) = calculate_funding_rate(
            0,
            true,
            0,
            0,
            3300000000,
            300000000,
            0,
        );
        assert!(funding_rate == 0, 0);
        assert!(funding_rate_positive == true, 0);

        let (funding_rate, funding_rate_positive) = calculate_funding_rate(
            0,
            true,
            200000,
            0,
            3300000000,
            300000000,
            86400,
        );
        assert!(funding_rate == 18181, 0);
        assert!(funding_rate_positive == true, 0);

        let (funding_rate, funding_rate_positive) = calculate_funding_rate(
            18181,
            true,
            0,
            0,
            3300000000,
            300000000,
            3600,
        );
        assert!(funding_rate == 18181, 0);
        assert!(funding_rate_positive == true, 0);

        let (funding_rate, funding_rate_positive) = calculate_funding_rate(
            18181,
            true,
            0,
            200000,
            3300000000,
            300000000,
            7200,
        );
        assert!(funding_rate == 16666, 0);
        assert!(funding_rate_positive == true, 0);

        let (funding_rate, funding_rate_positive) = calculate_funding_rate(
            16666,
            true,
            0,
            600000,
            3300000000,
            300000000,
            43200,
        );
        assert!(funding_rate == 10606, 0);
        assert!(funding_rate_positive == false, 0);
    }

    #[test]
    /// calcuate funding fee per size test
    fun T_calculate_funding_fee_per_size() {
        let (funding_fee_per_size, funding_fee_per_size_positive) = calculate_funding_fee_per_size(
            1500,
            true,
            2000,
            true,
            3000,
            true,
            8640
        );
        assert!(funding_fee_per_size == 1750, 0);
        assert!(funding_fee_per_size_positive == true, 0);

        let (funding_fee_per_size, funding_fee_per_size_positive) = calculate_funding_fee_per_size(
            1500,
            true,
            2000,
            true,
            3000,
            false,
            8640
        );
        assert!(funding_fee_per_size == 1450, 0);
        assert!(funding_fee_per_size_positive == true, 0);

        let (funding_fee_per_size, funding_fee_per_size_positive) = calculate_funding_fee_per_size(
            1500,
            true,
            2000,
            true,
            48000,
            true,
            8640
        );
        assert!(funding_fee_per_size == 4000, 0);
        assert!(funding_fee_per_size_positive == true, 0);

        let (funding_fee_per_size, funding_fee_per_size_positive) = calculate_funding_fee_per_size(
            1500,
            false,
            2000,
            false,
            48000,
            false,
            8640
        );
        assert!(funding_fee_per_size == 4000, 0);
        assert!(funding_fee_per_size_positive == false, 0);
    }

    #[test]
    /// calcuate funding fee per size test
    fun T_calculate_funding_fee() {
        let (funding_fee, is_funding_fee_profit) = calculate_funding_fee(
            4000,
            true,
            1000000,
            true,
            3000,
            true
        );
        assert!(funding_fee == 10, 0);
        assert!(is_funding_fee_profit == false, 0);

        let (funding_fee, is_funding_fee_profit) = calculate_funding_fee(
            2000,
            true,
            1000000,
            true,
            3000,
            true
        );
        assert!(funding_fee == 10, 0);
        assert!(is_funding_fee_profit == true, 0);

        let (funding_fee, is_funding_fee_profit) = calculate_funding_fee(
            2000,
            true,
            1000000,
            true,
            2000,
            true
        );
        assert!(funding_fee == 0, 0);
        assert!(is_funding_fee_profit == false, 0);
    }
    
    #[test]
    fun T_calculate_settle_amount() {
        let (sa, deposit_to_lp)= calculate_settle_amount(
            1000,
            true,
            100,
            true
        );
        assert!(sa == 1100, 0);
        assert!(deposit_to_lp == false, 0);

        (sa, deposit_to_lp)= calculate_settle_amount(
            1000,
            false,
            100,
            true
        );
        assert!(sa == 900, 0);
        assert!(deposit_to_lp == true, 0);

        (sa, deposit_to_lp)= calculate_settle_amount(
            100,
            false,
            1000,
            true
        );
        assert!(sa == 900, 0);
        assert!(deposit_to_lp == false, 0);

        (sa, deposit_to_lp)= calculate_settle_amount(
            100,
            false,
            1000,
            false
        );
        assert!(sa == 1100, 0);
        assert!(deposit_to_lp == true, 0);
    }

    #[test]
    fun T_calculate_new_price_limit_test() {
        let u64_max = 18446744073709551615;
        let r = calculate_new_price(
            10,
            100,
            100,
            100
        );
        assert!(r == 18, 0);
        r = calculate_new_price(
            u64_max,
            u64_max,
            u64_max,
            u64_max
        );
        assert!(r == u64_max, 0);
        r = calculate_new_price(
            10,
            100,
            20,
            100
        );
        assert!(r == 13, 0);
    }

}
