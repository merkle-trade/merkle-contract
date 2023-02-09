module merkle::limit_order_table {

    // Uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    use aptos_std::table;
    use std::vector;

    // Uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Error messages >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// When indicated 'pair info' already exist
    const KEY_NOT_IN_TABLE: u64 = 0;

    // Error messages <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Structs >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Extended version of `aptos_framework::table` with vector value
    struct LimitOrderTable<ORDER> has store {
        map: table::Table<u64, vector<ORDER>>,
    }

    // Structs <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Return an empty `LimitOrderTable`
    public fun empty<ORDER: store>():
    LimitOrderTable<ORDER> {
        LimitOrderTable { map: table::new() }
    }

    /// Push `order` to `limit_order_table`
    /// If key not in table, create vector.
    public fun push<ORDER>(
        _order_table: &mut LimitOrderTable<ORDER>,
        _price: u64,
        _order: ORDER
    ) {
        if (!table::contains(&mut _order_table.map, _price)) {
            let order_vector = vector::empty();
            vector::push_back(&mut order_vector, _order);
            table::add(&mut _order_table.map, _price, order_vector);
        } else {
            vector::push_back(table::borrow_mut(&mut _order_table.map, _price), _order);
        } ;
    }

    /// Pop `order` to `limit_order_table`
    /// Abort if key not in table.
    public fun pop<ORDER>(
        _order_table: &mut LimitOrderTable<ORDER>,
        _price: u64,
    ): ORDER {
        assert!(table::contains(&_order_table.map, _price), KEY_NOT_IN_TABLE);
        vector::pop_back(table::borrow_mut(&mut _order_table.map, _price))
    }

    /// Pop multiple `order` to `limit_order_table`
    /// Abort if key not in table.
    public fun multiple_pop<ORDER>(
        _order_table: &mut LimitOrderTable<ORDER>,
        _price: u64,
        _max_size: u64
    ): vector<ORDER> {
        assert!(table::contains(&_order_table.map, _price), KEY_NOT_IN_TABLE);
        let order_vector_ref_mut = table::borrow_mut(&mut _order_table.map, _price);
        let length = vector::length(order_vector_ref_mut);
        let pop_count =
            if (_max_size <= length) { _max_size }
            else { vector::length(order_vector_ref_mut) };
        let pop_order_vector = vector::empty();
        while (pop_count > 0) {
            vector::push_back(&mut pop_order_vector, vector::pop_back(order_vector_ref_mut));
            pop_count = pop_count - 1;
        };
        pop_order_vector
    }

    /// Return `true` if `key` in `limit_order_table`, otherwise `false`
    public fun contains<ORDER>(
        limit_order_table: &LimitOrderTable<ORDER>,
        key: u64
    ): bool {
        // Return if key in base table
        table::contains(&limit_order_table.map, key)
    }

    // Public functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Tests >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    struct TEST_ORDER has store, drop {
        test_value: u8
    }

    #[test]
    /// Verify push
    public entry fun push_test():
    LimitOrderTable<TEST_ORDER> {
        let limit_order_table = empty<TEST_ORDER>();
        assert!(!contains(&limit_order_table, 100), 0);

        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 5 });
        assert!(contains(&limit_order_table, 100), 0);

        limit_order_table
    }

    #[test]
    /// Verify pop
    public entry fun pop_test():
    LimitOrderTable<TEST_ORDER> {
        let limit_order_table = empty<TEST_ORDER>();
        assert!(!contains(&limit_order_table, 100), 0);

        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 1 });
        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 2 });
        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 3 });
        assert!(contains(&limit_order_table, 100), 0);

        let test_order = pop<TEST_ORDER>(&mut limit_order_table, 100);
        assert!(test_order.test_value == 3, 0);

        limit_order_table
    }

    #[test]
    /// Verify multiple pop
    public entry fun multiple_pop_test():
    LimitOrderTable<TEST_ORDER> {
        let limit_order_table = empty<TEST_ORDER>();
        assert!(!contains(&limit_order_table, 100), 0);

        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 1 });
        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 2 });
        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 3 });
        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 4 });
        push<TEST_ORDER>(&mut limit_order_table, 100, TEST_ORDER { test_value: 5 });
        assert!(contains(&limit_order_table, 100), 0);

        let test_order = multiple_pop<TEST_ORDER>(&mut limit_order_table, 100, 3);
        assert!(vector::contains(&mut test_order, &TEST_ORDER { test_value: 5 }), 0);
        assert!(vector::length(&mut test_order) == 3, 0);

        let test_order2 = multiple_pop<TEST_ORDER>(&mut limit_order_table, 100, 3);
        assert!(vector::length(&mut test_order2) == 2, 0);
        limit_order_table
    }
    // Tests <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
}