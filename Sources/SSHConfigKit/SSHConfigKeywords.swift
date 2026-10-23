/// Common ssh_config keywords with a short description, used for the editor's suggestions.
public enum SSHConfigKeywords {
    public static let common: [(key: String, help: String)] = [
        ("HostName", "Real host name or IP address to connect to"),
        ("User", "User name to log in as"),
        ("Port", "Port number on the remote host"),
        ("IdentityFile", "Private key file used for authentication"),
        ("IdentitiesOnly", "Only use the configured identity files (yes/no)"),
        ("ProxyJump", "Jump host(s), comma separated: user@jump1,jump2"),
        ("ProxyCommand", "Command used to connect to the server"),
        ("ForwardAgent", "Forward the authentication agent (yes/no)"),
        ("LocalForward", "Forward a local port: 8080 localhost:80"),
        ("RemoteForward", "Forward a remote port: 9000 localhost:9000"),
        ("DynamicForward", "SOCKS proxy on a local port"),
        ("ServerAliveInterval", "Seconds between keep-alive probes"),
        ("ServerAliveCountMax", "Missed keep-alives before disconnecting"),
        ("Compression", "Enable compression (yes/no)"),
        ("AddKeysToAgent", "Add keys to the agent on first use (yes/no/ask)"),
        ("UseKeychain", "Store passphrases in the macOS keychain (yes/no)"),
        ("PreferredAuthentications", "Order of authentication methods"),
        ("PubkeyAuthentication", "Allow public key authentication (yes/no)"),
        ("PasswordAuthentication", "Allow password authentication (yes/no)"),
        ("StrictHostKeyChecking", "Host key checking: yes/no/ask/accept-new"),
        ("UserKnownHostsFile", "Known hosts file path"),
        ("ConnectTimeout", "Connection timeout in seconds"),
        ("RequestTTY", "Request a TTY: yes/no/force/auto"),
        ("RemoteCommand", "Command executed on the remote host after login"),
        ("SetEnv", "Environment variables to send: NAME=value"),
        ("SendEnv", "Local environment variables to send"),
        ("LogLevel", "Verbosity: QUIET, ERROR, INFO, VERBOSE, DEBUG"),
        ("Ciphers", "Allowed ciphers"),
        ("KexAlgorithms", "Allowed key exchange algorithms"),
        ("HostKeyAlgorithms", "Allowed host key algorithms"),
        ("CertificateFile", "User certificate file"),
        ("ControlMaster", "Connection sharing: yes/no/auto/ask"),
        ("ControlPath", "Socket path for connection sharing"),
        ("ControlPersist", "Keep the master connection open"),
    ]

    /// Keywords that may legitimately appear multiple times in one block.
    public static let repeatable: Set<String> = [
        "identityfile", "localforward", "remoteforward", "dynamicforward", "sendenv", "setenv", "certificatefile",
    ]
}
