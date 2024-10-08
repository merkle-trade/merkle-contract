module merkle::coin_utils {

    use std::signer::address_of;
    use aptos_framework::coin;
    use aptos_framework::primary_fungible_store;

    public fun convert_all_coin_to_fungible_asset<CoinType>(_user: &signer) {
        let balance = coin::balance<CoinType>(address_of(_user));
        let from_coin = coin::withdraw<CoinType>(_user, balance);
        let to_fa = coin::coin_to_fungible_asset(from_coin);
        primary_fungible_store::deposit(address_of(_user), to_fa);
    }

    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use std::features;
    #[test_only]
    use std::option;
    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    struct TEST_USDC {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        if (!account::exists_at(address_of(host))) {
            aptos_account::create_account(address_of(host));
        };
        features::change_feature_flags_for_testing(aptos_framework, vector[features::get_auids()], vector[]);

        let decimals = 6;
        let (bc, fc, mc) = coin::initialize<TEST_USDC>(host,
            string::utf8(b"TEST_USDC"),
            string::utf8(b"TEST_USDC"),
            decimals,
            false);
        coin::destroy_burn_cap(bc);
        coin::destroy_freeze_cap(fc);
        coin::register<TEST_USDC>(host);
        coin::deposit(address_of(host), coin::mint<TEST_USDC>(1000000, &mc));
        coin::destroy_mint_cap(mc);

        coin::create_pairing<TEST_USDC>(aptos_framework);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun T_convert_all_coin_to_fungible_asset(host: &signer, aptos_framework: &signer) {
        call_test_setting(host, aptos_framework);
        let metadata = option::extract(&mut coin::paired_metadata<TEST_USDC>());
        assert!(coin::balance<TEST_USDC>(address_of(host)) == 1000000, 0);
        assert!(primary_fungible_store::balance(address_of(host), metadata) == 0, 0);

        convert_all_coin_to_fungible_asset<TEST_USDC>(host);

        assert!(coin::balance<TEST_USDC>(address_of(host)) == 1000000, 0);
        assert!(primary_fungible_store::balance(address_of(host), metadata) == 1000000, 0);
    }
}