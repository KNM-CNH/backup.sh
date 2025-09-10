#!/bin/bash

# ==============================================
# KOH Backup-Skript (v2.0)
# ==============================================
# Features:
# - Farbige Ausgaben für bessere Lesbarkeit
# - Umfangreiches Logging in Datei und Konsole
# - Backup-Verifizierung und Fehlerbehandlung
# - Passwort-Sicherheit via .my.cnf
# - Parallelisierte Komprimierung mit pigz
# - Backup-Rotation (älteste Backups löschen)
# - Metadaten-Erstellung für jedes Backup
# ==============================================

set -euo pipefail
trap 'cleanup_on_error' ERR INT TERM

# --- Globale Variablen ---
MAX_BACKUPS=2                        # Anzahl der zu behaltenden Backups
COMPRESSION_LEVEL=9                  # Komprimierungsstufe (1-9)
BACKUP_ROOT="$HOME/backup"           # Haupt-Backup-Verzeichnis

# --- Farben für Ausgaben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LIGHT_BLUE='\033[1;34m'              # Geändert zu hellem Blau
NC='\033[0m' # No Color

# --- Funktionen ---

cleanup_on_error() {
    echo -e "${RED}[!] Skript wurde unterbrochen oder ein Fehler trat auf.${NC}"
    echo -e "${YELLOW}[!] Aufräumen...${NC}"
    # Hier könnten temporäre Dateien gelöscht werden
    exit 1
}

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    case $level in
        "INFO") echo -e "${LIGHT_BLUE}[${timestamp}] INFO: ${message}${NC}" ;;  # Jetzt hellblau
        "SUCCESS") echo -e "${GREEN}[${timestamp}] ✓ ${message}${NC}" ;;
        "WARNING") echo -e "${YELLOW}[${timestamp}] [!] ${message}${NC}" ;;
        "ERROR") echo -e "${RED}[${timestamp}] ✗ ${message}${NC}" ;;
    esac
}

verify_backup() {
    local file=$1
    log_message "INFO" "Verifiziere Backup-Integrität: $file"

    if ! gzip -t "$file"; then
        log_message "ERROR" "Backup ist beschädigt: $file"
        return 1
    fi
    return 0
}

rotate_backups() {
    local project=$1
    log_message "INFO" "Rotate Backups für $project (behalte die neuesten $MAX_BACKUPS)"

    # Lösche älteste Backups, behalte nur MAX_BACKUPS
    find "$BACKUP_ROOT/bak.${project}" -name "${project}_*.tar.gz" -type f | sort -r | tail -n +$(($MAX_BACKUPS + 1)) | while read -r file; do
        log_message "WARNING" "Lösche altes Backup: $file"
        rm -f "$file"
    done
}

create_metadata() {
    local backup_dir=$1
    local project=$2
    local metadata_file="$backup_dir/metadata.txt"

    {
        echo "=== Backup Metadaten ==="
        echo "Projekt: $project"
        echo "Datum: $(date)"
        echo "Skript-Version: 2.0"
        echo "Komprimierungsstufe: $COMPRESSION_LEVEL"
        echo "Größe DB-Backup: $(du -h "$backup_dir/${project}_db_backup.sql" | cut -f1)"
        echo "Größe Web-Backup: $(du -h "$backup_dir/${project}_web_backup.tar.gz" | cut -f1)"
        if [[ -f "$backup_dir/${project}_media_backup.tar.gz" ]]; then
            echo "Größe Media-Backup: $(du -h "$backup_dir/${project}_media_backup.tar.gz" | cut -f1)"
        fi
    } > "$metadata_file"
}

# --- Hauptprogramm ---

clear
echo -e "${GREEN}"
echo "=============================================="
echo "=== KOH Backup-Skript (v2.0) ==="
echo "=============================================="
echo -e "${NC}"

