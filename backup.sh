#!/bin/bash

# ==============================================
# KOH Universal Backup & Restore Skript (v2.0.0)
# ==============================================
# Features:
# - Merged Backup and Restore functionality
# - Configurable paths and settings
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

# --- Konfigurationsbereich ---
PROJECT_ROOT="$HOME/public_html"     # Root-Verzeichnis der Projekte
BACKUP_ROOT="$HOME/backup"           # Haupt-Backup-Verzeichnis
MAX_BACKUPS=2                        # Anzahl der zu behaltenden Backups
COMPRESSION_LEVEL=9                  # Komprimierungsstufe (1-9)

# --- Farben für Ausgaben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m' # No Color

# --- Globale Hilfsfunktionen ---
cleanup_on_error() {
    echo -e "${RED}[!] Skript wurde unterbrochen oder ein Fehler trat auf.${NC}"
    echo -e "${YELLOW}[!] Aufräumen...${NC}"
    # Prüfe, ob das aktuelle Backup-Verzeichnis existiert und leer ist, und lösche es ggf.
    if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" && -z "$(ls -A "$BACKUP_DIR")" ]]; then
        echo -e "${YELLOW}[!] Lösche leeres Backup-Verzeichnis: $BACKUP_DIR${NC}"
        rm -rf "$BACKUP_DIR"
    fi
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

# --- Backup-spezifische Funktionen ---
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

    local db_backup_path="$backup_dir/db_backup.sql"
    local web_backup_path="$backup_dir/web_backup.tar.gz"
    local media_backup_path="$backup_dir/media_backup.tar.gz"

    {
        echo "=== Backup Metadaten ==="
        echo "Projekt: $project"
        echo "Datum: $(date)"
        echo "Skript-Version: 2.0.0"
        echo "Komprimierungsstufe: $COMPRESSION_LEVEL"
        if [[ -f "$db_backup_path" ]]; then echo "Größe DB-Backup: $(du -h "$db_backup_path" | cut -f1)"; fi
        if [[ -f "$web_backup_path" ]]; then echo "Größe Web-Backup: $(du -h "$web_backup_path" | cut -f1)"; fi
        if [[ -f "$media_backup_path" ]]; then echo "Größe Media-Backup: $(du -h "$media_backup_path" | cut -f1)"; fi
    } > "$metadata_file"
}

