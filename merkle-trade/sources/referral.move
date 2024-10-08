module merkle::referral {
    // <-- USE ----->
    use std::signer::address_of;
    use std::string::{String};
    use std::vector;
    use aptos_std::simple_map;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::coin;
    use aptos_framework::coin::Coin;
    use aptos_framework::event;
    use aptos_framework::event::EventHandle;
    use aptos_framework::timestamp;
    use merkle::vault_type;
    use merkle::vault;
    use merkle::season;

    friend merkle::managed_referral;
    friend merkle::managed_trading;
    friend merkle::managed_lootbox_v2;
    friend merkle::fee_distributor;

    const REBATE_PRECISION: u64 = 1000000;
    const VOLUME_PRECISION: u64 = 1000000; // same with trading volume precision
    const DAY_SECOND: u64 = 86400;
    const ANCESTOR_REBATE_RATE: u64 = 50000; // 5%

    /// REBATE TYPE
    const T_NORMAL_REBATE: u8 = 1;
    const T_ANCESTOR_REBATE: u8 = 2;

    const E_NOT_AUTHORIZED: u64 = 1;
    /// When user not exists
    const E_USER_NOT_EXISTS: u64 = 2;
    /// When trying to set invalid rebate rate
    const E_INVALID_USER_REBATE_RATE: u64 = 3;
    /// When trying deposit to hold user
    const E_REBATE_TO_HOLD_REFERRER: u64 = 4;

    struct AdminCapability has copy, store, drop {}

    struct ReferralInfo has key {
        epoch_period_sec: u64, // deprecated
        expire_period_sec: u64,
        epoch_start_date_sec: u64, // deprecated
    }

    struct UserInfos<phantom AssetT> has key {
        referrer: table::Table<address, ReferrerUserInfo<AssetT>>,
        referee: table::Table<address, RefereeUserInfo>
    }

    struct Affiliates has key {
        users: vector<address>
    }

    struct ReferrerUserInfo<phantom AssetT> has store, drop {
        rebate_rate: u64,
        unclaimed_amount: u64,
        hold_rebate: bool,
    }

    struct RefereeUserInfo has store, drop {
        referrer: address,
        registered_at: u64,
    }

    struct ReferralConfig has key {
        ancestors: vector<address>,
        params: simple_map::SimpleMap<String, vector<u8>>,
    }

    struct ReferralEvents has key {
        referral_register_event: EventHandle<RegisterEvent>,
        referral_rebate_event: EventHandle<RebateEvent>,
        referral_claim_event: EventHandle<ClaimEvent>,
    }

    struct RegisterEvent has drop, store {
        referrer: address,
        referee: address,
        registered_at: u64
    }

    struct RebateEvent has drop, store {
        referrer: address,
        referee: address,
        rebate: u64,
        rebate_rate: u64,
        epoch: u64,
        extras: vector<u8>
    }

    struct ClaimEvent has drop, store {
        user: address,
        amount: u64,
        epoch: u64,
        extras: vector<u8>
    }

    public fun initialize<AssetT>(_admin: &signer) {
        // initialize for public fun
        init_module<AssetT>(_admin);
    }

    fun init_module<AssetT>(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let start_date = timestamp::now_seconds() - (timestamp::now_seconds() % 86400);
        if (!exists<ReferralInfo>(address_of(_admin))) {
            move_to(_admin, ReferralInfo {
                epoch_period_sec: 28 * DAY_SECOND, // 4 weeks
                expire_period_sec: 365 * DAY_SECOND, // 1 year
                epoch_start_date_sec: start_date
            });
        };

        if (!exists<UserInfos<AssetT>>(address_of(_admin))) {
            move_to(_admin, UserInfos {
                referrer: table::new<address, ReferrerUserInfo<AssetT>>(),
                referee: table::new<address, RefereeUserInfo>()
            });
        };

        if (!exists<ReferralEvents>(address_of(_admin))) {
            move_to(_admin, ReferralEvents {
                referral_register_event: new_event_handle<RegisterEvent>(_admin),
                referral_rebate_event: new_event_handle<RebateEvent>(_admin),
                referral_claim_event: new_event_handle<ClaimEvent>(_admin)
            });
        };

        if (!exists<Affiliates>(address_of(_admin))) {
            move_to(_admin, Affiliates {
                users: vector::empty()
            })
        };

        if (!exists<ReferralConfig>(address_of(_admin))) {
            move_to(_admin, ReferralConfig {
                ancestors: vector::empty(),
                params: simple_map::new<String, vector<u8>>()
            })
        }
    }

    public fun get_epoch_info(): (u64, u64, u64) {
        // return current epoch start time, next epoch start time, current epoch number
        let season_number = season::get_current_season_number();
        let start_sec = 0;
        if (season_number > 1) {
            start_sec = season::get_season_end_sec(season_number - 1);
        };
        let end_sec = season::get_season_end_sec(season_number);

        (start_sec, end_sec, season_number)
    }

    public(friend) fun remove_referrer<AssetT>(_user_address: address)
    acquires UserInfos {
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (table::contains(&user_infos.referee, _user_address)) {
            table::remove(&mut user_infos.referee, _user_address);
        };
    }

    public(friend) fun register_referrer<AssetT>(_user_address: address, _referrer: address): bool
    acquires UserInfos, ReferralEvents {
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (table::contains(&user_infos.referee, _user_address) || _user_address == _referrer || _referrer == @0x0) {
            // If the user already has a referrer
            // when _user is same with _referrer
            // when _referrer is @0x0 (no register)
            return false
        };
        if (table::contains(&user_infos.referee, _referrer)) {
            let referrer_referee_info = table::borrow(&user_infos.referee, _referrer);
            if (referrer_referee_info.referrer == _user_address) {
                // vice versa case
                return false
            };
        };

        if (!table::contains(&user_infos.referrer, _referrer)) {
            table::upsert(&mut user_infos.referrer, _referrer, ReferrerUserInfo {
                rebate_rate: 5 * REBATE_PRECISION / 100,
                unclaimed_amount: 0,
                hold_rebate: false,
            })
        };
        table::upsert(&mut user_infos.referee, _user_address, RefereeUserInfo {
            referrer: _referrer,
            registered_at: timestamp::now_seconds(),
        });

        event::emit_event(&mut borrow_global_mut<ReferralEvents>(@merkle).referral_register_event, RegisterEvent {
            referrer: _referrer,
            referee: _user_address,
            registered_at: timestamp::now_seconds()
        });
        true
    }

    public fun get_rebate_rate<AssetT>(_referee: address): u64 acquires ReferralInfo, UserInfos {
        // return (rebate_rate, is_valid)
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (!table::contains(&user_infos.referee, _referee)) {
            return 0
        };
        let referee_info = table::borrow(&user_infos.referee, _referee);
        let referrer_info = table::borrow_mut(&mut user_infos.referrer, referee_info.referrer);
        let now = timestamp::now_seconds();
        let referral_info = borrow_global<ReferralInfo>(@merkle);
        if (referrer_info.hold_rebate || referee_info.registered_at + referral_info.expire_period_sec < now) {
            // referral expired
            return 0
        };

        referrer_info.rebate_rate
    }

    public fun get_ancestor_rebate_rate(): u64 {
        ANCESTOR_REBATE_RATE
    }

    public(friend) fun add_unclaimed_amount<AssetT>(_referee: address, _rebate_fee: Coin<AssetT>)
    acquires UserInfos, ReferralEvents {
        let amount = coin::value(&_rebate_fee);
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (amount == 0 || !table::contains(&user_infos.referee, _referee)) {
            // already checked at get_rebate_rate fun, check here just in case
            abort E_USER_NOT_EXISTS
        };
        let referee_info = table::borrow(&user_infos.referee, _referee);
        let referrer_info = table::borrow_mut(&mut user_infos.referrer, referee_info.referrer);
        if (referrer_info.hold_rebate) {
            // already checked at get_rebate_rate fun, check here just in case
            abort E_REBATE_TO_HOLD_REFERRER
        };

        vault::deposit_vault<vault_type::RebateVault, AssetT>(_rebate_fee);
        referrer_info.unclaimed_amount = referrer_info.unclaimed_amount + amount;

        let epoch = season::get_current_season_number();
        event::emit_event(&mut borrow_global_mut<ReferralEvents>(@merkle).referral_rebate_event, RebateEvent {
            referrer: referee_info.referrer,
            referee: _referee,
            rebate: amount,
            rebate_rate: referrer_info.rebate_rate,
            epoch,
            extras: vector[T_NORMAL_REBATE]
        });
    }

    public(friend) fun add_ancestor_amount<AssetT>(_referee: address, _rebate_fee: Coin<AssetT>) acquires ReferralEvents, UserInfos {
        let amount = coin::value(&_rebate_fee);
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (amount == 0 || !table::contains(&user_infos.referee, _referee)) {
            // already checked at get_rebate_rate fun, check here just in case
            abort E_USER_NOT_EXISTS
        };
        let ancestor = get_ancestor_address<AssetT>(user_infos, _referee);

        let ancestor_referrer_info = table::borrow_mut(&mut user_infos.referrer, ancestor);
        vault::deposit_vault<vault_type::RebateVault, AssetT>(_rebate_fee);
        ancestor_referrer_info.unclaimed_amount = ancestor_referrer_info.unclaimed_amount + amount;

        let epoch = season::get_current_season_number();
        event::emit_event(&mut borrow_global_mut<ReferralEvents>(@merkle).referral_rebate_event, RebateEvent {
            referrer: ancestor,
            referee: _referee,
            rebate: amount,
            rebate_rate: ANCESTOR_REBATE_RATE,
            epoch,
            extras: vector[T_ANCESTOR_REBATE]
        });
    }

    public fun claim_all<AssetT>(_user: &signer) acquires UserInfos, ReferralEvents {
        // This function must be called after the user's claim is complete.
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (!table::contains(&user_infos.referrer, address_of(_user))) {
            abort E_USER_NOT_EXISTS
        };
        let referrer_info = table::borrow_mut(&mut user_infos.referrer, address_of(_user));

        // vault withdraw
        let rebate = vault::withdraw_vault<vault_type::RebateVault, AssetT>(referrer_info.unclaimed_amount);
        if (!coin::is_account_registered<AssetT>(address_of(_user))) {
            coin::register<AssetT>(_user);
        };
        coin::deposit(address_of(_user), rebate);

        let epoch = season::get_current_season_number();
        event::emit_event(&mut borrow_global_mut<ReferralEvents>(@merkle).referral_claim_event, ClaimEvent {
            user: address_of(_user),
            amount: referrer_info.unclaimed_amount,
            epoch,
            extras: vector[]
        });
        referrer_info.unclaimed_amount = 0;
    }

    public fun is_ancestor_enabled<AssetT>(_user_address: address): bool acquires ReferralConfig, UserInfos {
        let referral_config = borrow_global<ReferralConfig>(@merkle);
        let user_infos = borrow_global<UserInfos<AssetT>>(@merkle);
        let ancestor = get_ancestor_address<AssetT>(user_infos, _user_address);
        vector::contains(&referral_config.ancestors, &ancestor)
    }

    fun get_ancestor_address<AssetT>(_user_infos: &UserInfos<AssetT>, _user_address: address): address {
        if (!table::contains(&_user_infos.referee, _user_address)) {
            return @0x0
        };
        let referee_info = table::borrow(&_user_infos.referee, _user_address);
        if (!table::contains(&_user_infos.referee, referee_info.referrer)) {
            return @0x0
        };
        let ancestor_info = table::borrow(&_user_infos.referee, referee_info.referrer);
        ancestor_info.referrer
    }

    public fun get_referrer_address<AssetT>(_user_address: address): address acquires UserInfos {
        let user_infos = borrow_global<UserInfos<AssetT>>(@merkle);
        if (!table::contains(&user_infos.referee, _user_address)) {
            return @0x0
        };
        let referee_info = table::borrow(&user_infos.referee, _user_address);
        referee_info.referrer
    }

    /// config setters
    public fun set_epoch_period_sec(_admin: &signer, _value: u64) acquires ReferralInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let referral_info = borrow_global_mut<ReferralInfo>(address_of(_admin));
        referral_info.epoch_period_sec = _value;
    }

    public fun set_expire_period_sec(_admin: &signer, _value: u64) acquires ReferralInfo {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let referral_info = borrow_global_mut<ReferralInfo>(address_of(_admin));
        referral_info.expire_period_sec = _value;
    }

    public fun set_user_hold_rebate<AssetT>(_admin: &signer, _user_address: address, _value: bool) acquires UserInfos {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let user_info = borrow_global_mut<UserInfos<AssetT>>(address_of(_admin));
        let referrer_user_info = table::borrow_mut(&mut user_info.referrer, _user_address);
        referrer_user_info.hold_rebate = _value;
    }

    public fun set_user_rebate_rate_admin_cap<AssetT>(_admin_cap: &AdminCapability, _user_address: address, _value: u64) acquires UserInfos {
        set_user_rebate_rate_internal<AssetT>(_user_address, _value);
    }

    public fun set_user_rebate_rate<AssetT>(_admin: &signer, _user_address: address, _value: u64) acquires UserInfos {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        set_user_rebate_rate_internal<AssetT>(_user_address, _value);
    }

    fun set_user_rebate_rate_internal<AssetT>(_user_address: address, _value: u64) acquires UserInfos {
        let user_info = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (!table::contains(&user_info.referrer, _user_address)) {
            table::upsert(&mut user_info.referrer, _user_address, ReferrerUserInfo<AssetT> {
                rebate_rate: 5 * REBATE_PRECISION / 100,
                unclaimed_amount: 0,
                hold_rebate: false,
            });
        };
        let referrer_user_info = table::borrow_mut(&mut user_info.referrer, _user_address);
        if (_value > 50 * REBATE_PRECISION / 100) {
            abort E_INVALID_USER_REBATE_RATE
        };
        referrer_user_info.rebate_rate = _value;
    }

    public fun add_affiliate_address_admin_cap(_admin_cap: &AdminCapability, _user_address: address) acquires Affiliates {
        add_affiliate_address_internal(_user_address);
    }

    public fun add_affiliate_address(_admin: &signer, _user_address: address) acquires Affiliates {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        add_affiliate_address_internal(_user_address);
    }

    inline fun add_affiliate_address_internal(_user_address: address) {
        let affiliates = borrow_global_mut<Affiliates>(@merkle);
        if (!vector::contains(&affiliates.users, &_user_address)) {
            vector::push_back(&mut affiliates.users, _user_address);
        };
    }

    public fun remove_affiliate_address(_admin: &signer, _user_address: address) acquires Affiliates {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let affiliates = borrow_global_mut<Affiliates>(address_of(_admin));
        if (!vector::contains(&affiliates.users, &_user_address)) {
            return
        };
        vector::remove_value(&mut affiliates.users, &_user_address);
    }

    public fun check_affiliates_address(_user_address: address): bool acquires Affiliates {
        let affiliates = borrow_global_mut<Affiliates>(@merkle);
        vector::contains(&affiliates.users, &_user_address)
    }

    public fun generate_admin_cap(
        _admin: &signer
    ): AdminCapability {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        (AdminCapability {})
    }

    public fun enable_ancestor_admin_cap(_admin_cap: &AdminCapability, _user_address: address) acquires ReferralConfig {
        let referral_config = borrow_global_mut<ReferralConfig>(@merkle);
        if (!vector::contains(&referral_config.ancestors, &_user_address)) {
            vector::push_back(&mut referral_config.ancestors, _user_address);
        };
    }

    public fun remove_ancestor_admin_cap(_admin_cap: &AdminCapability, _user_address: address) acquires ReferralConfig {
        let referral_config = borrow_global_mut<ReferralConfig>(@merkle);
        if (vector::contains(&referral_config.ancestors, &_user_address)) {
            vector::remove_value(&mut referral_config.ancestors, &_user_address);
        };
    }

    #[test_only]
    use aptos_framework::aptos_account;

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::aptos_coin;

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
    public fun call_test_setting<AssetT>(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };

        init_module<AssetT>(host);
        vault::register_vault<vault_type::RebateVault, AssetT>(host);

        create_test_coins<TEST_USDC>(host, b"USDC", 6, 1000_000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_init_module(host: &signer, aptos_framework: &signer) {
        call_test_setting<TEST_USDC>(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_register_referral(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        let re = register_referrer<TEST_USDC>(address_of(user), address_of(host));
        assert!(re == true, 0);
        let user_info = borrow_global_mut<UserInfos<TEST_USDC>>(@merkle);
        let referrer_user_info = table::borrow(&user_info.referrer, address_of(host));
        assert!(referrer_user_info.hold_rebate == false, 0);
        assert!(referrer_user_info.rebate_rate == 5 * REBATE_PRECISION / 100, 0);
        assert!(referrer_user_info.unclaimed_amount == 0, 0);

        let referee_user_info = table::borrow(&user_info.referee, address_of(user));
        assert!(referee_user_info.referrer == address_of(host), 0);
        assert!(referee_user_info.registered_at == 0, 0);

        re = register_referrer<TEST_USDC>(address_of(host), address_of(user));
        assert!(re == false, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_get_rebate_rate(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralInfo, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        register_referrer<TEST_USDC>(address_of(user), address_of(host));
        let r = get_rebate_rate<TEST_USDC>(address_of(user));
        assert!(r == 5 * REBATE_PRECISION / 100, 0);

        set_user_rebate_rate_internal<TEST_USDC>(address_of(host), 10 * REBATE_PRECISION / 100);
        r = get_rebate_rate<TEST_USDC>(address_of(user));
        assert!(r == 10 * REBATE_PRECISION / 100, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_claim(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        register_referrer<TEST_USDC>(address_of(user), address_of(host));

        let fee = coin::withdraw<TEST_USDC>(host, 100_000000);
        add_unclaimed_amount(address_of(user), fee);
        assert!(coin::balance<TEST_USDC>(address_of(host)) == 900_000000, 0);

        let user_info = borrow_global_mut<UserInfos<TEST_USDC>>(@merkle);
        let referrer_user_info = table::borrow(&user_info.referrer, address_of(host));
        assert!(referrer_user_info.hold_rebate == false, 0);
        assert!(referrer_user_info.rebate_rate == 5 * REBATE_PRECISION / 100, 0);
        assert!(referrer_user_info.unclaimed_amount == 100_000000, 0);

        claim_all<TEST_USDC>(host);
        assert!(coin::balance<TEST_USDC>(address_of(host)) == 1000_000000, 0);

        set_user_hold_rebate<TEST_USDC>(host, address_of(host), true);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_hold_rebate(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralInfo, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        register_referrer<TEST_USDC>(address_of(user), address_of(host));

        set_user_hold_rebate<TEST_USDC>(host, address_of(host), true);
        let r = get_rebate_rate<TEST_USDC>(address_of(user));
        assert!(r == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_REBATE_TO_HOLD_REFERRER, location = Self)]
    fun T_hold_rebate_abort(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        register_referrer<TEST_USDC>(address_of(user), address_of(host));

        set_user_hold_rebate<TEST_USDC>(host, address_of(host), true);
        let fee = coin::withdraw<TEST_USDC>(host, 100_000000);
        add_unclaimed_amount(address_of(user), fee);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    #[expected_failure(abort_code = E_INVALID_USER_REBATE_RATE, location = Self)]
    fun T_invalid_user_rebate_rate(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        register_referrer<TEST_USDC>(address_of(user), address_of(host));

        set_user_rebate_rate_internal<TEST_USDC>(address_of(host), 51 * REBATE_PRECISION / 100);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_set_configs(host: &signer, aptos_framework: &signer) acquires ReferralInfo {
        call_test_setting<TEST_USDC>(host, aptos_framework);

        set_epoch_period_sec(host, 12 * DAY_SECOND);
        set_expire_period_sec(host, 300 * DAY_SECOND);

        let referral_info = borrow_global<ReferralInfo>(address_of(host));
        assert!(referral_info.epoch_period_sec == 12 * DAY_SECOND, 0);
        assert!(referral_info.expire_period_sec == 300 * DAY_SECOND, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_make_new_referrer(host: &signer, aptos_framework: &signer) acquires UserInfos {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        set_user_rebate_rate_internal<TEST_USDC>(address_of(host), 30 * REBATE_PRECISION / 100);

        let user_info = borrow_global_mut<UserInfos<TEST_USDC>>(@merkle);
        let referrer_user_info = table::borrow(&user_info.referrer, address_of(host));
        assert!(referrer_user_info.hold_rebate == false, 0);
        assert!(referrer_user_info.rebate_rate == 30 * REBATE_PRECISION / 100, 0);
        assert!(referrer_user_info.unclaimed_amount == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE)]
    fun T_expire(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralInfo, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        register_referrer<TEST_USDC>(address_of(user), address_of(host));
        timestamp::fast_forward_seconds(366 * DAY_SECOND);
        let r = get_rebate_rate<TEST_USDC>(address_of(user));
        assert!(r == 0, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_prevent_self_referral(host: &signer, aptos_framework: &signer) acquires UserInfos, ReferralEvents {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        let r = register_referrer<TEST_USDC>(address_of(host), address_of(host));
        assert!(r == false, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_check_affiliates(host: &signer, aptos_framework: &signer) acquires Affiliates {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        assert!(!check_affiliates_address(address_of(host)), 0);
        add_affiliate_address(host, address_of(host));
        assert!(check_affiliates_address(address_of(host)), 0);
        remove_affiliate_address(host, address_of(host));
        assert!(!check_affiliates_address(address_of(host)), 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework, user = @0xC0FFEE, user2= @0xC0FFEE2)]
    fun T_ancestor_rebate(host: &signer, aptos_framework: &signer, user: &signer, user2: &signer)
    acquires UserInfos, ReferralEvents, ReferralConfig {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        aptos_account::create_account(address_of(user));
        aptos_account::create_account(address_of(user2));
        register_referrer<TEST_USDC>(address_of(user), address_of(host));
        register_referrer<TEST_USDC>(address_of(user2), address_of(user));

        assert!(!is_ancestor_enabled<TEST_USDC>(address_of(user2)), 0);
        let admin_cap = generate_admin_cap(host);
        enable_ancestor_admin_cap(&admin_cap, address_of(host));
        assert!(is_ancestor_enabled<TEST_USDC>(address_of(user2)), 0);
    }
}