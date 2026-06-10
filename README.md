# LimeSurvey biztonságos frissítés — útmutató

A [update-limesurvey.sh](update-limesurvey.sh) egy LimeSurvey példányt frissít a hivatalos zip-ből, teljes mentéssel és automatikus visszaállítással hiba esetén.

## Előkészület (egyszer)

```bash
# A script felmásolása a szerverre (a saját gépedről):
scp update-limesurvey.sh felhasznalo@szerver:/root/

# A szerveren:
chmod 700 /root/update-limesurvey.sh
```

## Frissítés menete (példányonként)

```bash
# 1. Hivatalos zip letöltése a szerverre — MINDIG a hivatalos forrásból, HTTPS-en:
wget -O /root/limesurvey.zip \
  "https://download.limesurvey.org/latest-stable-release/limesurvey6.x.y+YYMMDD.zip"

# 2. SHA-256 kiszámítása és összevetése a hivatalos oldalon közölttel (ha elérhető):
sha256sum /root/limesurvey.zip

# 3. Frissítés — ELŐSZÖR a kevésbé kritikus példányon:
sudo /root/update-limesurvey.sh \
  -i /var/www/limesurvey1 \
  -z /root/limesurvey.zip \
  -s <sha256-hash> \
  -u www-data \
  -c https://felmeres1.example.hu

# 4. Kézi ellenőrzés a böngészőben (admin belépés, egy teszt-kérdőív kitöltése)

# 5. Ha minden rendben, jöhet a második példány:
sudo /root/update-limesurvey.sh \
  -i /var/www/limesurvey2 \
  -z /root/limesurvey.zip \
  -s <sha256-hash> \
  -u www-data \
  -c https://felmeres2.example.hu
```

## Mit csinál a script?

1. **Előellenőrzések** — root, szükséges eszközök, lemezhely, zip-integritás, SHA-256, verziók kiírása
2. **Karbantartási mód** — `.htaccess` deny, hogy frissítés közben senki ne írjon az adatbázisba
3. **DB-mentés** — `mysqldump --single-transaction`, gzip, integritás-ellenőrzés; a jelszót a példány saját `config.php`-jából olvassa, és védett temp fájlon adja át (nem látszik a `ps`-ben, nincs a scriptben)
4. **Fájlmentés** — a teljes példány tar.gz-ben
5. **Staging + atomi csere** — az új verzió külön mappában áll össze (config.php, security.php, upload/ átmásolva), majd egyetlen `mv` cseréli; a régi könyvtár `*.old-<időbélyeg>` néven megmarad
6. **Hardened jogosultságok** — a kód `root` tulajdonú, a webszerver csak olvashatja; csak a `tmp/` és `upload/` írható
7. **DB-migráció** — `console.php updatedb` a webszerver usereként
8. **Health check** — HTTP 200 ellenőrzés a megadott URL-en

## Hiba esetén

- A script **automatikusan visszaállítja a fájlokat**, ha a csere után bármi elromlik.
- Az adatbázist szándékosan **nem** állítja vissza automatikusan — a pontos parancsot kiírja a naplóba:
  ```bash
  gunzip -c /var/backups/limesurvey/<példány>/<időbélyeg>/db.sql.gz | mysql <dbnév>
  ```
- Minden futásról teljes napló készül: `/var/backups/limesurvey/<példány>/<időbélyeg>/update.log`

## Fontos megjegyzések

- A karbantartási mód `.htaccess`-alapú — **Apache + `AllowOverride All`** esetén működik. Nginx alatt a frissítés idejére a vhostban kell ideiglenesen `return 503;`-at beállítani (a script többi része ugyanúgy működik).
- A script kiírja, ha az `application/config/` alatt **egyedi config-fájlt** talál, amit nem visz át automatikusan — ezeket kézzel kell ellenőrizni.
- A régi `*.old-*` könyvtárakat és a backupokat **pár nap üzem után érdemes törölni**, automatikusan nem törlődnek.
- **Major verzióugrásnál** (pl. 5.x → 6.x) előbb olvasd el a hivatalos release notes-t — ott lehetnek extra lépések (PHP-verzió követelmény stb.).
