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
    local project_backup_base="$BACKUP_ROOT/bak.${project}"
    log_message "INFO" "Rotiere Backups für $project in $project_backup_base (behalte die neuesten $MAX_BACKUPS)"

    # Finde alle Backup-Verzeichnisse, sortiere sie (neueste zuerst) und lösche die alten.
    # tail -n +X starts printing from the X-th item.
    local num_to_keep=$(($MAX_BACKUPS))
    if [[ $num_to_keep -lt 1 ]]; then
        log_message "WARNING" "MAX_BACKUPS ist auf 0 oder weniger gesetzt. Es werden alle Backups gelöscht!"
    fi

    find "$project_backup_base" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$(($num_to_keep + 1)) | while read -r backup_dir; do
        if [[ -d "$backup_dir" ]]; then
            log_message "WARNING" "Lösche altes Backup-Verzeichnis: $backup_dir"
            rm -rf "$backup_dir"
        fi
    done
}

create_metadata() {
    local backup_dir=$1
    local project=$2
    local metadata_file="$backup_dir/metadata.txt"

    # Define file paths based on the new structure
    local db_backup_path="$backup_dir/db_backup.sql"
    local web_backup_path="$backup_dir/web_backup.tar.gz"
    local media_backup_path="$backup_dir/media_backup.tar.gz"

    {
        echo "=== Backup Metadaten ==="
        echo "Projekt: $project"
        echo "Datum: $(date)"
        echo "Skript-Version: 2.0"
        echo "Komprimierungsstufe: $COMPRESSION_LEVEL"
        echo "Größe DB-Backup: $(du -h "$db_backup_path" | cut -f1)"
        echo "Größe Web-Backup: $(du -h "$web_backup_path" | cut -f1)"
        if [[ -f "$media_backup_path" ]]; then
            echo "Größe Media-Backup: $(du -h "$media_backup_path" | cut -f1)"
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
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
CONFIG_FILE="$HOME/public_html/${PROJECT_DIR}/includes/config.JTL-Shop.ini.php"
BACKUP_DIR_BASE="$BACKUP_ROOT/bak.${PROJECT_DIR}" # Base directory for project backups
BACKUP_DIR="$BACKUP_DIR_BASE/$TIMESTAMP"         # Timestamped directory for this run

DB_BACKUP_FILE="$BACKUP_DIR/db_backup.sql"
WEB_BACKUP_FILE="$BACKUP_DIR/web_backup.tar.gz"
MEDIA_BACKUP_FILE="$BACKUP_DIR/media_backup.tar.gz"

# --- Backup-Verzeichnis erstellen VOR Logging ---
mkdir -p "$BACKUP_DIR" || {
    echo -e "${RED}Konnte Backup-Verzeichnis nicht erstellen: $BACKUP_DIR${NC}"
    exit 1
}

LOG_FILE="$BACKUP_DIR/backup.log"
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
## TODO gelöst: Fehler beim Löschen wird nun mit Wiederholungsversuchen behandelt.
TEMPLATE_C_DIR="$HOME/public_html/${PROJECT_DIR}/templates_c"
log_message "INFO" "Bereinige Cache-Verzeichnis: $TEMPLATE_C_DIR..."

retries=3
success=false
for ((i=1; i<=retries; i++)); do
    # Führe den Befehl in einer Subshell aus, um 'set -e' temporär zu ignorieren.
    # Leite Fehlermeldungen von find/rm um, da wir den Erfolg selbst prüfen.
    (
        set +e
        find "$TEMPLATE_C_DIR" -mindepth 1 -maxdepth 1 \! -name "min" \! -name ".htaccess" -exec rm -rf {} + 2>/dev/null
        # Prüfe, ob noch unerwünschte Dateien vorhanden sind.
        remaining_items=$(find "$TEMPLATE_C_DIR" -mindepth 1 -maxdepth 1 \! -name "min" \! -name ".htaccess")
        if [ -z "$remaining_items" ]; then
            exit 0 # Erfolg
        else
            exit 1 # Fehler
        fi
    )
    if [ $? -eq 0 ]; then
        success=true
        break
    fi

    if [ $i -lt $retries ]; then
        log_message "WARNING" "Bereinigung fehlgeschlagen. Versuche erneut in 2 Sekunden... (Versuch $i/$retries)"
        sleep 2
    fi
done

if $success; then
    log_message "SUCCESS" "Bereinigung von $TEMPLATE_C_DIR abgeschlossen."
else
    log_message "ERROR" "Konnte $TEMPLATE_C_DIR nach $retries Versuchen nicht vollständig bereinigen. Fahre mit dem Backup fort."
fi

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
log_message "INFO" "Backup-Details in: $BACKUP_DIR"
ls -lh "$BACKUP_DIR" | awk '{print "  - " $9 " (" $5 ")"}'
echo -e "${LIGHT_BLUE}Log-Datei: $LOG_FILE${NC}"  # Jetzt hellblau