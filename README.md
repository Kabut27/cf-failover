# cf-failover

Automatic Cloudflare DNS failover kwa multi-node 3x-ui/Xray setup.
Domain records (mfano cdn1/cdn2) zinaelekezwa automatiki kwenye node
ya kwanza inayofanya kazi kutoka kwenye orodha ya priority uliyoweka.

## Features

- **Faili MOJA tu** (`cf-failover.sh`) - inakimbia kila dakika 1 kwenye cron
- Priority list ya nodes - 2, 3, au zaidi
- Domain records kadhaa (1, 2, au zaidi) zinabadilishwa pamoja
- **Inatengeneza DNS record kiotomatiki** ikiwa haipo bado kwenye Cloudflare
  (siyo tu kubadilisha zilizopo)
- TCP au HTTP health check
- Lock file - inazuia run mbili kugongana kwenye node moja
- Curl `--connect-timeout`, `--max-time`, na `--retry 1` kwenye API calls zote
- State file iko `/etc/cf-failover/state.env` (siyo `/var/tmp`) - haifutwi na
  usafi wa mfumo (`systemd-tmpfiles`)
- Log rotation (wiki 4, zimeshinikizwa)
- TTL ya DNS ni sekunde 30 kwa default - propagation ya haraka wakati wa failover

### Arifa za Telegram (hiari)

- 🔁 **FAILOVER** - DNS imebadilishwa kutoka node moja kwenda nyingine
- ✅ **RESTORED** - node kuu (top priority) imerudi hewani
- 🚨 **DHARURA** - node zote hazirespondi (arifa moja tu, siyo inayorudia kila dakika)
- 🟢 / 🔴 - node yoyote (hata backup isiyotumika) ikibadilika hali (up/down)
- 📊 Ripoti ya mara kwa mara ya hali ya node zote (muda unaowekwa wakati wa install)
- **Amri ya `/refresh`** - tuma ujumbe huu kwa bot yako wakati wowote kupata
  ripoti ya papo hapo (ndani ya dakika 1) bila kusubiri ripoti ya ratiba

**MUHIMU:** Tumia bot ya Telegram iliyotengwa kwa ajili ya cf-failover peke
yake - siyo bot inayotumika na huduma nyingine (mfano bot ya admin ya
Cloudflare). Bot moja haiwezi kusomwa (`getUpdates`) na huduma mbili tofauti
kwa wakati mmoja bila mgongano - amri ya `/refresh` haitafanya kazi vizuri
kama bot inashirikiana na kitu kingine kinachosikiliza ujumbe.

## Mfano wa muundo

Node zako:
```
1.1.1.1
2.2.2.2
3.3.3.3   <- unayoitegemea zaidi (top priority)
```

Domain zinazobadilishwa pamoja:
```
cdn1.domain.com
cdn2.domain.com
```

## Matumizi (one-click, kwenye kila server)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kabut27/cf-failover/main/install.sh)"
```

Installer inakuuliza: Cloudflare Token/Zone ID (na kuithibitisha moja kwa
moja kabla ya kuendelea), node priority, target records, health check
(tcp/http), na (hiari) Telegram Bot Token/Chat ID + kila dakika ngapi
utumie ripoti (mfano 360 = kila masaa 6). Pia inasakinisha `cron` na
`curl`/`flock` kiotomatiki ikiwa havipo kwenye mfumo.

## Jinsi ripoti inavyofanya kazi

Script inakimbia kila dakika 1 (kwa ajili ya failover check). Ndani ya run
hiyo hiyo, inaangalia kama muda uliowekwa (`STATUS_REPORT_MINUTES`) umepita
tangu ripoti ya mwisho - kama ndiyo, inatuma ripoti; kama siyo, inaruka
sehemu hiyo na kuendelea na kazi ya kawaida ya failover. Muda huu unahifadhiwa
kwenye state file ya kudumu, kwa hiyo haipotei hata baada ya cron kukimbia
mara nyingi. Ukituma `/refresh` kwenye Telegram, ripoti inatumwa papo hapo
bila kujali muda uliobaki.

## Kuangalia logs

```bash
tail -f /var/log/cf-failover.log
```

## Kuondoa (uninstall)

```bash
crontab -l | grep -v cf-failover.sh | crontab -
sudo rm -rf /opt/cf-failover /etc/cf-failover /etc/logrotate.d/cf-failover
```

## Kubadilisha config baadaye

```bash
sudo nano /etc/cf-failover/config.env
```
Hakuna haja ya kukimbiza install.sh tena - mabadiliko yanatumika kwenye run inayofuata.
