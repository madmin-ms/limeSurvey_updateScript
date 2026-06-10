#!/usr/bin/env bash
#===============================================================================
# update-limesurvey.sh — LimeSurvey biztonságos frissítő script
#
# Hivatalos zip-ből frissít egy LimeSurvey példányt:
#   1. Előellenőrzések (root, eszközök, lemezhely, zip)
#   2. Karbantartási mód be (.htaccess deny)
#   3. Adatbázis-mentés (mysqldump, jelszó nélkül a parancssorban)
#   4. Teljes fájlmentés (tar.gz)
#   5. Új verzió kicsomagolása staging mappába
#   6. Megőrzendő fájlok átmásolása (config.php, security.php, upload/)
#   7. Atomi csere (mv) — hiba esetén automatikus visszaállítás
#   8. Jogosultságok beállítása (hardened: kód root-é, csak tmp/ és upload/ írható)
#   9. DB-migráció CLI-ből (console.php updatedb)
#  10. Karbantartási mód ki + HTTP health check
#
# Használat (root-ként):
#   ./update-limesurvey.sh -i /var/www/limesurvey1 -z /root/limesurvey6.x.zip \
#       [-s <sha256>] [-u www-data] [-g www-data] [-c https://felmeres.example.hu]
#
#   -i  A LimeSurvey példány gyökérkönyvtára (kötelező)
#   -z  A hivatalos LimeSurvey zip elérési útja (kötelező)
#   -s  A zip elvárt SHA-256 hash-e (erősen ajánlott)
#   -u  Webszerver user (alapért.: www-data)
#   -g  Webszerver csoport (alapért.: a user csoportja)
#   -c  URL a frissítés utáni health checkhez (opcionális)
#   -b  Backup könyvtár (alapért.: /var/backups/limesurvey)
#
# A DB-jelszót a példány saját application/config/config.php-jából olvassa ki,
# sehol máshol nem kell megadni vagy tárolni.
#===============================================================================
set -Eeuo pipefail
umask 027

#--- Paraméterek ---------------------------------------------------------------
INSTANCE="" ZIP="" SHA256="" WEB_USER="www-data" WEB_GROUP="" CHECK_URL=""
BACKUP_ROOT="/var/backups/limesurvey"

while getopts "i:z:s:u:g:c:b:h" opt; do
  case "$opt" in
    i) INSTANCE="${OPTARG%/}" ;;
    z) ZIP="$OPTARG" ;;
    s) SHA256="$OPTARG" ;;
    u) WEB_USER="$OPTARG" ;;
    g) WEB_GROUP="$OPTARG" ;;
    c) CHECK_URL="$OPTARG" ;;
    b) BACKUP_ROOT="$OPTARG" ;;
    h) grep '^#' "$0" | head -40; exit 0 ;;
    *) echo "Ismeretlen kapcsoló. -h a súgóhoz." >&2; exit 2 ;;
  esac
done

[[ -n "$INSTANCE" && -n "$ZIP" ]] || { echo "HIBA: -i és -z kötelező. -h a súgóhoz." >&2; exit 2; }
[[ -n "$WEB_GROUP" ]] || WEB_GROUP="$(id -gn "$WEB_USER")"

TS="$(date +%Y%m%d-%H%M%S)"
NAME="$(basename "$INSTANCE")"
BACKUP_DIR="$BACKUP_ROOT/$NAME/$TS"
LOG="$BACKUP_DIR/update.log"
LOCK="/var/lock/limesurvey-update-$NAME.lock"
STAGING="" OLD_DIR="" SWAPPED=0 MAINT_ON=0

#--- Naplózás ------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_ROOT" "$BACKUP_ROOT/$NAME" "$BACKUP_DIR"
exec > >(tee -a "$LOG") 2>&1
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { log "HIBA: $*"; rollback 1; }

#--- Hibakezelés / visszaállítás ----------------------------------------------
maintenance_off() {
  if [[ "$MAINT_ON" -eq 1 && -d "$INSTANCE" ]]; then
    rm -f "$INSTANCE/.htaccess"
    [[ -f "$INSTANCE/.htaccess.pre-update" ]] && mv "$INSTANCE/.htaccess.pre-update" "$INSTANCE/.htaccess"
    MAINT_ON=0
    log "Karbantartási mód kikapcsolva."
  fi
}

