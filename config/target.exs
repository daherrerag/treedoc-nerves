import Config

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

config :nerves_runtime, startup_guard_enabled: true

config :nerves, :erlinit, update_clock: true

config :logger, :default_handler, false

# SSH access and firmware updates.
# Uses any of the standard public key types in ~/.ssh.
keys =
  System.user_home!()
  |> Path.join(".ssh/nerves-daherrerag-ed25519.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

# Wi-Fi credentials must be set as build-time env vars:
#   export NERVES_WIFI_SSID="your-network"
#   export NERVES_WIFI_PSK="your-password"
config :vintage_net,
  regulatory_domain: "CO",
  config: [
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [
           %{
             key_mgmt: :wpa_psk,
             ssid: System.fetch_env!("NERVES_WIFI_SSID"),
             psk: System.fetch_env!("NERVES_WIFI_PSK")
           }
         ]
       },
       ipv4: %{method: :dhcp}
     }}
  ]

config :mdns_lite,
  hosts: [:hostname, "nerves"],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]
