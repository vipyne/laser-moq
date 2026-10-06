# MoQ relay VM — human runbook

> Assumes an AWS Route 53 domain and OCI for hosting- amend as needed for your case.

A box that runs `moq-relay` 0.13.5 with real TLS: QUIC/WebTransport on
443/udp, WSS fallback (Safari) + the `/anon` landing page on 443/tcp.
Provider-agnostic in substance: any Ubuntu 24.04 host with a public IPv4 and
inbound **22/80/443 TCP + 443 UDP** works; the OCI commands below are the
concrete path, same shape as `docs/deploy-hls-origin.md`. `RELAY_DOMAIN` is
your hostname (e.g. `relay.example.com`).

## 1. Requirements + OCI provisioning *(laptop)*

- Ubuntu 24.04, public IPv4, inbound **22, 80, 443 TCP** and **443 UDP**.
- On OCI: `VM.Standard.A1.Flex` 1 OCPU / 6 GB (Always-Free eligible; the A1
  budget is 4 OCPU total across the tenancy).
- New network: VCN `relay-vcn`, subnet `relay-subnet`, reserved public IP
  `relay-ip`.

```bash
export C='<compartment-ocid>'   # paste your compartment OCID (kept out of the repo)
oci iam availability-domain list -c $C --query 'data[].name'
export AD='<one name from the list>'

VCN=$(oci network vcn create -c $C --cidr-blocks '["10.2.0.0/16"]' \
--display-name relay-vcn --wait-for-state AVAILABLE \
--query data.id --raw-output)
RT=$(oci network vcn get --vcn-id $VCN --query 'data."default-route-table-id"' --raw-output)
SL=$(oci network vcn get --vcn-id $VCN --query 'data."default-security-list-id"' --raw-output)

IGW=$(oci network internet-gateway create -c $C --vcn-id $VCN --is-enabled true \
--display-name relay-igw --wait-for-state AVAILABLE --query data.id --raw-output)
oci network route-table update --rt-id $RT --force --route-rules \
'[{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","networkEntityId":"'$IGW'"}]'

SUBNET=$(oci network subnet create -c $C --vcn-id $VCN --cidr-block 10.2.0.0/24 \
--display-name relay-subnet --wait-for-state AVAILABLE \
--query data.id --raw-output)
```

Replace the default security list's ingress rules (stateful; egress allow-all
untouched). SSH restricted to your IP (`YOUR_IP`); note the **UDP 443** rule —
that's the QUIC path:

```bash
oci network security-list update --security-list-id $SL --force \
  --ingress-security-rules '[
  {"protocol":"6","source":"YOUR_IP/32","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
  {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
  {"protocol":"17","source":"0.0.0.0/0","udpOptions":{"destinationPortRange":{"min":443,"max":443}}},
  {"protocol":"1","source":"0.0.0.0/0","icmpOptions":{"type":3,"code":4}},
  {"protocol":"1","source":"10.2.0.0/16","icmpOptions":{"type":3}}
]'
```

Instance (Ubuntu 24.04 aarch64, SSH user `ubuntu`; reserved IP attached after
launch so it survives stops):

```bash
IMAGE=$(oci compute image list -c $C \
  --operating-system "Canonical Ubuntu" --operating-system-version 24.04 \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)

INSTANCE=$(oci compute instance launch -c $C --availability-domain "$AD" \
  --shape VM.Standard.A1.Flex --shape-config '{"ocpus":1,"memoryInGBs":6}' \
  --image-id $IMAGE --subnet-id $SUBNET --assign-public-ip false \
  --ssh-authorized-keys-file ~/.ssh/id_ed25519.pub \
  --display-name moq-relay --wait-for-state RUNNING \
  --query data.id --raw-output)

VNIC=$(oci compute instance list-vnics --instance-id $INSTANCE \
  --query 'data[0].id' --raw-output)
PRIVIP=$(oci network private-ip list --vnic-id $VNIC \
  --query 'data[0].id' --raw-output)
oci network public-ip create -c $C --lifetime RESERVED --private-ip-id $PRIVIP \
  --display-name relay-ip --query 'data."ip-address"' --raw-output
```

The printed address is `PUBLIC_IP`. "Out of capacity" on A1 launch is common:
retry with another `$AD`, or fall back to a small x86 `VM.Standard.E4.Flex`
(drop the `--shape` filter from the image lookup).

**Gate:** `ssh -o StrictHostKeyChecking=accept-new ubuntu@PUBLIC_IP` works.

## 2. DNS *(laptop)*

An **A record** `RELAY_DOMAIN → PUBLIC_IP` in your DNS zone. Route 53 shape:

```bash
ZONE=$(aws route53 list-hosted-zones-by-name --dns-name <your-zone> \
  --query 'HostedZones[0].Id' --output text)
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" \
  --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "RELAY_DOMAIN",
      "Type": "A",
      "TTL": 300,
      "ResourceRecords": [{"Value": "PUBLIC_IP"}]
    }
  }]
}'
```

