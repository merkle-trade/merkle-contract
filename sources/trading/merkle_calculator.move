module merkle::merkle_calculator {

    // <-- CONSTANT ----->

    use merkle::safe_math_u64::safe_mul_div;

    const PRECISION: u64 = 100 * 10000;

    // <-- PRICE ----->

    /// Calculate new price
    public fun calculate_new_price(
        _original_price: u64,
        _original_size: u64,
        _new_price: u64,
        _size_delta: u64
    ): u64 {
        if (_original_size == 0) { return _new_price };
        (_original_size + _size_delta) * PRECISION
            / ((_original_size * PRECISION / _original_price)
            + (_size_delta * PRECISION / _new_price))
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

    // <-- FEE ----->

    /// Calculate price after price-impact
    public fun calculate_price_impact(
        _price: u64,
        _current_open_interest: u64,
        _trade_open_interest: u64,
        _market_depth: u64,
        _is_long: bool
    ): (u64, u64) {
        if (_market_depth == 0) {
            return (0, _price)
        };

        let price_impact_percent =
            safe_mul_div((_current_open_interest + _trade_open_interest), PRECISION, _market_depth);

        let price_impact = safe_mul_div(price_impact_percent, _price, PRECISION) / 100;

        let price_after_impact = if (_is_long) { _price + price_impact } else { _price - price_impact };

        (price_impact, price_after_impact)
    }

    /// Calculate price apply spread
    public fun calculate_price_after_spread(
        _price: u64,
        _spread: u64,
        _is_long: bool
    ): u64 {
        if (_is_long) {
            safe_mul_div(_price, (PRECISION + _spread), PRECISION)
        } else {
            safe_mul_div(_price, (PRECISION - _spread), PRECISION)
        }
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
        (_exit_acc_rollover_fee_per_collateral - _entry_acc_rollover_fee_per_collateral) * _collateral_amount / PRECISION
    }

    /// Calculate roll-over fee
    public fun calculate_rollover_fee_delta(
        _entry_timestamp: u64,
        _exit_timestamp: u64,
        _funding_fee_per_block: u64
    ): u64 {
        (_exit_timestamp - _entry_timestamp) * _funding_fee_per_block / PRECISION
    }

    /// Calculate funding fee
    public fun calculate_funding_fee(
        _entry_acc_funding_fee_per_interest: u64,
        _exit_acc_funding_fee_per_interest: u64,
        _size: u64
    ): (u64, bool) {
        if (_size == 0) {
            return (0, true)
        };
        let fee: u64;
        let is_profit: bool;
        if (_exit_acc_funding_fee_per_interest > _entry_acc_funding_fee_per_interest) {
            assert!(false, _entry_acc_funding_fee_per_interest);
            fee = safe_mul_div(
                _exit_acc_funding_fee_per_interest - _entry_acc_funding_fee_per_interest,
                _size,
                PRECISION
            );
            is_profit = false;
        } else {
            fee = safe_mul_div(
                _entry_acc_funding_fee_per_interest - _exit_acc_funding_fee_per_interest,
                _size,
                PRECISION
            );
            is_profit = true;
        };
        (fee, is_profit)
    }

    /// Calculate funding rate delta
    public fun calculate_funding_rate_delta(
        _long_open_interest: u64,
        _short_open_interest: u64,
        _start_timestamp: u64,
        _end_timestamp: u64,
        _funding_fee_per_timestamp: u64
    ): (u64, u64, bool) {
        let interest_gap;
        let long_to_short: bool;
        if (_long_open_interest > _short_open_interest) {
            interest_gap = _long_open_interest - _short_open_interest;
            long_to_short = true;
        } else {
            interest_gap = _short_open_interest - _long_open_interest;
            long_to_short = false;
        };

        let funding_fee_delta = interest_gap
            * (_end_timestamp - _start_timestamp)
            * _funding_fee_per_timestamp
            / PRECISION
            / 100;

        let long_delta = 0;
        let short_delta = 0;
        if (_long_open_interest > 0) {
            long_delta = funding_fee_delta * PRECISION / _long_open_interest;
        };

        if (_short_open_interest > 0) {
            short_delta = funding_fee_delta * PRECISION / _short_open_interest;
        };

        (long_delta, short_delta, long_to_short)
    }

    #[test]
    /// Success test calculate new price function
    public entry fun T_calculate_new_price() {
        let new_price =
            calculate_new_price(10000, 20000, 20000, 40000);
        assert!(new_price == 15000, 1);
    }

    #[test]
    /// Success test calculate new price function
    public entry fun T_calculate_new_price_2() {
        let new_price =
            calculate_new_price(10000, 20000, 5000, 20000);
        assert!(new_price == 6666, 1);
    }

    #[test]
    /// Success test calculate total pnl function
    public entry fun T_calculate_total_pnl_long_profit() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 20000, 10000, true);
        assert!(is_profit, 1);
        assert!(total_pnl == 10000, 2);
    }

    #[test]
    /// Success test calculate total pnl function
    public entry fun T_calculate_total_pnl_long_loss() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 5000, 10000, true);
        assert!(!is_profit, 1);
        assert!(total_pnl == 5000, 2);
    }

    #[test]
    /// Success test calculate total pnl function
    public entry fun T_calculate_total_pnl_short_profit() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 5000, 10000, false);
        assert!(is_profit, 1);
        assert!(total_pnl == 5000, 2);
    }

    #[test]
    /// Success test calculate total pnl function
    public entry fun T_calculate_total_pnl_short_loss() {
        let (total_pnl, is_profit) =
            calculate_pnl_without_fee(10000, 20000, 10000, false);
        assert!(!is_profit, 1);
        assert!(total_pnl == 10000, 2);
    }

    #[test]
    /// Success test calculate price impact long
    public entry fun T_calculate_price_impact_long() {
        let (price_impact, new_price) =
            calculate_price_impact(
                10000,
                20000,
                20000,
                40000,
                true
            );
        assert!(new_price == 10100, 1);
        assert!(price_impact == 100, 2);
    }

    #[test]
    /// Success test calculate price impact short
    public entry fun T_calculate_price_impact_short() {
        let (price_impact, new_price) =
            calculate_price_impact(
                10000,
                20000,
                20000,
                40000,
                false
            );
        assert!(new_price == 9900, 1);
        assert!(price_impact == 100, 2);
    }

    #[test]
    /// Success test calculate roll-over fee
    public entry fun T_calculate_rollover_fee() {
        let rollover_fee =
            calculate_rollover_fee(
                1 * PRECISION,
                2 * PRECISION,
                20000
            );
        assert!(rollover_fee == 20000, 1);
    }

    #[test]
    /// Success test calculate funding rate delta
    public entry fun T_calculate_funding_rate_delta_same_interest() {
        let (long_delta, short_delta, _) =
            calculate_funding_rate_delta(
                10000,
                10000,
                20000,
                30000,
                5
            );
        assert!(long_delta == 0, 1);
        assert!(short_delta == 0, 2);
    }

    #[test]
    /// Success test calculate funding rate delta
    public entry fun T_calculate_funding_rate_delta_long_to_short() {
        let (long_delta, short_delta, _) =
            calculate_funding_rate_delta(
                10000 * PRECISION,
                20000 * PRECISION,
                20000,
                30000,
                5
            );
        assert!(long_delta == 500, 1);
        assert!(short_delta == 250, 2);
    }
}
