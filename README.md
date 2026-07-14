# 🔁 cf-failover

**Automatic Cloudflare DNS failover** kwa multi-node servers (3x-ui/Xray n.k).
Domain zako zinaelekezwa kiotomatiki kwenye node ya kwanza inayofanya kazi.

---

## ✨ Features

- ✅ Faili moja tu — inakimbia kila dakika kwenye `cron`
- 🖥️ Nodes 2, 3, au zaidi kwa mpangilio wa priority
- 🌐 Domain records kadhaa zinabadilishwa pamoja
- 📡 Health check ya TCP au HTTP
- 🔒 Lock file — inazuia run mbili kugongana
- 📲 Kudhibiti kila kitu kupitia **Telegram** (bila kugusa server)

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

Installer itakuuliza Cloudflare Token/Zone ID, node priority, domain records, na (hiari) Telegram Bot Token/Chat ID.

---

## 📋 Kuangalia Logs

```bash
tail -f /var/log/cf-failover.log
```

## 🗑️ Kuondoa

```bash
crontab -l | grep -v cf-failover.sh | crontab -
sudo rm -rf /opt/cf-failover /etc/cf-failover /etc/logrotate.d/cf-failover
```

## ⚙️ Kubadilisha Config

```bash
sudo nano /etc/cf-failover/config.env
```
Hakuna haja ya install upya — mabadiliko yanatumika run inayofuata.