on_error() { rollback $?; }

rollback() {
  local rc=$1
  trap - ERR
  log "================ HIBA TÖRTÉNT (exit code: $rc) ================"
  if [[ "$SWAPPED" -eq 1 && -d "$OLD_DIR" ]]; then
    log "A fájlcsere már megtörtént — automatikus visszaállítás a régi verzióra..."
    rm -rf "${INSTANCE}.failed-$TS" 2>/dev/null || true
    mv "$INSTANCE" "${INSTANCE}.failed-$TS" 2>/dev/null || true
    mv "$OLD_DIR" "$INSTANCE"
    SWAPPED=0
    log "Fájlok visszaállítva. A hibás új verzió itt maradt: ${INSTANCE}.failed-$TS"
    log "FIGYELEM: ha az updatedb már lefutott, a DB-t kézzel kell visszaállítani:"
    log "  gunzip -c '$BACKUP_DIR/db.sql.gz' | mysql --defaults-extra-file=<cred-fájl> <dbnév>"
  fi
  maintenance_off
  log "Backup és napló: $BACKUP_DIR"
  exit "$rc"
}
trap on_error ERR

#--- 1. Előellenőrzések --------------------------------------------------------
log "=== LimeSurvey frissítés indul: $INSTANCE ==="

[[ "$(id -u)" -eq 0 ]] || fail "Root-ként futtasd (a chown miatt szükséges)."
for tool in php mysqldump unzip tar gzip rsync flock curl; do
  command -v "$tool" >/dev/null || fail "Hiányzó eszköz: $tool"
done
id "$WEB_USER" >/dev/null 2>&1 || fail "Nem létező user: $WEB_USER"
[[ -d "$INSTANCE" ]] || fail "Nem létezik a példány könyvtára: $INSTANCE"
[[ -f "$INSTANCE/application/config/config.php" ]] || fail "Nem LimeSurvey példánynak tűnik (nincs application/config/config.php)."
[[ -f "$ZIP" ]] || fail "Nem található a zip: $ZIP"

# Lock — két frissítés ne fusson egyszerre ugyanazon a példányon
exec 9>"$LOCK"
flock -n 9 || fail "Már fut egy frissítés ezen a példányon (lock: $LOCK)."

# Zip integritás + opcionális SHA-256
unzip -tqq "$ZIP" >/dev/null || fail "Sérült zip fájl: $ZIP"
if [[ -n "$SHA256" ]]; then
  echo "$SHA256  $ZIP" | sha256sum -c - >/dev/null || fail "SHA-256 eltérés! A zip nem az elvárt fájl."
  log "Zip SHA-256 ellenőrzés: OK"
else
  log "FIGYELEM: nincs SHA-256 megadva (-s), a zip eredetisége nincs ellenőrizve."
fi

# Verziók kiolvasása (régi a példányból, új a zipből)
OLD_VER="$(grep -oP "versionnumber.*?'\K[^']+" "$INSTANCE/application/config/version.php" 2>/dev/null | head -1 || echo '?')"
ZIP_TOP="$(unzip -Z1 "$ZIP" | head -1 | cut -d/ -f1)"
NEW_VER="$(unzip -p "$ZIP" "$ZIP_TOP/application/config/version.php" 2>/dev/null | grep -oP "versionnumber.*?'\K[^']+" | head -1 || echo '?')"
log "Jelenlegi verzió: $OLD_VER  →  Új verzió: $NEW_VER"

# Lemezhely: kell ~ a példány mérete kétszer (backup + staging) + ráhagyás
INST_KB="$(du -sk "$INSTANCE" | cut -f1)"
NEED_KB=$(( INST_KB * 5 / 2 ))
FREE_KB="$(df -Pk "$(dirname "$INSTANCE")" | awk 'NR==2{print $4}')"
(( FREE_KB > NEED_KB )) || fail "Kevés a szabad lemezhely: $((FREE_KB/1024)) MB van, ~$((NEED_KB/1024)) MB kellene."

