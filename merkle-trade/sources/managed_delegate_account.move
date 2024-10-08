module merkle::managed_delegate_account {
    use merkle::trading;
    use merkle::delegate_account;

    public entry fun initialize_module(_admin: &signer) {
        delegate_account::initialize_module(_admin);
    }

    public entry fun register<AssetT>(_host: &signer, _delegate_account: address) {
        delegate_account::register<AssetT>(_host, _delegate_account);
    }

    public entry fun deposit<AssetT>(_host: &signer, _delegate_account: address, _amount: u64) {
        trading::initialize_user_if_needed(_host);
        delegate_account::deposit<AssetT>(_host, _delegate_account, _amount);
    }

    public entry fun withdraw<AssetT>(_host: &signer, _amount: u64) {
        delegate_account::withdraw<AssetT>(_host, _amount);
    }

    public entry fun unregister<AssetT>(_host: &signer) {
        delegate_account::unregister<AssetT>(_host);
    }
}