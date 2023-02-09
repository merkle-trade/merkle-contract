module merkle::oracle_feed {
    use std::event;
    use std::signer;
    use std::error;
    use std::string::String;

    use aptos_std::table;
    use aptos_std::type_info;

    use aptos_framework::account;
    use aptos_framework::timestamp;

    struct DataRecord has copy, store, drop {
        ///The record value
        value: u64,
        ///Update timestamp microsecond
        updated_at: u64,
    }

    struct OracleUpdateEvent has copy, store, drop {
        key: String,
        record: DataRecord,
    }

    struct OracleFeed has key {
        records: table::Table<String, DataRecord>,
        update_events: event::EventHandle<OracleUpdateEvent>,
    }

    struct UpdateCapability has store, key, drop {
        account: address,
    }

    /// No capability to update the oracle value.
    const ERR_NO_UPDATE_CAPABILITY: u64 = 101;
    const ERR_CAPABILITY_ACCOUNT_MISS_MATCH: u64 = 102;

    fun init_module(
        host: &signer
    ) {
        let host_addr = signer::address_of(host);
        move_to(host, UpdateCapability{account: host_addr});
    }

    /// Register `OracleT` as an oracle type.
    public fun register_oracle<CoinT>(host: &signer, init_value: u64) acquires OracleFeed {
        let host_addr = signer::address_of(host);
        assert!(host_addr == @merkle, error::permission_denied(ERR_CAPABILITY_ACCOUNT_MISS_MATCH));

        if (!exists<UpdateCapability>(host_addr)) {
            move_to(host, UpdateCapability {
                account: host_addr
            });
        };


        let now = timestamp::now_microseconds();
        let coin_key = type_info::type_name<CoinT>();

        if (!exists<OracleFeed>(host_addr)) {
            move_to(host, OracleFeed {
                records: table::new(),
                update_events: account::new_event_handle<OracleUpdateEvent>(host),
            });
        };
        let oracle_feed = borrow_global_mut<OracleFeed>(host_addr);
        table::add(&mut oracle_feed.records, coin_key, DataRecord {
            value: init_value,
            updated_at: now
        });
    }

    /// Update Oracle's record with new value, the `host` must have UpdateCapability<OracleT>
    public fun update(host: &signer, key: String, value: u64) acquires UpdateCapability, OracleFeed {
        let host_addr = signer::address_of(host);
        assert!(exists<UpdateCapability>(host_addr), error::permission_denied(ERR_NO_UPDATE_CAPABILITY));
        let cap = borrow_global_mut<UpdateCapability>(host_addr);
        update_with_cap(cap, key, value);
    }

    /// Update Oracle's record with new value and UpdateCapability<OracleT>
    fun update_with_cap(cap: &mut UpdateCapability, key: String, value: u64) acquires OracleFeed  {
        let account = cap.account;
        let now = timestamp::now_microseconds();
        let oracle_feed = borrow_global_mut<OracleFeed>(account);
        let data_record = table::borrow_mut(&mut oracle_feed.records, key);
        data_record.value = value;
        data_record.updated_at = now;
        event::emit_event(&mut oracle_feed.update_events, OracleUpdateEvent {
            key,
            record: *data_record
        });
    }

    /// Read the Oracle's value from `addr`
    public fun read(key: String): u64 acquires OracleFeed {
        let oracle_feed = borrow_global<OracleFeed>(@merkle);
        let data_record = table::borrow(&oracle_feed.records, key);
        data_record.value
    }

    /// Read the Oracle's DataRecord from `addr`
    /// Not using switchboard
    public fun read_record(key: String): DataRecord acquires OracleFeed {
        let oracle_feed = borrow_global<OracleFeed>(@merkle);
        *table::borrow(&oracle_feed.records, key)
    }

    /// Unpack Record to fields: version, oracle, updated_at.
    public fun unpack_record(record: DataRecord):(u64, u64) {
        (record.value, record.updated_at)
    }

    /* test */
    #[test_only]
    struct TESTUSD has copy,store,drop {}

    #[test_only]
    fun call_test_setting(host: &signer, aptos_framework: &signer) {
        let host_addr = signer::address_of(host);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(host_addr);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_register_init(host: &signer, aptos_framework: &signer) acquires OracleFeed {
        call_test_setting(host, aptos_framework);
        register_oracle<TESTUSD>(host, 10);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_read(host: &signer, aptos_framework: &signer) acquires OracleFeed {
        let coin_key = type_info::type_name<TESTUSD>();
        call_test_setting(host, aptos_framework);

        register_oracle<TESTUSD>(host, 10);
        assert!(read(coin_key) == 10, 0);

        let record = read_record(coin_key);
        assert!(record.value == 10, 1);
        let (value, _) = unpack_record(record);
        assert!(value == 10, 2);
    }

    #[test(host = @merkle, aptos_framework = @aptos_framework)]
    fun test_update(host: &signer, aptos_framework: &signer) acquires OracleFeed, UpdateCapability {
        let coin_key = type_info::type_name<TESTUSD>();
        call_test_setting(host, aptos_framework);

        register_oracle<TESTUSD>(host,  10);
        update(host, coin_key, 20);
        let record = read_record(coin_key);
        assert!(record.value == 20, 0);
    }
}
