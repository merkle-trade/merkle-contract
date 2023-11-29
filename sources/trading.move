module merkle::trading {

    // <-- USE ----->
    use std::signer::address_of;
    use std::vector;

    use aptos_std::table;
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::event::{Self, EventHandle};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::account::new_event_handle;

    use merkle::house_lp;
    use merkle::vault;
    use merkle::vault_type;
    use merkle::price_oracle;
    use merkle::trading_calc;
    use merkle::fee_distributor;
    use merkle::safe_math_u64::{safe_mul_div, min, max, abs};
    use merkle::trading_calc::{calculate_settle_amount, calculate_partial_close_amounts, calculate_risk_fees, calculate_maker_taker_fee};
    use merkle::profile;

    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::coin::{BurnCapability, MintCapability};
    #[test_only]
    use merkle::lootbox;

    // <-- PRECISION ----->

    const U64_MAX: u64 = 18446744073709551615;

    /// opening_fee = 10000 => 1%
    const MAKER_TAKER_FEE_PRECISION: u64 = 1000000;
    /// interest_precision 10000 => 1%
    const INTEREST_PRECISION: u64 = 1000000;
    /// leverage_precision 10000 => 1%
    const LEVERAGE_PRECISION: u64 = 1000000;
    /// basis point 1e4 => 1
    const BASIS_POINT: u64 = 10000;

    // <-- ERROR CODE ----->

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
    const E_NOT_ZERO_SIZE_DELTA: u64 = 22;
    /// When take profit value invalid
    const E_UPDATE_TAKE_PROFIT_INVALID: u64 = 24;
    /// When order collateral delta is too small
    const E_ORDER_COLLATERAL_TOO_SMALL: u64 = 25;
    /// When position collateral is too small
    const E_POSITION_COLLATERAL_TOO_SMALL: u64 = 26;
    /// When position collateral is too small
    const E_POSITION_COLLATERAL_TOO_LARGE: u64 = 27;
    /// When decrease order size delta is bigger than position size
    const E_ORDER_SIZE_DELTA_TOO_LARGE: u64 = 28;
    /// When position size is too small
    const E_POSITION_SIZE_TOO_SMALL: u64 = 29;
    /// When breaks enabled
    const E_TEMPORARY_ORDER_BREAK: u64 = 30;


    /// <-- POSITION EVENT TYPE FLAG ----->
    /// When position open
    const T_POSITION_OPEN: u64 = 0;
    /// When position update (update collateral, size)
    const T_POSITION_UPDATE: u64 = 1;
    /// When position close (not liquidate, tp, sl)
    const T_POSITION_CLOSE: u64 = 2;
    /// When position liquidate close
    const T_POSITION_LIQUIDATE: u64 = 3;
    /// When position take profit close
    const T_POSITION_TAKE_PROFIT: u64 = 4;
    /// When position stop loss close
    const T_POSITION_STOP_LOSS: u64 = 5;

    /// <-- CANCEL EVENT TYPE FLAG ----->
    /// When user cancel order
    const T_CANCEL_ORDER_BY_USER: u64 = 0;
    /// When executor cancel order over max leverage
    const T_CANCEL_ORDER_OVER_MAX_LEVERAGE: u64 = 1;
    /// When executor cancel order under min leverage
    const T_CANCEL_ORDER_UNDER_MIN_LEVERAGE: u64 = 2;
    /// When market order price is unexecutable
    const T_CANCEL_ORDER_UNEXECUTABLE_MARKET_ORDER: u64 = 3;
    /// When decrease position size, collateral not enough
    const T_CANCEL_ORDER_NOT_ENOUGH_COLLATERAL: u64 = 4;
    /// When decrease position size, size not enough, maybe already liquidated
    const T_CANCEL_ORDER_NOT_ENOUGH_SIZE: u64 = 5;
    /// When more than 30 seconds have passed since the order was created
    const T_CANCEL_ORDER_EXPIRED: u64 = 6;
    /// When max interest exceeded
    const T_CANCEL_ORDER_OVER_MAX_INTEREST: u64 = 7;
    /// When max collateral exceeded
    const T_CANCEL_ORDER_OVER_MAX_COLLATERAL: u64 = 8;

    /// <-- STRUCT ----->

    /// Order info for UserStates
    struct OrderKey has copy, store, drop {
        /// pair type ex) ETH_USD
        pair_type: TypeInfo,
        /// collateral type ex) ETH_USD
        collateral_type: TypeInfo,
        /// order id
        order_id: u64,
    }

    /// Position pair collateral long info for UserStates
    struct UserPositionKey has copy, store, drop {
        /// pair type ex) ETH_USD
        pair_type: TypeInfo,
        /// collateral type ex) ETH_USD
        collateral_type: TypeInfo,
        /// Flag whether order is long.
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
    struct Order has copy, store {
        /// uid for related with position
        uid: u64,
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
        /// Position unique id
        uid: u64,
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
        /// Accumulative funding fee per size when position last execute.
        acc_funding_fee_per_size: u64,
        /// Accumulative funding fee sign per size when position last execute.
        acc_funding_fee_per_size_positive: bool,
        /// Stop-loss trigger price.
        stop_loss_trigger_price: u64,
        /// Take-profit trigger price.
        take_profit_trigger_price: u64
    }

    /// Offchain set states
    struct PairInfo<phantom PairType, phantom CollateralType> has key {
        /// Flag whether pair is paused.
        paused: bool,
        /// Minimum leverage of pair.
        min_leverage: u64,
        /// Maximum leverage of pair.
        max_leverage: u64,
        /// Maker fee. 1000000 => 100%
        maker_fee: u64,
        /// Taker fee. 1000000 => 100%
        taker_fee: u64,
        /// Rollover fee per timestamp. (1e6 => 1%)
        rollover_fee_per_timestamp: u64,
        /// skew_factor, for price impact, funding rate, (precision 6, 1e6 => 1)
        skew_factor: u64,
        /// max funding velocity, for funding rate. (precision 8, 1e8 => 1)
        max_funding_velocity: u64,
        /// Maximum open interest of this pair.
        max_open_interest: u64,
        /// market above depth of offchain exchange. It's for price-impact.
        market_depth_above: u64,
        /// market below depth of offchain exchange. It's for price-impact.
        market_depth_below: u64,
        /// Execute time limit. If it hasn't been executed after this time,
        /// the user can do it themselves. This is only for decrease order.
        execute_time_limit: u64,
        /// Threshold for liquidate, basis point 10000 => 100%
        liquidate_threshold: u64,
        /// Maximum profit basis point 90000 -> 900%
        maximum_profit: u64,
        /// Minimum collateral size for each order
        minimum_order_collateral: u64,
        /// Minimum collateral size for eash position
        minimum_position_collateral: u64,
        /// Minimum size for eash position
        minimum_position_size: u64,
        /// Maximum collateral size for eash position
        maximum_position_collateral: u64,
        /// Amount of APT for fxecution fee
        execution_fee: u64,
    }

    /// Onchain variable states
    struct PairState<phantom PairType, phantom CollateralType> has key {
        /// Incremental idx of order.
        next_order_id: u64,
        /// Total open interest of long positions.
        long_open_interest: u64,
        /// Total open interest of short positions.
        short_open_interest: u64,
        /// Accumulative funding rate. 100000000 => 100%
        funding_rate: u64,
        /// Sign of accumulative funding rate.
        funding_rate_positive: bool,
        /// Accumulative funding fee per size. 1000000 => 100%
        acc_funding_fee_per_size: u64,
        /// Sign of accumulative funding fee per size.
        acc_funding_fee_per_size_positive: bool,
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
        /// uid for event query
        uid_sequence: u64,
        /// Event handle for place order events.
        place_order_events: EventHandle<PlaceOrderEvent>,
        /// Event handle for cancel order events.
        cancel_order_events: EventHandle<CancelOrderEvent>,
        /// Event handle for position events.
        position_events: EventHandle<PositionEvent>,
        /// Event handle for position tpsl update events.
        update_tp_sl_events: EventHandle<UpdateTPSLEvent>,
    }

    /// this struct will be move to user for events
    struct UserTradingEvents has key {
        /// Event handle for place order events.
        place_order_events: EventHandle<PlaceOrderEvent>,
        /// Event handle for cancel order events.
        cancel_order_events: EventHandle<CancelOrderEvent>,
        /// Event handle for position events.
        position_events: EventHandle<PositionEvent>,
        /// Event handle for position tpsl update events.
        update_tp_sl_events: EventHandle<UpdateTPSLEvent>,
    }

    /// Emitted when a order place/cancel.
    struct PlaceOrderEvent has copy, drop, store {
        /// uid
        uid: u64,
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
        /// uid
        uid: u64,
        /// cancel order event type
        event_type: u64,
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

    /// Emitted when a position state change.
    /// ex) order fills / liquidate / stop-loss...
    struct PositionEvent has copy, drop, store {
        /// uid
        uid: u64,
        /// position event type
        event_type: u64,
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
        /// Original size
        original_size: u64,
        /// size delta
        size_delta: u64,
        /// Original collateral
        original_collateral: u64,
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
        rollover_fee: u64,
        /// long open interest
        long_open_interest: u64,
        /// short open interest
        short_open_interest: u64
    }

    /// Emitted when a position sltp update.
    struct UpdateTPSLEvent has drop, store {
        /// uid
        uid: u64,
        /// pair type of position
        pair_type: TypeInfo,
        /// collateral type of position
        collateral_type: TypeInfo,
        /// Address of position owner.
        user: address,
        /// Flag whether position is long.
        is_long: bool,
        /// Take-profit trigger price.
        take_profit_trigger_price: u64,
        /// Stop-loss trigger price.
        stop_loss_trigger_price: u64
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
    public fun initialize<PairType, CollateralType>(
        _host: &signer
    ): (ExecuteCapability<PairType, CollateralType>, AdminCapability<PairType, CollateralType>) {
        assert!(address_of(_host) == @merkle, E_NOT_AUTHORIZED);
        if (!exists<PairInfo<PairType, CollateralType>>(@merkle)) {
            move_to(
                _host,
                PairInfo<PairType, CollateralType> {
                    paused: false,
                    min_leverage: 0,
                    max_leverage: 0,
                    maker_fee: 0,
                    taker_fee: 0,
                    rollover_fee_per_timestamp: 0,
                    max_open_interest: 0,
                    market_depth_above: 10000000000,
                    market_depth_below: 10000000000,
                    skew_factor: 0,
                    max_funding_velocity: 0,
                    execute_time_limit: 300,
                    liquidate_threshold: 1000,
                    maximum_profit: 100000,
                    minimum_order_collateral: 0,
                    minimum_position_collateral: 1000000,
                    minimum_position_size: 0,
                    maximum_position_collateral: U64_MAX,
                    execution_fee: 0,
                });
        };
        if (!exists<PairState<PairType, CollateralType>>(@merkle)) {
            move_to(
                _host,
                PairState<PairType, CollateralType> {
                    next_order_id: 1,
                    long_open_interest: 0,
                    short_open_interest: 0,
                    funding_rate: 0,
                    funding_rate_positive: true,
                    acc_funding_fee_per_size: 0,
                    acc_funding_fee_per_size_positive: true,
                    acc_rollover_fee_per_collateral: 0,
                    orders: table::new(),
                    long_positions: table::new(),
                    short_positions: table::new(),
                    last_accrue_timestamp: timestamp::now_seconds()
                }
            );
        };
        if (!exists<TradingEvents>(address_of(_host))) {
            move_to(_host, TradingEvents {
                uid_sequence: 0,
                place_order_events: new_event_handle<PlaceOrderEvent>(_host),
                cancel_order_events: new_event_handle<CancelOrderEvent>(_host),
                position_events: new_event_handle<PositionEvent>(_host),
                update_tp_sl_events: new_event_handle<UpdateTPSLEvent>(_host),
            })
        };
        (ExecuteCapability<PairType, CollateralType> {}, AdminCapability<PairType, CollateralType> {})
    }

    /// generate new capability for others
    /// only @merkle can call this function
    public fun generate_execute_cap<PairType, CollateralType>(
        _admin: &signer,
        _cap: &AdminCapability<PairType, CollateralType>
    ): ExecuteCapability<PairType, CollateralType> {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        (ExecuteCapability<PairType, CollateralType> {})
    }

    /// generate new capability for others
    /// only @merkle can call this function
    public fun generate_admin_cap<PairType, CollateralType>(
        _admin: &signer,
        _cap: &AdminCapability<PairType, CollateralType>
    ): AdminCapability<PairType, CollateralType> {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        (AdminCapability<PairType, CollateralType> {})
    }

    // <-- ORDER FUNCTION ----->

    /// Place market/limit-order.
    /// @Parameters
    /// _user: Signer & order owner
    /// _order_info: Order info with states
    public fun place_order<
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
    ) acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        assert!(exists<PairInfo<PairType, CollateralType>>(@merkle), E_PAIR_NOT_EXIST);
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        assert!(
            !(house_lp::check_hard_break_exceeded<CollateralType>() ||
            (house_lp::check_soft_break_exceeded<CollateralType>() && _is_increase)),
            E_TEMPORARY_ORDER_BREAK
        );

        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);
        if (!exists<UserTradingEvents>(address_of(_user))) {
            move_to(_user, UserTradingEvents {
                place_order_events: new_event_handle<PlaceOrderEvent>(_user),
                cancel_order_events: new_event_handle<CancelOrderEvent>(_user),
                position_events: new_event_handle<PositionEvent>(_user),
                update_tp_sl_events: new_event_handle<UpdateTPSLEvent>(_user),
            });
        };
        // Accrue rollover/funding fee
        accrue(pair_info, pair_state);

        if (_is_increase) {
            vault::deposit_vault<vault_type::CollateralVault, CollateralType>(coin::withdraw(_user, _collateral_delta));
        };

        // Create new order
        let trading_events = borrow_global_mut<TradingEvents>(@merkle);
        let order = Order {
            uid: 0,
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

        let position_ref_mut: &mut Position;
        {
            // create position if not exists
            let positions_ref_mut =
                if (_is_long) { &mut pair_state.long_positions }
                else { &mut pair_state.short_positions };
            if (!table::contains(positions_ref_mut, order.user)) {
                table::add(positions_ref_mut, address_of(_user), Position {
                    uid: 0,
                    size: 0,
                    collateral: 0,
                    avg_price: 0,
                    last_execute_timestamp: timestamp::now_seconds(),
                    acc_rollover_fee_per_collateral: 0,
                    acc_funding_fee_per_size: 0,
                    acc_funding_fee_per_size_positive: false,
                    stop_loss_trigger_price: 0,
                    take_profit_trigger_price: 0
                });
            };
            position_ref_mut = table::borrow_mut(positions_ref_mut, order.user);
        };
        // uid is determined by the position.
        // If it exists, use it. If not, assign a new one.
        let uid = position_ref_mut.uid;
        if (position_ref_mut.size == 0) {
            uid = trading_events.uid_sequence;
            trading_events.uid_sequence = trading_events.uid_sequence + 1;
        };
        // order uid is same with position
        order.uid = uid;

        validate_order<PairType, CollateralType>(
            &order,
            position_ref_mut,
            pair_info,
            pair_state
        );

        // Store order to table
        table::add(&mut pair_state.orders, pair_state.next_order_id, order);
        add_order_id_to_user_states(_user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), pair_state.next_order_id);
        pair_state.next_order_id = pair_state.next_order_id + 1;

        // take execution fee
        if (pair_info.execution_fee > 0) {
            coin::transfer<AptosCoin>(_user, @merkle, pair_info.execution_fee);
        };

        // Emit order event
        let place_order_event = PlaceOrderEvent {
            uid,
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
        event::emit_event(&mut trading_events.place_order_events, place_order_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(address_of(_user)).place_order_events, place_order_event);
    }

    /// Cancel market/limit-order.
    /// @Parameters
    /// _user: Signer & order owner.
    /// _order_id: Index of order to cancel
    public fun cancel_order<
        PairType,
        CollateralType
    >(
        _user: &signer,
        _order_id: u64
    ) acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
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
            cancelled_order,
            T_CANCEL_ORDER_BY_USER
        );
    }

    /// Cancel order.
    fun cancel_order_internal<
        PairType,
        CollateralType
    >(
        _order_id: u64,
        _order: Order,
        event_type: u64
    ) acquires TradingEvents, UserTradingEvents, UserStates {
        if (_order.is_increase) {
            // If it's an increase order, return the deposited collateral to the user.
            let withdrawed_coin = vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(
                _order.collateral_delta
            );
            coin::deposit(_order.user, withdrawed_coin);
        };

        // Emit cancel order event
        let cancel_order_event = CancelOrderEvent {
            uid: _order.uid,
            event_type,
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            user: _order.user,
            order_id: _order_id,
            size_delta: _order.size_delta,
            collateral_delta: _order.collateral_delta,
            price: _order.price,
            is_long: _order.is_long,
            is_increase: _order.is_increase,
            is_market: _order.is_market
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).cancel_order_events, cancel_order_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(_order.user).cancel_order_events, cancel_order_event);

        remove_order_id_from_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order_id);
        drop_order(_order);
    }

    /// Validate a order.
    fun validate_order<PairType, CollateralType>(
        _order: &Order,
        _position: &Position,
        _pair_info: &PairInfo<PairType, CollateralType>,
        _pair_state: &PairState<PairType, CollateralType>
    ) {

        // Verify price not 0
        assert!(_order.price != 0, E_PRICE_0);

        // Validate decrease order
        if (!_order.is_increase) {
            let new_position_size = _position.size - _order.size_delta;
            assert!(new_position_size == 0 || (new_position_size >= _pair_info.minimum_position_size), E_POSITION_SIZE_TOO_SMALL);
            assert!(_order.size_delta <= _position.size, E_ORDER_SIZE_DELTA_TOO_LARGE);
            assert!(!(_order.size_delta == 0 && _order.collateral_delta == 0), E_NOT_ZERO_SIZE_DELTA);
            return
        };

        // Validate new position size too small
        let new_position_size = _position.size + _order.size_delta;
        assert!(new_position_size >= _pair_info.minimum_position_size, E_POSITION_SIZE_TOO_SMALL);

        // Validate increase order
        assert!(_order.collateral_delta > 0, E_ZERO_COLLATERAL_DELTA);

        // check minimum order collateral delta size
        assert!(_order.collateral_delta >= _pair_info.minimum_order_collateral, E_ORDER_COLLATERAL_TOO_SMALL);

        let (_,
            _,
            _,
            is_risk_fee_profit,
            risk_fee) = calculate_risk_fees(
            _pair_state.acc_rollover_fee_per_collateral,
            _pair_state.acc_funding_fee_per_size,
            _pair_state.acc_funding_fee_per_size_positive,
            _position.size,
            _position.collateral,
            _order.is_long,
            _position.acc_rollover_fee_per_collateral,
            _position.acc_funding_fee_per_size,
            _position.acc_funding_fee_per_size_positive,
        );

        let entry_fee = calculate_maker_taker_fee(
            _pair_state.long_open_interest,
            _pair_state.short_open_interest,
            _pair_info.maker_fee,
            _pair_info.taker_fee,
            _order.size_delta,
            _order.is_long,
            _order.is_increase
        );

        // max open interest check
        let new_open_interest = _order.size_delta + if (_order.is_long) { _pair_state.long_open_interest } else { _pair_state.short_open_interest } ;
        assert!(new_open_interest <= _pair_info.max_open_interest, E_OVER_MAXIMUM_INTEREST);

        // leverage check
        let new_collateral = _position.collateral + _order.collateral_delta - entry_fee;
        if (is_risk_fee_profit) {
            new_collateral = new_collateral + risk_fee;
        } else {
            new_collateral = new_collateral - risk_fee;
        };
        assert!(new_collateral >= _pair_info.minimum_position_collateral, E_POSITION_COLLATERAL_TOO_SMALL);
        assert!(new_collateral <= _pair_info.maximum_position_collateral, E_POSITION_COLLATERAL_TOO_LARGE);
        // leverage add / sub padding 1 because of float diff fault
        assert!(
            safe_mul_div(new_position_size, LEVERAGE_PRECISION, new_collateral) >= _pair_info.min_leverage - 1,
            E_UNDER_MINIMUM_LEVEREAGE
        );
        assert!(
            safe_mul_div(new_position_size, LEVERAGE_PRECISION, new_collateral) <= _pair_info.max_leverage + 1,
            E_OVER_MAXIMUM_LEVEREAGE
        );
    }

    /// Drop order.
    fun drop_order(order: Order) {
        let Order {
            uid: _,
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
        _index_price: u64,
        _pyth_vaa: vector<u8>,
        _cap: &ExecuteCapability<PairType, CollateralType>
    ) acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);

        // Get order by id
        assert!(table::contains(&mut pair_state.orders, _order_id), E_ORDER_NOT_EXIST);
        let order = table::remove(&mut pair_state.orders, _order_id);

        // Check more than 30 seconds have passed since the order was created
        let now = timestamp::now_seconds();
        if ((order.is_market && now - order.created_timestamp > 30) ||
            (house_lp::check_hard_break_exceeded<CollateralType>() ||
                (house_lp::check_soft_break_exceeded<CollateralType>() && order.is_increase)
            )
        ) {
            cancel_order_internal<PairType, CollateralType>(
                _order_id,
                order,
                T_CANCEL_ORDER_EXPIRED
            );
            return
        };

        // Accrue rollover/funding fee
        accrue<PairType, CollateralType>(pair_info, pair_state);

        // Update oracle price
        price_oracle::update<PairType>(_executor, _index_price, _pyth_vaa);
        let price = price_oracle::read<PairType>(if (order.is_increase) order.is_long else !order.is_long);

        price = trading_calc::calculate_price_impact(
            price,
            order.size_delta,
            order.is_long,
            order.is_increase,
            pair_state.long_open_interest,
            pair_state.short_open_interest,
            pair_info.skew_factor
        );

        // Read oracle price & Execute increase/decrease order
        if (order.is_increase) {
            execute_increase_order_internal<PairType, CollateralType>(
                pair_info,
                pair_state,
                price,
                _order_id,
                order
            )
        } else {
            execute_decrease_order_internal<PairType, CollateralType>(
                pair_info,
                pair_state,
                price,
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
        _index_price: u64,
        _pyth_vaa: vector<u8>,
        _cap: &ExecuteCapability<PairType, CollateralType>
    ) acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // Borrow trading pair info
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);

        // Accrue rollover/funding fee
        accrue<PairType, CollateralType>(pair_info, pair_state);

        // Update & read oracle price
        price_oracle::update<PairType>(_executor, _index_price, _pyth_vaa);
        let price = price_oracle::read<PairType>(!_is_long);

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
        price = trading_calc::calculate_price_impact(
            price,
            position_ref_mut.size,
            _is_long,
            false,
            pair_state.long_open_interest,
            pair_state.short_open_interest,
            pair_info.skew_factor
        );

        // risk fee = rollover fee + funding fee
        let (rollover_fee,
            is_funding_fee_profit,
            funding_fee,
            is_risk_fee_profit,
            risk_fee) = calculate_risk_fees(
            pair_state.acc_rollover_fee_per_collateral,
            pair_state.acc_funding_fee_per_size,
            pair_state.acc_funding_fee_per_size_positive,
            position_ref_mut.size,
            position_ref_mut.collateral,
            _is_long,
            position_ref_mut.acc_rollover_fee_per_collateral,
            position_ref_mut.acc_funding_fee_per_size,
            position_ref_mut.acc_funding_fee_per_size_positive
        );
        let exit_fee = calculate_maker_taker_fee(
            pair_state.long_open_interest,
            pair_state.short_open_interest,
            pair_info.maker_fee,
            pair_info.taker_fee,
            position_ref_mut.size,
            _is_long,
            false
        );

        // Settle profit and loss and fee & Repay collateral to user
        let pnl_without_fee: u64;
        let is_profit: bool;
        let is_maximum_profit = false;
        {
            // Calculate pnl & closed collateral
            (pnl_without_fee, is_profit) = trading_calc::calculate_pnl_without_fee(
                position_ref_mut.avg_price,
                price,
                original_size,
                _is_long
            );

            // pnl_without_fee plus risk_fee
            let (settle_amount, is_deposit_to_lp) =
                calculate_settle_amount(
                    pnl_without_fee,
                    is_profit,
                    risk_fee,
                    is_risk_fee_profit
                );

            // limit maximum profit & minimum loss
            // this is for event, maximum pnl_without_fee
            if (is_profit) {
                pnl_without_fee = min(pnl_without_fee, safe_mul_div(position_ref_mut.collateral, pair_info.maximum_profit, BASIS_POINT));
            } else {
                pnl_without_fee = min(pnl_without_fee, position_ref_mut.collateral);
            };

            if (is_deposit_to_lp) {
                // If loss, deposited into the LP.
                settle_amount = min(settle_amount, position_ref_mut.collateral);
                position_ref_mut.collateral = position_ref_mut.collateral - settle_amount;
                house_lp::pnl_deposit_to_lp<CollateralType>(
                    vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(
                        settle_amount
                    )
                );
            } else {
                // If it is profit, withdraw from LP and deposited into collateral_vault (and user).
                if (settle_amount > safe_mul_div(position_ref_mut.collateral, pair_info.maximum_profit, BASIS_POINT)) {
                    is_maximum_profit = true;
                    settle_amount = safe_mul_div(position_ref_mut.collateral, pair_info.maximum_profit, BASIS_POINT);
                };
                position_ref_mut.collateral = position_ref_mut.collateral + settle_amount;
                vault::deposit_vault<vault_type::CollateralVault, CollateralType>(
                    house_lp::pnl_withdraw_from_lp<CollateralType>(settle_amount)
                );
            };
            // exit fee
            exit_fee = min(exit_fee, position_ref_mut.collateral);
            position_ref_mut.collateral = position_ref_mut.collateral - exit_fee;
            // Deposit exit fee to distributor
            fee_distributor::deposit_fee_with_rebate(
                vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(exit_fee),
                _user
            );
        };

        // Check is executable condition (liquidation / stop-loss / take-profit)
        let event_type = T_POSITION_LIQUIDATE;
        {
            let is_executable = false;
            if (position_ref_mut.collateral <= safe_mul_div(original_collateral, pair_info.liquidate_threshold, BASIS_POINT)) {
                // liquidate threshold basis point
                is_executable = true;
            } else if ((_is_long && position_ref_mut.take_profit_trigger_price <= price)
                || (!_is_long && position_ref_mut.take_profit_trigger_price >= price)
                || is_maximum_profit) {
                // take profit
                is_executable = true;
                event_type = T_POSITION_TAKE_PROFIT;
            } else if ((_is_long && position_ref_mut.stop_loss_trigger_price >= price)
                || (!_is_long && position_ref_mut.stop_loss_trigger_price <= price)) {
                // stop loss
                is_executable = true;
                event_type = T_POSITION_STOP_LOSS;
            };
            assert!(is_executable, E_NOT_OVER_THRESHOLD);
        };

        // increase xp
        profile::increase_xp(_user, exit_fee * 100);

        // Store position state
        {
            if (position_ref_mut.collateral > 0) {
                // If profit, deposit to user.
                coin::deposit(
                    _user,
                    vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(position_ref_mut.collateral)
                );
            };
            position_ref_mut.size = 0;
            position_ref_mut.collateral = 0;
            position_ref_mut.avg_price = 0;
        };

        // Store trading pair state
        let prev_long_open_interest = pair_state.long_open_interest;
        let prev_short_open_interest = pair_state.short_open_interest;
        {
            if (_is_long) {
                pair_state.long_open_interest = pair_state.long_open_interest - original_size;
            } else {
                pair_state.short_open_interest = pair_state.short_open_interest - original_size;
            };
        };

        // Emit position event
        let position_event = PositionEvent {
            uid: position_ref_mut.uid,
            event_type,
            pair_type: type_info::type_of<PairType>(),
            collateral_type:type_info::type_of<CollateralType>(),
            user: _user,
            order_id: 0,
            is_long: _is_long,
            price,
            original_size,
            size_delta: original_size,
            original_collateral,
            collateral_delta: original_collateral,
            is_increase: false,
            is_partial: false,
            pnl_without_fee,
            is_profit,
            entry_exit_fee: exit_fee,
            funding_fee,
            is_funding_fee_profit,
            rollover_fee,
            long_open_interest: prev_long_open_interest,
            short_open_interest: prev_short_open_interest
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
    public fun execute_order_self<
        PairType,
        CollateralType,
    >(
        _executor: &signer,
        _order_id: u64
    ) acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
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

        // Accrue rollover/funding fee
        accrue<PairType, CollateralType>(pair_info, pair_state);
        let index_price = price_oracle::read<PairType>(!order.is_long);
        let price = trading_calc::calculate_price_impact(
            index_price,
            order.size_delta,
            order.is_long,
            false,
            pair_state.long_open_interest,
            pair_state.short_open_interest,
            pair_info.skew_factor
        );

        // close position
        execute_decrease_order_internal<PairType, CollateralType>(
            pair_info,
            pair_state,
            price,
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
    ) acquires TradingEvents, UserTradingEvents, UserStates {
        assert!(_order.is_increase, E_NOT_INCREASE_ORDER);

        // Validate order is executable price
        // If unexecutable price, market-order cancel / limit-order abort
        // If _order.size_delta == 0, it's add collateral, so don't check
        if ((_order.price != _price) && (_order.size_delta > 0) &&
            (_order.can_execute_above_price != (_order.price < _price))) {
            // when limit order, revert and retry
            assert!(_order.is_market, E_UNEXECUTABLE_PRICE_LIMIT_ORDER);

            // when market order, cancel it
            cancel_order_internal<PairType, CollateralType>(
                _order_id,
                _order,
                T_CANCEL_ORDER_UNEXECUTABLE_MARKET_ORDER
            );
            return
        };

        // Validate Max OI
        if ((_order.is_long && _pair_state.long_open_interest + _order.size_delta > _pair_info.max_open_interest) ||
            (!_order.is_long && _pair_state.short_open_interest + _order.size_delta > _pair_info.max_open_interest)) {
            cancel_order_internal<PairType, CollateralType>(
                _order_id,
                _order,
                T_CANCEL_ORDER_OVER_MAX_INTEREST
            );
            return
        };

        // Get Order owner's position.
        // If not exist create new position.
        let position_ref_mut: &mut Position;
        {
            let positions_ref_mut =
                if (_order.is_long) { &mut _pair_state.long_positions }
                else { &mut _pair_state.short_positions };
            position_ref_mut = table::borrow_mut(positions_ref_mut, _order.user);
        };
        let event_type = if (position_ref_mut.size == 0) { T_POSITION_OPEN } else { T_POSITION_UPDATE };
        let original_size = position_ref_mut.size;
        let original_collateral = position_ref_mut.collateral;

        // risk fee = rollover fee + funding fee
        let (rollover_fee,
            is_funding_fee_profit,
            funding_fee,
            is_risk_fee_profit,
            risk_fee) = calculate_risk_fees(
            _pair_state.acc_rollover_fee_per_collateral,
            _pair_state.acc_funding_fee_per_size,
            _pair_state.acc_funding_fee_per_size_positive,
            position_ref_mut.size,
            position_ref_mut.collateral,
            _order.is_long,
            position_ref_mut.acc_rollover_fee_per_collateral,
            position_ref_mut.acc_funding_fee_per_size,
            position_ref_mut.acc_funding_fee_per_size_positive
        );
        let entry_fee = calculate_maker_taker_fee(
            _pair_state.long_open_interest,
            _pair_state.short_open_interest,
            _pair_info.maker_fee,
            _pair_info.taker_fee,
            _order.size_delta,
            _order.is_long,
            _order.is_increase
        );

        _order.collateral_delta = _order.collateral_delta - entry_fee;
        if (_order.collateral_delta > _pair_info.maximum_position_collateral) {
            cancel_order_internal<PairType, CollateralType>(
                _order_id,
                _order,
                T_CANCEL_ORDER_OVER_MAX_COLLATERAL
            );
            return
        };

        // deposit entry fee to fee_distributor
        fee_distributor::deposit_fee_with_rebate(
            vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(entry_fee),
            _order.user
        );
        profile::increase_xp(_order.user, entry_fee * 100);
        profile::add_daily_boost(_order.user);

        // Take position's cumulative risk fees
        if (is_risk_fee_profit) {
            position_ref_mut.collateral = position_ref_mut.collateral + risk_fee;
            vault::deposit_vault<vault_type::CollateralVault, CollateralType>(
                house_lp::pnl_withdraw_from_lp<CollateralType>(risk_fee)
            );
        } else {
            position_ref_mut.collateral = position_ref_mut.collateral - risk_fee;
            house_lp::pnl_deposit_to_lp<CollateralType>(
                vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(risk_fee)
            );
        };

        // Store position state
        {
            if (original_size == 0) {
                position_ref_mut.uid = _order.uid;
            };
            position_ref_mut.avg_price = trading_calc::calculate_new_price(
                position_ref_mut.avg_price,
                position_ref_mut.size,
                _price,
                _order.size_delta
            );
            position_ref_mut.acc_rollover_fee_per_collateral = _pair_state.acc_rollover_fee_per_collateral;
            position_ref_mut.last_execute_timestamp = timestamp::now_seconds();
            position_ref_mut.size = position_ref_mut.size + _order.size_delta;
            position_ref_mut.collateral = position_ref_mut.collateral + _order.collateral_delta;
            position_ref_mut.acc_funding_fee_per_size = _pair_state.acc_funding_fee_per_size;
            position_ref_mut.acc_funding_fee_per_size_positive = _pair_state.acc_funding_fee_per_size_positive;
            // If the stop loss price is greater than avg_price, it will be set to 0 or U64_MAX.
            // 0 or U64_MAX means no stop loss is used.
            // If the take profit price is greater than maximum_profit, it will be set to maximum_profit.
            let maximum_profit = safe_mul_div(
                position_ref_mut.collateral,
                _pair_info.maximum_profit,
                BASIS_POINT
            );
            if (_order.is_long) {
                position_ref_mut.stop_loss_trigger_price = _order.stop_loss_trigger_price;
                let maximum_take_profit_price = safe_mul_div(
                    position_ref_mut.avg_price,
                    (position_ref_mut.size + maximum_profit),
                    position_ref_mut.size
                );
                position_ref_mut.take_profit_trigger_price = min(_order.take_profit_trigger_price, maximum_take_profit_price)
            } else {
                position_ref_mut.stop_loss_trigger_price = _order.stop_loss_trigger_price;
                // If maximum profit is less than or equal to 0 in a short position, it will be set to 1.
                // This is because a price of 0 cannot occur.
                let maximum_take_profit_price = safe_mul_div(
                    position_ref_mut.avg_price,
                    if (position_ref_mut.size > maximum_profit) { position_ref_mut.size - maximum_profit } else 1,
                    position_ref_mut.size
                );
                position_ref_mut.take_profit_trigger_price = max(_order.take_profit_trigger_price, maximum_take_profit_price)
            };
        };

        // leverage check
        // leverage add / sub padding 1 because of float diff fault
        position_ref_mut.size = max(
            position_ref_mut.size,
            safe_mul_div(position_ref_mut.collateral, _pair_info.min_leverage, LEVERAGE_PRECISION)
        );
        position_ref_mut.size = min(
            position_ref_mut.size,
            safe_mul_div(position_ref_mut.collateral, _pair_info.max_leverage, LEVERAGE_PRECISION)
        );
        let size_delta = position_ref_mut.size - original_size;

        // Store trading pair state
        let prev_long_open_interest = _pair_state.long_open_interest;
        let prev_short_open_interest = _pair_state.short_open_interest;
        {
            if (_order.is_long) {
                _pair_state.long_open_interest = _pair_state.long_open_interest + size_delta;
            } else {
                _pair_state.short_open_interest = _pair_state.short_open_interest + size_delta;
            };
        };

        // Emit position event
        let position_event = PositionEvent {
            uid: position_ref_mut.uid,
            event_type,
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            user: _order.user,
            order_id: _order_id,
            is_long: _order.is_long,
            price: _price,
            original_size,
            size_delta,
            original_collateral,
            collateral_delta: _order.collateral_delta,
            is_increase: true,
            is_partial: (position_ref_mut.size != _order.size_delta),
            pnl_without_fee: 0,
            is_profit: false,
            entry_exit_fee: entry_fee,
            funding_fee,
            is_funding_fee_profit,
            rollover_fee,
            long_open_interest: prev_long_open_interest,
            short_open_interest: prev_short_open_interest
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
    ) acquires TradingEvents, UserTradingEvents, UserStates {
        assert!(!_order.is_increase, E_NOT_DECREASE_ORDER);

        // Validate order is executable price
        // If unexecutable price, market-order cancel / limit-order abort
        if ((_order.price != _price) &&
            (_order.can_execute_above_price != (_order.price < _price))) {
            assert!(_order.is_market, E_UNEXECUTABLE_PRICE_LIMIT_ORDER);
            cancel_order_internal<PairType, CollateralType>(
                _order_id,
                _order,
                T_CANCEL_ORDER_UNEXECUTABLE_MARKET_ORDER
            );
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

        if (position_ref_mut.size < _order.size_delta) {
            // not enough position size
            // maybe already liquidated
            cancel_order_internal<PairType, CollateralType>(
                _order_id,
                _order,
                T_CANCEL_ORDER_NOT_ENOUGH_SIZE
            );
            return
        };

        let original_size = position_ref_mut.size;
        let is_fully_close = original_size == _order.size_delta;

        // risk fee = rollover fee + funding fee
        let (rollover_fee,
            is_funding_fee_profit,
            funding_fee,
            is_risk_fee_profit,
            risk_fee) = calculate_risk_fees(
            _pair_state.acc_rollover_fee_per_collateral,
            _pair_state.acc_funding_fee_per_size,
            _pair_state.acc_funding_fee_per_size_positive,
            position_ref_mut.size,
            position_ref_mut.collateral,
            _order.is_long,
            position_ref_mut.acc_rollover_fee_per_collateral,
            position_ref_mut.acc_funding_fee_per_size,
            position_ref_mut.acc_funding_fee_per_size_positive
        );
        let exit_fee = calculate_maker_taker_fee(
            _pair_state.long_open_interest,
            _pair_state.short_open_interest,
            _pair_info.maker_fee,
            _pair_info.taker_fee,
            _order.size_delta,
            _order.is_long,
            _order.is_increase
        );

        // Calculate pnl
        let (pnl_without_fee, is_profit) = trading_calc::calculate_pnl_without_fee(
            position_ref_mut.avg_price,
            _price,
            _order.size_delta,
            _order.is_long
        );
        let collateral_delta = if (is_fully_close) position_ref_mut.collateral else _order.collateral_delta;
        let original_collateral = position_ref_mut.collateral;

        // calculate settle amount (pnl + risk fee)
        let (settle_amount, is_deposit_to_lp) =
            calculate_settle_amount(
                pnl_without_fee,
                is_profit,
                risk_fee,
                is_risk_fee_profit
            );

        // limit maximum profit & minimum loss
        // this is for event, maximum pnl_without_fee
        if (is_profit) {
            pnl_without_fee = min(pnl_without_fee, safe_mul_div(position_ref_mut.collateral, _pair_info.maximum_profit, BASIS_POINT));
        } else {
            pnl_without_fee = min(pnl_without_fee, position_ref_mut.collateral);
        };
        
        if (is_deposit_to_lp) {
            // Check if loss is greater than collateral
            settle_amount = min(settle_amount, original_collateral);
        } else {
            // Check if profit is greater than max profit
            settle_amount = min(settle_amount, safe_mul_div(position_ref_mut.collateral, _pair_info.maximum_profit, BASIS_POINT));
        };

        // calculate withdraw amount, decrease collateral amount and increase amount
        let (withdraw_amount, decrease_collateral) = calculate_partial_close_amounts(
            collateral_delta,
            settle_amount,
            is_deposit_to_lp,
            exit_fee
        );
        let new_collateral = 0;
        if (is_fully_close) {
            // decrease exit_fee if is not enough
            if (position_ref_mut.collateral < decrease_collateral) {
                let diff = decrease_collateral - position_ref_mut.collateral;
                if (diff < exit_fee) {
                    exit_fee = exit_fee - diff;
                } else {
                    exit_fee = 0;
                };
            }
        } else {
            // if position is not fully closed, check leverage limit
            let new_leverage = 0;
            if (decrease_collateral < position_ref_mut.collateral) {
                new_collateral = position_ref_mut.collateral - decrease_collateral;
                new_leverage = safe_mul_div(position_ref_mut.size - _order.size_delta, LEVERAGE_PRECISION, new_collateral);
            };
            if (new_collateral == 0 ||
                new_leverage < _pair_info.min_leverage ||
                new_leverage > _pair_info.max_leverage) {
                let cancel_order_event_type = T_CANCEL_ORDER_NOT_ENOUGH_COLLATERAL;
                if (new_leverage < _pair_info.min_leverage) {
                    cancel_order_event_type = T_CANCEL_ORDER_UNDER_MIN_LEVERAGE;
                } else if (new_leverage > _pair_info.max_leverage) {
                    cancel_order_event_type = T_CANCEL_ORDER_OVER_MAX_LEVERAGE;
                };
                cancel_order_internal<PairType, CollateralType>(
                    _order_id,
                    _order,
                    cancel_order_event_type
                );
                return
            };
        };

        // exit fee
        fee_distributor::deposit_fee_with_rebate(
            vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(exit_fee),
            _order.user
        );
        profile::increase_xp(_order.user, exit_fee * 100);

        // calculate assets
        if (is_deposit_to_lp) {
            house_lp::pnl_deposit_to_lp<CollateralType>(
                vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(settle_amount)
            );
        } else {
            vault::deposit_vault<vault_type::CollateralVault, CollateralType>(
                house_lp::pnl_withdraw_from_lp<CollateralType>(settle_amount)
            );
        };

        if (withdraw_amount > 0) {
            // profit or, if there is any collateral left, deposit it to user
            coin::deposit(
                _order.user,
                vault::withdraw_vault<vault_type::CollateralVault, CollateralType>(withdraw_amount)
            );
        };

        // Store position state
        {
            position_ref_mut.acc_rollover_fee_per_collateral = _pair_state.acc_rollover_fee_per_collateral;
            position_ref_mut.last_execute_timestamp = timestamp::now_seconds();
            position_ref_mut.size = position_ref_mut.size - _order.size_delta;
            position_ref_mut.collateral = new_collateral;
        };

        // Store trading pair state
        let prev_long_open_interest = _pair_state.long_open_interest;
        let prev_short_open_interest = _pair_state.short_open_interest;
        {
            if (_order.is_long) {
                _pair_state.long_open_interest = _pair_state.long_open_interest - _order.size_delta;
            } else {
                _pair_state.short_open_interest = _pair_state.short_open_interest - _order.size_delta;
            };
        };

        // Emit position event
        let event_type = if (is_fully_close) T_POSITION_CLOSE else T_POSITION_UPDATE;
        let position_event = PositionEvent {
            uid: position_ref_mut.uid,
            event_type,
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            user: _order.user,
            order_id: _order_id,
            is_long: _order.is_long,
            price: _price,
            original_size,
            size_delta: _order.size_delta,
            original_collateral,
            collateral_delta,
            is_increase: false,
            is_partial: (position_ref_mut.size != 0),
            pnl_without_fee,
            is_profit,
            entry_exit_fee: exit_fee,
            funding_fee,
            is_funding_fee_profit,
            rollover_fee,
            long_open_interest: prev_long_open_interest,
            short_open_interest: prev_short_open_interest
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).position_events, position_event);
        event::emit_event(&mut borrow_global_mut<UserTradingEvents>(_order.user).position_events, position_event);
        if (position_ref_mut.size == 0) {
            remove_position_key_from_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order.is_long);
        };

        // Drop order
        remove_order_id_from_user_states(_order.user, type_info::type_of<PairType>(), type_info::type_of<CollateralType>(), _order_id);
        drop_order(_order);
    }

    /// update take profit and stop loss at user position
    /// @Parameters
    /// _is_long: side for update
    /// _take_profit_trigger_price: take profit for update
    /// _stop_loss_trigger_price: stop loss for update
    public fun update_position_tp_sl<
        PairType,
        CollateralType
    >(
        _host: &signer,
        _is_long: bool,
        _take_profit_trigger_price: u64,
        _stop_loss_trigger_price: u64
    ) acquires PairState, PairInfo, TradingEvents {
        let host_addr = address_of(_host);
        let pair_info =
            borrow_global<PairInfo<PairType, CollateralType>>(@merkle);
        assert!(!pair_info.paused, E_PAUSED_PAIR);
        let pair_state =
            borrow_global_mut<PairState<PairType, CollateralType>>(@merkle);

        let positions_ref_mut =
            if (_is_long) { &mut pair_state.long_positions }
            else { &mut pair_state.short_positions };
        assert!(table::contains(positions_ref_mut, host_addr), E_POSITION_NOT_EXIST);
        let position_ref_mut = table::borrow_mut(positions_ref_mut, host_addr);
        assert!(position_ref_mut.collateral != 0, E_POSITION_NOT_EXIST);

        // validate max profit
        let price_change = safe_mul_div(
            abs(_take_profit_trigger_price, position_ref_mut.avg_price),
            BASIS_POINT,
            position_ref_mut.avg_price
        );
        let tp_percent = safe_mul_div(position_ref_mut.size, price_change, position_ref_mut.collateral);
        assert!(tp_percent <= pair_info.maximum_profit, E_UPDATE_TAKE_PROFIT_INVALID);

        // update
        position_ref_mut.take_profit_trigger_price = _take_profit_trigger_price;
        position_ref_mut.stop_loss_trigger_price = _stop_loss_trigger_price;

        let update_tpsl_event = UpdateTPSLEvent {
            uid: position_ref_mut.uid,
            pair_type: type_info::type_of<PairType>(),
            collateral_type: type_info::type_of<CollateralType>(),
            user: host_addr,
            is_long: _is_long,
            take_profit_trigger_price: _take_profit_trigger_price,
            stop_loss_trigger_price: _stop_loss_trigger_price
        };
        event::emit_event(&mut borrow_global_mut<TradingEvents>(@merkle).update_tp_sl_events, update_tpsl_event);
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
        // MUST calculate funding per size FIRST, BEFORE calculate funding rate
        let now = timestamp::now_seconds();
        let (current_funding_rate, current_funding_rate_positive) = trading_calc::calculate_funding_rate(
            _pair_state.funding_rate,
            _pair_state.funding_rate_positive,
            _pair_state.long_open_interest,
            _pair_state.short_open_interest,
            _pair_info.skew_factor,
            _pair_info.max_funding_velocity,
            now - _pair_state.last_accrue_timestamp
        );
        let (current_funding_fee_per_size, current_funding_fee_per_size_positive) = trading_calc::calculate_funding_fee_per_size(
            _pair_state.acc_funding_fee_per_size,
            _pair_state.acc_funding_fee_per_size_positive,
            _pair_state.funding_rate,
            _pair_state.funding_rate_positive,
            current_funding_rate,
            current_funding_rate_positive,
            now - _pair_state.last_accrue_timestamp
        );


        // Rollover fee
        let rollover_fee_delta = trading_calc::calculate_rollover_fee_delta(
            _pair_state.last_accrue_timestamp,
            timestamp::now_seconds(),
            _pair_info.rollover_fee_per_timestamp
        );

        _pair_state.acc_rollover_fee_per_collateral = _pair_state.acc_rollover_fee_per_collateral + rollover_fee_delta;
        _pair_state.acc_funding_fee_per_size = current_funding_fee_per_size;
        _pair_state.acc_funding_fee_per_size_positive = current_funding_fee_per_size_positive;
        _pair_state.funding_rate = current_funding_rate;
        _pair_state.funding_rate_positive = current_funding_rate_positive;
        _pair_state.last_accrue_timestamp = now;
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

    public fun set_rollover_fee_per_block<PairType, CollateralType>(
        _fee: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.rollover_fee_per_timestamp = _fee;
    }

    public fun set_maker_fee<PairType, CollateralType>(
        _fee: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.maker_fee = _fee;
    }

    public fun set_taker_fee<PairType, CollateralType>(
        _fee: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.taker_fee = _fee;
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

    public fun set_skew_factor<PairType, CollateralType>(
        _skew_factor: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.skew_factor = _skew_factor;
    }

    public fun set_max_funding_velocity<PairType, CollateralType>(
        _max_funding_velocity: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.max_funding_velocity = _max_funding_velocity;
    }

    public fun set_minimum_order_collateral<PairType, CollateralType>(
        _minimum_collateral: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.minimum_order_collateral = _minimum_collateral;
    }

    public fun set_minimum_position_collateral<PairType, CollateralType>(
        _minimum_collateral: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.minimum_position_collateral = _minimum_collateral;
    }

    public fun set_minimum_position_size<PairType, CollateralType>(
        _minimum_position_size: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.minimum_position_size = _minimum_position_size;
    }

    public fun set_maximum_position_collateral<PairType, CollateralType>(
        _maximum_collateral: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.maximum_position_collateral = _maximum_collateral;
    }

    public fun set_execution_fee<PairType, CollateralType>(
        _execution_fee: u64,
        _admin_cap: &AdminCapability<PairType, CollateralType>,
    ) acquires PairInfo {
        let pair_ref_mut = borrow_global_mut<PairInfo<PairType, CollateralType>>(@merkle);
        pair_ref_mut.execution_fee = _execution_fee;
    }

    // <-- TEST CODE ----->

    #[test_only]
    struct TestPair has key, store, drop {}

    #[test_only]
    struct TEST_USDC has store, drop {}

    #[test_only]
    use merkle::referral;

    #[test_only]
    struct CapStore has key {
        mint_cap: MintCapability<AptosCoin>,
        burn_cap: BurnCapability<AptosCoin>,
    }

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
    fun call_test_setting(host: &signer, aptos_framework: &signer)
    : (ExecuteCapability<TestPair, TEST_USDC>, AdminCapability<TestPair, TEST_USDC>) acquires PairInfo {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_account::create_account(address_of(host));
        price_oracle::register_oracle<TestPair>(host);

        vault::register_vault<vault_type::CollateralVault, TEST_USDC>(host);
        vault::register_vault<vault_type::HouseLPVault, TEST_USDC>(host);
        vault::register_vault<vault_type::FeeHouseLPVault, TEST_USDC>(host);
        vault::register_vault<vault_type::FeeStakingVault, TEST_USDC>(host);
        vault::register_vault<vault_type::FeeDevVault, TEST_USDC>(host);

        let (execute_cap, admin_cap) = initialize<TestPair, TEST_USDC>(host);
        set_maker_fee(500, &admin_cap);
        set_taker_fee(1000, &admin_cap);
        set_max_interest(10000000 * INTEREST_PRECISION, &admin_cap);
        set_min_leverage(3 * LEVERAGE_PRECISION, &admin_cap);
        set_max_leverage(100 * LEVERAGE_PRECISION, &admin_cap);
        set_minimum_order_collateral(10, &admin_cap);
        set_minimum_position_collateral(100, &admin_cap);
        create_test_coins<TEST_USDC>(host, b"USDC", 8, 10000000 * 100000000);
        house_lp::register<TEST_USDC>(host);
        house_lp::deposit<TEST_USDC>(host, 1000000 * 1000000);

        fee_distributor::initialize<TEST_USDC>(host);
        fee_distributor::set_lp_weight<TEST_USDC>(host, 6);
        fee_distributor::set_dev_weight<TEST_USDC>(host, 2);
        fee_distributor::set_stake_weight<TEST_USDC>(host, 2);

        profile::init_module_for_test(host);
        lootbox::init_module_for_test(host);

        referral::call_test_setting<TEST_USDC>(host, aptos_framework);

        (execute_cap, admin_cap)
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Test initialize
    fun T_initialize(host: &signer, aptos_framework: &signer) {
        aptos_account::create_account(address_of(host));
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize<TestPair, TEST_USDC>(
            host
        );
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test place order
    fun T_place_order(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
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
    #[expected_failure(abort_code = E_ZERO_COLLATERAL_DELTA, location = Self)]
    /// Fail test place order zero collateral delta
    fun T_place_order_E_ZERO_COLLATERAL_DELTA(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        call_test_setting(host, aptos_framework);

        // when
        place_order<TestPair, TEST_USDC>(host, 500000, 0, 300000, true, true, true, 0, 0, true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test cancel order
    fun T_cancel_order(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
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
    #[expected_failure(abort_code = E_ORDER_NOT_EXIST, location = Self)]
    /// Fail test cancel order
    fun T_cancel_order_E_ORDER_NOT_EXIST(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        call_test_setting(host, aptos_framework);

        // when
        cancel_order<TestPair, TEST_USDC>(host, 1);
    }


    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_execute_increase_market_order(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let size = 500000;
        place_order<TestPair, TEST_USDC>(host, size, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(!table::contains(&mut pair_state.orders, 1), 0);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == size, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_execute_increase_market_order_2(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let size = 500000;
        place_order<TestPair, TEST_USDC>(host, size, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 400000, vector::empty(), &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(!table::contains(&mut pair_state.orders, 1), 0);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == size, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_execute_increase_market_order_cancel(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 200000, vector::empty(), &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        assert!(!table::contains(&mut pair_state.orders, 1), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_UNEXECUTABLE_PRICE_LIMIT_ORDER, location = Self)]
    /// Fail test execute increase limit order
    fun T_execute_increase_limit_order_E_UNEXECUTABLE_PRICE_LIMIT_ORDER(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, false, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 200000, vector::empty(), &execute_cap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_ORDER_NOT_EXIST, location = Self)]
    /// Fail test execute increase limit order
    fun T_execute_increase_limit_order_E_NOT_EXIST_ORDER(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, false, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 2, 200000, vector::empty(), &execute_cap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    fun T_execute_decrease_market_order_long(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let original_size = 500000;
        place_order<TestPair, TEST_USDC>(host, original_size, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 310000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, 0, 300000, true, false, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.size == 0, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    fun T_execute_decrease_market_order_long_partial(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 100000;
        let original_size = 500000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        // coll size = 100000, pos size = 500000
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        // position opened
        // entry fee = 1500
        // coll size = 98500, pos size = 500000
        let before_coll = coin::balance<TEST_USDC>(address_of(host));
        place_order<TestPair, TEST_USDC>(host, original_size/2, coll_size/2, 300000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);
        // half of position (250000) closed
        // exit fee = 500 ( 250000 * 0.2% )
        // coll size left = 49250, coll size out = 48500, pos size left = 250000,
        let after_coll = coin::balance<TEST_USDC>(address_of(host));

        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
        assert!(coll_size / 2 - (after_coll - before_coll) == original_size / 2 * pair_info.maker_fee / MAKER_TAKER_FEE_PRECISION, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order profit
    fun T_execute_partial_decrease_profit(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 100000;
        let original_size = 500000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        // coll size = 100000, pos size = 500000
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        // position opened
        // entry fee = 1500
        // coll size = 98500, pos size = 500000
        let before_coll = coin::balance<TEST_USDC>(address_of(host));
        place_order<TestPair, TEST_USDC>(host, original_size/2, coll_size/2, 330000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 330000, vector::empty(), &execute_cap);
        // half of position (250000) closed
        // exit fee = 500 ( 250000 * 0.2% )
        // coll size left = 49250, coll size out = 48500, pos size left = 250000,
        // profit = 25000
        let after_coll = coin::balance<TEST_USDC>(address_of(host));

        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
        assert!((after_coll - before_coll) == coll_size / 2 + original_size / 2 / 10 - (original_size / 2 * pair_info.maker_fee / MAKER_TAKER_FEE_PRECISION), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order loss
    fun T_execute_partial_decrease_loss(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 100000;
        let original_size = 500000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        // coll size = 100000, pos size = 500000
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        // position opened
        // entry fee = 1500
        // coll size = 98500, pos size = 500000
        let before_coll = coin::balance<TEST_USDC>(address_of(host));
        place_order<TestPair, TEST_USDC>(host, original_size/2, coll_size/2, 270000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 270000, vector::empty(), &execute_cap);
        // half of position (250000) closed
        // exit fee = 500 ( 250000 * 0.2% )
        // coll size left = 49250, coll size out = 48500, pos size left = 250000,
        // loss = 25000
        let after_coll = coin::balance<TEST_USDC>(address_of(host));

        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
        assert!((after_coll - before_coll) == coll_size / 2 - original_size / 2 / 10 - (original_size / 2 * pair_info.maker_fee / MAKER_TAKER_FEE_PRECISION), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order loss with small collateral
    fun T_execute_partial_decrease_loss_small_collateral(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 100000;
        let original_size = 500000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        // coll size = 100000, pos size = 500000
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        // position opened
        // entry fee = 1500
        // coll size = 98500, pos size = 500000
        let before_coll = coin::balance<TEST_USDC>(address_of(host));
        place_order<TestPair, TEST_USDC>(host, original_size/2, 10, 270000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 270000, vector::empty(), &execute_cap);
        // half of position (250000) closed
        // exit fee = 500 ( 250000 * 0.2% )
        // loss = 25000
        // coll size left = 72990, coll size out = 0, pos size left = 250000,
        let after_coll = coin::balance<TEST_USDC>(address_of(host));
        assert!((after_coll - before_coll) == 0, 0);

        let pair_state =  borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
        let entry_fee = original_size * pair_info.taker_fee / MAKER_TAKER_FEE_PRECISION;
        let exit_fee = original_size / 2 * pair_info.maker_fee / MAKER_TAKER_FEE_PRECISION;
        assert!(position.collateral == coll_size - (entry_fee + original_size / 2 / 10 + exit_fee), 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order loss twice
    fun T_execute_partial_decrease_twice(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 100000;
        let original_size = 500000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        let before_coll = coin::balance<TEST_USDC>(address_of(host));
        place_order<TestPair, TEST_USDC>(host, original_size/2, 10, 270000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 270000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size/2, 0, 270000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 270000, vector::empty(), &execute_cap);

        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
        let entry_fee = original_size * pair_info.taker_fee / MAKER_TAKER_FEE_PRECISION;
        let exit_fee = original_size * pair_info.maker_fee / MAKER_TAKER_FEE_PRECISION;
        let after_coll = coin::balance<TEST_USDC>(address_of(host));
        assert!((after_coll - before_coll) == coll_size - entry_fee - exit_fee - original_size/10, 0);

        let pair_state =  borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.collateral == 0, 1);
        assert!(position.size == 0, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order but not enough exit fee
    fun T_execute_partial_decrease_not_enough_exit_fee(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 100000;
        let original_size = 500000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        let before_coll = coin::balance<TEST_USDC>(address_of(host));
        place_order<TestPair, TEST_USDC>(host, original_size, 0, 240200, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 240200, vector::empty(), &execute_cap);
        let after_coll = coin::balance<TEST_USDC>(address_of(host));
        assert!((after_coll - before_coll) == 0, 0);

        let pair_state =  borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.collateral == 0, 1);
        assert!(position.size == 0, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    fun T_execute_decrease_market_order_short(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, false, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 310000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, 300000, 60000, 300000, false, false, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);

        // then
        let pair_state =
            borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.short_positions, address_of(host));
        assert!(position.size == 200000, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test liquidate position
    fun T_liquidate(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            100000,
            vector::empty(),
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
    fun T_stop_loss(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 299000, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            298000,
            vector::empty(),
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
    fun T_take_profit(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 301000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            305000,
            vector::empty(),
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
    #[expected_failure(abort_code = E_NOT_OVER_THRESHOLD, location = Self)]
    /// Fail test execute without order not over threshold
    fun T_execute_exit_position_E_NOT_OVER_THRESHOLD(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 200000, 400000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            300000,
            vector::empty(),
            &execute_cap
        );
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test close_position maximum_profit
    fun T_maximum_profit_close_position(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let host_addr = address_of(host);
        let original_value = coin::balance<TEST_USDC>(host_addr);
        let size_value = 500000;
        let coll_value = 100000;

        place_order<TestPair, TEST_USDC>(host, size_value, coll_value, 300000, true, true, true, 0, 30000000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        place_order<TestPair, TEST_USDC>(host, size_value, 0, 3000000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 3000000, vector::empty(), &execute_cap);
        let after_value = coin::balance<TEST_USDC>(host_addr);
        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(host_addr);
        let entry_fee = safe_mul_div(size_value, pair_info.taker_fee, MAKER_TAKER_FEE_PRECISION);
        let exit_fee = safe_mul_div(size_value, pair_info.maker_fee, MAKER_TAKER_FEE_PRECISION);

        assert!(after_value - original_value == safe_mul_div(coll_value - entry_fee, pair_info.maximum_profit, BASIS_POINT) - entry_fee - exit_fee, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test stop_profit maximum_profit
    fun T_maximum_profit_stop_profit(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let host_addr = address_of(host);
        let original_value = coin::balance<TEST_USDC>(host_addr);
        let size_value = 500000;
        let coll_value = 100000;

        place_order<TestPair, TEST_USDC>(host, size_value, coll_value, 300000, true, true, true, 0, 2700000, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // when
        execute_exit_position<TestPair, TEST_USDC>(
            host,
            address_of(host),
            true,
            3000000,
            vector::empty(),
            &execute_cap
        );
        let after_value = coin::balance<TEST_USDC>(host_addr);
        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(host_addr);
        let entry_fee = safe_mul_div(size_value, pair_info.taker_fee, MAKER_TAKER_FEE_PRECISION);
        let exit_fee = safe_mul_div(size_value, pair_info.maker_fee, MAKER_TAKER_FEE_PRECISION);

        assert!(after_value - original_value == safe_mul_div(coll_value - entry_fee, pair_info.maximum_profit, BASIS_POINT) - entry_fee - exit_fee, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test stop_profit maximum_profit
    fun T_user_states_order_positions(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
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

        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
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

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_NOT_ZERO_SIZE_DELTA, location = Self)]
    /// Success test execute decrease market order
    fun T_execute_decrease_market_order_fail(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let original_size = 500000;
        place_order<TestPair, TEST_USDC>(host, original_size, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 310000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, 0, 0, 300000, true, false, true, 0, 0, true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    fun T_execute_decrease_market_order_change_leverage(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);

        // place position, size: 500000, collateral: 100000, price: 300000
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        let decrease_size = 100000;
        let before_size: u64;
        let before_collatera: u64;
        {
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            before_size = position_ref.size;
            before_collatera = position_ref.collateral;
        };
        let before_amount = coin::balance<TEST_USDC>(address_of(host));

        // decrease position, size delta: 100000, collateral delta: 0, price: 300000 -> only exit fee paid
        place_order<TestPair, TEST_USDC>(host, decrease_size, 0, 300000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);
        // no profit, no collateral exit, so exit fee paid from position collateral
        let after_amount = coin::balance<TEST_USDC>(address_of(host));
        assert!(before_amount == after_amount, 0);
        {
            let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            let exit_fee = safe_mul_div(decrease_size, pair_info.maker_fee, MAKER_TAKER_FEE_PRECISION);
            assert!(before_size - position_ref.size == decrease_size, 1);
            assert!(before_collatera - position_ref.collateral == exit_fee, 2);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order with profit
    fun T_execute_decrease_market_order_profit(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);

        // place position, size: 500000, collateral: 100000, price: 300000
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        let decrease_size = 100000;
        let before_amount = coin::balance<TEST_USDC>(address_of(host));
        let collateral_size: u64;
        {
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            collateral_size = position_ref.collateral;
        };

        // decrease position, size delta: 100000, collateral delta: 0, price: 330000 -> 10% price increase,
        place_order<TestPair, TEST_USDC>(host, decrease_size, 0, 330000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 330000, vector::empty(), &execute_cap);
        // 10% profit from size delta -> 10000, collateral delta: 0, exit fee 300 -> 9700 out
        let after_profit_amount = coin::balance<TEST_USDC>(address_of(host));
        {
            let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            let exit_fee = safe_mul_div(decrease_size, pair_info.maker_fee, MAKER_TAKER_FEE_PRECISION);
            assert!(after_profit_amount - before_amount == decrease_size / 10 - exit_fee, 3);
            assert!(collateral_size - position_ref.collateral == 0, 1);
        };

        // decrease position, size delta: 0, collateral delta: 1000, price: 330000 -> 10% price increase,
        place_order<TestPair, TEST_USDC>(host, 0, 1000, 300000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 300000, vector::empty(), &execute_cap);
        // 10% profit from size delta -> 0, collateral delta: 1000, exit fee 0 -> no pnl, exit fee
        let after_only_collateral_amount = coin::balance<TEST_USDC>(address_of(host));
        assert!(after_only_collateral_amount - after_profit_amount == 1000, 4);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order with loss
    fun T_execute_decrease_market_order_loss(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);

        // place position, size: 500000, collateral: 100000, price: 300000
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        let before_amount = coin::balance<TEST_USDC>(address_of(host));
        let collateral_before_loss: u64;
        {
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(address_of(host));
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            collateral_before_loss = position_ref.collateral;
        };

        // decrease position, size delta: 10000, collateral delta: 0, price: 270000 -> 10% price decrease,
        place_order<TestPair, TEST_USDC>(host, 10000, 0, 270000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 270000, vector::empty(), &execute_cap);
        // 10% loss from size delta -> 10000, collateral delta: 0, exit fee 0 -> paid out 0
        let after_loss_amount = coin::balance<TEST_USDC>(address_of(host));
        assert!(after_loss_amount == before_amount, 5);
        {
            let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
            let exit_fee = safe_mul_div(10000, pair_info.maker_fee, MAKER_TAKER_FEE_PRECISION);
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            assert!(collateral_before_loss - position_ref.collateral == 1000 + exit_fee, 6);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_ORDER_NOT_EXIST, location = Self)]
    /// Success test execute decrease market order
    fun T_execute_decrease_market_cancel(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 500000, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        let size_before: u64;
        let collateral_before: u64;
        {
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            size_before = position_ref.size;
            collateral_before = position_ref.collateral;
        };

        place_order<TestPair, TEST_USDC>(host, 400000, 0, 300000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);
        // leverage(1x) became less than minimum leverage(3x), order canceled
        {
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            assert!(size_before == position_ref.size, 0);
            assert!(collateral_before == position_ref.collateral, 1);
        };

        place_order<TestPair, TEST_USDC>(host, 0, 98000, 300000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 300000, vector::empty(), &execute_cap);
        // leverage(1000x) became more than maximum leverage(100x), order canceled
        {
            let pair_state = borrow_global<PairState<TestPair, TEST_USDC>>(@merkle);
            let position_ref = table::borrow(&pair_state.long_positions, address_of(host));
            assert!(size_before == position_ref.size, 2);
            assert!(collateral_before == position_ref.collateral, 3);
        };
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);
        execute_order<TestPair, TEST_USDC>(host, 3, 300000, vector::empty(), &execute_cap);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute decrease market order
    fun T_execute_decrease_market_with_risk_fee(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, admin_cap) = call_test_setting(host, aptos_framework);
        let rollover_fee_per_block = 10;
        let size = 50000000000;
        let coll_size = 1000000000;
        set_rollover_fee_per_block<TestPair, TEST_USDC>(rollover_fee_per_block, &admin_cap);

        place_order<TestPair, TEST_USDC>(host, size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        let time_passed = 10000;
        timestamp::fast_forward_seconds(time_passed);
        {
            let is_risk_fee_profit = false;
            let risk_fee: u64;
            let rollover_fee: u64;
            let entry_fee: u64;
            {
                let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
                let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
                entry_fee = size / MAKER_TAKER_FEE_PRECISION * pair_info.taker_fee;

                accrue(pair_info, pair_state);

                let position_ref_mut = table::borrow_mut(&mut pair_state.long_positions, address_of(host));

                rollover_fee = trading_calc::calculate_rollover_fee(
                    position_ref_mut.acc_rollover_fee_per_collateral,
                    pair_state.acc_rollover_fee_per_collateral,
                    position_ref_mut.collateral
                );

                // add funding fee
                risk_fee = rollover_fee;
            };
            assert!(is_risk_fee_profit == false, 0);
            // rollover_fee_per_block = 1e6 -> 1%
            let calc_rollover_fee = (coll_size - entry_fee) / 100 * rollover_fee_per_block / 1000000 * time_passed;
            assert!(risk_fee == calc_rollover_fee, 1);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_update_tp_sl(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let size = 500000;
        place_order<TestPair, TEST_USDC>(host, size, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // then
        {
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            let position = table::borrow(&mut pair_state.long_positions, address_of(host));
            assert!(position.take_profit_trigger_price == 0, 0);
            assert!(position.stop_loss_trigger_price == 0, 1);
        };
        update_position_tp_sl<TestPair, TEST_USDC>(host, true, 330000, 270000);
        {
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            let position = table::borrow(&mut pair_state.long_positions, address_of(host));
            assert!(position.take_profit_trigger_price == 330000, 2);
            assert!(position.stop_loss_trigger_price == 270000, 3);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_UPDATE_TAKE_PROFIT_INVALID, location = Self)]
    /// Success test execute increase market order
    fun T_update_tp_sl_tp_failed(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 1000000, 100000, 300000, true, true, true, 0, 0, true);

        // when
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        // then
        {
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            let position = table::borrow(&mut pair_state.long_positions, address_of(host));
            assert!(position.take_profit_trigger_price == 0, 0);
            assert!(position.stop_loss_trigger_price == 0, 1);
        };
        update_position_tp_sl<TestPair, TEST_USDC>(host, true, 600000, 270000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_increase_collateral_without_size(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 1000000, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, 0, 100000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);

        // then
        {
            let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            let position = table::borrow(&mut pair_state.long_positions, address_of(host));
            let entry_fee = safe_mul_div(1000000, pair_info.taker_fee, MAKER_TAKER_FEE_PRECISION);
            assert!(position.size == 1000000, 1);
            assert!(position.collateral == 200000 - entry_fee, 2);
        };
    }

    #[test(host = @merkle, host2 = @0xC0FFEE, host3 = @0xCAFE, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_decrease_position_cancel(host: &signer, host2: &signer, host3: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(host2));
        aptos_account::create_account(address_of(host3));
        coin::register<TEST_USDC>(host2);
        coin::transfer<TEST_USDC>(host, address_of(host2), 10000 * 1000000);
        coin::register<TEST_USDC>(host3);
        coin::transfer<TEST_USDC>(host, address_of(host3), 10000 * 1000000);

        place_order<TestPair, TEST_USDC>(host2, 10000, 1000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host3, 10000, 1000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);

        place_order<TestPair, TEST_USDC>(host2, 10000, 1000, 300100, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 300100, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host3, 10000, 1000, 299200, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 4, 299100, vector::empty(), &execute_cap);

        {
            let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            let position = table::borrow(&mut pair_state.long_positions, address_of(host2));
            assert!(position.size == 0, 1);
            assert!(position.collateral == 0, 2);
            position = table::borrow(&mut pair_state.long_positions, address_of(host3));
            assert!(position.size == 10000, 3);
            assert!(position.collateral == 1000 - 10000 * pair_info.taker_fee / MAKER_TAKER_FEE_PRECISION, 4);
        };

        place_order<TestPair, TEST_USDC>(host3, 10000, 1000, 299200, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 5, 299200, vector::empty(), &execute_cap);

        {
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            let position = table::borrow(&mut pair_state.long_positions, address_of(host3));
            assert!(position.size == 0, 4);
            assert!(position.collateral == 0, 5);
        };
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_OVER_MAXIMUM_INTEREST, location = Self)]
    /// Check over max open interest check
    fun T_check_max_open_interest(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (_, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 20000000 * INTEREST_PRECISION, 2000000 * INTEREST_PRECISION, 300000, true, true, true, 0, 0, true);
    }

    #[test(host = @merkle, host2 = @0xC0FFEE, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_ORDER_COLLATERAL_TOO_SMALL, location = Self)]
    fun T_minimum_order_collateral_check(host: &signer, host2: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (_, _) = call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(host2));
        coin::register<TEST_USDC>(host2);
        coin::transfer<TEST_USDC>(host, address_of(host2), 10000 * 1000000);

        place_order<TestPair, TEST_USDC>(host2, 2000, 200, 300000, true, true, true, 0, 0, true);
        place_order<TestPair, TEST_USDC>(host2, 90, 9, 300000, true, true, true, 0, 0, true);
    }

    #[test(host = @merkle, host2 = @0xC0FFEE, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_POSITION_COLLATERAL_TOO_SMALL, location = Self)]
    fun T_minimum_position_collateral_check(host: &signer, host2: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (_, _) = call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(host2));
        coin::register<TEST_USDC>(host2);
        coin::transfer<TEST_USDC>(host, address_of(host2), 10000 * 1000000);

        place_order<TestPair, TEST_USDC>(host2, 2000, 200, 300000, true, true, true, 0, 0, true);
        place_order<TestPair, TEST_USDC>(host2, 90, 20, 300000, true, true, true, 0, 0, true);
    }

    #[test(host = @merkle, host2 = @0xC0FFEE, aptos_framework = @aptos_framework)]
    fun T_take_execution_fee(host: &signer, host2: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (_, admin_cap) = call_test_setting(host, aptos_framework);
        aptos_account::create_account(address_of(host2));
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        let apt = coin::mint<AptosCoin>(1000, &mint_cap);
        move_to(host2, CapStore {
            mint_cap,
            burn_cap
        });
        coin::deposit<AptosCoin>(address_of(host2), apt);
        assert!(coin::balance<AptosCoin>(address_of(host2)) == 1000, 0);

        coin::register<TEST_USDC>(host2);
        coin::transfer<TEST_USDC>(host, address_of(host2), 10000 * 1000000);
        set_execution_fee(100, &admin_cap);
        place_order<TestPair, TEST_USDC>(host2, 2000, 200, 300000, true, true, true, 0, 0, true);
        assert!(coin::balance<AptosCoin>(address_of(host2)) == 900, 1);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Check taker maker fee when it flipped
    fun T_taker_maker_fee_flipped(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let size = 1000000;
        let coll = 100000;
        place_order<TestPair, TEST_USDC>(host, size, coll, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        place_order<TestPair, TEST_USDC>(host, 2 * size, coll, 300000, false, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);

        let pair_info = borrow_global<PairInfo<TestPair, TEST_USDC>>(@merkle);
        let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.short_positions, address_of(host));
        let entry_fee = safe_mul_div(size, pair_info.taker_fee, MAKER_TAKER_FEE_PRECISION) + safe_mul_div(size, pair_info.maker_fee, MAKER_TAKER_FEE_PRECISION);

        assert!(position.collateral == coll - entry_fee, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Check event parameters
    fun T_check_uid_sequence(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let size = 1000000;
        let coll = 100000;
        place_order<TestPair, TEST_USDC>(host, size, coll, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        {
            let trading_events = borrow_global<TradingEvents>(@merkle);
            assert!(trading_events.uid_sequence == 1, 0);
        };

        place_order<TestPair, TEST_USDC>(host, size, coll, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);
        {
            let trading_events = borrow_global<TradingEvents>(@merkle);
            assert!(trading_events.uid_sequence == 1, 0);
        };
        place_order<TestPair, TEST_USDC>(host, size * 2, 0, 330000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 330000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, size, coll, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 4, 300000, vector::empty(), &execute_cap);
        {
            let trading_events = borrow_global<TradingEvents>(@merkle);
            assert!(trading_events.uid_sequence == 2, 0);
        }
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_over_leverage_resize(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 10000000, 110000, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, 10000000, 105000, 300000, false, true, true, 0, 0, true);
        place_order<TestPair, TEST_USDC>(host, 10000000, 0, 300000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 300000, vector::empty(), &execute_cap);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);

        let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.short_positions, address_of(host));
        assert!(position.collateral == 95000, 0);
        assert!(position.size == 9500000, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// Success test execute increase market order
    fun T_under_leverage_resize(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        place_order<TestPair, TEST_USDC>(host, 300000, 100300, 300000, true, true, true, 0, 0, true);
        place_order<TestPair, TEST_USDC>(host, 300000, 100300, 300000, false, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 300000, vector::empty(), &execute_cap);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);

        let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
        let position = table::borrow(&mut pair_state.long_positions, address_of(host));
        assert!(position.collateral == 100150, 0);
        assert!(position.size == 300450, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_TEMPORARY_ORDER_BREAK, location = Self)]
    /// soft break activate check
    fun T_activate_soft_break(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 10000 * 1000000;
        let original_size = 500000 * 1000000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 330000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 330000, vector::empty(), &execute_cap);

        house_lp::set_house_lp_soft_break<TEST_USDC>(host, 0);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// soft break is active, but decrease order is working.
    fun T_activate_soft_break_decrease(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 10000 * 1000000;
        let original_size = 500000 * 1000000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 330000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 330000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 300000, vector::empty(), &execute_cap);

        house_lp::set_house_lp_soft_break<TEST_USDC>(host, 0);
        house_lp::set_house_lp_hard_break<TEST_USDC>(host, 100000);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, false, true, 0, 0, true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = E_TEMPORARY_ORDER_BREAK, location = Self)]
    /// soft break activate check
    fun T_activate_hard_break(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 10000 * 1000000;
        let original_size = 500000 * 1000000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 330000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 330000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 3, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 4, 300000, vector::empty(), &execute_cap);

        house_lp::set_house_lp_soft_break<TEST_USDC>(host, 0);
        house_lp::set_house_lp_hard_break<TEST_USDC>(host, 100000);
        // only soft break, working
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, false, true, 0, 0, true);
        house_lp::set_house_lp_hard_break<TEST_USDC>(host, 0);
        // hard break also activated
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, false, true, 0, 0, true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    /// soft break activate check
    fun T_break_execute_cancel(host: &signer, aptos_framework: &signer)
    acquires PairInfo, PairState, TradingEvents, UserTradingEvents, UserStates {
        // given
        let (execute_cap, _) = call_test_setting(host, aptos_framework);
        let coll_size = 10000 * 1000000;
        let original_size = 500000 * 1000000;

        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 1, 300000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 330000, true, false, true, 0, 0, true);
        execute_order<TestPair, TEST_USDC>(host, 2, 330000, vector::empty(), &execute_cap);
        place_order<TestPair, TEST_USDC>(host, original_size, coll_size, 300000, true, true, true, 0, 0, true);
        {
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            assert!(pair_state.long_open_interest == 0, 0);
        };
        house_lp::set_house_lp_soft_break<TEST_USDC>(host, 0);
        house_lp::set_house_lp_hard_break<TEST_USDC>(host, 0);
        execute_order<TestPair, TEST_USDC>(host, 3, 300000, vector::empty(), &execute_cap);
        {
            let pair_state = borrow_global_mut<PairState<TestPair, TEST_USDC>>(@merkle);
            assert!(pair_state.long_open_interest == 0, 0);
        };
    }
}