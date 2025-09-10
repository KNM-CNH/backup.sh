#!/bin/bash

# ===============================================
# KOH Restore-Skript (v1.0)
# ===============================================
# Features:
# - Basiert auf dem KOH Backup-Skript (v2.0)
# - Farbige Ausgaben für bessere Lesbarkeit
# - Interaktive Auswahl von Projekt und Backup
# - Leeren von Webspace und Datenbank vor Restore
# - Wiederherstellung von Datenbank und Dateien
# - Sicherheitsabfrage vor destruktiven Aktionen
# ===============================================

set -euo pipefail
trap 'cleanup_on_error' ERR INT TERM

# --- Globale Variablen ---
BACKUP_ROOT="$HOME/backup"           # Haupt-Backup-Verzeichnis

# --- Farben für Ausgaben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m' # No Color

# --- Funktionen ---

cleanup_on_error() {
    log_message "ERROR" "Skript wurde unterbrochen oder ein Fehler trat auf."
    exit 1
}

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    case $level in
        "INFO") echo -e "${LIGHT_BLUE}[${timestamp}] INFO: ${message}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[${timestamp}] ✓ ${message}${NC}" ;;
        "WARNING") echo -e "${YELLOW}[${timestamp}] [!] ${message}${NC}" ;;
        "ERROR") echo -e "${RED}[${timestamp}] ✗ ${message}${NC}" ;;
    esac
}

# --- Hauptprogramm ---

clear
echo -e "${GREEN}"
echo "=============================================="
echo "=== KOH Restore-Skript (v1.0) ==="
echo "=============================================="
echo -e "${NC}"

# --- 1. Projektauswahl ---
log_message "INFO" "1. Projekt für die Wiederherstellung auswählen:"
select PROJECT_DIR in $(ls -d ~/public_html/*/ | xargs -n 1 basename); do
    if [[ -n "$PROJECT_DIR" ]]; then
        log_message "SUCCESS" "Projekt '$PROJECT_DIR' ausgewählt."
        break
    else
        log_message "WARNING" "Ungültige Auswahl. Bitte erneut versuchen."
    fi
done

# --- 2. Passenden Backup-Ordner suchen ---
PROJECT_BACKUP_BASE="$BACKUP_ROOT/bak.${PROJECT_DIR}"
if [[ ! -d "$PROJECT_BACKUP_BASE" ]]; then
    log_message "ERROR" "Kein Backup-Verzeichnis für das Projekt '$PROJECT_DIR' gefunden unter: $PROJECT_BACKUP_BASE"
    exit 1
fi
log_message "INFO" "Backup-Verzeichnis gefunden: $PROJECT_BACKUP_BASE"

# --- 3. Gespeichertes Backup auswählen ---
log_message "INFO" "2. Backup für die Wiederherstellung auswählen:"
cd "$PROJECT_BACKUP_BASE"
select BACKUP_TIMESTAMP in $(ls -d */ | sort -r | xargs -n 1 basename); do
    if [[ -n "$BACKUP_TIMESTAMP" ]]; then
        SELECTED_BACKUP_DIR="$PROJECT_BACKUP_BASE/$BACKUP_TIMESTAMP"
        log_message "SUCCESS" "Backup '$BACKUP_TIMESTAMP' ausgewählt."
        break
    else
        log_message "WARNING" "Ungültige Auswahl. Bitte erneut versuchen."
    fi
done

# --- Pfade und Dateinamen definieren ---
WEB_ROOT="$HOME/public_html/$PROJECT_DIR"
CONFIG_FILE="$WEB_ROOT/includes/config.JTL-Shop.ini.php"
DB_BACKUP_FILE="$SELECTED_BACKUP_DIR/db_backup.sql"
WEB_BACKUP_FILE="$SELECTED_BACKUP_DIR/web_backup.tar.gz"
MEDIA_BACKUP_FILE="$SELECTED_BACKUP_DIR/media_backup.tar.gz"

# --- Sicherheitsabfrage ---
echo -e "\n${RED}================ ACHTUNG! ================"
echo -e "Sie sind dabei, das Projekt '${YELLOW}$PROJECT_DIR${RED}' wiederherzustellen."
echo -e "Das ausgewählte Backup ist vom: ${YELLOW}$BACKUP_TIMESTAMP${RED}."
echo -e "Dies wird die folgenden Aktionen ausführen:"
echo -e "  1. ${YELLOW}ALLE Tabellen${RED} in der Datenbank werden gelöscht."
echo -e "  2. Der Inhalt des Web-Verzeichnisses ${YELLOW}$WEB_ROOT${RED} wird gelöscht."
echo -e "  3. Die Datenbank und die Dateien aus dem Backup werden wiederhergestellt."
echo -e "Diese Aktion kann ${YELLOW}NICHT rückgängig${RED} gemacht werden."
echo -e "============================================${NC}"
read -p "Sind Sie sicher, dass Sie fortfahren möchten? (ja/nein): " confirm
if [[ "$confirm" != "ja" ]]; then
    log_message "WARNING" "Wiederherstellung vom Benutzer abgebrochen."
    exit 0
