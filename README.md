# cf-failover

Automatic Cloudflare DNS failover kwa multi-node 3x-ui/Xray setup.
Domain records (mfano cdn1/cdn2) zinaelekezwa automatiki kwenye node
ya kwanza inayofanya kazi kutoka kwenye orodha ya priority uliyoweka.

## Features

- Priority list ya nodes - **2, 3, au zaidi**, siyo primary+backup peke yake
- Domain records kadhaa (**1, 2, 3, au zaidi**) zinabadilishwa pamoja
- TCP au HTTP health check (HTTP inaangalia jibu halisi la service, siyo tu port)
- Lock file - inazuia run mbili kugongana kama run moja ikachelewa
- Arifa za Telegram (hiari) - unapata ujumbe kila DNS ikibadilishwa au node zote zikianguka
- Log rotation - logs hazijazi disk
- Curl timeouts kwenye kila API call - script haiwezi kunasa (hang) Cloudflare ikiwa slow
- Inasoma hali halisi ya DNS kwenye Cloudflare kila run (siyo "kumbukumbu" ya server moja) -
  salama kuiweka kwenye node zote hata primary yenyewe

## Mfano wa muundo

Node zako (zinaweza kuwa 2, 3, au zaidi):
```
1.1.1.1
2.2.2.2
3.3.3.3   <- unayoitegemea zaidi (top priority)
```

Domain zinazobadilishwa pamoja (zinaweza kuwa 1, 2, au zaidi):
```
cdn1.domain.com
cdn2.domain.com
```

Kwa mfano huu:
- `NODE_PRIORITY = 3.3.3.3,2.2.2.2,1.1.1.1`
- `TARGET_RECORDS = cdn1.domain.com,cdn2.domain.com`

3.3.3.3 ikianguka → zote zinaelekezwa 2.2.2.2.
2.2.2.2 nayo ikianguka → zote zinaelekezwa 1.1.1.1.
3.3.3.3 ikirudi hewani → zote zinarudi 3.3.3.3 automatiki (bila delay).

## Matumizi (one-click, kwenye kila server)

```bash
curl -sSL https://raw.githubusercontent.com/Kabut27/cf-failover/main/install.sh | sudo bash
```

Itakuuliza:
- Cloudflare API Token na Zone ID
- Node priority (comma separated)
- Target records (comma separated) - unaweza kuweka 1, 2, au zaidi
- Port ya kucheck
- Fail threshold
- Aina ya health check: `tcp` (haraka, inaangalia port tu) au `http`
  (sahihi zaidi, inaangalia jibu la service - unaulizwa scheme na path)
- Telegram Bot Token na Chat ID (hiari - acha wazi kama hutaki arifa)

**Weka input SAWA kwenye node zote** - kila node inafanya uamuzi wake
kwa kuangalia hali halisi ya DNS kwenye Cloudflare.

## Arifa za Telegram

Ukiweka Bot Token na Chat ID wakati wa install, utapata ujumbe moja kwa moja:
- Kila wakati DNS record inapobadilishwa (na kuonyesha kutoka IP gani kwenda IP gani)
- Onyo la dharura kama node ZOTE zikianguka wakati mmoja

Kupata Chat ID yako: tuma ujumbe wowote kwa bot yako, kisha fungua
`https://api.telegram.org/bot<TOKEN>/getUpdates` kwenye browser, `chat.id`
itaonekana kwenye JSON.

## Kwa nini ni salama kuweka kwenye node zote (hata top priority)

Script haitegemei "kumbukumbu" ya server moja - kila run inasoma DNS record
halisi kutoka Cloudflare API kabla ya kuamua kubadilisha kitu. Node moja
ikianguka, zile nyingine bado zinafanya kazi na kugundua/kubadilisha.
Lock file inazuia node hiyo hiyo isijirudie kukimbiza run mbili kwa wakati mmoja.

## Kuangalia logs

```bash
tail -f /var/log/cf-failover.log
```

Logs zinazungushwa (rotate) kila wiki, zinahifadhiwa wiki 4 tu, hivyo hazitajaza disk.

## Kuondoa (uninstall)

```bash
crontab -l | grep -v cf-failover.sh | crontab -
sudo rm -rf /opt/cf-failover /etc/cf-failover /etc/logrotate.d/cf-failover
```

## Kubadilisha config baadaye

Hariri moja kwa moja kwenye kila server:
```bash
sudo nano /etc/cf-failover/config.env
```
Hakuna haja ya kukimbiza install.sh tena - mabadiliko yanatumika kwenye run inayofuata.
