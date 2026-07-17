# 🔁 cf-failover

**DNS failover ya kiotomatiki kwenye Cloudflare** kwa multi-node servers
(3x-ui/Xray n.k). Domain zako zinaelekezwa kiotomatiki kwenye node ya
kwanza inayofanya kazi, na kila kitu kinadhibitiwa kupitia Telegram.

---

## ✨ Features

- 🖥️ Nodes 2, 3, au zaidi kwa mpangilio wa priority
- 🌐 Domain records kadhaa zinabadilishwa pamoja
- 📡 Health check (TCP/HTTP) kila dakika 1 kupitia `cron`
- 📲 Kudhibiti kila kitu kupitia **Telegram** — amri zinajibiwa ndani
  ya sekunde 1-2 (huduma ya `systemd`, siyo kusubiri cron)
- 🧩 Sakinisha kwenye server zote kwa amri MOJA — hakuna server "kuu"
- 👑 **Leader election** — node ZOTE zinaendesha huduma ya Telegram,
  lakini moja tu inaongea na Telegram kwa wakati mmoja. Ikizima,
  nyingine inachukua nafasi kiotomatiki ndani ya sekunde chache
- ☁️ **Cloudflare pekee ndiyo chanzo cha data** — node/domain
  HAZIHIFADHIWI kwenye VPS popote; zinasomwa moja kwa moja kutoka
  Cloudflare kila run
- 🧹 Kinga dhidi ya marudio (duplicates), na amri ya kusafisha yoyote
  yaliyopo

---

## ☁️ Data iko wapi?

| Data | Iko wapi |
|---|---|
| Node (IP) na Domain records | **Cloudflare pekee** (TXT record), hakuna copy VPS |
| Cloudflare API Token / Zone ID | VPS (`/etc/cf-failover/config.env`) — inahitajika kuongea na Cloudflare |
| Telegram Bot Token / Chat ID | VPS (`/etc/cf-failover/config.env`) |
| "Kiongozi ni nani" (leader heartbeat) | Cloudflare (TXT record nyingine, kiufundi tu) |

Server yoyote mpya unayosakinisha inasoma node/domain zilizopo moja
kwa moja kutoka Cloudflare — huhitaji kuweka chochote tena.

---

## 🚀 Usanikishaji (kwenye kila server)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kabut27/cf-failover/main/install.sh)"
```

Installer itakuuliza Cloudflare Token/Zone ID, jina la config record,
mipangilio ya health-check, na (hiari) Telegram Bot Token/Chat ID.
**Haitakuuliza node wala domain** — hizo unaziongeza baadaye kupitia
Telegram, mara moja tu (zitasambaa kiotomatiki kwenye server zote).

Ukiweka Telegram Bot Token, huduma ya `systemd` ya Telegram itawashwa
moja kwa moja kwenye server hiyo hiyo. Tumia **Token/Chat ID/Config
record name SAWA** kwenye server zote unazosakinisha.

---

## 📋 Kuangalia Logs

```bash
# Health-check / DNS-failover (cron)
tail -f /var/log/cf-failover.log

# Huduma ya Telegram (systemd)
journalctl -u cf-failover-telegram -f
```

Kutambua ni server ipi ni "kiongozi" wa Telegram kwa sasa:
```bash
journalctl -u cf-failover-telegram -n 5 --no-pager
```

## 🗑️ Kuondoa

```bash
crontab -l | grep -v cf-failover.sh | crontab -
sudo systemctl disable --now cf-failover-telegram.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/cf-failover-telegram.service
sudo systemctl daemon-reload
sudo rm -rf /opt/cf-failover /etc/cf-failover /etc/logrotate.d/cf-failover
```

## ⚙️ Kubadilisha Config

```bash
sudo nano /etc/cf-failover/config.env
```
Baada ya kuhariri:
- Health-check (cron) — hakuna haja ya install upya, mabadiliko yanatumika run inayofuata.
- Huduma ya Telegram (systemd) — kimbiza `sudo systemctl restart cf-failover-telegram` ili isome config mpya (mfano ukibadili Bot Token).
