# Proxmox SDN Network Setup Script

Bash skript Proxmox VE SDN (Software Defined Networking) võrkude automaatseks loomiseks ja haldamiseks. Võimaldab luua isoleeritud subneteid koos automaatse DHCP-ga ning ühendada VM-e loodud võrkudega — kas käsitsi või CSV failist hulgi.

---

## Mida skript teeb

- Loob SDN Zone'i automaatse DHCP serveriga
- Loob VNet'i (virtuaalse võrgu)
- Loob Subnet'i koos DHCP vahemikuga
- Lubab SNAT'i (VM-id pääsevad internetti läbi NAT)
- Ühendab valitud VM-id loodud võrguga — ühe kaupa või CSV failist hulgi

---

## Nõuded

- Proxmox VE 7.x või uuem
- Root õigused
- SDN plugin lubatud Proxmox klastris
- `dnsmasq` pakett paigaldatud (DHCP jaoks)

---

## Paigaldus

```bash
# Laadi skript alla või kopeeri see serverisse
cd /root
nano setup-network.sh
# Kopeeri skripti sisu, salvesta ja sulge

chmod +x setup-network.sh
```

---

## Kasutamine

```bash
./setup-network.sh
```

Käivitamisel küsib skript režiimi valiku:

```
=========================================
Proxmox SDN Network Setup Script
=========================================
Choose setup mode:
1) Interactive mode (single subnet)
2) Batch mode (CSV import)
Enter choice (1 or 2):
```

---

## Režiimid

### 1) Interaktiivne režiim

Loob ühe subneti ja ühendab valikuliselt VM-i.

```
Enter subnet number (0-255) to create 192.168.X.0/24: 10
Enter VM ID to attach network (or 0 to skip): 100
```

- Kui sisestad juba kasutusel oleva subneti numbri, küsib skript kas soovid lisada VM-i olemasolevasse subneti
- Kui VM-l on juba `net0` konfigureeritud, hoiatatakse enne ülekirjutamist
- VM ID kohale `0` sisestamine jätab VM ühendamata

### 2) CSV režiim (hulgiimport)

Skript otsib automaatselt kõik `.csv` failid samast kaustast kus skript asub.

- Kui leitakse **üks** CSV fail → kasutatakse seda automaatselt
- Kui leitakse **mitu** CSV faili → näidatakse nimekirja ja küsitakse valik
- Kui **ühtegi** CSV faili ei leita → kuvatakse veateade koos juhisega

#### CSV faili formaat

```csv
subnet_id,vm_id
10,100
10,101
11,200
12,0
```

| Veerg | Kirjeldus |
|---|---|
| `subnet_id` | Subneti number vahemikus 0–255. Loob võrgu `192.168.X.0/24` |
| `vm_id` | VM ID mida ühendada. `0` tähendab "ära ühenda VM-i" |

**Reeglid:**
- Päise rida (`subnet_id,vm_id`) on valikuline — skript ignoreerib seda automaatselt
- Mitu VM-i samas subnetis on lubatud — korrake sama `subnet_id` mitmel real
- Subnet luuakse ainult üks kord, isegi kui sama number esineb mitmel real
- Juba olemasolevaid subneteid ei kirjutata üle — VM-id lihtsalt lisatakse
- Vigased read (vale formaat, olematu VM) jäetakse vahele koos hoiatusega

---

## Mida skript loob

Iga uue subneti kohta luuakse automaatselt:

| Komponent | Näide (subnet 10) | Kirjeldus |
|---|---|---|
| Zone | `zone10` | SDN tsoon, tüüp `simple` |
| VNet | `vnet10` | Virtuaalne võrk |
| Subnet | `192.168.10.0/24` | IP aadressiruum |
| Gateway | `192.168.10.1` | Võrgu värav |
| DHCP vahemik | `192.168.10.100–200` | Automaatne IP jagamine |
| DHCP server | `dnsmasq` | DHCP teenus |
| SNAT | Lubatud | VM-id saavad internetti |

> IP-aadressid vahemikus `.2–.99` jäävad vabaks staatiliseks kasutamiseks.

VM ühendatakse VNet-iga läbi `net0` liidese, kasutades `virtio` draiverit.

---

## Näited

### Näide 1 — üks subnet ilma VM-ita

```bash
./setup-network.sh
# Vali: 1
# Subnet number: 15
# VM ID: 0
```

Tulemus: Luuakse `zone15`, `vnet15`, subnet `192.168.15.0/24`. VM-i ei ühendata.

### Näide 2 — mitu VM-i samas subnetis CSV-st

`networks.csv`:
```csv
subnet_id,vm_id
20,300
20,301
20,302
21,400
```

```bash
./setup-network.sh
# Vali: 2
# (skript leiab networks.csv automaatselt)
```

Tulemus:
- `vnet20` — ühendatud VM-id 300, 301, 302
- `vnet21` — ühendatud VM 400

### Näide 3 — mitu CSV faili kaustas

```
Searching for CSV files in current directory: /root

Found 3 CSV file(s):
  1) /root/networks.csv
  2) /root/test.csv
  3) /root/backup.csv

Select CSV file (1-3):
```

---

## Turvalisus

Skript kontrollib, kas VM-il on juba `net0` liides olemas. Kui jah, küsib kinnitust enne ülekirjutamist:

```
WARNING: VM 125 already has net0 configured:
net0: virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr0
Do you want to overwrite it? (y/n):
```

---

## Mida skript EI muuda

- Node'i füüsilist võrgukonfiguratsiooni
- `vmbr0` bridge'i seadeid
- Node'i IP-aadressi, gateway'd või DNS-i
- Teisi VM-e või konteinereid
- Ligipääsu Proxmox web UI-le või SSH-le

---

## Kontrolli tulemust

```bash
# Vaata loodud tsoone
pvesh get /cluster/sdn/zones

# Vaata loodud VNet-e
pvesh get /cluster/sdn/vnets

# Vaata konkreetse VM võrgu konfiguratsiooni
qm config <VMID>

# Vaata SDN olekut
pvesh get /cluster/sdn
```

---

## Vigade käsitlemine

| Olukord | Skripti käitumine |
|---|---|
| Subnet juba eksisteerib | Vahele jäetud (CSV), või küsitakse kas lisada VM (interaktiivne) |
| VM ei eksisteeri | Hoiatus, subnet luuakse ikkagi |
| Vale subnet number (>255) | Veateade, rida jäetakse vahele |
| Vale VM ID formaat | Hoiatus, subnet luuakse ilma VM-ita |
| CSV faili ei leita | Veateade koos formaadi selgitusega |
| Skript ei käivitu root'ina | Viga ja väljumine |

### Levinud veakoodid

| Viga | Lahendus |
|---|---|
| `zone ID contains illegal characters` | Zone nimi ei tohi sisaldada kriipse |
| `unexpected property 'bridge'` | Simple zone ei tohi saada `--bridge` parameetrit |
| `Option dhcp is ambiguous` | Kasuta `--dhcp-range` asemel õiget formaati |
| `invalid format - value without key` | DHCP range formaat: `start-address=IP,end-address=IP` |

---

## Muutujad

Skripti alguses saab muuta vaikeväärtusi:

```bash
BRIDGE="vmbr0"      # Füüsiline bridge (praegu pole kasutusel simple zones'is)
DHCP_START="100"    # DHCP vahemiku algus (192.168.X.100)
DHCP_END="200"      # DHCP vahemiku lõpp (192.168.X.200)
```

---

## Litsents

Vabalt kasutatav ja muudetav vastavalt vajadusele.
