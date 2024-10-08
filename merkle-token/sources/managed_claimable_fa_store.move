module merkle::managed_claimable_fa_store {
    use merkle::claimable_fa_store;

    public entry fun deposit_funding_store(_host: &signer, _resource_account: address, _amount: u64) {
        claimable_fa_store::deposit_funding_store(_host, _resource_account, _amount);
    }
}