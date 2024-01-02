module merkle::pMKL {
    use std::signer::address_of;
    use aptos_std::table;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::event::{Self, EventHandle};
    use merkle::season;

    friend merkle::trading;
    friend merkle::lootbox;
    friend merkle::lootbox_v2;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;
    /// When call invalid season
    const E_INVALID_SEASON_NUMBER: u64 = 2;

    // pMKL
    // decimals: 6
    struct PMKLInfo has key {
        season_pmkl: table::Table<u64, SeasonPMKLInfo>, // key = season
    }

    struct SeasonPMKLInfo has store {
        supply: u64,
        user_balance: table::Table<address, u64>,
        user_claimed: table::Table<address, u64>
    }

    // return type
    struct SeasonUserPMKLInfoView has drop {
        season_number: u64,
        total_supply: u64,
        user_balance: u64
    }

    // return type
    struct SeasonPMKLSupplyView has drop {
        season_number: u64,
        total_supply: u64
    }

    // events
    struct PMKLEvents has key {
        mint_events: EventHandle<MintEvent>,
        claim_events: EventHandle<ClaimEvent>
    }

    struct MintEvent has drop, store {
        /// season number
        season_number: u64,
        /// user address
        user: address,
        /// minted pmkl
        amount: u64
    }

    struct ClaimEvent has drop, store {
        /// season number
        season_number: u64,
        /// user address
        user: address,
        /// minted pmkl
        amount: u64
    }

    public fun initialize_module(_admin: &signer) {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (exists<PMKLInfo>(address_of(_admin))) {
            return
        };

        move_to(_admin, PMKLInfo {
            season_pmkl: table::new()
        });

        move_to(_admin, PMKLEvents {
            mint_events: new_event_handle<MintEvent>(_admin),
            claim_events: new_event_handle<ClaimEvent>(_admin)
        })
    }

    public(friend) fun mint_pmkl(_user: address, _amount: u64) acquires PMKLInfo, PMKLEvents {
        let season_pmkl_info = borrow_global_mut<PMKLInfo>(@merkle);
        let season_number = season::get_current_season_number();
        if (!table::contains(&season_pmkl_info.season_pmkl, season_number)) {
            table::add(&mut season_pmkl_info.season_pmkl, season_number, SeasonPMKLInfo {
                supply: 0,
                user_balance: table::new<address, u64>(),
                user_claimed: table::new<address, u64>(),
            });
        };
        let pmkl_info = table::borrow_mut(&mut season_pmkl_info.season_pmkl, season_number);
        pmkl_info.supply = pmkl_info.supply + _amount;
        if (!table::contains(&pmkl_info.user_balance, _user)) {
            table::add(&mut pmkl_info.user_balance, _user, 0);
        };
        let user_balance = table::borrow_mut(&mut pmkl_info.user_balance, _user);
        *user_balance = *user_balance + _amount;

        event::emit_event(&mut borrow_global_mut<PMKLEvents>(@merkle).mint_events, MintEvent {
            season_number,
            user: _user,
            amount: _amount
        });
    }

    public fun get_season_user_pmkl(_user: address, _season_number: u64): SeasonUserPMKLInfoView acquires PMKLInfo {
        let season_pmkl_info = borrow_global<PMKLInfo>(@merkle);
        if (!table::contains(&season_pmkl_info.season_pmkl, _season_number)) {
            return SeasonUserPMKLInfoView {
                season_number: _season_number,
                total_supply: 0,
                user_balance: 0
            }
        };
        assert!(table::contains(&season_pmkl_info.season_pmkl, _season_number), E_INVALID_SEASON_NUMBER);
        let pmkl_info = table::borrow(&season_pmkl_info.season_pmkl, _season_number);
        if (!table::contains(&pmkl_info.user_balance, _user)) {
            return SeasonUserPMKLInfoView {
                season_number: _season_number,
                total_supply: pmkl_info.supply,
                user_balance: 0
            }
        };
        let user_balance = *table::borrow(&pmkl_info.user_balance, _user);
        SeasonUserPMKLInfoView {
            season_number: _season_number,
            total_supply: pmkl_info.supply,
            user_balance
        }
    }

    public fun get_current_season_info(): SeasonPMKLSupplyView acquires PMKLInfo {
        let season_pmkl_info = borrow_global<PMKLInfo>(@merkle);
        let season_number = season::get_current_season_number();
        if (!table::contains(&season_pmkl_info.season_pmkl, season_number)) {
            return SeasonPMKLSupplyView {
                season_number,
                total_supply: 0,
            }
        };
        let pmkl_info = table::borrow(&season_pmkl_info.season_pmkl, season_number);
        SeasonPMKLSupplyView {
            season_number,
            total_supply: pmkl_info.supply,
        }
    }

    // <--- test --->
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    public fun get_user_pmkl_balance(_user: address, _season: u64): u64 acquires PMKLInfo {
        get_season_user_pmkl(_user, _season).user_balance
    }

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        season::initialize_module(host);
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_initialize_module(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_mint_pmkl(host: &signer, aptos_framework: &signer) acquires PMKLInfo, PMKLEvents {
        call_test_setting(host, aptos_framework);
        mint_pmkl(address_of(host), 100);
        mint_pmkl(address_of(aptos_framework), 200);
        let season_pmkl_info = borrow_global<PMKLInfo>(address_of(host));
        let season_number = season::get_current_season_number();
        let pmkl_info = table::borrow(&season_pmkl_info.season_pmkl, season_number);
        assert!(pmkl_info.supply == 300, 0);
        assert!(*table::borrow(&pmkl_info.user_balance, address_of(host)) == 100, 0);

        let user_pmkl_info = get_season_user_pmkl(address_of(host), season_number);
        assert!(user_pmkl_info.total_supply == 300, 0);
        assert!(user_pmkl_info.season_number == 1, 0);
        assert!(user_pmkl_info.user_balance == 100, 0);

        let current_season_info = get_current_season_info();
        assert!(current_season_info.total_supply == 300, 0);
        assert!(current_season_info.season_number == 1, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_next_season(host: &signer, aptos_framework: &signer) acquires PMKLInfo, PMKLEvents {
        call_test_setting(host, aptos_framework);
        season::add_new_season(host, 24 * 60 * 60 * 28 * 2);

        mint_pmkl(address_of(host), 100);
        mint_pmkl(address_of(aptos_framework), 200);
        timestamp::fast_forward_seconds(24 * 60 * 60 * 28 + 1);
        mint_pmkl(address_of(host), 300);
        mint_pmkl(address_of(aptos_framework), 400);

        let season_number = season::get_current_season_number();
        let user_pmkl_info = get_season_user_pmkl(address_of(host), season_number);
        assert!(user_pmkl_info.total_supply == 700, 0);
        assert!(user_pmkl_info.season_number == 2, 0);
        assert!(user_pmkl_info.user_balance == 300, 0);

        let user_pmkl_info = get_season_user_pmkl(address_of(host), season_number - 1);
        assert!(user_pmkl_info.total_supply == 300, 0);
        assert!(user_pmkl_info.season_number == 1, 0);
        assert!(user_pmkl_info.user_balance == 100, 0);
    }
}