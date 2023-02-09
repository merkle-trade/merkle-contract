module merkle::merkle_coin {

    // <-- USE ----->

    use std::string;
    use std::signer;

    use aptos_framework::coin;

    use merkle::math_u64;

    // <-- CONSTANT ----->

    const COIN_NAME: vector<u8> = b"Merkle";
    const COIN_SYMBOL: vector<u8> = b"MKL";
    const COIN_DECIMALS: u8 = 8;
    const MAX_SUPPLY: u64 = 10 * 1000 * 1000;

    // <-- ERROR CODE ----->

    const E_NO_CAPABILITIES: u64 = 1;
    const E_TOO_BIG_AMOUNT: u64 = 2;

    // <-- STRUCT ----->

    struct MerkleCoin has key {}

    struct Capabilities<phantom CoinType> has key {
        burn_cap: coin::BurnCapability<CoinType>,
        freeze_cap: coin::FreezeCapability<CoinType>,
        mint_cap: coin::MintCapability<CoinType>,
    }

    // <-- PUBLIC FUNCTION ----->

    /// Initialize new coin 'Merkle' in Aptos Blockchain.
    /// Mint and Burn, freeze Capabilities will be stored under `account` in `Capabilities` resource.
    public entry fun initialize(
        _owner: &signer,
    ) {
        let (burn_cap, freeze_cap, mint_cap) =
            coin::initialize<MerkleCoin>(
                _owner,
                string::utf8(COIN_NAME),
                string::utf8(COIN_SYMBOL),
                COIN_DECIMALS,
                true
            );

        move_to(_owner, Capabilities<MerkleCoin> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    /// Mint merkle coin and deposit into _to's account.
    public entry fun mint(
        _minter: &signer,
        _to: address,
        _amount: u64,
    ) acquires Capabilities {
        let account_addr = signer::address_of(_minter);

        assert!(exists<Capabilities<MerkleCoin>>(account_addr), E_NO_CAPABILITIES);

        let capabilities = borrow_global<Capabilities<MerkleCoin>>(account_addr);
        let coins_minted = coin::mint(_amount, &capabilities.mint_cap);
        coin::deposit(_to, coins_minted);
    }

    public fun scaling_factor(): u64 {
        math_u64::exp(10, (COIN_DECIMALS as u64))
    }

    public fun get_max_supply(): u64 {
        scaling_factor() * MAX_SUPPLY
    }
}