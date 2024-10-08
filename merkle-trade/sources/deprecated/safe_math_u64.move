module merkle::safe_math_u64 {
    ///
    ///
    ///
    /// [Deprecated Module]
    ///
    /// Don't use this module anymore
    ///


    const EXP_SCALE_9: u64 = 1000000000;// e9
    const EXP_SCALE_10: u64 = 10000000000;// e10
    const EXP_SCALE_18: u64 = 1000000000000000000;// e18
    const U64_MAX:u64 = 18446744073709551615;  //length(U64_MAX)==20
    const U128_MAX:u128 = 340282366920938463463374607431768211455;  //length(U128_MAX)==39
    const U256_MAX: u256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935; // length(U256_MAX)==78

    const SCALAR: u64 = 1 << 16;
    const ROUNDING_UP: u8 = 0; // Toward infinity

    const EQUAL: u8 = 0;
    const LESS_THAN: u8 = 1;
    const GREATER_THAN: u8 = 2;

    const OVER_FLOW: u64 = 1001;
    const DIVIDE_BY_ZERO: u64 = 1002;

    /// @dev Returns the largest of two numbers.
    public fun max(a: u64, b: u64): u64 {
        if (a >= b) a else b
    }

    /// @dev Returns the smallest of two numbers.
    public fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    /// |a - b|
    public fun diff(a: u64, b: u64): u64 {
        max(a, b) - min(a, b)
    }

    #[deprecated]
    public fun abs(_a: u64, _b: u64): u64 {
        0
    }

    /// @dev Returns a to the power of b.
    public fun exp(a: u64, b: u64): u64 {
        let c = 1;

        while (b > 0) {
            if (b & 1 > 0) c = c * a;
            b = b >> 1;
            a = a * a;
        };
        c
    }

    /// x * y / z
    public fun safe_mul_div(x: u64, y: u64, z: u64): u64 {
        if ( z == 0) {
            abort DIVIDE_BY_ZERO
        };
        (((x as u256) * (y as u256) / (z as u256)) as u64)
    }

    /// calculate signed a + b
    public fun signed_plus(a: u64, a_sign: bool, b: u64, b_sign: bool): (u64, bool) {
        if (a_sign == b_sign) {
            return ((a + b), a_sign)
        };
        let result = diff(a, b);
        let result_sign = if (a >= b) { a_sign } else { b_sign };
        (result, result_sign)
    }

    #[test]
    #[expected_failure(abort_code = DIVIDE_BY_ZERO, location = Self)]
    fun T_safe_mul_div() {
        safe_mul_div(3, 4, 0);
    }
}

