module merkle::decimals {
    use merkle::math_u64;
    const BASIS_POINTS_DIVISOR: u128 = 10000;

    // change u64 -> u128
    public fun multiply_with_decimals(num1: u64, num2: u64, num1Decimal: u8, num2Decimal: u8, toDecimal: u8): u64 {
        let a = (num1 as u128);
        let b = a * (num2 as u128);
        let c = b / (math_u64::exp(10, (num1Decimal as u64)) as u128);
        let d = c * BASIS_POINTS_DIVISOR;
        let e = d / (math_u64::exp(10, (num2Decimal as u64)) as u128);
        let f = e * (math_u64::exp(10, (toDecimal as u64)) as u128);
        ((f / BASIS_POINTS_DIVISOR) as u64)
    }

    public fun divide_with_decimals(num1: u64, num2: u64, num1Decimal: u8, num2Decimal: u8, toDecimal: u8): u64 {
        // num1 / num2 -> result with toDecimal decimals
        let a = (num1 as u128);
        let b = a * BASIS_POINTS_DIVISOR;
        let c = b / (num2 as u128);
        let d = c * (math_u64::exp(10, (toDecimal as u64)) as u128);
        let e = d / (math_u64::exp(10, (num1Decimal as u64)) as u128);
        let f = e * (math_u64::exp(10, (num2Decimal as u64)) as u128);
        ((f / BASIS_POINTS_DIVISOR) as u64)
    }

    public fun change_decimals(num: u64, fromDecimal: u8, toDecimal: u8): u64 {
        if (fromDecimal > toDecimal) return num / math_u64::exp(10, (fromDecimal - toDecimal as u64))
        else if (fromDecimal < toDecimal) return num * math_u64::exp(10, (toDecimal - fromDecimal as u64))
        else num
    }

    #[test]
    public fun tests_decimals() {
        let mul = multiply_with_decimals(1000000, 2000, 5, 3, 4);
        assert!(mul == 200000, 0);
        let div = divide_with_decimals(1000000, 2000, 5, 3, 4);
        assert!(div == 50000, 1);
        mul = multiply_with_decimals(1000000, 200000, 5, 5, 5);
        assert!(mul == 2000000, 2);
        div = divide_with_decimals(1000000, 200000, 5, 5, 5);
        assert!(div == 500000, 3);

        let decimal_change = change_decimals(1000, 3, 6);
        assert!(decimal_change == 1000000, 4);
    }
}