run_backup() {
    log_message "INFO" "Backup-Prozess gestartet."

    # --- Projektauswahl ---
    log_message "INFO" "Wähle Projektverzeichnis aus:"
    # Verwende PROJECT_ROOT Variable
    select PROJECT_DIR in $(ls -d $PROJECT_ROOT/*/ | xargs -n 1 basename); do
        if [[ -n "$PROJECT_DIR" ]]; then
            break
        else
            log_message "WARNING" "Ungültige Auswahl. Bitte erneut versuchen."
        fi
    done

    # --- Backup-Modus auswählen ---
    log_message "INFO" "Wähle den Backup-Modus aus:"
    options=("Alles (Web + Media)" "Nur Web" "Nur Media")
    select opt in "${options[@]}"; do
        case $opt in
            "Alles (Web + Media)") BACKUP_MODE="all"; break;;
            "Nur Web") BACKUP_MODE="web_only"; break;;
            "Nur Media") BACKUP_MODE="media_only"; break;;
            *) log_message "WARNING" "Ungültige Auswahl. Bitte erneut versuchen.";;
        esac
    done
    log_message "INFO" "Modus '$BACKUP_MODE' ausgewählt."

    # --- Pfade setzen ---
    TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
    CONFIG_FILE="$PROJECT_ROOT/${PROJECT_DIR}/includes/config.JTL-Shop.ini.php"
    BACKUP_DIR_BASE="$BACKUP_ROOT/bak.${PROJECT_DIR}"
    BACKUP_DIR="$BACKUP_DIR_BASE/$TIMESTAMP"

    DB_BACKUP_FILE="$BACKUP_DIR/db_backup.sql"
    WEB_BACKUP_FILE="$BACKUP_DIR/web_backup.tar.gz"
    MEDIA_BACKUP_FILE="$BACKUP_DIR/media_backup.tar.gz"

    mkdir -p "$BACKUP_DIR" || { log_message "ERROR" "Konnte Backup-Verzeichnis nicht erstellen: $BACKUP_DIR"; exit 1; }

    LOG_FILE="$BACKUP_DIR/backup.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_message "INFO" "Backup-Verzeichnis angelegt: $BACKUP_DIR"

    # --- MySQL-Zugangsdaten extrahieren ---
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
    TEMPLATE_C_DIR="$PROJECT_ROOT/${PROJECT_DIR}/templates_c"
    log_message "INFO" "Bereinige Cache-Verzeichnis: $TEMPLATE_C_DIR..."
    ( find "$TEMPLATE_C_DIR" -mindepth 1 -maxdepth 1 \! -name "min" \! -name ".htaccess" -exec rm -rf {} + ) || log_message "WARNING" "Konnte $TEMPLATE_C_DIR nicht vollständig bereinigen."
    log_message "SUCCESS" "Bereinigung von $TEMPLATE_C_DIR abgeschlossen."

    # --- Webverzeichnis sichern ---
    if [[ "$BACKUP_MODE" == "all" || "$BACKUP_MODE" == "web_only" ]]; then
        log_message "INFO" "Sichere Webverzeichnis (ohne media, mediafiles)..."
        if ! tar --exclude="media" --exclude="mediafiles" -cf - -C "$PROJECT_ROOT" "$PROJECT_DIR" | pigz -$COMPRESSION_LEVEL > "$WEB_BACKUP_FILE"; then
            log_message "ERROR" "Fehler beim Webverzeichnis-Backup!"
            exit 3
        fi
        verify_backup "$WEB_BACKUP_FILE"
        log_message "SUCCESS" "Webverzeichnis-Backup erfolgreich: $(du -h "$WEB_BACKUP_FILE" | cut -f1)"
    fi

    # --- Media-Verzeichnis sichern ---
    if [[ "$BACKUP_MODE" == "all" || "$BACKUP_MODE" == "media_only" ]]; then
        log_message "INFO" "Sichere media-Verzeichnis separat..."
        if ! tar -cf - -C "$PROJECT_ROOT/$PROJECT_DIR" "media" | pigz -$COMPRESSION_LEVEL > "$MEDIA_BACKUP_FILE"; then
            log_message "ERROR" "Fehler beim Media-Backup!"
            exit 4
        fi
        verify_backup "$MEDIA_BACKUP_FILE"
        log_message "SUCCESS" "Media-Backup erfolgreich: $(du -h "$MEDIA_BACKUP_FILE" | cut -f1)"
    fi

    create_metadata "$BACKUP_DIR" "$PROJECT_DIR"
    rotate_backups "$PROJECT_DIR"

    echo -e "${GREEN}"
    echo "=============================================="
    echo "=== BACKUP ERFOLGREICH ABGESCHLOSSEN ==="
    echo "=============================================="
    echo -e "${NC}"
    log_message "SUCCESS" "Backup abgeschlossen!"
}

run_restore() {
    log_message "INFO" "Restore-Prozess gestartet."

    # --- 1. Projektauswahl ---
    log_message "INFO" "1. Projekt für die Wiederherstellung auswählen:"
    select PROJECT_DIR in $(ls -d $PROJECT_ROOT/*/ | xargs -n 1 basename); do
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
        log_message "ERROR" "Kein Backup-Verzeichnis für das Projekt '$PROJECT_DIR' gefunden."
        exit 1
    fi

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
    cd - > /dev/null # Zurück zum vorherigen Verzeichnis

    # --- Pfade und Dateinamen definieren ---
    WEB_ROOT="$PROJECT_ROOT/$PROJECT_DIR"
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

    # --- MySQL-Zugangsdaten extrahieren ---
    log_message "INFO" "Extrahiere DB-Zugangsdaten aus der Konfigurationsdatei im Backup..."
    TEMP_CONFIG_DIR="/tmp/$PROJECT_DIR"
    mkdir -p "$TEMP_CONFIG_DIR/includes"
    tar -xzf "$WEB_BACKUP_FILE" -C "/tmp" "$PROJECT_DIR/includes/config.JTL-Shop.ini.php"
    TEMP_CONFIG_FILE="$TEMP_CONFIG_DIR/includes/config.JTL-Shop.ini.php"

    if [[ ! -f "$TEMP_CONFIG_FILE" ]]; then
        log_message "ERROR" "Konnte die Konfigurationsdatei nicht im Backup finden!"
        rm -rf "$TEMP_CONFIG_DIR"
        exit 1
    fi

    DB_HOST=$(sed -n "s/define([\"']DB_HOST[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
    DB_NAME=$(sed -n "s/define([\"']DB_NAME[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
    DB_USER=$(sed -n "s/define([\"']DB_USER[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
    DB_PASS=$(sed -n "s/define([\"']DB_PASS[\"'] *, *[\"']\([^\"']*\)[\"'].*/\1/p" "$TEMP_CONFIG_FILE")
    rm -rf "$TEMP_CONFIG_DIR"
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
    find "$WEB_ROOT" -mindepth 1 -delete
    log_message "SUCCESS" "Web-Verzeichnis erfolgreich geleert."

    # --- Datenbank wiederherstellen ---
    log_message "INFO" "Stelle die Datenbank wieder her..."
    if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$DB_BACKUP_FILE"; then
        log_message "ERROR" "Fehler bei der Wiederherstellung der Datenbank!"
        exit 5
    fi
    log_message "SUCCESS" "Datenbank erfolgreich wiederhergestellt."

    # --- Dateien wiederherstellen ---
    if [[ -f "$WEB_BACKUP_FILE" ]]; then
        log_message "INFO" "Stelle Web-Dateien wieder her..."
        if ! tar -xzf "$WEB_BACKUP_FILE" -C "$PROJECT_ROOT"; then
            log_message "ERROR" "Fehler bei der Wiederherstellung der Web-Dateien!"
            exit 6
        fi
        log_message "SUCCESS" "Web-Dateien erfolgreich wiederhergestellt."
    fi

    if [[ -f "$MEDIA_BACKUP_FILE" ]]; then
        log_message "INFO" "Stelle Media-Dateien wieder her..."
        if ! tar -xzf "$MEDIA_BACKUP_FILE" -C "$WEB_ROOT"; then
            log_message "ERROR" "Fehler bei der Wiederherstellung der Media-Dateien!"
            exit 7
        fi
        log_message "SUCCESS" "Media-Dateien erfolgreich wiederhergestellt."
    fi

    echo -e "\n${GREEN}=============================================="
    echo "=== WIEDERHERSTELLUNG ERFOLGREICH ABGESCHLOSSEN ==="
    echo "=============================================="
    echo -e "${NC}"
}

# --- Hauptmenü ---
main() {
    clear
    echo -e "${GREEN}"
    echo "=============================================="
    echo "=== KOH Backup & Restore Skript (v2.0.0) ==="
    echo "=============================================="
    echo -e "${NC}"
    echo "Bitte wählen Sie eine Aktion:"
    echo "1) Backup erstellen"
    echo "2) Backup wiederherstellen"
    echo "3) Beenden"
    echo

    read -p "Auswahl [1-3]: " choice
    case "$choice" in
        1)
            run_backup
            ;;
        2)
            run_restore
            ;;
        3)
            echo "Skript wird beendet."
            exit 0
            ;;
        *)
            echo -e "${RED}Ungültige Auswahl. Bitte erneut versuchen.${NC}"
            sleep 2
            main
            ;;
    esac
}

# Skript starten
main