**Gate:** `dig +short RELAY_DOMAIN @1.1.1.1` prints `PUBLIC_IP`. Do this
before §4 — certbot can't issue until it resolves publicly.

## 3. Box prep *(on the box — `ssh ubuntu@PUBLIC_IP`)*

Oracle's Ubuntu image ships iptables rules that **reject everything except
SSH**, independent of the security list — open the ports first (UDP 443
included):

```bash
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 443 -j ACCEPT
sudo netfilter-persistent save

sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 certbot
sudo usermod -aG docker ubuntu   # then log out/in for it to take effect
```

**Gate:** `docker ps` works as `ubuntu` after re-login.

## 4. TLS certificate *(on the box)*

Standalone certbot on port 80 (nothing else listens there), certs copied to
the path the compose file mounts. The copy runs again on every renewal via a
deploy hook:

```bash
sudo certbot certonly --standalone -d RELAY_DOMAIN --agree-tos -m you@example.com -n

sudo mkdir -p /etc/moq/tls
sudo tee /etc/letsencrypt/renewal-hooks/deploy/moq-relay.sh >/dev/null <<'EOF'
#!/bin/sh
cp /etc/letsencrypt/live/RELAY_DOMAIN/fullchain.pem /etc/moq/tls/
cp /etc/letsencrypt/live/RELAY_DOMAIN/privkey.pem /etc/moq/tls/
chmod 644 /etc/moq/tls/*.pem
docker restart laser-moq-relay 2>/dev/null || true
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/moq-relay.sh
sudo /etc/letsencrypt/renewal-hooks/deploy/moq-relay.sh
```

(644 on the key matches the single-admin posture of this box; tighten to the
container's uid if yours is shared.)

**Gate:** `ls /etc/moq/tls` shows `fullchain.pem privkey.pem`.

## 5. Ship + run

*(laptop)*

```bash
rsync -a moq-relay/ ubuntu@PUBLIC_IP:~/moq-relay/
```

*(on the box)*

```bash
cd ~/moq-relay
docker compose up -d --build   # first build compiles moq-relay: ~10 min on 1-OCPU A1
```

**Gates** *(laptop)*:

```bash
curl -s https://RELAY_DOMAIN/anon | head -1    # relay landing page over valid TLS
MOQ_RELAY_URL=https://RELAY_DOMAIN/anon SOURCE=test HLS=0 scripts/publish.sh
# logs "connected version=moq-lite-…" within a few seconds and stays up
```

Then wire the demo to it. On the publisher:

```bash
export MOQ_RELAY_URL=https://RELAY_DOMAIN/anon
```

And set the repo Actions variable so the Pages workflow writes it into
`site/config.js`:

```bash
gh variable set MOQ_RELAY_URL --body 'https://RELAY_DOMAIN/anon'
```

## 6. Auth (optional) — token-gate publishing

`/anon` stays open; a root key makes every other path (e.g. `/livestream`)
require a JWT. Key stays on the laptop; only a copy rides to the box.

*(laptop)*

```bash
moq token generate > ~/moq-root.jwk
scp ~/moq-root.jwk ubuntu@PUBLIC_IP:/tmp/
```

*(on the box)*

```bash
sudo mv /tmp/moq-root.jwk /etc/moq/moq-root.jwk
sudo chmod 644 /etc/moq/moq-root.jwk
cd ~/moq-relay   # uncomment the MOQ_AUTH_KEY line + jwk volume in compose.yml
docker compose up -d
```

*(laptop — mint tokens, publisher gets put+get, viewers get-only)*

```bash
EXP=$(date -v+90d +%s)
moq token sign --key ~/moq-root.jwk --root livestream --publish "" --subscribe "" --expires $EXP   # publisher
moq token sign --key ~/moq-root.jwk --root livestream --subscribe "" --expires $EXP               # viewer
export MOQ_RELAY_URL="https://RELAY_DOMAIN/livestream?jwt=<PUBLISHER_TOKEN>"
gh variable set MOQ_RELAY_URL --body 'https://RELAY_DOMAIN/livestream?jwt=<VIEWER_TOKEN>'
```

**Gate:** `bash tests/test-auth.sh` — token publishes, tokenless publish
rejected.

## 7. Day-to-day *(laptop unless noted)*

- Logs *(on the box)*: `docker logs -f laser-moq-relay`.
- Restart *(on the box)*: `cd ~/moq-relay && docker compose restart`.
- Version bumps: keep `moq-relay` (Dockerfile) paired with the publisher's
  `moq-cli` — a skew can connect fine and silently drop streams.
- Park between shows (the reserved IP `relay-ip` persists):
  `oci compute instance action --instance-id $INSTANCE --action STOP`
  (later `--action START`).
- Done for good: `oci compute instance terminate --instance-id $INSTANCE`, then
  `oci network public-ip list --scope RESERVED -c $C --query 'data[].{ip:"ip-address",id:id}'`
  and `oci network public-ip delete --public-ip-id <id>`.