fi

# --- 4. Backup wiederherstellen ---
log_message "INFO" "Starte Wiederherstellung..."

# --- MySQL-Zugangsdaten aus Config extrahieren ---
# Wir müssen die Config aus dem *Backup* lesen, falls die Live-Version nicht mehr existiert
log_message "INFO" "Extrahiere DB-Zugangsdaten aus der Konfigurationsdatei..."
# Temporär das Web-Backup entpacken, um an die config zu kommen
tar -xzf "$WEB_BACKUP_FILE" -C "/tmp" "$PROJECT_DIR/includes/config.JTL-Shop.ini.php"
TEMP_CONFIG_FILE="/tmp/$PROJECT_DIR/includes/config.JTL-Shop.ini.php"

if [[ ! -f "$TEMP_CONFIG_FILE" ]]; then
    log_message "ERROR" "Konnte die Konfigurationsdatei nicht im Backup finden!"
    rm -rf "/tmp/$PROJECT_DIR"
    exit 1
fi

DB_HOST=$(sed -n "s/define([\"']DB_HOST[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
DB_NAME=$(sed -n "s/define([\"']DB_NAME[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
DB_USER=$(sed -n "s/define([\"']DB_USER[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
DB_PASS=$(sed -n "s/define([\"']DB_PASS[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
rm -rf "/tmp/$PROJECT_DIR" # Temporäre Config-Datei löschen

log_message "SUCCESS" "DB-Zugangsdaten erfolgreich extrahiert."

# --- Datenbank leeren ---
log_message "INFO" "Leere die Datenbank '$DB_NAME'..."
TABLES=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -N -e "SHOW TABLES" "$DB_NAME")
if [[ -n "$TABLES" ]]; then
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SET FOREIGN_KEY_CHECKS=0; $(echo "$TABLES" | awk '{print "DROP TABLE IF EXISTS \`" $1 "\`;"}'); SET FOREIGN_KEY_CHECKS=1;"
    log_message "SUCCESS" "Datenbank erfolgreich geleert."
else
    log_message "INFO" "Datenbank ist bereits leer."
fi

# --- Webspace leeren ---
log_message "INFO" "Leere das Web-Verzeichnis: $WEB_ROOT..."
# Lösche alles im Verzeichnis, aber nicht das Verzeichnis selbst
find "$WEB_ROOT" -mindepth 1 -delete
log_message "SUCCESS" "Web-Verzeichnis erfolgreich geleert."

# --- Datenbank wiederherstellen ---
log_message "INFO" "Stelle die Datenbank aus '$DB_BACKUP_FILE' wieder her..."
if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$DB_BACKUP_FILE"; then
    log_message "ERROR" "Fehler bei der Wiederherstellung der Datenbank!"
    exit 5
fi
log_message "SUCCESS" "Datenbank erfolgreich wiederhergestellt."

# --- Dateien wiederherstellen ---
if [[ -f "$WEB_BACKUP_FILE" ]]; then
    log_message "INFO" "Stelle Web-Dateien aus '$WEB_BACKUP_FILE' wieder her..."
    # Entpacke direkt in das public_html Verzeichnis, da das Backup den PROJECT_DIR enthält
    if ! tar -xzf "$WEB_BACKUP_FILE" -C "$HOME/public_html"; then
        log_message "ERROR" "Fehler bei der Wiederherstellung der Web-Dateien!"
        exit 6
    fi
    log_message "SUCCESS" "Web-Dateien erfolgreich wiederhergestellt."
fi

if [[ -f "$MEDIA_BACKUP_FILE" ]]; then
    log_message "INFO" "Stelle Media-Dateien aus '$MEDIA_BACKUP_FILE' wieder her..."
    # Entpacke direkt in das Projektverzeichnis
    if ! tar -xzf "$MEDIA_BACKUP_FILE" -C "$WEB_ROOT"; then
        log_message "ERROR" "Fehler bei der Wiederherstellung der Media-Dateien!"
        exit 7
    fi
    log_message "SUCCESS" "Media-Dateien erfolgreich wiederhergestellt."
fi

# --- Abschluss ---
echo -e "\n${GREEN}=============================================="
echo "=== WIEDERHERSTELLUNG ERFOLGREICH ABGESCHLOSSEN ==="
echo "=============================================="
echo -e "${NC}"
log_message "SUCCESS" "Das Projekt '$PROJECT_DIR' wurde erfolgreich aus dem Backup vom '$BACKUP_TIMESTAMP' wiederhergestellt."
log_message "INFO" "Vergessen Sie nicht, die Dateiberechtigungen zu überprüfen und den Cache zu leeren, falls erforderlich."
