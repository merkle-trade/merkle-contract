module merkle::pair_types {
    use std::string;
    use std::vector;
    use aptos_std::type_info;

    // Collection of listed PairType structures.
    struct BTC_USD {}
    struct ETH_USD {}
    struct APT_USD {}
    struct BNB_USD {}
    struct DOGE_USD {}
    struct MATIC_USD {}
    struct SOL_USD {}
    struct ARB_USD {}
    struct SUI_USD {}
    struct USD_JPY {}
    struct EUR_USD {}
    struct GBP_USD {}
    struct AUD_USD {}
    struct NZD_USD {}
    struct USD_CAD {}
    struct USD_CHF {}
    struct XAU_USD {}
    struct XAG_USD {}
    struct TIA_USD {}
    struct MEME_USD {}
    struct PYTH_USD {}
    struct BLUR_USD {}
    struct AVAX_USD {}
    struct SEI_USD {}
    struct MANTA_USD {}
    struct JUP_USD {}
    struct INJ_USD {}
    struct STRK_USD {}
    struct WLD_USD {}
    struct WIF_USD {}
    struct LINK_USD {}
    struct PEPE_USD {}
    struct W_USD {}
    struct ENA_USD {}
    struct HBAR_USD {}
    struct BONK_USD {}
    struct TON_USD {}
    struct SHIB_USD {}
    struct OP_USD {}
    struct ZRO_USD {}
    struct TAO_USD {}
    struct EIGEN_USD {}

    // not listed
    struct REZ_USD {}
    struct BCH_USD {} // only for testnet
    struct FLOKI_USD {} // only for testnet

    const PAIR_LIST: vector<vector<u8>> = vector[
        b"BTC_USD", b"ETH_USD", b"APT_USD", b"BNB_USD", b"DOGE_USD",
        b"MATIC_USD", b"SOL_USD", b"ARB_USD", b"SUI_USD", b"USD_JPY",
        b"EUR_USD", b"GBP_USD", b"AUD_USD", b"NZD_USD", b"USD_CAD",
        b"USD_CHF", b"XAU_USD", b"XAG_USD", b"TIA_USD", b"MEME_USD",
        b"PYTH_USD", b"BLUR_USD", b"AVAX_USD", b"SEI_USD", b"MANTA_USD",
        b"JUP_USD", b"INJ_USD", b"STRK_USD", b"WLD_USD", b"WIF_USD",
        b"PEPE_USD", b"LINK_USD", b"W_USD", b"ENA_USD", b"HBAR_USD",
        b"BONK_USD", b"TON_USD", b"SHIB_USD", b"OP_USD", b"ZRO_USD",
        b"TAO_USD", b"EIGEN_USD"];
    const CLASS_LIST: vector<vector<u8>> = vector[
        b"CRYPTO", b"FOREX", b"COMMODITY"
    ];
    const CRYPTO_LIST: vector<vector<u8>> = vector[
        b"BTC_USD", b"ETH_USD", b"APT_USD", b"BNB_USD", b"DOGE_USD",
        b"MATIC_USD", b"SOL_USD", b"ARB_USD", b"SUI_USD", b"TIA_USD",
        b"MEME_USD", b"PYTH_USD", b"BLUR_USD", b"AVAX_USD", b"SEI_USD",
        b"MANTA_USD", b"JUP_USD", b"INJ_USD", b"STRK_USD", b"WLD_USD",
        b"WIF_USD", b"PEPE_USD", b"LINK_USD", b"W_USD", b"ENA_USD",
        b"HBAR_USD", b"BONK_USD", b"TON_USD", b"SHIB_USD", b"OP_USD",
        b"ZRO_USD", b"TAO_USD", b"EIGEN_USD"];
    const FOREX_LIST: vector<vector<u8>> = vector[
        b"USD_JPY", b"EUR_USD", b"GBP_USD", b"AUD_USD", b"NZD_USD", b"USD_CAD", b"USD_CHF"
    ];
    const COMMODITY_LIST: vector<vector<u8>> = vector[
        b"XAU_USD", b"XAG_USD"
    ];

    public fun len_pair(): u64 {
        // number of pairs
        vector::length(&PAIR_LIST)
    }

    public fun len_pair_class(): u64 {
        // 0 = crypto
        // 1 = forex
        // 2 = commodity
        vector::length(&CLASS_LIST)
    }

    public fun get_pair_name(idx: u64): vector<u8> {
        *vector::borrow(&PAIR_LIST, idx)
    }

    public fun get_class_name(idx: u64): vector<u8> {
        *vector::borrow(&CLASS_LIST, idx)
    }

    public fun check_target<PairType>(_pair_or_class: string::String): bool {
        let (is_class, idx) = vector::index_of(&CLASS_LIST, string::bytes(&_pair_or_class));
        if (is_class) {
            if(idx == 0) {
                return vector::contains(&CRYPTO_LIST, &type_info::struct_name(&type_info::type_of<PairType>()))
            } else if (idx == 1) {
                return vector::contains(&FOREX_LIST, &type_info::struct_name(&type_info::type_of<PairType>()))
            } else {
                return vector::contains(&COMMODITY_LIST, &type_info::struct_name(&type_info::type_of<PairType>()))
            };
        };
        type_info::struct_name(&type_info::type_of<PairType>()) == *string::bytes(&_pair_or_class)
    }
}