#--- DB-adatok kiolvasása a config.php-ból -------------------------------------
log "DB-kapcsolat kiolvasása a config.php-ból..."
DB_INFO="$(php -d display_errors=0 -r '
  $c = include $argv[1];
  $db = $c["components"]["db"];
  preg_match("/host=([^;]+)/",   $db["connectionString"], $h);
  preg_match("/port=([^;]+)/",   $db["connectionString"], $p);
  preg_match("/dbname=([^;]+)/", $db["connectionString"], $d);
  echo ($h[1] ?? "localhost"), "\n", ($p[1] ?? "3306"), "\n", ($d[1] ?? ""), "\n",
       $db["username"], "\n", $db["password"], "\n";
' "$INSTANCE/application/config/config.php")" || fail "Nem sikerült a config.php-ból kiolvasni a DB-adatokat."
{ read -r DB_HOST; read -r DB_PORT; read -r DB_NAME; read -r DB_USER; read -r DB_PASS; } <<< "$DB_INFO"
[[ -n "$DB_NAME" && -n "$DB_USER" ]] || fail "Hiányos DB-adatok a config.php-ban."
log "Adatbázis: $DB_NAME @ $DB_HOST:$DB_PORT (user: $DB_USER)"

# Jelszó SOHA nem kerül parancssorba: védett temp credential fájl
CRED="$(mktemp)"
chmod 600 "$CRED"
trap 'rm -f "$CRED"' EXIT
printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' \
  "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" > "$CRED"

#--- 2. Karbantartási mód be ---------------------------------------------------
log "Karbantartási mód bekapcsolása (.htaccess)..."
[[ -f "$INSTANCE/.htaccess" ]] && cp -a "$INSTANCE/.htaccess" "$INSTANCE/.htaccess.pre-update"
cat > "$INSTANCE/.htaccess" <<'EOF'
# LIMESURVEY-UPDATE-MAINTENANCE — a frissítő script tette ide, a végén törli
<IfModule mod_authz_core.c>
  Require all denied
</IfModule>
ErrorDocument 403 "Karbantartas folyamatban, kerjuk latogass vissza kesobb."
EOF
MAINT_ON=1
sleep 2   # futó kérések lecsengése

#--- 3. Adatbázis-mentés -------------------------------------------------------
log "Adatbázis mentése: $BACKUP_DIR/db.sql.gz ..."
mysqldump --defaults-extra-file="$CRED" \
  --single-transaction --quick --routines --triggers --events \
  --no-tablespaces "$DB_NAME" | gzip > "$BACKUP_DIR/db.sql.gz"
gzip -t "$BACKUP_DIR/db.sql.gz" || fail "A DB-dump gzip ellenőrzése sikertelen."
gunzip -c "$BACKUP_DIR/db.sql.gz" | tail -1 | grep -q "Dump completed" \
  || fail "A DB-dump hiányosnak tűnik (nincs 'Dump completed' a végén)."
log "DB-mentés kész: $(du -h "$BACKUP_DIR/db.sql.gz" | cut -f1)"

#--- 4. Teljes fájlmentés ------------------------------------------------------
log "Fájlok mentése: $BACKUP_DIR/files.tar.gz ..."
tar -czf "$BACKUP_DIR/files.tar.gz" -C "$(dirname "$INSTANCE")" "$NAME"
tar -tzf "$BACKUP_DIR/files.tar.gz" >/dev/null || fail "A fájlmentés tar ellenőrzése sikertelen."
log "Fájlmentés kész: $(du -h "$BACKUP_DIR/files.tar.gz" | cut -f1)"

#--- 5. Új verzió kicsomagolása staging mappába --------------------------------
# A staging a példánnyal azonos fájlrendszeren van, hogy az mv atomi legyen.
STAGING="$(mktemp -d "$(dirname "$INSTANCE")/.${NAME}-staging-XXXXXX")"
log "Kicsomagolás staging mappába: $STAGING ..."
unzip -q "$ZIP" -d "$STAGING"
[[ -d "$STAGING/$ZIP_TOP/application" ]] || fail "Váratlan zip-szerkezet (nincs $ZIP_TOP/application)."

