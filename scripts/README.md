# scripts/

Lab helpers. Do not commit `router.pub`, `*.key`, `*.psk`, or generated `peers/`.

## wg-ap-peer.sh

Generate a WireGuard keypair on the **AP**. The **router** already owns the WG interface.

```text
AP  [Interface] Address     = this AP's tunnel IP (/32)
AP  [Interface] PrivateKey  = generated here
AP  [Peer] PublicKey        = router WG public key
AP  [Peer] Endpoint         = router_reachable_ip:listen-port
AP  [Peer] AllowedIPs       = WG net (+ LAN with --lan)

Router peer public-key      = AP public key
Router peer allowed-address = AP tunnel IP /32
Router peer endpoint        = empty (AP initiates)
```

```bash
echo '<router-wg-public-key>' > router.pub
# edit ROUTER_ENDPOINT / ROUTER_PORT / WG_PREFIX at the top of the script
./scripts/wg-ap-peer.sh add ap1
./scripts/wg-ap-peer.sh add ap1 --lan 192.168.88.0/24
```

Paste `peers/ap1/mikrotik.rsc` on the router, then:

```bash
sudo wg-quick up peers/ap1/ap1.conf
ping 10.10.10.1
sudo wg show
```
