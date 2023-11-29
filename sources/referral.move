module merkle::referral {
    // <-- USE ----->
    use std::signer::address_of;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::coin;
    use aptos_framework::coin::Coin;
    use aptos_framework::event;
    use aptos_framework::event::EventHandle;
    use aptos_framework::timestamp;
    use merkle::vault_type;
    use merkle::vault;

    friend merkle::managed_trading;
    friend merkle::fee_distributor;

    const REBATE_PRECISION: u64 = 1000000;
    const VOLUME_PRECISION: u64 = 1000000; // same with trading volume precision
    const DAY_SECOND: u64 = 86400;

    const E_NOT_AUTHORIZED: u64 = 1;
    /// When user not exists
    const E_USER_NOT_EXISTS: u64 = 2;
    /// When trying to set invalid rebate rate
    const E_INVALID_USER_REBATE_RATE: u64 = 3;
    /// When trying deposit to hold user
    const E_REBATE_TO_HOLD_REFERRER: u64 = 4;

    struct AdminCapability has copy, store, drop {}

    struct ReferralInfo has key {
        epoch_period_sec: u64,
        expire_period_sec: u64,
        epoch_start_date_sec: u64,
    }

    struct UserInfos<phantom AssetT> has key {
        referrer: table::Table<address, ReferrerUserInfo<AssetT>>,
        referee: table::Table<address, RefereeUserInfo>
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
        move_to(_admin, ReferralInfo {
            epoch_period_sec: 28 * DAY_SECOND, // 4 weeks
            expire_period_sec: 365 * DAY_SECOND, // 1 year
            epoch_start_date_sec: start_date
        });

        move_to(_admin, UserInfos {
            referrer: table::new<address, ReferrerUserInfo<AssetT>>(),
            referee: table::new<address, RefereeUserInfo>()
        });

        move_to(_admin, ReferralEvents {
            referral_register_event: new_event_handle<RegisterEvent>(_admin),
            referral_rebate_event: new_event_handle<RebateEvent>(_admin),
            referral_claim_event: new_event_handle<ClaimEvent>(_admin)
        })
    }

    public fun get_epoch_info(): (u64, u64, u64) acquires ReferralInfo {
        // return current epoch start time, next epoch start time, current epoch number
        let referral_info = borrow_global_mut<ReferralInfo>(@merkle);
        let current_epoch = calc_current_epoch(referral_info.epoch_start_date_sec, referral_info.epoch_period_sec);
        let current_epoch_start_time =  referral_info.epoch_start_date_sec + current_epoch * referral_info.epoch_period_sec;
        let next_epoch_start_time = current_epoch_start_time + referral_info.epoch_period_sec;
        (current_epoch_start_time, next_epoch_start_time, current_epoch)
    }

    fun calc_current_epoch(epoch_start_date_sec: u64, epoch_period_sec: u64): u64 {
        (timestamp::now_seconds() - epoch_start_date_sec) / epoch_period_sec
    }

    public(friend) fun register_referrer<AssetT>(_user: address, _referrer: address): bool
    acquires UserInfos, ReferralEvents {
        // If the user already has a referrer, return false
        // otherwise, return true
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (table::contains(&user_infos.referee, _user) ||  _user == _referrer || _referrer == @0x0) {
            return false
        };
        if (table::contains(&user_infos.referee, _referrer)) {
            let referrer_referee_info = table::borrow(&user_infos.referee, _referrer);
            if (referrer_referee_info.referrer == _user) {
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
        table::upsert(&mut user_infos.referee, _user, RefereeUserInfo {
            referrer: _referrer,
            registered_at: timestamp::now_seconds(),
        });

        event::emit_event(&mut borrow_global_mut<ReferralEvents>(@merkle).referral_register_event, RegisterEvent {
            referrer: _referrer,
            referee: _user,
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

    public(friend) fun add_unclaimed_amount<AssetT>(_referee: address, _rebate_fee: Coin<AssetT>)
    acquires ReferralInfo, UserInfos, ReferralEvents {
        let amount = coin::value(&_rebate_fee);
        let user_infos = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (amount == 0 || !table::contains(&user_infos.referee, _referee)) {
            abort E_USER_NOT_EXISTS
        };
        let referee_info = table::borrow(&user_infos.referee, _referee);
        let referrer_info = table::borrow_mut(&mut user_infos.referrer, referee_info.referrer);
        if (referrer_info.hold_rebate) {
            abort E_REBATE_TO_HOLD_REFERRER
        };

        referrer_info.unclaimed_amount = referrer_info.unclaimed_amount + amount;
        vault::deposit_vault<vault_type::RebateVault, AssetT>(_rebate_fee);

        let referral_info = borrow_global<ReferralInfo>(@merkle);
        let epoch = calc_current_epoch(referral_info.epoch_start_date_sec, referral_info.epoch_period_sec);
        event::emit_event(&mut borrow_global_mut<ReferralEvents>(@merkle).referral_rebate_event, RebateEvent {
            referrer: referee_info.referrer,
            referee: _referee,
            rebate: amount,
            rebate_rate: referrer_info.rebate_rate,
            epoch,
            extras: vector[]
        });
    }

    public fun claim_all<AssetT>(_user: &signer) acquires UserInfos, ReferralEvents, ReferralInfo {
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

        let referral_info = borrow_global<ReferralInfo>(@merkle);
        let epoch = calc_current_epoch(referral_info.epoch_start_date_sec, referral_info.epoch_period_sec);
        event::emit_event(&mut borrow_global_mut<ReferralEvents>(@merkle).referral_claim_event, ClaimEvent {
            user: address_of(_user),
            amount: referrer_info.unclaimed_amount,
            epoch,
            extras: vector[]
        });
        referrer_info.unclaimed_amount = 0;
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

    public fun set_user_hold_rebate<AssetT>(_admin: &signer, _user: address, _value: bool) acquires UserInfos {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let user_info = borrow_global_mut<UserInfos<AssetT>>(address_of(_admin));
        let referrer_user_info = table::borrow_mut(&mut user_info.referrer, _user);
        referrer_user_info.hold_rebate = _value;
    }

    public fun set_user_rebate_rate_admin_cap<AssetT>(_admin_cap: &AdminCapability, _user: address, _value: u64) acquires UserInfos {
        set_user_rebate_rate_internal<AssetT>(_user, _value);
    }

    public fun set_user_rebate_rate<AssetT>(_admin: &signer, _user: address, _value: u64) acquires UserInfos {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        set_user_rebate_rate_internal<AssetT>(_user, _value);
    }

    fun set_user_rebate_rate_internal<AssetT>(_user: address, _value: u64) acquires UserInfos {
        let user_info = borrow_global_mut<UserInfos<AssetT>>(@merkle);
        if (!table::contains(&user_info.referrer, _user)) {
            table::upsert(&mut user_info.referrer, _user, ReferrerUserInfo<AssetT> {
                rebate_rate: 5 * REBATE_PRECISION / 100,
                unclaimed_amount: 0,
                hold_rebate: false,
            });
        };
        let referrer_user_info = table::borrow_mut(&mut user_info.referrer, _user);
        if (_value > 50 * REBATE_PRECISION / 100) {
            abort E_INVALID_USER_REBATE_RATE
        };
        referrer_user_info.rebate_rate = _value;
    }

    public fun generate_admin_cap(
        _admin: &signer
    ): AdminCapability {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        (AdminCapability {})
    }

    #[test_only]
    use aptos_framework::aptos_account;

    #[test_only]
    use std::string;

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
        aptos_account::create_account(address_of(host));

        init_module<AssetT>(host);
        vault::register_vault<vault_type::RebateVault, AssetT>(host);

        create_test_coins<TEST_USDC>(host, b"USDC", 6, 1000_000000);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_init_module(host: &signer, aptos_framework: &signer) {
        call_test_setting<TEST_USDC>(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_epoch_test(host: &signer, aptos_framework: &signer) acquires ReferralInfo {
        call_test_setting<TEST_USDC>(host, aptos_framework);
        {
            let (curr, next, num) = get_epoch_info();
            let referral_info = borrow_global<ReferralInfo>(address_of(host));
            assert!(curr == timestamp::now_seconds() - timestamp::now_seconds() % DAY_SECOND, 0);
            assert!(next == curr + referral_info.epoch_period_sec, 0);
            assert!(num == 0, 0);
            timestamp::fast_forward_seconds(referral_info.epoch_period_sec + 3);
        };

        {
            let (curr, next, num) = get_epoch_info();
            let referral_info = borrow_global<ReferralInfo>(address_of(host));
            assert!(curr == timestamp::now_seconds() - timestamp::now_seconds() % referral_info.epoch_period_sec, 0);
            assert!(next == curr + referral_info.epoch_period_sec, 0);
            assert!(num == 1, 0);
        };
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
    fun T_claim(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralInfo, ReferralEvents {
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
    fun T_hold_rebate_abort(host: &signer, aptos_framework: &signer, user: &signer) acquires UserInfos, ReferralInfo, ReferralEvents {
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
}