#--- 6. Megőrzendő fájlok átmásolása -------------------------------------------
log "Konfiguráció és feltöltött tartalmak átvétele..."
cp -a "$INSTANCE/application/config/config.php" "$STAGING/$ZIP_TOP/application/config/config.php"
[[ -f "$INSTANCE/application/config/security.php" ]] && \
  cp -a "$INSTANCE/application/config/security.php" "$STAGING/$ZIP_TOP/application/config/security.php"
rsync -a "$INSTANCE/upload/" "$STAGING/$ZIP_TOP/upload/"

# Figyelmeztetés egyedi config-fájlokra, amiket nem viszünk át automatikusan
while IFS= read -r f; do
  base="$(basename "$f")"
  [[ -e "$STAGING/$ZIP_TOP/application/config/$base" ]] || \
    log "FIGYELEM: egyedi config-fájl, kézi ellenőrzést igényel: $f"
done < <(find "$INSTANCE/application/config" -maxdepth 1 -name '*.php')

#--- 7. Atomi csere ------------------------------------------------------------
OLD_DIR="${INSTANCE}.old-$TS"
log "Csere: a régi verzió ide kerül: $OLD_DIR"
mv "$INSTANCE" "$OLD_DIR"
mv "$STAGING/$ZIP_TOP" "$INSTANCE"
SWAPPED=1
rmdir "$STAGING" 2>/dev/null || rm -rf "$STAGING"
STAGING=""

# A karbantartási .htaccess átvitele az új könyvtárba (még tartson a zárlat)
cp -a "$OLD_DIR/.htaccess" "$INSTANCE/.htaccess"
[[ -f "$OLD_DIR/.htaccess.pre-update" ]] && cp -a "$OLD_DIR/.htaccess.pre-update" "$INSTANCE/.htaccess.pre-update"

#--- 8. Jogosultságok (hardened) -----------------------------------------------
# A kód root tulajdonú és a webszerver számára csak olvasható — így egy esetleges
# webes kompromittálás nem tudja a PHP-kódot átírni. Csak a tmp/ és upload/ írható.
log "Jogosultságok beállítása (kód: root:$WEB_GROUP csak olvasható; tmp/, upload/: írható)..."
chown -R "root:$WEB_GROUP" "$INSTANCE"
find "$INSTANCE" -type d -exec chmod 750 {} +
find "$INSTANCE" -type f -exec chmod 640 {} +
chown -R "$WEB_USER:$WEB_GROUP" "$INSTANCE/tmp" "$INSTANCE/upload"
find "$INSTANCE/tmp" "$INSTANCE/upload" -type d -exec chmod 750 {} +
find "$INSTANCE/tmp" "$INSTANCE/upload" -type f -exec chmod 640 {} +
chmod 640 "$INSTANCE/application/config/config.php"

#--- 9. DB-migráció ------------------------------------------------------------
log "Adatbázis-migráció futtatása (console.php updatedb)..."
sudo -u "$WEB_USER" php "$INSTANCE/application/commands/console.php" updatedb \
  || fail "Az updatedb sikertelen — a fájlok automatikusan visszaállnak."
log "DB-migráció kész."

#--- 10. Karbantartási mód ki + health check -----------------------------------
maintenance_off

if [[ -n "$CHECK_URL" ]]; then
  log "Health check: $CHECK_URL ..."
  HTTP_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 30 "$CHECK_URL" || echo '000')"
  if [[ "$HTTP_CODE" == "200" ]]; then
    log "Health check: OK (HTTP 200)"
  else
    log "FIGYELEM: a health check HTTP $HTTP_CODE -t adott — ellenőrizd kézzel a felületet!"
  fi
fi

log "=== KÉSZ: $OLD_VER → $NEW_VER ==="
log "Backup:        $BACKUP_DIR  (db.sql.gz + files.tar.gz)"
log "Régi fájlok:   $OLD_DIR  (ha minden rendben, pár nap múlva törölhető)"
log "Visszaállítás szükség esetén:"
log "  mv '$INSTANCE' '${INSTANCE}.broken' && mv '$OLD_DIR' '$INSTANCE'"
log "  gunzip -c '$BACKUP_DIR/db.sql.gz' | mysql <dbnév>   # csak ha az updatedb is lefutott"
