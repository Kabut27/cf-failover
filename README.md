# 🔁 cf-failover

**Automatic Cloudflare DNS failover** kwa multi-node servers (3x-ui/Xray n.k).
Domain zako zinaelekezwa kiotomatiki kwenye node ya kwanza inayofanya kazi.

---

## ✨ Features

- 🖥️ Nodes 2, 3, au zaidi kwa mpangilio wa priority
- 🌐 Domain records kadhaa zinabadilishwa pamoja
- 📡 Health check ya TCP au HTTP — kila dakika 1 kupitia `cron`
- 🔒 Lock file — inazuia run mbili kugongana
- 📲 Kudhibiti kila kitu kupitia **Telegram** (bila kugusa server), na
  amri zinajibiwa **ndani ya sekunde 1-2** (huduma ya `systemd`, siyo
  kusubiri dakika ya cron)
- 🧩 Sakinisha kwenye server zote kwa amri MOJA — hakuna server "kuu"

---

## 🧱 Muundo wa faili

| Faili | Kazi | Inaendeshwa vipi |
|---|---|---|
| `cf-failover-lib.sh` | Functions zinazoshirikiwa (Cloudflare API, amri za /addip n.k.) | inasomwa (source) na faili nyingine mbili |
| `cf-failover.sh` | Health-check ya nodes + kubadili DNS | `cron`, kila dakika 1 |
| `cf-telegram-bot.sh` | Inasikiliza amri za Telegram muda wote na kujibu papo hapo | `systemd` service |

Health-check inabaki kila dakika 1 kimakusudi — kuifanya ya papo hapo
kungesababisha DNS kubadilika mno node ikipepesuka (flap) na kuharibu
utulivu wa mfumo. Amri za Telegram hazina sababu ya kusubiri hiyo dakika,
kwa hiyo zina huduma yake tofauti inayosikiliza papo hapo.

---

## 🤖 Amri za Telegram

| Amri | Kazi |
|------|------|
| `/addip <ip> [nafasi]` | Ongeza node |
| `/removeip <ip>` | Ondoa node |
| `/setpriority <ip1,ip2,...>` | Badilisha orodha yote |
| `/listips` | Onyesha nodes zote |
| `/addrecord <domain>` | Ongeza domain |
| `/removerecord <domain>` | Ondoa domain |
| `/listrecords` | Onyesha domains zote |
| `/refresh` au `/status` | Ripoti ya papo hapo |
| `/help` | Onyesha amri zote |

> ⚠️ Tumia bot ya Telegram **iliyotengwa** kwa cf-failover peke yake.

---

## 🚀 Usanikishaji (kwenye kila server)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kabut27/cf-failover/main/install.sh)"
```

Installer itakuuliza Cloudflare Token/Zone ID, node priority, domain
records, na (hiari) Telegram Bot Token/Chat ID. Ukiweka Telegram Bot
Token, huduma ya `systemd` ya Telegram itawashwa moja kwa moja kwenye
server hiyo hiyo.

---

## 📋 Kuangalia Logs

```bash
# Health-check / DNS-failover (cron)
tail -f /var/log/cf-failover.log

# Huduma ya Telegram (systemd)
journalctl -u cf-failover-telegram -f
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
