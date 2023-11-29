module merkle::managed_vault {
    use merkle::vault;

    public entry fun register_vault<VaultT, AssetT>(_host: &signer) {
        vault::register_vault<VaultT, AssetT>(_host);
    }
}