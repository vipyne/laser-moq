# HLS origin VM — human runbook

A **new** box that runs MediaMTX (RTMP in → LL-HLS out) behind Caddy (automatic
TLS for `hls-laserdisc.vanessa-dev.com`). Do **not** reuse the relay box — the relay is
shared with the <internal-moq-demo> demo and stays untouched. Provider-agnostic in
substance: any Ubuntu 24.04 host with a public IPv4 and inbound 22/80/443/1935
TCP works; the OCI commands below are the concrete path, modelled on
`<internal-bench-repo>/…/deploy-oci.md`.

## 1. Requirements + OCI provisioning *(laptop)*

- Ubuntu 24.04, public IPv4, inbound **22, 80, 443, 1935 TCP**.
- On OCI: a **new** `VM.Standard.A1.Flex` 1 OCPU / 6 GB. Always-Free A1 budget
  is 4 OCPU total; three 1-OCPU boxes already exist → **exactly one more fits**.
- New network, do not reuse `relay-subnet`: VCN `hls-vcn`, subnet `hls-subnet`,
  reserved public IP `hls-ip`.

```bash
export C='<compartment-ocid>'   # paste your compartment OCID (kept out of the repo)
oci iam availability-domain list -c $C --query 'data[].name'
export AD='<one name from the list>'

VCN=$(oci network vcn create -c $C --cidr-blocks '["10.1.0.0/16"]' \
--display-name hls-vcn --wait-for-state AVAILABLE \
--query data.id --raw-output)
RT=$(oci network vcn get --vcn-id $VCN --query 'data."default-route-table-id"' --raw-output)
SL=$(oci network vcn get --vcn-id $VCN --query 'data."default-security-list-id"' --raw-output)

IGW=$(oci network internet-gateway create -c $C --vcn-id $VCN --is-enabled true \
--display-name hls-igw --wait-for-state AVAILABLE --query data.id --raw-output)
oci network route-table update --rt-id $RT --force --route-rules \
'[{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","networkEntityId":"'$IGW'"}]'

SUBNET=$(oci network subnet create -c $C --vcn-id $VCN --cidr-block 10.1.0.0/24 \
--display-name hls-subnet --wait-for-state AVAILABLE \
--query data.id --raw-output)
```

Replace the default security list's ingress rules (stateful; egress allow-all
untouched). SSH restricted to your IP (`YOUR_IP`); the ICMP path-MTU rules are
the console defaults:

```bash
oci network security-list update --security-list-id $SL --force \
  --ingress-security-rules '[
  {"protocol":"6","source":"YOUR_IP/32","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
  {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
  {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":1935,"max":1935}}},
  {"protocol":"1","source":"0.0.0.0/0","icmpOptions":{"type":3,"code":4}},
  {"protocol":"1","source":"10.1.0.0/16","icmpOptions":{"type":3}}
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
  --display-name hls-origin --wait-for-state RUNNING \
  --query data.id --raw-output)

VNIC=$(oci compute instance list-vnics --instance-id $INSTANCE \
  --query 'data[0].id' --raw-output)
PRIVIP=$(oci network private-ip list --vnic-id $VNIC \
  --query 'data[0].id' --raw-output)
oci network public-ip create -c $C --lifetime RESERVED --private-ip-id $PRIVIP \
  --display-name hls-ip --query 'data."ip-address"' --raw-output
```

The printed address is `PUBLIC_IP`. If the launch fails with "Out of capacity"
(common for A1), retry with another `$AD`, or fall back to a small x86
`VM.Standard.E4.Flex` (drop the `--shape` filter from the image lookup).

**Gate:** `ssh -o StrictHostKeyChecking=accept-new ubuntu@PUBLIC_IP` works.

## 2. DNS *(laptop)*

Route 53 A record `hls-laserdisc.vanessa-dev.com → PUBLIC_IP` (`AWS_PROFILE=vanessa-dev`).
Do this before §4 — Caddy cannot get a certificate until it resolves publicly:

```bash
ZONE=$(AWS_PROFILE=vanessa-dev aws route53 list-hosted-zones-by-name --dns-name vanessa-dev.com \
  --query 'HostedZones[0].Id' --output text)
AWS_PROFILE=vanessa-dev aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" \
  --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "hls-laserdisc.vanessa-dev.com",
      "Type": "A",
      "TTL": 300,
      "ResourceRecords": [{"Value": "PUBLIC_IP"}]
    }
  }]
}'
```

**Gate:** `dig +short hls-laserdisc.vanessa-dev.com @1.1.1.1` prints `PUBLIC_IP`.

## 3. Box prep *(on the box — `ssh ubuntu@PUBLIC_IP`)*

Oracle's Ubuntu image ships iptables rules that **reject everything except
SSH**, independent of the security list — open the ports first:

```bash
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 1935 -j ACCEPT
sudo netfilter-persistent save

sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker ubuntu   # then log out/in for it to take effect
```

**Gate:** `docker ps` works as `ubuntu` after re-login.

## 4. Ship + run

*(laptop)*

```bash
rsync -a hls-origin/ ubuntu@PUBLIC_IP:~/hls-origin/
```

*(on the box)*

```bash
cd ~/hls-origin
cp env.example .env        # set HLS_DOMAIN and a real RTMP_PUBLISH_PASS (openssl rand -hex 16)
docker compose up -d
```

**Gate:** `curl -sI https://hls-laserdisc.vanessa-dev.com/ | head -1` → `404` with a valid
certificate (MediaMTX 404s the root; the cert is what matters).

## 5. Publish from the laptop *(laptop)*

```bash
RTMP_URL="rtmp://hls-laserdisc.vanessa-dev.com:1935/laserdisc?user=laserdisc&pass=$RTMP_PUBLISH_PASS" SOURCE=test scripts/publish.sh
```

**Gate:** `J=$(mktemp); curl -sfL -c "$J" -b "$J" https://hls-laserdisc.vanessa-dev.com/laserdisc/index.m3u8 | head` prints
a playlist while the publisher runs.

## 6. Day-to-day *(laptop unless noted)*

- Logs *(on the box)*: `docker logs -f laser-mediamtx`, `docker logs -f laser-caddy`.
- Restart *(on the box)*: `cd ~/hls-origin && docker compose restart`.
- Park between shows (the reserved IP `hls-ip` persists):
  `oci compute instance action --instance-id $INSTANCE --action STOP`
  (later `--action START`).
- Done for good: `oci compute instance terminate --instance-id $INSTANCE`, then
  `oci network public-ip list --scope RESERVED -c $C --query 'data[].{ip:"ip-address",id:id}'`
  and `oci network public-ip delete --public-ip-id <id>`.
