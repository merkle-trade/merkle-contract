module merkle::rebase {
    use std::signer;
    use merkle::safe_math_u64;

    struct ModifyCapability<phantom T> has key, store { owner: address }

    struct Rebase<phantom T> has key, store {
        elastic: u64,
        base: u64,
    }

    const REBASE_NOT_EXISTS: u64 = 102;
    const CAP_NOT_EXISTS: u64 = 103;

    public fun initialize<T: store>(account: &signer) {
        move_to(account, Rebase<T> { elastic: 0, base: 0 });
        move_to(account, ModifyCapability<T> { owner: signer::address_of(account) });
    }

    public fun remove_modify_capability<T: store>(
        account: &signer,
    ): ModifyCapability<T> acquires ModifyCapability {
        move_from<ModifyCapability<T>>(signer::address_of(account))
    }

    // Calculates the base value in relationship to `elastic` and `total`.
    public fun toBase<T: store>(
        addr: address,
        elastic: u64,
        roundUp: bool,
    ): u64 acquires Rebase {
        assert!(exists<Rebase<T>>(addr), REBASE_NOT_EXISTS);
        let total = borrow_global<Rebase<T>>(addr);
        if (total.elastic == 0) {
            elastic
        } else {
            let base = safe_math_u64::safe_mul_div(elastic, total.base, total.elastic);
            if (roundUp && safe_math_u64::safe_mul_div(base, total.elastic, total.base) < elastic) {
                base = base + 1;
            };
            base
        }
    }

    // Calculates the elastic value in relationship to `base` and `total`.
    public fun toElastic<T: store>(
        addr: address,
        base: u64,
        roundUp: bool,
    ): u64 acquires Rebase {
        assert!(exists<Rebase<T>>(addr), REBASE_NOT_EXISTS);
        let total = borrow_global<Rebase<T>>(addr);
        if (total.base == 0) {
            base
        } else {
            let elastic = safe_math_u64::safe_mul_div(base, total.elastic, total.base);
            if (roundUp && safe_math_u64::safe_mul_div(elastic, total.base, total.elastic) < base) {
                elastic = elastic + 1;
            };
            elastic
        }
    }

    // Get `elastic` and `base`
    public fun get<T: store>(addr: address): (u64, u64) acquires Rebase {
        assert!(exists<Rebase<T>>(addr), REBASE_NOT_EXISTS);
        let total = borrow_global<Rebase<T>>(addr);
        (total.elastic, total.base)
    }

    fun assert_capability<T: store>(account: &signer): address {
        let account_addr = signer::address_of(account);
        assert!(exists<ModifyCapability<T>>(account_addr), CAP_NOT_EXISTS);
        account_addr
    }

    public fun addElasticWithCapability<T: store>(cap: &ModifyCapability<T>, elastic: u64) acquires Rebase {
        assert!(exists<Rebase<T>>(cap.owner), REBASE_NOT_EXISTS);
        let total = borrow_global_mut<Rebase<T>>(cap.owner);
        total.elastic = total.elastic + elastic;
    }

    // Add `elastic` to `total` and update storage.
    public fun addElastic<T: store>(account: &signer, elastic: u64) acquires ModifyCapability, Rebase {
        let addr = assert_capability<T>(account);
        addElasticWithCapability<T>(borrow_global<ModifyCapability<T>>(addr), elastic);
    }

    public fun subElasticWithCapability<T: store>(cap: &ModifyCapability<T>, elastic: u64) acquires Rebase {
        assert!(exists<Rebase<T>>(cap.owner), REBASE_NOT_EXISTS);
        let total = borrow_global_mut<Rebase<T>>(cap.owner);
        total.elastic = total.elastic - elastic;
    }

    // Subtract `elastic` from `total` and update storage.
    public fun subElastic<T: store>(account: &signer, elastic: u64) acquires ModifyCapability, Rebase {
        let addr = assert_capability<T>(account);
        subElasticWithCapability<T>(borrow_global<ModifyCapability<T>>(addr), elastic);
    }

    public fun addWithCapability<T: store>(cap: &ModifyCapability<T>, elastic: u64, base: u64) acquires Rebase {
        assert!(exists<Rebase<T>>(cap.owner), REBASE_NOT_EXISTS);
        let total = borrow_global_mut<Rebase<T>>(cap.owner);
        total.elastic = total.elastic + elastic;
        total.base = total.base + base;
    }

    // Add `elastic` and `base` to `total`.
    public fun add<T: store>(account: &signer, elastic: u64, base: u64) acquires ModifyCapability, Rebase {
        let addr = assert_capability<T>(account);
        addWithCapability<T>(borrow_global<ModifyCapability<T>>(addr), elastic, base);
    }

    public fun subWithCapability<T: store>(cap: &ModifyCapability<T>, elastic: u64, base: u64) acquires Rebase {
        assert!(exists<Rebase<T>>(cap.owner), REBASE_NOT_EXISTS);
        let total = borrow_global_mut<Rebase<T>>(cap.owner);
        total.elastic = total.elastic - elastic;
        total.base = total.base - base;
    }

    // Subtract `elastic` and `base` to `total`.
    public fun sub<T: store>(account: &signer, elastic: u64, base: u64) acquires ModifyCapability, Rebase {
        let addr = assert_capability<T>(account);
        subWithCapability<T>(borrow_global<ModifyCapability<T>>(addr), elastic, base);
    }

    public fun addByElasticWithCapability<T: store>(
        cap: &ModifyCapability<T>,
        elastic: u64,
        roundUp: bool,
    ): u64 acquires Rebase {
        let base = toBase<T>(cap.owner, elastic, roundUp);
        addWithCapability<T>(cap, elastic, base);
        base
    }

    // Add `elastic` to `total` and doubles `total.base`.
    // return base in relationship to `elastic`.
    public fun addByElastic<T: store>(
        account: &signer,
        elastic: u64,
        roundUp: bool,
    ): u64 acquires ModifyCapability, Rebase {
        let addr = assert_capability<T>(account);
        addByElasticWithCapability<T>(borrow_global<ModifyCapability<T>>(addr), elastic, roundUp)
    }

    public fun subByBaseWithCapability<T: store>(
        cap: &ModifyCapability<T>,
        base: u64,
        roundUp: bool,
    ): u64 acquires Rebase {
        let elastic = toElastic<T>(cap.owner, base, roundUp);
        subWithCapability<T>(cap, elastic, base);
        elastic
    }

    // Sub `base` from `total` and update `total.elastic`.
    // return elastic in relationship to `base`
    public fun subByBase<T: store>(
        account: &signer,
        base: u64,
        roundUp: bool,
    ): u64 acquires ModifyCapability, Rebase {
        let addr = assert_capability<T>(account);
        subByBaseWithCapability<T>(borrow_global<ModifyCapability<T>>(addr), base, roundUp)
    }
}