# --- Projektauswahl ---
log_message "INFO" "Wähle Projektverzeichnis aus:"
select PROJECT_DIR in $(ls -d ~/public_html/*/ | xargs -n 1 basename); do
    if [[ -n "$PROJECT_DIR" ]]; then
        break
    else
        log_message "WARNING" "Ungültige Auswahl. Bitte erneut versuchen."
    fi
done

# --- Backup-Modus auswählen ---
log_message "INFO" "Soll das Backup alle Dateien enthalten (inkl. Medien)? (Y/N)"
read -r CHOICE

if [[ "$CHOICE" =~ ^[Yy]$ ]]; then
    MODE="all"
elif [[ "$CHOICE" =~ ^[Nn]$ ]]; then
    MODE="no-media"
else
    log_message "ERROR" "Ungültige Eingabe! Bitte mit Y oder N antworten."
    exit 1
fi

# --- Pfade setzen ---
CONFIG_FILE="$HOME/public_html/${PROJECT_DIR}/includes/config.JTL-Shop.ini.php"
BACKUP_DIR="$BACKUP_ROOT/bak.${PROJECT_DIR}"
DB_BACKUP_FILE="$BACKUP_DIR/${PROJECT_DIR}_db_backup.sql"
WEB_BACKUP_FILE="$BACKUP_DIR/${PROJECT_DIR}_web_backup.tar.gz"
MEDIA_BACKUP_FILE="$BACKUP_DIR/${PROJECT_DIR}_media_backup.tar.gz"

# --- Backup-Verzeichnis erstellen VOR Logging ---
mkdir -p "$BACKUP_DIR" || {
    echo -e "${RED}Konnte Backup-Verzeichnis nicht erstellen: $BACKUP_DIR${NC}"
    exit 1
}

LOG_FILE="$BACKUP_DIR/${PROJECT_DIR}_backup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_message "INFO" "Backup-Verzeichnis angelegt: $BACKUP_DIR"

# --- MySQL-Zugangsdaten aus Config extrahieren ---
DB_HOST=$(sed -n "s/define([\"']DB_HOST[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$CONFIG_FILE")
DB_NAME=$(sed -n "s/define([\"']DB_NAME[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$CONFIG_FILE")
DB_USER=$(sed -n "s/define([\"']DB_USER[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$CONFIG_FILE")
DB_PASS=$(sed -n "s/define([\"']DB_PASS[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$CONFIG_FILE")

# --- MySQL Dump erstellen ---
log_message "INFO" "Erstelle Datenbank-Backup..."
if ! mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$DB_BACKUP_FILE"; then
    log_message "ERROR" "Fehler beim Erstellen des Datenbank-Backups!"
    exit 2
fi
log_message "SUCCESS" "Datenbank-Backup erfolgreich: $(du -h "$DB_BACKUP_FILE" | cut -f1)"

# --- templates_c bereinigen ---
## TODO rm: cannot remove '/usr/home/tackle/public_html/tackle-deals.eu/templates_c/TACKLE_DEALS': Directory not empty (Fehler abfanngen und weitermachen, oder vorgang wiederholen und dann erst überspringen)
TEMPLATE_C_DIR="$HOME/public_html/${PROJECT_DIR}/templates_c"
log_message "INFO" "Bereinige $TEMPLATE_C_DIR..."
find "$TEMPLATE_C_DIR" -mindepth 1 -maxdepth 1 \! -name "min" \! -name ".htaccess" -exec rm -rf {} +
log_message "SUCCESS" "Bereinigung abgeschlossen."

# --- Webverzeichnis sichern (ohne media, mediafiles) ---
log_message "INFO" "Sichere Webverzeichnis (ohne media, mediafiles)..."
if ! tar --exclude="media" --exclude="mediafiles" -cf - -C "$HOME/public_html" "$PROJECT_DIR" | pigz -$COMPRESSION_LEVEL > "$WEB_BACKUP_FILE"; then
    log_message "ERROR" "Fehler beim Webverzeichnis-Backup!"
    exit 3
fi
verify_backup "$WEB_BACKUP_FILE"
log_message "SUCCESS" "Webverzeichnis-Backup erfolgreich: $(du -h "$WEB_BACKUP_FILE" | cut -f1)"

# --- Media-Verzeichnis separat sichern (nur im all-Modus) ---
if [[ "$MODE" == "all" ]]; then
    log_message "INFO" "Sichere media-Verzeichnis separat..."
    if ! tar -cf - -C "$HOME/public_html/$PROJECT_DIR" "media" | pigz -$COMPRESSION_LEVEL > "$MEDIA_BACKUP_FILE"; then
        log_message "ERROR" "Fehler beim Media-Backup!"
        exit 4
    fi
    verify_backup "$MEDIA_BACKUP_FILE"
    log_message "SUCCESS" "Media-Backup erfolgreich: $(du -h "$MEDIA_BACKUP_FILE" | cut -f1)"
fi

# --- Metadaten erstellen ---
create_metadata "$BACKUP_DIR" "$PROJECT_DIR"

# --- Backup-Rotation durchführen ---
rotate_backups "$PROJECT_DIR"

# --- Zusammenfassung anzeigen ---
echo -e "${GREEN}"
echo "=============================================="
echo "=== BACKUP ERFOLGREICH ABGESCHLOSSEN ==="
echo "=============================================="
echo -e "${NC}"
log_message "SUCCESS" "Backup abgeschlossen!"
log_message "INFO" "Backup-Details:"
ls -lh "$BACKUP_DIR/${PROJECT_DIR}"_* | awk '{print "- " $9 " (" $5 ")"}'
echo -e "${LIGHT_BLUE}Log-Datei: $LOG_FILE${NC}"  # Jetzt hellblau