# cf-failover

Automatic Cloudflare DNS failover kwa multi-node 3x-ui/Xray setup.
Domain records (mfano cdn1/cdn2) zinaelekezwa automatiki kwenye node
ya kwanza inayofanya kazi kutoka kwenye orodha ya priority uliyoweka.

## Features

- Faili MOJA tu (`cf-failover.sh`) - inakimbia kila dakika 1 kwenye cron
- Priority list ya nodes - 2, 3, au zaidi
- Domain records kadhaa (1, 2, au zaidi) zinabadilishwa pamoja
- TCP au HTTP health check
- Lock file - inazuia run mbili kugongana
- Arifa za Telegram (hiari): failover, restored, dharura, na ripoti ya mara kwa mara
- Log rotation
- Curl timeouts kwenye kila API call
- State file iko `/etc/cf-failover/state.env` (siyo `/var/tmp`) - haifutwi na
  usafi wa mfumo (`systemd-tmpfiles`). Hii ilikuwa sababu ya tatizo la awali
  ambapo ripoti ilitumwa kila dakika badala ya kila masaa kadhaa.

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

Itakuuliza token, zone ID, node priority, target records, health check,
na (hiari) Telegram Bot Token/Chat ID + kila dakika ngapi utumie ripoti
(mfano 360 = kila masaa 6).

## Jinsi ripoti inavyofanya kazi

Script inakimbia kila dakika 1 (kwa ajili ya failover check). Ndani ya run
hiyo hiyo, inaangalia kama muda uliowekwa (`STATUS_REPORT_MINUTES`) umepita
tangu ripoti ya mwisho - kama ndiyo, inatuma ripoti; kama siyo, inaruka
sehemu hiyo na kuendelea na kazi ya kawaida ya failover. Muda huu unahifadhiwa
kwenye state file ya kudumu, kwa hiyo haipotei hata baada ya cron kukimbia
mara nyingi.

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
Hakuna haja ya kukimbiza install.sh tena.
