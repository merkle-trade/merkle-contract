module merkle::trading {

    // <-- USE ----->
    use std::signer::address_of;
    use std::vector;

    use aptos_std::table;
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::event::{Self, EventHandle};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::account::new_event_handle;

    use merkle::price_oracle;
    use merkle::merkle_calculator;
    use merkle::distributor;
    use merkle::house_lp;
    use merkle::math::min;
    use merkle::math_u64;
    use merkle::safe_math_u64::safe_mul_div;
    use merkle::merkle_calculator::calculate_settle_amount;

    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::aptos_account;

    // <-- PRECISION ----->

    /// opening_fee = 10000 => 1%
    const ENTRY_EXIT_FEE_PRECISION: u64 = 100 * 10000;
    /// interest_precision 10000 => 1%
    const INTEREST_PRECISION: u64 = 100 * 10000;
    /// leverage_precision 10000 => 1%
    const LEVERAGE_PRECISION: u64 = 100 * 10000;
    /// basis point 1e4 => 1
    const BASIS_POINT: u64 = 10000;

    // <-- ERROR CODE ----->

    /// When indicated 'pair info' already exist
    const E_PAIR_ALREDY_EXIST: u64 = 0;
    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When indicated `pair` does not exist
    const E_PAIR_NOT_EXIST: u64 = 2;
    /// When indicated limit price is 0
    const E_PRICE_0: u64 = 3;
    /// When indicated leverege under minimum
    const E_UNDER_MINIMUM_LEVEREAGE: u64 = 4;
    /// When indicated leverege over maximum
    const E_OVER_MAXIMUM_LEVEREAGE: u64 = 5;
    /// When indicated `order` does not exist
    const E_ORDER_NOT_EXIST: u64 = 6;
    /// When indicated order's long/short is not same with an existing position
    const E_COLLIDE_WITH_EXISTING_POSITION: u64 = 7;
    /// When indicated `collateral` is zero
    const E_ZERO_COLLATERAL: u64 = 9;
    /// When indicated `delta` is zero
    const E_ZERO_COLLATERAL_DELTA: u64 = 10;
    /// When indicated 'order' is not market order
    const E_NOT_MARKET_ORDER: u64 = 11;
    /// When indicated 'order' is not limit order
    const E_NOT_LIMIT_ORDER: u64 = 12;
    /// When indicated 'order' is not increase order
    const E_NOT_INCREASE_ORDER: u64 = 13;
    /// When indicated 'order' is not decrease order
    const E_NOT_DECREASE_ORDER: u64 = 13;
    /// When indicated 'order' is not over trigger price
    const E_UNEXECUTABLE_PRICE_LIMIT_ORDER: u64 = 14;
    /// When indicated `position` does not exist
    const E_POSITION_NOT_EXIST: u64 = 15;
    /// When indicated `pair` is paused by owner
    const E_PAUSED_PAIR: u64 = 16;
    /// When indicated 'order' is invalid
    const E_INVALID_LIMIT_ORDER: u64 = 17;
    /// When indicated open interest over max interest
    const E_OVER_MAXIMUM_INTEREST: u64 = 18;
    /// When indicated not over 'take-profit / stop-loss / liquidate' threshold
    const E_NOT_OVER_THRESHOLD: u64 = 19;
    /// When indicated executor is not position owner
    const E_NOT_POSITION_OWNER: u64 = 20;
    /// When indicated order's create time is not over
    const E_NOT_OVER_KEEPER_TIME: u64 = 21;
    /// When indicated `delta` is not zero
    const E_NOT_ZERO_COLLATERAL_DELTA: u64 = 22;

    /// <-- ORDER TYPE FLAG ----->

    /// Flag for `OrderEvnet.type` when order is palced.
    const PLACE: u8 = 0;
    /// Flag for `OrderEvent.type` when order is cancelled.
    const CANCEL: u8 = 1;

    /// <-- STRUCT ----->

    /// Order info for UserStates
    struct OrderKey has store, drop, copy {
        pair_type: TypeInfo,
        collateral_type: TypeInfo,
        order_id: u64,
    }

    /// Position pair collateral long info for UserStates
    struct UserPositionKey has store, drop, copy {
        pair_type: TypeInfo,
        collateral_type: TypeInfo,
        is_long: bool
    }

    /// USER STATES for current open order, positions
    struct UserStates has key {
        /// open order ids
        order_keys: vector<OrderKey>,
        /// open positions
        user_position_keys: vector<UserPositionKey>,
    }

    /// ORDER
    struct Order has store {
        /// Address of order owner.
        user: address,
        /// Increasing/Decreasing size of order.
        size_delta: u64,
        /// Increasing/Decreasing collateral of order.
        collateral_delta: u64,
        /// Order requested price.
        /// If market-order, this price is the allowable price including slippage.
        price: u64,
        /// Flag whether order is long.
        is_long: bool,
        /// Flag whether order is increase.
        is_increase: bool,
        /// Flag whether order is market-order.
        is_market: bool,
        /// Flag whether order can execute above oracle price.
        can_execute_above_price: bool,
        /// Stop-loss trigger price.
        stop_loss_trigger_price: u64,
        /// Take-profit trigger price.
        take_profit_trigger_price: u64,
        /// Time the order was created.
        created_timestamp: u64
    }

    struct Position has store {
        /// Total position size.
        size: u64,
        /// The remaining amount of collateral.
        collateral: u64,
        /// An average price.
        avg_price: u64,
        /// Last execute / fee accrue timestamp.
        last_execute_timestamp: u64,
        /// Accumulative rollover fee per collateral when position last execute.
        acc_rollover_fee_per_collateral: u64,
        /// Accumulative funding fee per open interest when position last execute.
        acc_funding_fee_per_open_interest: u64,
        /// Stop-loss trigger price.
        stop_loss_trigger_price: u64,
        /// Take-profit trigger price.
        take_profit_trigger_price: u64
    }

    /// Offchain set states
    struct PairInfo<phantom PairType, phantom CollateralType> has key, store {
        /// Flag whether pair is paused.
        paused: bool,
        /// Minimum leverage of pair.
        min_leverage: u64,
        /// Maximum leverage of pair.
        max_leverage: u64,
        /// Entry/exit fee. 1000000 => 100%
        entry_exit_fee: u64,
        /// Funding fee per timestamp. (1e6 => 1)
        funding_fee_per_timestamp: u64,
        /// Rollover fee per timestamp. (1e6 => 1)
        rollover_fee_per_timestamp: u64,
        /// Spread. 1000000 => 100%
        spread: u64,
        /// Maximum open interest of this pair.
        max_open_interest: u64,
        /// market above depth of offchain exchange. It's for price-impact.
        market_depth_above: u64,
        /// market below depth of offchain exchange. It's for price-impact.
        market_depth_below: u64,
        /// Execute cool-time.
        execute_time_limit: u64,
        /// Threshold for liquidate, basis point 10000 => 100%
        liquidate_threshold: u64,
        /// Maximum profit basis point 90000 -> 900%
        maximum_profit: u64,
    }

    /// Onchain variable states
    struct PairState<phantom PairType, phantom CollateralType> has key, store {
        /// Incremental idx of order.
        next_order_id: u64,
        /// Total open interest of long positions.
        long_open_interest: u64,
        /// Total open interest of short positions.
        short_open_interest: u64,
        /// Accumulative funding fee per long open interest.
        long_acc_funding_fee_per_open_interest: u64,
        /// Accumulative funding fee per short open interest.
        short_acc_funding_fee_per_open_interest: u64,
        /// Accumulative rollover fee per collateral.
        acc_rollover_fee_per_collateral: u64,
        /// Last accrue timestamp.
        last_accrue_timestamp: u64,

        /// Mapping order_id to Order.
        orders: table::Table<u64, Order>,

        /// Mapping user address to long Position.
        long_positions: table::Table<address, Position>,
        /// Mapping user address to short Position.
        short_positions: table::Table<address, Position>
    }

    /// whole events in trading for merkle
    struct TradingEvents has key {
        /// Event handle for place order events.
        place_order_events: EventHandle<PlaceOrderEvent>,
        /// Event handle for cancel order events.
        cancel_order_events: EventHandle<CancelOrderEvent>,
        /// Event handle for position events.
        position_events: EventHandle<PositionEvent>
    }

    /// this struct will be move to user for events
    struct UserTradingEvents has key {
        /// Event handle for place order events.
        place_order_events: EventHandle<PlaceOrderEvent>,
        /// Event handle for cancel order events.
        cancel_order_events: EventHandle<CancelOrderEvent>,
        /// Event handle for position events.
        position_events: EventHandle<PositionEvent>
    }

    /// Emitted when a order place/cancel.
    struct PlaceOrderEvent has copy, drop, store {
        /// pair type of order
        pair_type: TypeInfo,
        /// collateral type of order
        collateral_type: TypeInfo,
        /// Address of order owner.
        user: address,
        /// Order ID.
        order_id: u64,
        /// Increasing/Decreasing size of order.
        size_delta: u64,
        /// Increasing/Decreasing collateral of order.
        collateral_delta: u64,
        /// Order requested price.
        price: u64,
        /// Flag whether order is long.
        is_long: bool,
        /// Flag whether order is increase.
        is_increase: bool,
        /// Flag whether order is market-order.
        is_market: bool
    }

    /// Emitted when a order place/cancel.
    struct CancelOrderEvent has copy, drop, store {
        /// pair type of order
        pair_type: TypeInfo,
        /// collateral type of order
        collateral_type: TypeInfo,
        /// Order ID.
        order_id: u64
    }

    /// Emitted when a position state change.
    /// ex) order fills / liquidate / stop-loss...
    struct PositionEvent has copy, drop, store {
        /// pair type of position
        pair_type: TypeInfo,
        /// collateral type of position
        collateral_type: TypeInfo,
        /// Address of position owner.
        user: address,
        /// Order ID. If no order execution, zero.
        order_id: u64,
        /// Flag whether position is long.
        is_long: bool,
        /// Execution price.
        price: u64,
        /// size delta
        size_delta: u64,
        /// collateral delta
        collateral_delta: u64,
        /// is increase or decrease
        is_increase: bool,
        /// is partial or open(close)
        is_partial: bool,
        /// amount of pnl without fee
        pnl_without_fee: u64,
        /// is profit or loss
        is_profit: bool,
        /// entry or exit fee
        entry_exit_fee: u64,
        /// funding fee
        funding_fee: u64,
        /// is funding fee profit
        is_funding_fee_profit: bool,
        /// rollover fee
        rollover_fee: u64
    }

    struct CollateralBox<phantom PairType, phantom CollateralType> has key {
        balance: Coin<CollateralType>
    }

    /// Capability required to execute order.
    struct ExecuteCapability<phantom CoinType, phantom CollateralType> has copy, store, drop {}

    /// Capability required to call admin function.
    struct AdminCapability<phantom CoinType, phantom CollateralType> has copy, store, drop {}

    // <-- PAIR FUNCTION ----->

    /// Initialize trading pair
    /// @Parameters
    /// _host: Signer & host of this module
    /// _min_leverage: Minimum leverage of position
    /// _max_leverage: Maximum leverage of position
    /// _fee: Entry / Exit fee
    /// _max_interest: Maximum interest of this pair
    public entry fun initialize<PairType, CollateralType>(
        _host: &signer
    ): (ExecuteCapability<PairType, CollateralType>, AdminCapability<PairType, CollateralType>) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        assert!(!exists<PairInfo<PairType, CollateralType>>(@merkle), E_PAIR_ALREDY_EXIST);
        move_to(
            _host,
            PairInfo<PairType, CollateralType> {
                paused: false,
                min_leverage: 0,
                max_leverage: 0,
                entry_exit_fee: 0,
                funding_fee_per_timestamp: 0,
                rollover_fee_per_timestamp: 0,
                max_open_interest: 0,
                market_depth_above: 100000 * 100000,
                market_depth_below: 100000 * 100000,
                spread: 0,
                execute_time_limit: 300,
                liquidate_threshold: 100,
                maximum_profit: 90000,
            });
        move_to(
            _host,
            PairState<PairType, CollateralType> {
                next_order_id: 1,
                long_open_interest: 0,
                short_open_interest: 0,
                long_acc_funding_fee_per_open_interest: math_u64::u64_max() / 2,
                short_acc_funding_fee_per_open_interest: math_u64::u64_max() / 2,
                acc_rollover_fee_per_collateral: 0,
                orders: table::new(),
                long_positions: table::new(),
                short_positions: table::new(),
                last_accrue_timestamp: timestamp::now_seconds()
            }
        );
        if (!exists<TradingEvents>(address_of(_host))) {
            move_to(_host, TradingEvents {
                place_order_events: new_event_handle<PlaceOrderEvent>(_host),
                cancel_order_events: new_event_handle<CancelOrderEvent>(_host),
                position_events: new_event_handle<PositionEvent>(_host),
            })
        };
        move_to(
            _host,
            CollateralBox<PairType, CollateralType> {
                balance: coin::zero()
            });
        (ExecuteCapability<PairType, CollateralType> {}, AdminCapability<PairType, CollateralType> {})
    }

    // <-- COLLATERAL FUNCTION ----->

    /// Deposit marfin to box.
    fun deposit_collateral_internal<PairType, CollateralType>(
        _coin: Coin<CollateralType>
    ) acquires CollateralBox {
        // Borrow collateral
        let collateral_box_ref_mut =
            borrow_global_mut<CollateralBox<PairType, CollateralType>>(@merkle);
        coin::merge(&mut collateral_box_ref_mut.balance, _coin);
    }

    /// Withdraw collateral from box.
    fun withdraw_collateral_internal<PairType, CollateralType>(
        _collateral_delta: u64
    ): Coin<CollateralType>
    acquires CollateralBox {
        // return if no collateral
        if (_collateral_delta == 0) { () };

        // Borrow collateral
        let collateral_box_balance_ref_mut =
            &mut borrow_global_mut<CollateralBox<PairType, CollateralType>>(@merkle).balance;

        coin::extract(collateral_box_balance_ref_mut, _collateral_delta)
    }

    // <-- ORDER FUNCTION ----->

    /// Place market/limit-order.
    /// @Parameters
    /// _user: Signer & order owner
    /// _order_info: Order info with states
    public entry fun place_order<
        PairType,
        CollateralType
    >(
        _user: &signer,
        _size_delta: u64,
        _collateral_delta: u64,
        _price: u64,
        _is_long: bool,
        _is_increase: bool,
        _is_market: bool,
        _stop_loss_trigger_price: u64,
        _take_profit_trigger_price: u64,
        _can_execute_above_price: bool
    ) acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // Borrow Pair states
        assert!(exists<PairInfo<PairType, CollateralType>>(@merkle), E_PAIR_NOT_EXIST);
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);
        if (!exists<UserTradingEvents>(address_of(_user))) {
            move_to(_user, UserTradingEvents {
                place_order_events: new_event_handle<PlaceOrderEvent>(_user),
                cancel_order_events: new_event_handle<CancelOrderEvent>(_user),
                position_events: new_event_handle<PositionEvent>(_user),
            });
        };

        deposit_collateral_internal<PairType, CollateralType>(coin::withdraw(_user, _collateral_delta));

        // Create new order
        let order = Order {
            user: address_of(_user),
            size_delta: _size_delta,
            collateral_delta: _collateral_delta,
            price: _price,
            is_long: _is_long,
            is_increase: _is_increase,
            is_market: _is_market,
            stop_loss_trigger_price: _stop_loss_trigger_price,
            take_profit_trigger_price: _take_profit_trigger_price,
            can_execute_above_price: _can_execute_above_price,
            created_timestamp: timestamp::now_seconds()
        };

        validate_order<PairType, CollateralType>(
            &order,
            pair_info
        );

        // Store order to table
        table::add(&mut pair_state.orders, pair_state.next_order_id, order);
        add_order_id_to_user_states(_user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), pair_state.next_order_id);
        pair_state.next_order_id = pair_state.next_order_id + 1;

        // Emit order event
        let place_order_event = PlaceOrderEvent {
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            user: address_of(_user),
            order_id: pair_state.next_order_id - 1,
            size_delta: _size_delta,
            collateral_delta: _collateral_delta,
            price: _price,
            is_long: _is_long,
            is_increase: _is_increase,
            is_market: _is_market,
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).place_order_events, place_order_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(address_of(_user)).place_order_events, place_order_event);
    }

    /// Cancel market/limit-order.
    /// @Parameters
    /// _user: Signer & order owner.
    /// _order_id: Index of order to cancel
    public entry fun cancel_order<
        PairType,
        CollateralType
    >(
        _user: &signer,
        _order_id: u64
    ) acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);

        assert!(table::contains(&mut pair_state.orders, _order_id), E_ORDER_NOT_EXIST);
        let cancelled_order = table::remove(&mut pair_state.orders, _order_id);

        assert!(cancelled_order.user == address_of(_user), E_NOT_AUTHORIZED);
        cancel_order_internal<PairType, CollateralType>(
            _order_id,
            cancelled_order
        );
    }

    /// Cancel order.
    fun cancel_order_internal<
        PairType,
        CollateralType
    >(
        _order_id: u64,
        _order: Order
    ) acquires CollateralBox, TradingEvents, UserTradingEvents, UserStates {
        let withdrawed_coin = withdraw_collateral_internal<PairType, CollateralType>(
            _order.collateral_delta
        );

        coin::deposit(_order.user, withdrawed_coin);

        // Emit cancel order event
        let cancel_order_event = CancelOrderEvent {
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            order_id: _order_id
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).cancel_order_events, cancel_order_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(_order.user).cancel_order_events, cancel_order_event);

        remove_order_id_from_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order_id);
        drop_order(_order);
    }

    /// Validate a order.
    fun validate_order<PairType, CollateralType>(
        _order: &Order,
        _pair_info: &PairInfo<PairType, CollateralType>,
    ) {
        // Verify price not 0
        assert!(_order.price != 0, E_PRICE_0);

        // Validate leverage if decrease order
        if (!_order.is_increase) {
            assert!(_order.collateral_delta == 0, E_NOT_ZERO_COLLATERAL_DELTA);
            return
        };

        // Validate leverage if increase order
        assert!(_order.collateral_delta > 0, E_ZERO_COLLATERAL_DELTA);
        assert!(
            safe_mul_div(_order.size_delta, LEVERAGE_PRECISION, _order.collateral_delta)
                >= _pair_info.min_leverage,
            E_UNDER_MINIMUM_LEVEREAGE
        );
        assert!(
            safe_mul_div(_order.size_delta, LEVERAGE_PRECISION, _order.collateral_delta)
                <= _pair_info.max_leverage,
            E_OVER_MAXIMUM_LEVEREAGE
        );
    }

    /// Drop order.
    fun drop_order(order: Order) {
        let Order {
            user: _,
            size_delta: _,
            collateral_delta: _,
            price: _,
            is_long: _,
            is_increase: _,
            is_market: _,
            stop_loss_trigger_price: _,
            take_profit_trigger_price: _,
            can_execute_above_price: _,
            created_timestamp: _
        } = order;
    }


    // <-- POSITION FUNCTION ----->

    /// Execute order function.
    /// @Parameters
    /// _executor: Executor of the order, not position owner. This address can take execute fee.
    /// _order_id: Index of order to execute.
    /// _fast_price: Reference price
    /// _cap: Executor capapbility
    public fun execute_order<
        PairType,
        CollateralType
    >(
        _executor: &signer,
        _order_id: u64,
        _fast_price: u64,
        _cap: &ExecuteCapability<PairType, CollateralType>
    ) acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // Borrow trading pair info
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);

        // Get order by id
        assert!(table::contains(&mut pair_state.orders, _order_id), E_ORDER_NOT_EXIST);
        let order = table::remove(&mut pair_state.orders, _order_id);

        // Accrue rollover/funding fee
        accrue<PairType, CollateralType>(pair_info, pair_state);

        // Update oracle price
        price_oracle::update_with_type<PairType>(_executor, _fast_price);

        // Read oracle price & Execute increase/decrease order
        if (order.is_increase) {
            execute_increase_order_internal<PairType, CollateralType>(
                pair_info,
                pair_state,
                price_oracle::read_with_type<PairType>(order.is_long),
                _order_id,
                order
            )
        } else {
            execute_decrease_order_internal<PairType, CollateralType>(
                pair_info,
                pair_state,
                price_oracle::read_with_type<PairType>(!order.is_long),
                _order_id,
                order
            )
        }
    }

    /// Execute take-profit or stop_loss or liquidate function.
    /// @Parameters
    /// _executor: Executor of the order, not position owner. This address can take execute fee.
    /// _user: Address of position owner
    /// _is_long: Flag wheter order is long
    /// _fast_price: Reference price
    /// _cap: Executor capapbility
    public fun execute_exit_position<
        PairType,
        CollateralType
    >(
        _executor: &signer,
        _user: address,
        _is_long: bool,
        _fast_price: u64,
        _cap: &ExecuteCapability<PairType, CollateralType>
    ) acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // Borrow trading pair info
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);

        // Accrue rollover/funding fee
        accrue<PairType, CollateralType>(pair_info, pair_state);

        // Update & read oracle price
        price_oracle::update_with_type<PairType>(_executor, _fast_price);
        let price = price_oracle::read_with_type<PairType>(!_is_long);

        // Get Order owner's position.
        // Revert if not exist.
        let position_ref_mut: &mut Position;
        {
            let positions_ref_mut =
                if (_is_long) { &mut pair_state.long_positions }
                else { &mut pair_state.short_positions };
            assert!(table::contains(positions_ref_mut, _user), E_POSITION_NOT_EXIST);
            position_ref_mut = table::borrow_mut(positions_ref_mut, _user);
        };

        let original_size = position_ref_mut.size;
        let original_collateral = position_ref_mut.collateral;

        // Calculate risk fee
        let is_risk_fee_profit = false;
        let risk_fee: u64;
        let rollover_fee: u64;
        let funding_fee: u64;
        let is_funding_fee_profit: bool;
        {
            rollover_fee = merkle_calculator::calculate_rollover_fee(
                position_ref_mut.acc_rollover_fee_per_collateral,
                pair_state.acc_rollover_fee_per_collateral,
                position_ref_mut.collateral
            );

            (funding_fee, is_funding_fee_profit) = merkle_calculator::calculate_funding_fee(
                position_ref_mut.acc_funding_fee_per_open_interest,
                if (_is_long) { pair_state.long_acc_funding_fee_per_open_interest }
                else { pair_state.short_acc_funding_fee_per_open_interest },
                position_ref_mut.size
            );

            if (is_funding_fee_profit && (funding_fee > rollover_fee)) {
                is_risk_fee_profit = true;
                risk_fee = funding_fee - rollover_fee;
            } else if (is_funding_fee_profit) {
                risk_fee = rollover_fee - funding_fee;
            } else {
                risk_fee = rollover_fee + funding_fee;
            };
        };

        // Settle profit and loss and fee & Repay collateral to user
        let pnl_without_fee: u64;
        let is_profit: bool;
        {
            // Calculate pnl & closed collateral
            (pnl_without_fee, is_profit) = merkle_calculator::calculate_pnl_without_fee(
                position_ref_mut.avg_price,
                price,
                original_size,
                _is_long
            );
            let (settle_amount, is_deposit_to_lp) =
                calculate_settle_amount(
                    pnl_without_fee,
                    is_profit,
                    risk_fee,
                    is_risk_fee_profit
                );
            if (is_deposit_to_lp) {
                settle_amount = min(settle_amount, position_ref_mut.collateral);
                position_ref_mut.collateral = position_ref_mut.collateral - settle_amount;
                house_lp::pnl_deposit_to_lp<CollateralType>(
                    withdraw_collateral_internal<PairType, CollateralType>(settle_amount)
                );
            } else {
                settle_amount = min(settle_amount, safe_mul_div(position_ref_mut.collateral, pair_info.maximum_profit, BASIS_POINT));
                position_ref_mut.collateral = position_ref_mut.collateral + settle_amount;
                deposit_collateral_internal<PairType, CollateralType>(
                    house_lp::pnl_withdraw_from_lp<CollateralType>(settle_amount)
                );
            };
        };

        // Deposit exit fee to distributor
        let exit_fee: u64;
        {
            exit_fee = min(safe_mul_div(
                position_ref_mut.size,
                pair_info.entry_exit_fee,
                ENTRY_EXIT_FEE_PRECISION
            ), position_ref_mut.collateral);
            distributor::deposit_fee(withdraw_collateral_internal<PairType, CollateralType>(exit_fee));
            position_ref_mut.collateral = position_ref_mut.collateral - exit_fee
        };

        // Check is executable condition (liquidation / stop-loss / take-profit)
        {
            let is_executable = false;
            if (position_ref_mut.collateral <= safe_mul_div(original_collateral, pair_info.liquidate_threshold, BASIS_POINT)) { // liquidate threshold basis point
                is_executable = true;
            } else if (_is_long
                && (position_ref_mut.take_profit_trigger_price <= price
                || position_ref_mut.stop_loss_trigger_price >= price)) {
                is_executable = true;
            } else if (!_is_long
                && (position_ref_mut.take_profit_trigger_price >= price
                || position_ref_mut.stop_loss_trigger_price <= price)) {
                is_executable = true;
            } else if ((position_ref_mut.collateral + exit_fee) / original_collateral >= (pair_info.maximum_profit / BASIS_POINT + 1)) { // maximum profit exceeded
                is_executable = true;
            };
            assert!(is_executable, E_NOT_OVER_THRESHOLD);
        };

        // Store position state
        {
            if (position_ref_mut.collateral > 0) {
                coin::deposit(
                    _user,
                    withdraw_collateral_internal<PairType, CollateralType>(position_ref_mut.collateral)
                );
            };
            position_ref_mut.size = 0;
            position_ref_mut.collateral = 0;
            position_ref_mut.avg_price = 0;
        };

        // Store trading pair state
        {
            if (_is_long) {
                pair_state.long_open_interest = pair_state.long_open_interest - original_size;
            } else {
                pair_state.short_open_interest = pair_state.short_open_interest - original_size;
            };
        };

        // Emit position event
        let position_event = PositionEvent {
            pair_type: type_info::type_of<PairType>(),
            collateral_type:type_info::type_of<CollateralType>(),
            user: _user,
            order_id: 0,
            is_long: _is_long,
            price,
            size_delta: original_size,
            collateral_delta: original_collateral,
            is_increase: false,
            is_partial: false,
            pnl_without_fee,
            is_profit,
            entry_exit_fee: exit_fee,
            funding_fee,
            is_funding_fee_profit,
            rollover_fee
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).position_events, position_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(_user).position_events, position_event);
        remove_position_key_from_user_states(_user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _is_long);
    }

    /// Execute order self when keepers not work.
    /// It's only for market-decrease-order
    /// @Parameters
    /// _executor: Executor of the order & order owner.
    /// _order_id: Index of order to execute.
    public entry fun execute_order_self<
        PairType,
        CollateralType,
    >(
        _executor: &signer,
        _order_id: u64
    ) acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);

        assert!(table::contains(&mut pair_state.orders, _order_id), E_ORDER_NOT_EXIST);
        let order = table::remove(&mut pair_state.orders, _order_id);

        assert!(order.is_market, E_NOT_MARKET_ORDER);
        assert!(!order.is_increase, E_NOT_DECREASE_ORDER);
        assert!(address_of(_executor) == order.user, E_NOT_POSITION_OWNER);
        assert!(order.created_timestamp + pair_info.execute_time_limit < timestamp::now_seconds(), E_NOT_OVER_KEEPER_TIME);

        accrue<PairType, CollateralType>(pair_info, pair_state);
        execute_decrease_order_internal<PairType, CollateralType>(
            pair_info,
            pair_state,
            price_oracle::read_with_type<PairType>(order.is_long),
            _order_id,
            order
        )
    }

    /// Execute increase-order. (Similar with open-order)
    /// @Parameters
    /// _pair_info: Pair setted states refereence.
    /// _pair_state: Pair variable states mutable refereence.
    /// _executor: Executor of the order, not order owner. This address can take execute fee.
    /// _price: Trading price. it is determined by oracle and fast-price.
    /// _order_id: Order index for event
    /// _order: Order struct. It contais order states.
    fun execute_increase_order_internal<
        PairType,
        CollateralType
    >(
        _pair_info: &PairInfo<PairType, CollateralType>,
        _pair_state: &mut PairState<PairType, CollateralType>,
        _price: u64,
        _order_id: u64,
        _order: Order
    ) acquires CollateralBox, TradingEvents, UserTradingEvents, UserStates {
        assert!(_order.is_increase, E_NOT_INCREASE_ORDER);

        // Calculate price impact & spread
        {
            (_, _price) = merkle_calculator::calculate_price_impact(
                _price,
                if (_order.is_long) _pair_state.long_open_interest else _pair_state.short_open_interest,
                _order.size_delta,
                if (_order.is_long) _pair_info.market_depth_above else _pair_info.market_depth_below,
                _order.is_long
            );
            _price = merkle_calculator::calculate_price_after_spread(
                _price,
                _pair_info.spread,
                _order.is_long
            );
        };

        // Validate order is executable price
        // If unexecutable price, market-order cancel / limit-order abort
        if ((_order.price != _price) &&
            (_order.can_execute_above_price != (_order.price < _price))) {
            assert!(_order.is_market, E_UNEXECUTABLE_PRICE_LIMIT_ORDER);

            cancel_order_internal<PairType, CollateralType>(_order_id, _order);
            return
        };

        // Get Order owner's position.
        // If not exist create new position.
        let position_ref_mut: &mut Position;
        {
            let positions_ref_mut =
                if (_order.is_long) { &mut _pair_state.long_positions }
                else { &mut _pair_state.short_positions };
            if (!table::contains(positions_ref_mut, _order.user)) {
                table::add(positions_ref_mut, _order.user, Position {
                    size: 0,
                    collateral: 0,
                    avg_price: 0,
                    last_execute_timestamp: timestamp::now_seconds(),
                    acc_rollover_fee_per_collateral: 0,
                    acc_funding_fee_per_open_interest: 0,
                    stop_loss_trigger_price: 0,
                    take_profit_trigger_price: 0
                });
            };
            position_ref_mut = table::borrow_mut(positions_ref_mut, _order.user);
        };

        // Deposit entry fee to distributor
        let entry_fee: u64;
        {
            entry_fee = safe_mul_div(_order.size_delta, _pair_info.entry_exit_fee, ENTRY_EXIT_FEE_PRECISION);
            distributor::deposit_fee(withdraw_collateral_internal<PairType, CollateralType>(entry_fee));
            _order.collateral_delta = _order.collateral_delta - entry_fee;
        };

        // Take position's cumulative risk fees
        let rollover_fee: u64;
        let funding_fee: u64;
        let is_funding_fee_profit: bool;
        {
            rollover_fee = merkle_calculator::calculate_rollover_fee(
                position_ref_mut.acc_rollover_fee_per_collateral,
                _pair_state.acc_rollover_fee_per_collateral,
                position_ref_mut.collateral
            );

            (funding_fee, is_funding_fee_profit) = merkle_calculator::calculate_funding_fee(
                position_ref_mut.acc_funding_fee_per_open_interest,
                if (_order.is_long) { _pair_state.long_acc_funding_fee_per_open_interest }
                else { _pair_state.short_acc_funding_fee_per_open_interest },
                position_ref_mut.size
            );

            let is_fee_profit = false;
            let risk_fee: u64;
            if (is_funding_fee_profit && (funding_fee > rollover_fee)) {
                is_fee_profit = true;
                risk_fee = funding_fee - rollover_fee;
            } else if (is_funding_fee_profit) {
                risk_fee = rollover_fee - funding_fee;
            } else {
                risk_fee = rollover_fee + funding_fee;
            };

            if (is_fee_profit) {
                position_ref_mut.collateral = position_ref_mut.collateral + risk_fee;
                deposit_collateral_internal<PairType, CollateralType>(
                    house_lp::pnl_withdraw_from_lp<CollateralType>(risk_fee)
                );
            } else {
                position_ref_mut.collateral = position_ref_mut.collateral - risk_fee;
                house_lp::pnl_deposit_to_lp<CollateralType>(
                    withdraw_collateral_internal<PairType, CollateralType>(risk_fee)
                );
            };
        };

        // Store position state
        {
            position_ref_mut.avg_price = merkle_calculator::calculate_new_price(
                position_ref_mut.avg_price,
                position_ref_mut.size,
                if (_order.is_market) { _price } else { _order.price },
                _order.size_delta
            );
            position_ref_mut.acc_funding_fee_per_open_interest =
                if (_order.is_long) { _pair_state.long_acc_funding_fee_per_open_interest }
                else { _pair_state.short_acc_funding_fee_per_open_interest };
            position_ref_mut.acc_rollover_fee_per_collateral = _pair_state.acc_rollover_fee_per_collateral;
            position_ref_mut.last_execute_timestamp = timestamp::now_seconds();
            position_ref_mut.size = position_ref_mut.size + _order.size_delta;
            position_ref_mut.collateral = position_ref_mut.collateral + _order.collateral_delta;
            position_ref_mut.stop_loss_trigger_price = _order.stop_loss_trigger_price;
            position_ref_mut.take_profit_trigger_price = _order.take_profit_trigger_price;
        };

        // Store trading pair state
        {
            if (_order.is_long) {
                _pair_state.long_open_interest = _pair_state.long_open_interest + _order.size_delta;
            } else {
                _pair_state.short_open_interest = _pair_state.short_open_interest + _order.size_delta;
            };
        };

        // leverage check
        assert!(
            _pair_state.long_open_interest + _pair_state.short_open_interest
                <= _pair_info.max_open_interest,
            E_OVER_MAXIMUM_INTEREST
        );
        assert!(
            position_ref_mut.size * LEVERAGE_PRECISION / position_ref_mut.collateral >= _pair_info.min_leverage,
            E_UNDER_MINIMUM_LEVEREAGE
        );
        assert!(
            position_ref_mut.size * LEVERAGE_PRECISION / position_ref_mut.collateral <= _pair_info.max_leverage,
            E_OVER_MAXIMUM_LEVEREAGE
        );

        // Emit position event
        let position_event = PositionEvent {
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            user: _order.user,
            order_id: _order_id,
            is_long: _order.is_long,
            price: _price,
            size_delta: _order.size_delta,
            collateral_delta: _order.collateral_delta,
            is_increase: true,
            is_partial: (position_ref_mut.size != _order.size_delta),
            pnl_without_fee: 0,
            is_profit: false,
            entry_exit_fee: entry_fee,
            funding_fee,
            is_funding_fee_profit,
            rollover_fee
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).position_events, position_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(_order.user).position_events, position_event);
        add_position_key_to_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order.is_long);

        // Drop order
        remove_order_id_from_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order_id);
        drop_order(_order);
    }

    /// Execute decrease-order (Similar with close-order).
    /// @Parameters
    /// _pair_info: Pair setted states refereence.
    /// _pair_state: Pair variable states mutable refereence.
    /// _executor: Executor of the order, not order owner. This address can take execute fee.
    /// _price: Trading price. it is determined by oracle and fast-price.
    /// _order_id: Order index for event
    /// _order: Order struct. It contais order states.
    fun execute_decrease_order_internal<
        PairType,
        CollateralType
    >(
        _pair_info: &PairInfo<PairType, CollateralType>,
        _pair_state: &mut PairState<PairType, CollateralType>,
        _price: u64,
        _order_id: u64,
        _order: Order
    ) acquires CollateralBox, TradingEvents, UserTradingEvents, UserStates {
        assert!(!_order.is_increase, E_NOT_DECREASE_ORDER);

        // Validate order is executable price
        // If unexecutable price, market-order cancel / limit-order abort
        if ((_order.price != _price) &&
            (_order.can_execute_above_price != (_order.price < _price))) {
            assert!(_order.is_market, E_UNEXECUTABLE_PRICE_LIMIT_ORDER);

            cancel_order_internal<PairType, CollateralType>(_order_id, _order);
            return
        };

        // Get Order owner's position.
        // Revert if not exist.
        let position_ref_mut: &mut Position;
        {
            let positions_ref_mut =
                if (_order.is_long) { &mut _pair_state.long_positions }
                else { &mut _pair_state.short_positions };
            assert!(table::contains(positions_ref_mut, _order.user), E_POSITION_NOT_EXIST);
            position_ref_mut = table::borrow_mut(positions_ref_mut, _order.user);
        };

        let original_size = position_ref_mut.size;
        // Calculate risk fee
        let is_fee_profit = false;
        let risk_fee: u64;
        let rollover_fee: u64;
        let funding_fee: u64;
        let is_funding_fee_profit: bool;
        {
            rollover_fee = merkle_calculator::calculate_rollover_fee(
                position_ref_mut.acc_rollover_fee_per_collateral,
                _pair_state.acc_rollover_fee_per_collateral,
                position_ref_mut.collateral
            );

            (funding_fee, is_funding_fee_profit) = merkle_calculator::calculate_funding_fee(
                position_ref_mut.acc_funding_fee_per_open_interest,
                if (_order.is_long) { _pair_state.long_acc_funding_fee_per_open_interest }
                else { _pair_state.short_acc_funding_fee_per_open_interest },
                position_ref_mut.size
            );

            if (is_funding_fee_profit && (funding_fee > rollover_fee)) {
                is_fee_profit = true;
                risk_fee = funding_fee - rollover_fee;
            } else if (is_funding_fee_profit) {
                risk_fee = rollover_fee - funding_fee;
            } else {
                risk_fee = rollover_fee + funding_fee;
            };
        };


        // Settle profit and loss & Repay closed collateral with pnl to user
        let pnl_without_fee: u64;
        let is_profit: bool;
        let closed_pnl: u64;
        {
            // Calculate pnl & closed collateral
            (pnl_without_fee, is_profit) = merkle_calculator::calculate_pnl_without_fee(
                position_ref_mut.avg_price,
                _price,
                _order.size_delta,
                _order.is_long
            );
            closed_pnl = safe_mul_div(pnl_without_fee, _order.size_delta, original_size);

            let (settle_amount, is_deposit_to_lp) =
                calculate_settle_amount(
                    closed_pnl,
                    is_profit,
                    risk_fee,
                    is_fee_profit
                );

            if (is_deposit_to_lp) {
                settle_amount = min(settle_amount, position_ref_mut.collateral);
                position_ref_mut.collateral = position_ref_mut.collateral - settle_amount;
                house_lp::pnl_deposit_to_lp<CollateralType>(
                    withdraw_collateral_internal<PairType, CollateralType>(settle_amount)
                );
            } else {
                settle_amount = min(settle_amount, safe_mul_div(position_ref_mut.collateral, _pair_info.maximum_profit, BASIS_POINT));
                position_ref_mut.collateral = position_ref_mut.collateral + settle_amount;
                deposit_collateral_internal<PairType, CollateralType>(
                    house_lp::pnl_withdraw_from_lp<CollateralType>(settle_amount)
                );
            };
        };

        // Repay coin to user
        let closed_collateral =
            safe_mul_div(position_ref_mut.collateral, _order.size_delta, original_size);

        // Deposit exit fee to distributor
        let exit_fee: u64;
        {
            exit_fee = min(safe_mul_div(_order.size_delta, _pair_info.entry_exit_fee, ENTRY_EXIT_FEE_PRECISION), closed_collateral);
            distributor::deposit_fee(withdraw_collateral_internal<PairType, CollateralType>(exit_fee));
        };
        {
            coin::deposit(
                _order.user,
                withdraw_collateral_internal<PairType, CollateralType>(closed_collateral - exit_fee)
            );
        };

        // Store position state
        {
            position_ref_mut.acc_funding_fee_per_open_interest =
                if (_order.is_long) { _pair_state.long_acc_funding_fee_per_open_interest }
                else { _pair_state.short_acc_funding_fee_per_open_interest };
            position_ref_mut.acc_rollover_fee_per_collateral = _pair_state.acc_rollover_fee_per_collateral;
            position_ref_mut.last_execute_timestamp = timestamp::now_seconds();
            position_ref_mut.size = position_ref_mut.size - _order.size_delta;
            position_ref_mut.collateral = position_ref_mut.collateral - closed_collateral;
        };

        // Store trading pair state
        {
            if (_order.is_long) {
                _pair_state.long_open_interest = _pair_state.long_open_interest - _order.size_delta;
            } else {
                _pair_state.short_open_interest = _pair_state.short_open_interest - _order.size_delta;
            };
        };

        // if position not fully close, check leverage limit
        if (position_ref_mut.size > 0) {
            assert!(
                safe_mul_div(position_ref_mut.size, LEVERAGE_PRECISION, position_ref_mut.collateral)  >= _pair_info.min_leverage,
                E_UNDER_MINIMUM_LEVEREAGE
            );
            assert!(
                safe_mul_div(position_ref_mut.size, LEVERAGE_PRECISION, position_ref_mut.collateral) <= _pair_info.max_leverage,
                E_OVER_MAXIMUM_LEVEREAGE
            );
        };

        // Emit position event
        let position_event = PositionEvent {
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            user: _order.user,
            order_id: _order_id,
            is_long: _order.is_long,
            price: _price,
            size_delta: _order.size_delta,
            collateral_delta: _order.collateral_delta,
            is_increase: false,
            is_partial: (position_ref_mut.size != 0),
            pnl_without_fee: closed_pnl,
            is_profit,
            entry_exit_fee: exit_fee,
            funding_fee,
            is_funding_fee_profit,
            rollover_fee
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).position_events, position_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(_order.user).position_events, position_event);
        remove_position_key_from_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order.is_long);

        // Drop order
        remove_order_id_from_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order_id);
        drop_order(_order);
    }

    /// add order id to UserStates when order placed
    /// @Parameters
    /// _order_id: order id for add
    fun add_order_id_to_user_states(_host: &signer, pair_type: TypeInfo, collateral_type: TypeInfo, order_id: u64) acquires UserStates {
        let host_addr = address_of(_host);
        if (!exists<UserStates>(host_addr)){
            move_to(_host, UserStates {
                order_keys: vector::empty(),
                user_position_keys: vector::empty()
            })
        };
        let user_states = borrow_global_mut<UserStates>(host_addr);
        vector::push_back(&mut user_states.order_keys, OrderKey {
            pair_type,
            collateral_type,
            order_id
        });
    }

    /// remove order id from UserStates when order executed or canceled
    /// @Parameters
    /// _order_id: order id for remove
    fun remove_order_id_from_user_states(host_addr: address, pair_type: TypeInfo, collateral_type: TypeInfo, order_id: u64) acquires UserStates {
        let user_states = borrow_global_mut<UserStates>(host_addr);
        let (exists, idx) = vector::index_of(&user_states.order_keys, &OrderKey {
            pair_type,
            collateral_type,
            order_id
        });

        if (exists) {
            vector::remove(&mut user_states.order_keys, idx);
        } else {
            abort E_ORDER_NOT_EXIST
        };
    }

    /// add position key to UserStates when position opened
    /// position key is "_pair_type/_collateral_type/_is_long"
    /// @Parameters
    /// _pair_type: position pair type
    /// _collateral_type: position collateral type
    /// _is_long: position is long or short
    fun add_position_key_to_user_states(host_addr: address, pair_type: TypeInfo, collateral_type: TypeInfo, is_long: bool) acquires UserStates {
        let user_states = borrow_global_mut<UserStates>(host_addr);
        let position_key = UserPositionKey {
            pair_type,
            collateral_type,
            is_long
        };
        let (exists, _) = vector::index_of(&user_states.user_position_keys, &position_key);
        if (!exists) {
            vector::push_back(&mut user_states.user_position_keys, position_key);
        };
    }

    /// remove position key from UserStates when position closed
    /// position key is "_pair_type/_collateral_type/_is_long"
    /// @Parameters
    /// _pair_type: position pair type
    /// _collateral_type: position collateral type
    /// _is_long: position is long or short
    fun remove_position_key_from_user_states(host_addr: address, pair_type: TypeInfo, collateral_type: TypeInfo, is_long: bool) acquires UserStates {
        let user_states = borrow_global_mut<UserStates>(host_addr);
        let (exists, idx) = vector::index_of(&user_states.user_position_keys, &UserPositionKey {
            pair_type,
            collateral_type,
            is_long
        });

        if (exists) {
            vector::remove(&mut user_states.user_position_keys, idx);
        } else {
            abort E_POSITION_NOT_EXIST
        };
    }

    /// Accure rollover / funding fees.
    /// @Parameters
    /// _pair_info: Pair setted states refereence.
    /// _pair_state: Pair variable states mutable refereence.
    fun accrue<PairType, CollateralType>(
        _pair_info: &PairInfo<PairType, CollateralType>,
        _pair_state: &mut PairState<PairType, CollateralType>
    ) {
        // Funding fee
        let (long_funding_rate_delta, short_funding_rate_delta, long_to_short) =
            merkle_calculator::calculate_funding_rate_delta(
                _pair_state.long_open_interest,
                _pair_state.short_open_interest,
                _pair_state.last_accrue_timestamp,
                timestamp::now_seconds(),
                _pair_info.funding_fee_per_timestamp
            );

        _pair_state.long_acc_funding_fee_per_open_interest =
            if (long_to_short) { _pair_state.long_acc_funding_fee_per_open_interest + long_funding_rate_delta }
            else { _pair_state.long_acc_funding_fee_per_open_interest - long_funding_rate_delta };

        _pair_state.short_acc_funding_fee_per_open_interest =
            if (long_to_short) { _pair_state.short_acc_funding_fee_per_open_interest - short_funding_rate_delta }
            else { _pair_state.short_acc_funding_fee_per_open_interest + short_funding_rate_delta };

        // Rollover fee
        let rollover_fee_delta = merkle_calculator::calculate_rollover_fee_delta(
            _pair_state.last_accrue_timestamp,
            timestamp::now_seconds(),
            _pair_info.rollover_fee_per_timestamp
        );

        _pair_state.acc_rollover_fee_per_collateral =
            _pair_state.acc_rollover_fee_per_collateral + rollover_fee_delta;
    }

    // <-- ADMIN FUNCTION ----->

    public fun pause<PairType, CollateralType>(
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.paused = true;
    }

    public fun restart<PairType, CollateralType>(
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.paused = false;
    }

    public fun set_funding_fee_per_block<PairType, CollateralType>(
        _fee: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.funding_fee_per_timestamp = _fee;
    }

    public fun set_rollover_fee_per_block<PairType, CollateralType>(
        _fee: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.rollover_fee_per_timestamp = _fee;
    }

    public fun set_entry_exit_fee<PairType, CollateralType>(
        _fee: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.entry_exit_fee = _fee;
    }

    public fun set_max_interest<PairType, CollateralType>(
        _max_interest: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.max_open_interest = _max_interest;
    }

    public fun set_min_leverage<PairType, CollateralType>(
        _min_leverage: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.min_leverage = _min_leverage;
    }

    public fun set_max_leverage<PairType, CollateralType>(
        _max_leverage: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.max_leverage = _max_leverage
    }

    public fun set_market_depth_above<PairType, CollateralType>(
        _market_depth_above: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.market_depth_above = _market_depth_above
    }

    public fun set_market_depth_below<PairType, CollateralType>(
        _market_depth_below: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.market_depth_below = _market_depth_below
    }

    public fun set_execute_time_limit<PairType, CollateralType>(
        _execute_time_limit: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.execute_time_limit = _execute_time_limit
    }

    public fun set_liquidate_threshold<PairType, CollateralType>(
        _liquidate_threshold: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.liquidate_threshold = _liquidate_threshold
    }

    public fun set_maximum_profit<PairType, CollateralType>(
        _maximum_profit: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.maximum_profit = _maximum_profit
    }

    public fun set_spread<PairType, CollateralType>(
        _spread: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.spread = _spread;
    }

    // <-- TEST CODE ----->

    #[test_only]
    struct TestPair has key, store, drop {}

    #[test_only]
    struct TEST_USDC has store, drop {}

    #[test_only]
    fun create_test_coins<T>(
        host: &signer,
        name: vector<u8>,
        decimals: u8,
        amount: u64
    ) {
        let (bc, fc, mc) = coin::initialize<T>(host,
            string::utf8(name),
            string::utf8(name),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<T>(host);
        coin::deposit(address_of(host), coin::mint<T>(amount, &mc));
        coin::destroy_mint_cap(mc);
    }

    #[test_only]
    public entry fun call_test_setting(host: &signer, aptos_framework: &signer)
    : (ExecuteCapability<TestPair, TEST_USDC>, AdminCapability<TestPair, TEST_USDC>) acquires PairInfo {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_account::create_account(address_of(host));

        price_oracle::register_oracle<TestPair>(host, 0);
        price_oracle::register_oracle<TEST_USDC>(host, 30 * math_u64::exp(10, 4));

        let (execute_cap, admin_cap) = initialize<TestPair, TEST_USDC>(host);
        set_entry_exit_fee(3000, &admin_cap);
        set_max_interest(100000 * INTEREST_PRECISION, &admin_cap);
        set_min_leverage(3 * LEVERAGE_PRECISION, &admin_cap);
        set_max_leverage(100 * LEVERAGE_PRECISION, &admin_cap);
        create_test_coins<TEST_USDC>(host, b"USDC", 8, 10000000 * 100000000);
        house_lp::register<TEST_USDC>(host, 10);
        house_lp::deposit<TEST_USDC>(host, 10000000 * 1000000);

        distributor::initialize(host);
        distributor::register_reward<TEST_USDC>(host);

        (execute_cap, admin_cap)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test initialize
    public entry fun T_initialize(host: &signer, aptos_framework: &signer) {
        aptos_account::create_account(address_of(host));
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize<TestPair, TEST_USDC>(
            host
        );
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test place order
    public entry fun T_place_order(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        call_test_setting(host, aptos_framework);

        // when
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(table::contains(&mut pair_state.orders, 1), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 10)]
    /// Fail test place order zero collateral delta
    public entry fun T_place_order_E_ZERO_COLLATERAL_DELTA(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        call_test_setting(host, aptos_framework);

        // when
        place_order<TestPair, TEST_USDC>(host, 500000, 0, 300000, true, true, true, 0, 0, true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test cancel order
    public entry fun T_cancel_order(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);

        // when
        cancel_order<TestPair, TEST_USDC>(host, 1);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(!table::contains(&mut pair_state.orders, 1), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 6)]
    /// Fail test cancel order
    public entry fun T_cancel_order_E_ORDER_NOT_EXIST(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        call_test_setting(host, aptos_framework);

        // when
        cancel_order<TestPair, TEST_USDC>(host, 1);
    }


    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    public entry fun T_execute_increase_market_order(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let size = 500000;
        place_order<TestPair, TEST_USDC>(host, size, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(!table::contains(&mut pair_state.orders, 1), 0);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == size, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    public entry fun T_execute_increase_market_order_2(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let size = 500000;
        place_order<TestPair, TEST_USDC>(host, size, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 400000, &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(!table::contains(&mut pair_state.orders, 1), 0);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == size, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    public entry fun T_execute_increase_market_order_cancel(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 200000, &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(!table::contains(&mut pair_state.orders, 1), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 14)]
    /// Fail test execute increase limit order
    public entry fun T_execute_increase_limit_order_E_UNEXECUTABLE_PRICE_LIMIT_ORDER(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, false, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 200000, &execute_cap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 6)]
    /// Fail test execute increase limit order
    public entry fun T_execute_increase_limit_order_E_NOT_EXIST_ORDER(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, false, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 2, 200000, &execute_cap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    public entry fun T_execute_decrease_market_order_long(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let original_size = 500000;
        place_order<TestPair, TEST_USDC>(host, original_size, 100000, 300000, true, true, true, 0, 0, true);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        execute_order<TestPair, TEST_USDC>(host, 1, 310000, &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, 0, 300000, true, false, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == 0, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    public entry fun T_execute_decrease_market_order_long_partial(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 100000;
        let original_size = 500000;
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        // coll size = 100000, pos size = 500000
        timestamp::set_time_has_started_for_testing(aptos_framework);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);
        // position opened
        // entry fee = 1500
        // coll size = 98500, pos size = 500000
        let before_coll = coin::balance<TEST_USDC>(address_of(host));
        place_order<TestPair, TEST_USDC>(host, original_size/2, 0, 300000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, &execute_cap);
        // half of position (250000) closed
        // half of entry fee = 750, exit fee = 750 ( 250000 * 0.3% )
        // coll size left = 49250, coll size out = 48500, pos size left = 250000,
        let after_coll = coin::balance<TEST_USDC>(address_of(host));

        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
        assert!(coll_size / 2 - (after_coll - before_coll) == original_size * pair_info.entry_exit_fee / ENTRY_EXIT_FEE_PRECISION, 0);
        // exit size is 250000 so entry fee = 750, exit fee = 750
        // check entry exit fee is 1500
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    public entry fun T_execute_decrease_market_order_short(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, false, true, true, 0, 0, true);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        execute_order<TestPair, TEST_USDC>(host, 1, 310000, &execute_cap);
        place_order<TestPair, TEST_USDC>(host, 300000, 0, 300000, false, false, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.short_positions, address_of(host));
        assert!(position.size == 200000, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test liquidate position
    public entry fun T_liquidate(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            100000,
            &execute_cap
        );

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == 0, 1);
        assert!(position.collateral == 0, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test stap-loss
    public entry fun T_stop_loss(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 299000, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            298000,
            &execute_cap
        );

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == 0, 1);
        assert!(position.collateral == 0, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test take-profit
    public entry fun T_take_profit(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 301000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            305000,
            &execute_cap
        );

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == 0, 1);
        assert!(position.collateral == 0, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 19)]
    /// Fail test execute without order not over threshold
    public entry fun T_execute_exit_position_E_NOT_OVER_THRESHOLD(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 200000, 400000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            300000,
            &execute_cap
        );
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test close_position maximum_profit
    public entry fun T_maximum_profit_close_position(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let host_addr = address_of(host);
        let original_value = coin::balance<TEST_USDC>(host_addr);
        let size_value = 500000;
        let coll_value = 100000;

        place_order<TestPair, TEST_USDC>(host, size_value, coll_value, 300000, true, true, true, 0, 30000000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);

        place_order<TestPair, TEST_USDC>(host, size_value, 0, 3000000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 3000000, &execute_cap);
        let after_value = coin::balance<TEST_USDC>(host_addr);
        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(host_addr);
        let entry_fee = safe_mul_div(size_value, pair_info.entry_exit_fee, ENTRY_EXIT_FEE_PRECISION);

        assert!(after_value - original_value == safe_mul_div(coll_value - entry_fee, pair_info.maximum_profit, BASIS_POINT) - entry_fee * 2, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test stop_profit maximum_profit
    public entry fun T_maximum_profit_stop_profit(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let host_addr = address_of(host);
        let original_value = coin::balance<TEST_USDC>(host_addr);
        let size_value = 500000;
        let coll_value = 100000;

        place_order<TestPair, TEST_USDC>(host, size_value, coll_value, 300000, true, true, true, 0, 2700000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            3000000,
            &execute_cap
        );
        let after_value = coin::balance<TEST_USDC>(host_addr);
        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(host_addr);
        let entry_fee = safe_mul_div(size_value, pair_info.entry_exit_fee, ENTRY_EXIT_FEE_PRECISION);

        assert!(after_value - original_value == safe_mul_div(coll_value - entry_fee, pair_info.maximum_profit, BASIS_POINT) - entry_fee * 2, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test stop_profit maximum_profit
    public entry fun T_user_states_order_positions(host: &signer, aptos_framework: &signer)
    acquires PairInfo, CollateralBox, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let host_addr = address_of(host);

        let size_value = 500000;
        let coll_value = 100000;
        let pair_type = type_info::type_of<TestPair>();
        let collateral_type = type_info::type_of<TEST_USDC>();

        place_order<TestPair, TEST_USDC>(host, size_value, coll_value, 300000, true, true, true, 0, 2700000, true);
        {
            let user_states = borrow_global_mut<UserStates>(host_addr);
            assert!(vector::length(&user_states.order_keys) == 1, 0);
            assert!(*vector::borrow(&mut user_states.order_keys, 0) == OrderKey {
                pair_type,
                collateral_type,
                order_id: 1,
            }, 1);
            assert!(vector::length(&user_states.user_position_keys) == 0, 2);
        };

        execute_order<TestPair, TEST_USDC>(host, 1, 300000, &execute_cap);
        {
            let user_states = borrow_global_mut<UserStates>(host_addr);
            assert!(vector::length(&user_states.order_keys) == 0, 3);
            assert!(vector::length(&user_states.user_position_keys) == 1, 4);

            assert!(*vector::borrow(&mut user_states.user_position_keys, 0) == UserPositionKey {
                pair_type,
                collateral_type,
                is_long: true
            }, 1);
        };
    }
}