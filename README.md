# cf-failover

Automatic Cloudflare DNS failover kwa multi-node 3x-ui/Xray setup.
Domain records (mfano cdn1/cdn2/cdn3) zinaelekezwa automatiki kwenye node
ya kwanza inayofanya kazi kutoka kwenye orodha ya priority uliyoweka.

## Mfano wa muundo (kama wako)

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
cdn3.domain.com
```

Kwa mfano huu:
- `NODE_PRIORITY = 3.3.3.3,2.2.2.2,1.1.1.1`
- `TARGET_RECORDS = cdn1.domain.com,cdn2.domain.com,cdn3.domain.com`

3.3.3.3 ikianguka → zote tatu (cdn1, cdn2, cdn3) zinaelekezwa 2.2.2.2.
2.2.2.2 nayo ikianguka → zote zinaelekezwa 1.1.1.1.
3.3.3.3 ikirudi hewani → zote zinarudi 3.3.3.3 automatiki.

## Jinsi ya kuweka kwenye GitHub (fanya hii mara moja)

1. Tengeneza repo mpya kwenye GitHub, mfano `cf-failover`
2. Pakia faili hizi mbili: `install.sh` na `cf-failover.sh`
3. Fungua `install.sh` na badilisha line hii juu:
   ```
   REPO_RAW_URL="https://raw.githubusercontent.com/USERNAME_YAKO/REPO_YAKO/main"
   ```
   weka username na jina la repo yako halisi
4. Commit na push

## Matumizi (one-click, kwenye kila server)

```bash
curl -sSL https://raw.githubusercontent.com/USERNAME_YAKO/REPO_YAKO/main/install.sh | sudo bash
```

Itakuuliza:
- Cloudflare API Token
- Cloudflare Zone ID
- Node priority (comma separated, kwa mpangilio)
- Target records (comma separated)
- Port ya kucheck
- Fail threshold

**Weka input SAWA kwenye server zote 3** - kila node inafanya uamuzi wake
kwa kuangalia hali halisi ya DNS kwenye Cloudflare, hivyo hakuna haja ya
kutofautisha config kati ya server.

## Kwa nini ni salama kuweka kwenye node zote 3 (hata primary)

Script haitegemei "kumbukumbu" ya server moja - kila run inasoma DNS record
halisi kutoka Cloudflare API kabla ya kuamua kubadilisha kitu. Hivyo:
- 3.3.3.3 (top priority) ikianguka, script iliyo kwenye 1.1.1.1 na 2.2.2.2
  bado inafanya kazi na itagundua na kubadilisha
- Script iliyokuwa kwenye 3.3.3.3 yenyewe itasimama tu (server iko chini),
  bila kuathiri zile nyingine mbili

## Kuangalia logs

```bash
tail -f /var/log/cf-failover.log
```

## Kuondoa (uninstall)

```bash
crontab -l | grep -v cf-failover.sh | crontab -
sudo rm -rf /opt/cf-failover /etc/cf-failover
```

## Kubadilisha config baadaye

Hariri moja kwa moja kwenye kila server:
```bash
sudo nano /etc/cf-failover/config.env
```
Hakuna haja ya kukimbiza install.sh tena.
