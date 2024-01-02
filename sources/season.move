module merkle::season {
    use std::signer::address_of;
    use aptos_std::simple_map;
    use aptos_framework::timestamp;

    /// When signer is not owner of module
    const E_NOT_AUTHORIZED: u64 = 1;

    struct Seasons has key {
        season_info: simple_map::SimpleMap<u64, SeasonInfo> // key = season number
    }
    struct SeasonInfo has copy, store, drop {
        end_sec: u64,
    }

    struct SeasonView has copy, drop {
        season_number: u64,
        end_sec: u64
    }

    public fun initialize_module(_admin: &signer) acquires Seasons {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        if (exists<Seasons>(address_of(_admin))) {
            return
        };

        let start_season_number = 1;
        let start_sec = timestamp::now_seconds() - timestamp::now_seconds() % 86400;
        move_to(_admin, Seasons {
            season_info: simple_map::new()
        });
        let seasons = borrow_global_mut<Seasons>(address_of(_admin));
        simple_map::add(&mut seasons.season_info, start_season_number, SeasonInfo {
            end_sec: start_sec + 24 * 60 * 60 * 28, // 4 weeks
        })
    }

    public fun add_new_season(_admin: &signer, _end_sec: u64) acquires Seasons {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let current_season_number = get_current_season_number();
        let seasons = borrow_global_mut<Seasons>(address_of(_admin));
        simple_map::add(&mut seasons.season_info, current_season_number + 1, SeasonInfo {
            end_sec: _end_sec
        })
    }

    public fun set_season_end_sec(_admin: &signer, _season_number: u64, _end_sec: u64) acquires Seasons {
        assert!(address_of(_admin) == @merkle, E_NOT_AUTHORIZED);
        let seasons = borrow_global_mut<Seasons>(address_of(_admin));
        simple_map::upsert(&mut seasons.season_info, _season_number, SeasonInfo {
            end_sec: _end_sec
        });
    }

    // <--- view --->
    public fun get_current_season_number(): u64 acquires Seasons {
        if (!exists<Seasons>(@merkle)) {
            return 1
        };
        let seasons = borrow_global_mut<Seasons>(@merkle);
        let i = 1;
        let now_sec = timestamp::now_seconds();
        while(simple_map::contains_key(&seasons.season_info, &i)) {
            let season_info = simple_map::borrow(&seasons.season_info, &i);
            if (now_sec <= season_info.end_sec) {
                break
            };
            i = i + 1;
        };
        return i
    }

    public fun get_current_season_info(): SeasonView acquires Seasons {
        let season_number = get_current_season_number();
        let seasons = borrow_global<Seasons>(@merkle);
        let end_sec = (*simple_map::borrow(&seasons.season_info, &season_number)).end_sec;
        SeasonView {
            season_number,
            end_sec
        }
    }

    public fun get_season_info(_season_number: u64): SeasonView acquires Seasons {
        let seasons = borrow_global<Seasons>(@merkle);
        let end_sec = (*simple_map::borrow(&seasons.season_info, &_season_number)).end_sec;
        SeasonView {
            season_number: _season_number,
            end_sec
        }
    }

    // <--- test --->
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_account;

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) acquires Seasons {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        initialize_module(host);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_initialize_module(host: &signer, aptos_framework: &signer) acquires Seasons {
        call_test_setting(host, aptos_framework);
        assert!(1 == get_current_season_number(), 0);
        let season_info = get_current_season_info();
        assert!(1 == season_info.season_number, 0);
        assert!(24 * 60 * 60 * 28 == season_info.end_sec, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_add_new_season(host: &signer, aptos_framework: &signer) acquires Seasons {
        call_test_setting(host, aptos_framework);

        add_new_season(host, 24 * 60 * 60 * 28 * 2);
        let season_info = get_season_info(2);
        assert!(season_info.season_number == 2, 0);
        assert!(season_info.end_sec == 24 * 60 * 60 * 28 * 2, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_set_season_end_sec(host: &signer, aptos_framework: &signer) acquires Seasons {
        call_test_setting(host, aptos_framework);

        add_new_season(host, 24 * 60 * 60 * 28 * 2);
        set_season_end_sec(host, 1, 24 * 60 * 60 * 28 + 1);
        let season_info = get_season_info(1);
        assert!(season_info.season_number == 1, 0);
        assert!(season_info.end_sec == 24 * 60 * 60 * 28 + 1, 0);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    public fun T_season_passed(host: &signer, aptos_framework: &signer) acquires Seasons {
        call_test_setting(host, aptos_framework);

        add_new_season(host, 24 * 60 * 60 * 28 * 2);
        assert!(get_current_season_number() == 1, 0);
        timestamp::fast_forward_seconds(24 * 60 * 60 * 28 + 2);
        assert!(get_current_season_number() == 2, 0);
        let season_info = get_current_season_info();
        assert!(season_info.season_number == 2, 0);
        assert!(season_info.end_sec == 24 * 60 * 60 * 28 * 2, 0);
    }
}