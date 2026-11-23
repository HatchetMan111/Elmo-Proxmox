#!/usr/bin/env bash
# =============================================================================
#  🔍 Elmo – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/Elmo-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  Elmo (https://github.com/elmohq/elmo): die Open-Source-Plattform für
#  AI-Visibility-Tracking (AEO/GEO) – wie oft nennen ChatGPT, Gemini,
#  Google AI Overviews & Co. deine Marke, wie zitieren sie dich, welches
#  Sentiment und welche Wettbewerber tauchen auf. Nach dem Vorbild der
#  Proxmox VE Community Scripts.
#
#  Architektur im Container: Docker CE + die 4 offiziellen elmo-Images
#  (elmohq/elmo-web, elmo-worker, elmo-db-migrate + postgres:18-alpine) in
#  einer Compose-Datei nach dem exakten Template der offiziellen CLI
#  (@elmohq/cli), ergänzt um Restart-Policies und Härtung: Postgres bleibt
#  komplett im Container-Netz (KEIN 5432-Exposure), nur die Web-UI ist über
#  0.0.0.0:<PORT> im LAN erreichbar. KEIN Build im CT, Telemetrie
#  standardmäßig AUS.
#
#  Wichtig: Elmo fragt echte AI-Engines ab – dafür braucht es eigene
#  Provider-Keys (z. B. OpenRouter + einen Scraper). Der Stack läuft auch
#  OHNE Keys hoch, die Keys lassen sich jederzeit in /opt/elmo/.env
#  nachrüsten (+ --update). Details im README und in der Summary am Ende.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget --no-cache --no-cookies --header="Cache-Control: no-cache" -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)"
#  (Das --no-cache --no-cookies beugt einem STALE wget-Cache vor – Live-Grube
#   2026-11-23: ein alter Installer lief und die Fixes fehlten. INSTALLER_VERSION
#   am Anfang der Ausgabe zeigt, welchen Stand man wirklich erwischt hat.)
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 4096 --port 1515 --openrouter-key sk-or-...
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.7"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="elmo"
UPSTREAM_OWNER="elmohq"
UPSTREAM_REPO="elmo"
ELMO_VERSION="0.7.12"       # Image-Pin = offizielles CLI-Release (@elmohq/cli 0.7.12);
                            # --version überschreibt; --update zieht den hier gepinnten Stand
IMAGE_PREFIX="elmohq/elmo"  # offizielle Images: elmo-web / elmo-worker / elmo-db-migrate
POSTGRES_IMAGE="postgres:18-alpine"   # exakt wie im CLI-Template
                            # (elmo-web lauscht fest auf Container-Port 3000)
APP_DIR="/opt/elmo"         # Projektverzeichnis im Container
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="elmo"
CT_STORAGE="local-lvm"
CT_ROOTFS=12                # GB – Docker-Images (~2 GB) + Postgres (Roh-Antworten wachsen)
CT_CORES=2                  # Postgres + 2 Node-Services, kein Realtime-Bedarf
CT_MEMORY=6144              # MB – Postgres + web + worker (Node) + Docker-Daemon +
                            # Pull/Entpacken-Spitzen. 4096 war live ZU KNAPP:
                            # docker compose pull wurde vom OOM-Killer gekillt
                            # (Exit 137 = SIGKILL, Live 2026-11-23 CT 204).
CT_SWAP=2048                # MB Puffer für Pull/Entpacken-Spitzen
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
UI_PORT=1515                # Web-UI-Host-Port (Default der offiziellen elmo-CLI)
SCRAPE_TARGETS_DEFAULT="stub:stub:online"
                            # Default = der KEYLESS-"stub"-Provider ("no network",
                            # antwortet mit dem Prompt selbst) – der Worker bootet
                            # damit OHNE API-Keys garantiert (Live-Gruben: "provider
                            # openrouter requires API key(s)" → Crash-Loop).
                            # Format ist model:provider[:version][:online] – Segment 2
                            # ist der PROVIDER! "stub:main" war ein Bug (main landete
                            # als Provider → "Unknown provider: main", Live 2026-11-23).
                            # Modell 'stub' + Provider 'stub' + :online = gültig.
                            # Echte Targets: --scrape-targets + --openrouter-key o. Keys
SCRAPE_TARGETS=""           # leer = Default oben (Flag --scrape-targets überschreibt)
OPENROUTER_API_KEY=""       # optional per Flag; Nachrüstung jederzeit in .env
ONBOARDING_KEY=""           # --onboarding-key: Alias für --openrouter-key + Auto-Target
TELEMETRY=false             # DISABLE_TELEMETRY=1 (Elmo sammelt sonst anonyme Telemetrie)
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
ONBOARDING=false           # --onboarding-key gesetzt (Schnellweg für Setup)
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
# WICHTIG: `wget -qLO -` ohne Cache-Header kann einen STALE-Cache Treffer landen
# (Live-Grube 2026-11-23: alter Installer lief → v1.0.4-Fixes fehlten). Deshalb
# `--no-cache --no-cookies` + `Cache-Control: no-cache`-Header – GitHub Raw
# liefert zwar korrekt aus, aber der wget-Cache auf dem Host kann trotzdem stale
# sein. Der Installer druckt am Anfang INSTALLER_VERSION – so sieht man sofort,
# welchen Stand man erwischt hat.
ONE_LINER='bash -c "$(wget --no-cache --no-cookies --header="Cache-Control: no-cache" -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Docker-Compose), falls schon
# ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Docker):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/elmo-setup.log 2>/dev/null
            echo "--- docker compose ps -a ---"
            docker compose --project-directory /opt/elmo ps -a 2>/dev/null || true
            echo "--- docker compose logs (letzte 25 Zeilen) ---"
            docker compose --project-directory /opt/elmo logs --tail 25 2>/dev/null || true
            echo "--- journalctl -u elmo -u docker ---"
            journalctl -u elmo --no-pager 2>/dev/null | tail -n 10 || true
            journalctl -u docker --no-pager 2>/dev/null | tail -n 10 || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – Docker-Images + get.docker.com brauchen Namensauflösung.
    # Live-Fall (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner getent-Erfolg
    # reichte, Stunden später war wieder alles tot. Deshalb: 3 Erfolge in Folge
    # verlangen; eine einzige Störung in diesem Fenster → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts get.docker.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts get.docker.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    # pct status liefert "status: <wert>" – Prefix abschneiden für saubere Meldungen
    state="${state#status: }"
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

host_arch() {
    # Host-Architektur auf die Template-Suffixe mappen (Live-Grube: auf einem
    # x86-Host darf NIE ein arm64-Template gewählt werden, auch wenn es die
    # neuere Versionsnummer trägt – ProxSmartHome 2026-11-22).
    #  -m liefert x86_64/aarch64/... (nicht die Debian-Suffixe amd64/arm64!)
    case "$(uname -m 2>/dev/null || echo "unbekannt")" in
        x86_64)         echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              echo "" ;;
    esac
}

verify_ct_started() {
    # Exit-0-Täuschung (Live-Grube DatacenterManager/ProxSmartHome): `pct create
    # --start 1` kann Exit 0 liefern, obwohl der Start intern scheitert
    # ("Failed to spawn container" – u. a. bei Architektur-Mismatch des
    # Templates). Deshalb: Status prüfen, bei Defekt einmal pct start mit
    # sichtbarer Ausgabe versuchen und sonst mit KOMPLITTER Fehlerkette die().
    local id="$1" state out=""
    state=$(pct status "$id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" == "running" ]]; then
        ok "Container $id läuft (Status: running)"
        return 0
    fi
    warn "Container $id läuft NICHT (Status: ${state:-unbekannt}) – 'pct create --start 1' hat es nicht gestartet."
    info "Start-Versuch mit vollständiger Fehlerausgabe:"
    out=$(pct start "$id" 2>&1 || true)
    while IFS= read -r line; do
        echo "    $line"
    done <<< "$out"
    if pct status "$id" 2>/dev/null | grep -q 'status: running'; then
        warn "Container $id läuft nach manuellem pct start – fahre fort."
        return 0
    fi
    die "Container $id startet nicht.\n  pct start sagte: ${out:-<keine Ausgabe>}\n  Häufigste Ursache: Template-Architektur ≠ Host-Architektur ($(uname -m) → $(host_arch || echo unbekannt)) – dies ist ein Installer-Bug, bitte melden.\n  Manuell prüfen: pct start $id && pct status $id && journalctl -u pveproxy -n 50"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)              CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)        CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)         CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)          CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)           CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)          CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)            CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)          CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)              CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)         CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)        CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)          CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)            UI_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --version)         ELMO_VERSION="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --scrape-targets)  SCRAPE_TARGETS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --openrouter-key)  OPENROUTER_API_KEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --onboarding-key)  ONBOARDING_KEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --telemetry)       TELEMETRY=true; i=$((i+1)) ;;
            --force)           FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)          ASSUME_YES=true; i=$((i+1)) ;;
            --update)          UPDATE=true; i=$((i+1)) ;;
            --uninstall)       UNINSTALL=true; i=$((i+1)) ;;
            --status)          STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)           set -x; i=$((i+1)) ;;
            --help|-h)         print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (--help zeigt alle Optionen)" ;;
        esac
    done
    # Port hart validieren – er landet direkt in der Compose-Config im Container.
    if ! [[ "$UI_PORT" =~ ^[0-9]+$ ]] || [[ "$UI_PORT" -lt 1 || "$UI_PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$UI_PORT' (1–65535 erwartet, z. B. --port 1515)"
    fi
    if ! [[ "$ELMO_VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
        die "Ungültige Versions-Pin-Angabe: '$ELMO_VERSION' (erwartet z. B. 0.7.12)"
    fi
    if [[ -n "$SCRAPE_TARGETS" && "$SCRAPE_TARGETS" != *:* ]]; then
        die "Ungültiges SCRAPE_TARGETS-Format: '$SCRAPE_TARGETS'\n  Format: modell:provider[:version][:online], z. B. chatgpt:openrouter:openai/gpt-5-mini:online"
    fi
    # --onboarding-key ist der userfreundliche Schnellweg: setzt den OpenRouter-
    # Key und – wenn kein explizites --scrape-targets kam – automatisch ein
    # passendes Echt-Target (chatgpt via OpenRouter). "--onboarding-key" und
    # "--openrouter-key" schließen sich gegenseitig aus (gleicher Key).
    if [[ -n "$ONBOARDING_KEY" ]]; then
        if [[ -n "$OPENROUTER_API_KEY" && "$OPENROUTER_API_KEY" != "$ONBOARDING_KEY" ]]; then
            die "--onboarding-key und --openrouter-key sind beide gesetzt, aber unterschiedlich – bitte nur einen verwenden."
        fi
        OPENROUTER_API_KEY="$ONBOARDING_KEY"
        if [[ -z "$SCRAPE_TARGETS" ]]; then
            SCRAPE_TARGETS="chatgpt:openrouter:openai/gpt-5-mini:online"
        fi
        ONBOARDING=true
    fi
}

print_help() {
    cat <<'EOF'
🔍 Elmo – Proxmox-Installer (AI-Visibility-Tracking / AEO, elmohq/elmo)

Installation:   bash -c "$(wget --no-cache --no-cookies --header="Cache-Control: no-cache" -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID            Container-ID (Default: nächste freie ab 200)
  --hostname NAME    Container-Hostname (Default: elmo)
  --storage NAME     Storage für rootfs (Default: local-lvm)
  --rootfs GB        Disk-Größe (Default: 12 – Docker-Images + Postgres-Daten)
  --cores N          vCPUs (Default: 2)
  --memory MB        RAM (Default: 6144 – Postgres + web + worker + Pull-Spitzzen;
                     4096 war live zu knapp → OOM-Kill beim docker pull, Exit 137)
  --swap MB          Swap (Default: 2048)
  --bridge BR        Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR          Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
                     Empfehlenswert: feste IP (oder DHCP-Reservierung), damit die
                     APP_URL dauerhaft stimmt (wird sonst beim Boot synchronisiert).
  --gateway GW       Gateway für statische IP
  --password PW      Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD      Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT        Web-UI-Port (Default: 1515 – der Default der offiziellen elmo-CLI)
  --version V        elmo-Image-Pin überschreiben (Default: 0.7.12)
  --scrape-targets S SCRAPE_TARGETS setzen (Format: modell:provider[:version][:online],
                     z. B. "chatgpt:openrouter:openai/gpt-5-mini:online,perplexity:perplexity-api")
                     Default: stub:main (keyless – Worker bootet ohne Keys)
  --openrouter-key K OpenRouter-API-Key direkt in die .env schreiben (optional)
  --onboarding-key K Alias für --openrouter-key + schaltet SCRAPE_TARGETS
                     automatisch auf ein passendes Echt-Target um (kein Setup-
                     Rätsel) – der schnellste Weg zu einem Setup ohne Meldungen
  --telemetry        Anonyme Telemetrie an elmo erlauben (Default: AUS)
  --force            Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y         Rückfragen überspringen
  --update           Elmo im bestehenden Container aktualisieren (.env bleibt erhalten)
  --uninstall        Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status           Status anzeigen
  --debug            Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (Ports, Version, DNS, Keys, Telemetrie) kommen als Umgebungs-
# variablen via `pct exec -- env …` in den Container. Das vermeidet die
# Escaping-Grube bei Compose-/Shell-Sonderzeichen komplett.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Elmo In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: APP_DIR, ELMO_VERSION, IMAGE_PREFIX, POSTGRES_IMAGE,
#                    UI_PORT, HOST_DNS, TELEMETRY, SCRAPE_TARGETS_IN,
#                    OPENROUTER_KEY_IN, APPLY_SCRAPE, APPLY_OPENROUTER
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
ok(){ echo "✔ $1"; }
warn(){ echo "⚠ $1"; }
die(){ err "$1"; exit 1; }

: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${ELMO_VERSION:?ELMO_VERSION fehlt (env)}"
: "${IMAGE_PREFIX:?IMAGE_PREFIX fehlt (env)}"
: "${POSTGRES_IMAGE:?POSTGRES_IMAGE fehlt (env)}"
: "${UI_PORT:?UI_PORT fehlt (env)}"

echo ">>> curl sicherstellen (nacktes Debian-Template hat KEIN curl) ..."
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null
fi

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
# (chattr +i funktioniert in unprivilegierten LXCs nicht – fehlendes Capability,
#  Live-Fund 2026-11-10: CT-DNS war nach Stunden wieder kaputt.)
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# Elmo: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Docker installieren / prüfen ..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL --retry 3 "https://get.docker.com" -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1 || sh /tmp/get-docker.sh
else
    echo "    Docker bereits vorhanden: $(docker --version 2>/dev/null || echo 'unbekannt')"
fi
if ! docker compose version >/dev/null 2>&1; then
    die "docker compose (v2-Plugin) fehlt – get.docker.com hätte es installieren müssen.\n  Debug: docker --version; ls /usr/libexec/docker/cli-plugins/"
fi
# Docker-Daemon muss laufen (Debian startet ihn bei apt-Install meist schon)
systemctl enable docker >/dev/null 2>&1 || true
if ! docker info >/dev/null 2>&1; then
    systemctl start docker
    for _ in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then break; fi
        sleep 1
    done
    docker info >/dev/null 2>&1 || die "Docker-Daemon startet nicht.\n  Debug: journalctl -u docker -e"
fi

echo ">>> Compose-Datei schreiben (Template der offiziellen @elmohq/cli, gehärtet) ..."
#  - Version-Pin via ELMO_VERSION (kein :latest – Updates laufen gezielt über
#    den Installer (--update), nicht unbemerkt beim Boot)
#  - Postgres OHNE ports-Block: bleibt im internen Compose-Netz (die CLI-
#    Vorlage exponiert 5432 auf den Host – im LXC unnötige Angriffsfläche)
#  - restart: unless-stopped auf postgres/web/worker → Überleben nach Reboot/
#    Crash (docker-seitig; zusätzlich überwacht systemd den ganzen Stack)
#  - db-migrate ist ein One-Shot (kein restart) – web/worker starten erst,
#    wenn die Migration erfolgreich durch ist (service_completed_successfully)
mkdir -p "$APP_DIR"
cat > "$APP_DIR/docker-compose.yaml" <<COMPEOF
name: elmo

services:
  postgres:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: elmo
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
      start_period: 30s
  db-migrate:
    image: ${IMAGE_PREFIX}-db-migrate:${ELMO_VERSION}
    restart: "no"
    environment:
      - DATABASE_URL=postgres://postgres:postgres@postgres:5432/elmo
    depends_on:
      postgres:
        condition: service_healthy
  web:
    image: ${IMAGE_PREFIX}-web:${ELMO_VERSION}
    restart: unless-stopped
    env_file:
      - path: .env
        required: true
    ports:
      - "${UI_PORT}:3000"
    depends_on:
      db-migrate:
        condition: service_completed_successfully
  worker:
    image: ${IMAGE_PREFIX}-worker:${ELMO_VERSION}
    restart: unless-stopped
    env_file:
      - path: .env
        required: true
    stop_grace_period: 35s
    depends_on:
      db-migrate:
        condition: service_completed_successfully

volumes:
  postgres_data:
COMPEOF
cd "$APP_DIR"

# ── .env: Secrets idempotent erzeugen (bestehende bleiben erhalten) ─────────
generate_secret() {
    # openssl bevorzugt, Fallback /dev/urandom
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; return 0; fi
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}
generate_secret_b64() {
    # ELMO_ENCRYPTION_KEY im selben Format wie die CLI (32 Bytes, base64)
    if command -v openssl >/dev/null 2>&1; then openssl rand -base64 32; return 0; fi
    od -An -N32 -tx1 /dev/urandom | base64
}
generate_uuid() {
    # DEPLOYMENT_ID im UUID-Format (wie die CLI: crypto.randomUUID())
    if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; return 0; fi
    openssl rand -hex 16 2>/dev/null || od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}
dotenv_get() {
    # Wert eines Keys aus .env lesen (leer, wenn nicht vorhanden)
    local key=$1 line
    [[ -f .env ]] || { return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < .env
    return 0
}
dotenv_set() {
    # Key setzen/ersetzen; fehlende .env wird erzeugt
    local key=$1 value=$2 tmp=".env.tmp.$$" line updated=false
    if [[ -f .env ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "$key"=*) printf '%s=%s\n' "$key" "$value"; updated=true ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < .env > "$tmp"
        if [[ "$updated" != "true" ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
        fi
    else
        printf '%s=%s\n' "$key" "$value" > "$tmp"
    fi
    mv -f "$tmp" .env
}

echo ">>> .env erzeugen/prüfen (Secrets bleiben bei Update erhalten) ..."
# Nicht-geheime Basiswerte – wie die offizielle `elmo init` sie schreibt:
[[ -n "$(dotenv_get DEPLOYMENT_MODE)" ]] || dotenv_set DEPLOYMENT_MODE "local"
if [[ -z "$(dotenv_get DEPLOYMENT_ID)" ]]; then
    dotenv_set DEPLOYMENT_ID "$(generate_uuid)"
    echo "    DEPLOYMENT_ID erzeugt"
fi
if [[ -z "$(dotenv_get BETTER_AUTH_SECRET)" ]]; then
    dotenv_set BETTER_AUTH_SECRET "$(generate_secret)"
    echo "    BETTER_AUTH_SECRET erzeugt"
fi
if [[ -z "$(dotenv_get ELMO_ENCRYPTION_KEY)" ]]; then
    dotenv_set ELMO_ENCRYPTION_KEY "$(generate_secret_b64)"
    echo "    ELMO_ENCRYPTION_KEY erzeugt"
fi
[[ -n "$(dotenv_get APP_NAME)" ]]        || dotenv_set APP_NAME "Elmo"
[[ -n "$(dotenv_get APP_ICON)" ]]        || dotenv_set APP_ICON "/icons/elmo-icon.svg"
[[ -n "$(dotenv_get VITE_APP_NAME)" ]]   || dotenv_set VITE_APP_NAME "Elmo"
[[ -n "$(dotenv_get VITE_APP_ICON)" ]]   || dotenv_set VITE_APP_ICON "/icons/elmo-icon.svg"
[[ -n "$(dotenv_get DATABASE_URL)" ]]    || dotenv_set DATABASE_URL "postgres://postgres:postgres@postgres:5432/elmo"
# WICHTIG – die Zwei-URL-Aufteilung (Live-Grube "Invalid origin" 2026-11-22):
#  • APP_URL = die ECHTE Origin (http://<CT-IP>:<PORT>) – Better Auth prüft
#    dagegen die Browser-Origin beim Login/Registrieren. Mit Loopback hier
#    scheitert jeder Login vom LAN ("Invalid origin")!
#  • BETTER_AUTH_URL = Loopback (http://127.0.0.1:<PORT>) – die MCP-Auth liest
#    die baseURL (APP_URL || BETTER_AUTH_URL) und akzeptiert für die MCP-
#    Resource-ID NUR https/localhost/127.x → ohne diesen Pin Boot-500.
#  Beide zusammen: web bootet (MCP ok) UND Login/Registrierung vom LAN ok.
#  sync-app-url.sh hält beide synchron (nur http, kein https → Domain-Modus
#  mit echter https-APP_URL lässt alles unverändert).
[[ -n "$(dotenv_get APP_URL)" ]]         || dotenv_set APP_URL "http://127.0.0.1:${UI_PORT}"
[[ -n "$(dotenv_get BETTER_AUTH_URL)" ]] || dotenv_set BETTER_AUTH_URL "http://127.0.0.1:${UI_PORT}"
[[ -n "$(dotenv_get VITE_APP_URL)" ]]    || dotenv_set VITE_APP_URL "http://127.0.0.1:${UI_PORT}"
# Telemetrie: AUS ist Default (--telemetry erlaubt sie). Leerer Wert = erlaubt,
# "1" = aus (die CLI prüft Boolean(process.env.DISABLE_TELEMETRY) – "0" wäre
# wahrheitsähnlich und würde fälschlich deaktivieren, deshalb Leere statt 0).
if [[ "${TELEMETRY:-false}" == "true" ]]; then
    dotenv_set DISABLE_TELEMETRY ""
else
    dotenv_set DISABLE_TELEMETRY "1"
fi
# SCRAPE_TARGETS: der Worker validiert die Syntax BOOTEND (ohne gültige Syntax
# crash-looped er) – deshalb immer ein gültiger Wert, Flag überschreibt.
if [[ "${APPLY_SCRAPE:-0}" == "1" ]]; then
    dotenv_set SCRAPE_TARGETS "${SCRAPE_TARGETS_IN}"
    echo "    SCRAPE_TARGETS gesetzt (per --scrape-targets)"
else
    [[ -n "$(dotenv_get SCRAPE_TARGETS)" ]] || dotenv_set SCRAPE_TARGETS "${SCRAPE_TARGETS_IN}"
fi
# Provider-Keys: nur per Flag setzen (Nachrüstung in .env bleibt unangetastet)
if [[ "${APPLY_OPENROUTER:-0}" == "1" ]]; then
    dotenv_set OPENROUTER_API_KEY "${OPENROUTER_KEY_IN}"
    echo "    OPENROUTER_API_KEY gesetzt (per --openrouter-key)"
fi
chmod 600 .env

echo ">>> Compose-Konfiguration validieren ..."
docker compose config -q || die "docker compose config meldet Fehler (Compose-Datei/.env prüfen).\n  Debug: cd $APP_DIR && docker compose config"

echo ">>> APP-URL-Sync-Script schreiben (APP_URL = echte IP, BETTER_AUTH_URL = Loopback) ..."
# Live-Gruben 2026-11-22 (zwei gegenläufige Zwänge):
#  1. MCP-Auth (packages/lib/src/auth/server.ts:mcpResource) verlangt für die
#     MCP-Resource-ID zwingend https:// ODER localhost/127.x – NODE_ENV=production
#     ist im Image fix, "localhost" greift also nicht als localOrigin. Die
#     baseURL (APP_URL || BETTER_AUTH_URL) muss deshalb loopback-akzeptiert sein,
#     sonst Boot-500.
#  2. Better Auth prüft beim Login/Registrieren die Browser-Origin gegen
#     APP_URL (trustedOrigins) – ist APP_URL ein Loopback, scheitert JEDER Login
#     vom LAN mit "Invalid origin".
# Lösung: APP_URL = echte Origin (http://<CT-IP>:<PORT>), BETTER_AUTH_URL =
# Loopback (http://127.0.0.1:<PORT>). Die Zwei-URL-Aufteilung erfüllt beide:
# web bootet (MCP sieht Loopback) UND Login/Registrierung vom LAN klappen
# (Better Auth vertraut der echten Origin). Email/Login-Redirects sind relativ
# (safeReturnTo) – kein Problem. Wer MCP braucht, setzt eine https://-APP_URL
# (Domain-Modus: dann greift weder IP- noch Loopback-Sync).
cat > "${APP_DIR}/sync-app-url.sh" <<SYNCEOF
#!/usr/bin/env bash
# Hält APP_URL (echte CT-IP-Origin, für Better-Auth trustedOrigins) und
# BETTER_AUTH_URL (Loopback, für die MCP-Resource-ID) synchron.
# Domain-Modus: beginnt APP_URL mit https://, greift NICHTS (Sync macht nichts).
set -euo pipefail
SELF_DIR=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)
cd "\$SELF_DIR"
set_key() { # KEY VALUE – ersetzen oder anhängen (idempotent)
    if /bin/grep -q "^\$1=" .env; then
        /bin/sed -i "s|^\$1=.*|\$1=\$2|" .env
    else
        printf '%s=%s\n' "\$1" "\$2" >> .env
    fi
}
CURRENT=\$(sed -n 's/^APP_URL=//p' .env 2>/dev/null | head -1 || true)
case "\$CURRENT" in
    https://*) echo "elmo-sync: Domain-Modus (APP_URL=\$CURRENT) – kein Sync"; exit 0 ;;
esac
IP=\$(ip -4 addr show eth0 scope global 2>/dev/null | awk '/inet /{print \$2; exit}' | cut -d/ -f1 || true)
[[ -n "\$IP" ]] || { echo "elmo-sync: keine globale IPv4 an eth0 – .env bleibt unverändert"; exit 0; }
WANT_APP="http://\${IP}:${UI_PORT}"
WANT_AUTH="http://127.0.0.1:${UI_PORT}"
if [[ "\$CURRENT" != "\$WANT_APP" ]]; then
    echo "elmo-sync: APP_URL=\${CURRENT:-unbekannt} → \$WANT_APP (echte IP-Origin)"
else
    echo "elmo-sync: APP_URL unverändert (\$WANT_APP)"
fi
set_key APP_URL "\$WANT_APP"
set_key VITE_APP_URL "\$WANT_APP"
set_key BETTER_AUTH_URL "\$WANT_AUTH"
SYNCEOF
chmod +x "${APP_DIR}/sync-app-url.sh"

echo ">>> systemd-Unit 'elmo' schreiben (Restart=always) ..."
cat > /etc/systemd/system/elmo.service <<'UNITEOF'
[Unit]
Description=Elmo AI-Visibility-Plattform (docker compose)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
# Attached `docker compose up`: systemd überwacht den Compose-Prozess,
# Restart=always startet den Stack bei Crash/Abbruch neu. Die Container
# tragen zusätzlich restart: unless-stopped (in der Compose-Datei).
Type=simple
WorkingDirectory=/opt/elmo
ExecStartPre=/opt/elmo/sync-app-url.sh
ExecStart=/usr/bin/docker compose --project-directory /opt/elmo up --pull=missing
ExecStop=/usr/bin/docker compose --project-directory /opt/elmo stop
Restart=always
RestartSec=15
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable elmo >/dev/null 2>&1 || true

echo ">>> IP-abhängige .env-Einträge synchronisieren ..."
"${APP_DIR}/sync-app-url.sh"

echo ">>> Docker-Images ziehen (elmo-web, elmo-worker, elmo-db-migrate, postgres) ..."
# Mit Retry: ein abgebrochener Pull (OOM/Netz) soll den ganzen Install nicht
# killen. Das Docker-Daemon-Flag --max-concurrent-downloads=2 hält die
# Entpack-Spitzen niedriger (weniger RAM pro Pull) – es muss VOR dem
# Subcommand stehen, ist aber nur ein daemon-Startparameter; wir nutzen hier
# den einfachen `docker compose pull` mit Retry (der Daemon läuft bereits).
systemctl stop elmo >/dev/null 2>&1 || true
pull_ok=0
for attempt in 1 2 3; do
    if docker compose pull; then
        pull_ok=1
        break
    fi
    echo "    Pull-Versuch ${attempt}/3 fehlgeschlagen – warte 10 s und retry ..."
    sleep 10
done
if [[ "$pull_ok" -ne 1 ]]; then
    die "docker compose pull nach 3 Versuchen fehlgeschlagen.\n  Debug: cd $APP_DIR && docker compose pull\n  (Exit 137 = OOM/externer Kill: CT-RAM erhöhen, z. B. --memory 8192)"
fi
ok "Images gepullt"

echo ">>> Elmo-Stack starten (docker compose up -d) ..."
docker compose up -d

echo ">>> systemd-Service starten (übernimmt den laufenden Stack) ..."
systemctl start elmo

echo ">>> Warte auf Web-UI (http://127.0.0.1:${UI_PORT}/) ..."
WEB_OK=""
code="000"
for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${UI_PORT}/" || true)
    # 2xx/3xx: die Landingpage darf auf Login/Onboarding umleiten
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        WEB_OK=1
        break
    fi
    sleep 5
done
if [[ -z "$WEB_OK" ]]; then
    die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose ps -a && docker compose logs --tail 50 web\n  (db-migrate muss erfolgreich durch sein, bevor 'web' startet)"
fi
ok "Web-UI antwortet (HTTP ${code})"

echo ">>> Prüfe Worker-Status (verarbeitet die Abfrage-Jobs) ..."
ps_out=$(docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
if /bin/grep -q '^worker running$' <<<"$ps_out" 2>/dev/null; then
    ok "Worker läuft (SCRAPE_TARGETS ist gültig und key-fähig)"
else
    warn "Worker läuft nicht (Status prüfen) – Web-UI funktioniert trotzdem."
    warn "Häufigste Ursache: SCRAPE_TARGETS nennt einen Provider ohne Key"
    warn "(z. B. openrouter ohne OPENROUTER_API_KEY – der bootet dann nicht)."
    warn "Logs: docker compose logs --tail 50 worker"
fi

echo ">>> Aufräumen ..."
rm -f /tmp/get-docker.sh

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere Elmo im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (Grube 14).
    # APPLY_SCRAPE/APPLY_OPENROUTER: bei Installation immer anwenden; SCRAPE-
    # TARGETS-Default wird bei Update NICHT über bestehende .env-Werte gestampft
    # (Nutzer-Konfiguration bleibt erhalten) – nur explizite Flags überschreiben.
    # --onboarding-key setzt automatisch mit (Schnellweg für ein Setup ohne
    # "Missing environment configuration"-Meldung).
    local scrape_in="$SCRAPE_TARGETS"
    [[ -n "$scrape_in" ]] || scrape_in="$SCRAPE_TARGETS_DEFAULT"
    local apply_scrape=1
    if $UPDATE && [[ -z "$SCRAPE_TARGETS" ]]; then
        apply_scrape=0
    fi
    local apply_openrouter=0
    if [[ -n "$OPENROUTER_API_KEY" ]]; then
        apply_openrouter=1
    fi
    pct exec "$ct_id" -- env APP_DIR="$APP_DIR" ELMO_VERSION="$ELMO_VERSION" \
        IMAGE_PREFIX="$IMAGE_PREFIX" POSTGRES_IMAGE="$POSTGRES_IMAGE" \
        UI_PORT="$UI_PORT" HOST_DNS="${HOST_DNS:-1.1.1.1}" \
        TELEMETRY="$TELEMETRY" SCRAPE_TARGETS_IN="$scrape_in" \
        OPENROUTER_KEY_IN="$OPENROUTER_API_KEY" APPLY_SCRAPE="$apply_scrape" \
        APPLY_OPENROUTER="$apply_openrouter" ONBOARDING="$ONBOARDING" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/elmo-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # systemd-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet elmo 2>/dev/null; then
            ok "Service elmo läuft (systemctl is-active)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service elmo läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u elmo -e && pct exec $ct_id -- systemctl status elmo"
        fi
        sleep 1
    done

    # Compose-Services oben? (db-migrate ist ein One-Shot – dessen Erfolg ist
    # implizit verifiziert, weil web NUR nach erfolgreicher Migration startet.)
    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker compose --project-directory "$APP_DIR" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
    local missing=""
    for svc in postgres web worker; do
        if ! grep -q "^${svc} " <<<"$ps_out"; then
            missing+="${svc} "
        fi
    done
    if [[ -n "$missing" ]]; then
        die "Compose-Services fehlen oder sind nicht hochgekommen: ${missing}\n  Debug: pct exec $ct_id -- docker compose --project-directory $APP_DIR ps -a\n  Logs:  pct exec $ct_id -- docker compose --project-directory $APP_DIR logs --tail 50"
    fi
    ok "Compose-Services laufen (postgres, web, worker)"

    # Web-UI antwortet? (Grube: curl -w gibt bei Verbindungsfehler bereits
    # 000 aus – NIE zusätzlich || echo 000 anhängen, sonst falsch-positiv.)
    tries=0
    code="000"
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${UI_PORT}/" || true)
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Web-UI antwortet (HTTP ${code} auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- docker compose --project-directory $APP_DIR logs --tail 50 web"
        fi
        sleep 2
    done

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${UI_PORT}/" || true)
        if [[ "$host_code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${UI_PORT} (HTTP ${host_code})"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${UI_PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🔍  Elmo ist bereit!"

    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:    http://${ct_ip}:${UI_PORT}${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:  pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:   ${CT_PASSWORD}${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer: v${INSTALLER_VERSION} (upstream ${UPSTREAM_OWNER}/${UPSTREAM_REPO}, Images ${IMAGE_PREFIX}:*)${NC}"
    echo -e "  ${GREEN}  📦 Image-Pin: ${ELMO_VERSION}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Erste Schritte:${NC}"
    echo "  1. http://${ct_ip}:${UI_PORT} öffnen und im Onboarding die erste"
    echo "     Marke (+ Wettbewerber) anlegen"
    echo ""
    echo -e "  ${CYAN}Setup vervollständigen (empfohlen, damit Onboarding & Report$NC"
    echo -e "  ${CYAN}funktionieren und keine 'Missing environment configuration'-$NC"
    echo -e "  ${CYAN}Meldung erscheint):${NC}"
    echo "     LLM-Key (Onboarding + Opportunities – EINER reicht):"
    echo "       ${ONE_LINER} --update --onboarding-key sk-or-v1-...     # OpenRouter"
    echo "     Scraper (echte ChatGPT-/Gemini-/Google-AI-Antworten – ohne Keys"
    echo "     läuft der Worker im Stub-Modus, 'no network'):"
    echo "       Key in ${APP_DIR}/.env ergänzen (z. B. CLORO_API_KEY=...), dann:"
    echo "       ${ONE_LINER} --update"
    echo "     Volle Kontrolle (Key + Targets getrennt):"
    echo "       ${ONE_LINER} --update --openrouter-key sk-or-... --scrape-targets \"chatgpt:openrouter:openai/gpt-5-mini:online\""
    echo "     (WICHTIG: jeder Provider in SCRAPE_TARGETS braucht seinen Key,"
    echo "      sonst bootet der Worker nicht – siehe README.)"
    echo ""
    echo -e "  ${CYAN}MCP-Server (für Claude & Co.):${NC}"
    echo "  Die Web-UI läuft; der MCP-Endpunkt http://${ct_ip}:${UI_PORT}/api/mcp"
    echo "  braucht eine https://-APP_URL (oder localhost) – setze dafür in"
    echo "  ${APP_DIR}/.env APP_URL=https://deine-domain.example (Reverse-Proxy),"
    echo "  der Loopback-Pin greift dann nicht mehr."
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Stack-Logs: pct exec ${CT_ID} -- docker compose --project-directory ${APP_DIR} logs -f"
    echo ""
    warn "Daten (Postgres mit allen getrackten Antworten) liegen im Docker-Volume"
    warn "postgres_data im CT – ein --update erhält sie, pct destroy löscht sie."
    warn "Für Backups: pct backup / vzdump."
    if [[ "$CT_IP" == "dhcp" ]]; then
        warn "CT hat DHCP – die APP_URL ist auf 127.0.0.1 gepinnt (unabhängig"
        warn "von der CT-IP); trotzdem empfohlen: DHCP-Reservierung im Router."
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🔍 Installiere Elmo (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Selbstdiagnose: STALE-CACHE erkennen (Live-Grube 2026-11-23). Ein alter
    # Installer (< v1.0.4) hat die Zwei-URL-Logik nicht – das Resultat ist ein
    # Boot-500 von web mit "access token is bound to http://<IP>:1515/api/mcp"
    # (statt 127.0.0.1). Statt das eigene Skript zu prüfen (bei `bash -c` zeigt
    # $0/BASH_SOURCE auf nichts Sinnvolles), ziehen wir die AKTUELLE Rohdatei
    # mit Cache-Headern und schauen, ob SIE die Zwei-URL-Logik enthält. Fehlt
    # sie dort, ist der GitHub-Stand alt (oder der wget-Cache stale) – in beiden
    # Fällen wäre ein --update mit dem alten Einzeiler wirkungslos.
    local _remote
    _remote=$(wget --no-cache --no-cookies --header="Cache-Control: no-cache" -qO- --timeout=15 \
        "https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh" 2>/dev/null || true)
    if [[ -n "$_remote" ]] && ! grep -q 'BETTER_AUTH_URL' <<<"$_remote"; then
        warn "STALE-CACHE VERDACHT: der aktuelle GitHub-Stand enthält die Zwei-URL-Logik"
        warn "(BETTER_AUTH_URL) NICHT – vermutlich wurde die Rohdatei noch nicht"
        warn "gepusht oder der wget-Cache ist stale. Ein --update würde den Fehler"
        warn "nicht beheben. Bitte den korrekten --no-cache-Einzeiler nutzen:"
        echo "    ${ONE_LINER}"
    fi
    unset _remote

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen (13 bevorzugt – Docker unterstützt trixie;
    # rV-Sortierung nimmt 13 vor 12, Fallback bleibt).
    # WICHTIG: Arch-Filter! Auf einem Host können Templates FREMder Architektur
    # im Cache liegen (Live-Grube ProxSmartHome 2026-11-22: arm64-Template mit
    # NEUERER Versionsnummer als das passende amd64 → Spawn-Fehler). Deshalb
    # wird zuerst auf die Host-Architektur gefiltert, dann versionssortiert.
    header "🧱 Container-Template"
    local arch template="" t_arch
    arch=$(host_arch)
    if [[ -z "$arch" ]]; then
        die "Host-Architektur $(uname -m) wird nicht unterstützt (amd64/arm64 erwartet)."
    fi
    info "Host-Architektur: $(uname -m) → Template-Suffix '${arch}'"

    template=$(pveam list local 2>/dev/null | awk '{print $1}' \
        | grep -o "debian-1[23]-standard[^ ]*_${arch}\\.tar[^ ]*" | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein passendes Debian-12/13-Template (${arch}) vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null \
            | grep -o "debian-1[23]-standard[^ ]*_${arch}\\.tar[^ ]*" | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12/13-standard-Template für ${arch} gefunden (pveam available leer?)."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # Gegenprobe: geladenes Template muss zur Host-Architektur passen – falls
    # pveam (unerwartet) ein Fremd-Arch-Template liefert, hier hart abbrechen
    # statt später mit kryptischem Spawn-Fehler.
    # (Nicht mit tr -d '_.tar' arbeiten – das löscht die Zeichen einzeln!)
    t_arch="${template%.tar*}"      # debian-13-standard_13.6-1_amd64
    t_arch="${t_arch##*_}"          # amd64
    if [[ "$t_arch" != "$arch" ]]; then
        die "Template '${template}' passt nicht zur Host-Architektur ($(uname -m) → ${arch}).\n  Bitte ein ${arch}-Template bereitstellen: pveam available --section system | grep ${arch}"
    fi

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="elmo-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    net0+=",firewall=0"
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    # pct create kann trotz intern fehlgeschlagenem Start Exit 0 liefern –
    # deshalb der explizite Status-Check mit Fehlerausgabe (Grube 10/Exit-0).
    verify_ct_started "$CT_ID"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update Elmo (Images ${ELMO_VERSION} ziehen, .env bleibt erhalten)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – Daten (Postgres-Volume) blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere Elmo"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "ALLE Daten gehen verloren: Accounts, Marken, getrackte Antworten (Postgres)."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status Elmo"
    info "Installer-Version: v${INSTALLER_VERSION} | Image-Pin: ${ELMO_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $NF}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Stack/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet elmo 2>/dev/null; then
        ok "Service:   elmo läuft (systemctl is-active)"
    else
        err "Service:   elmo läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u elmo -e"
    fi

    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker compose --project-directory "$APP_DIR" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
    if [[ -n "$ps_out" ]]; then
        info "Stack:     $(echo "$ps_out" | tr '\n' ' ' | sed 's/ $//')"
    else
        warn "Stack:     docker compose ps lieferte nichts (Stack noch nie gestartet?)"
    fi

    # Konfiguration (ohne Secrets auszugeben – nur KEY-Status, nie Werte)
    local app_url scrape
    app_url=$(pct exec "$ct_id" -- sed -n 's/^APP_URL=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    scrape=$(pct exec "$ct_id" -- sed -n 's/^SCRAPE_TARGETS=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    if [[ -n "$app_url" ]]; then
        info "APP_URL:   $app_url"
    fi
    if [[ -n "$scrape" ]]; then
        info "Scrape:    $scrape"
    fi

    # ── Provider-Key-Status (LLM fürs Onboarding + Scraper fürs Tracking) ──
    # Onboarding/Opportunities brauchen EINEN LLM-Key (OpenRouter | OpenAI |
    # Anthropic | Mistral). Scraper-Keys (Cloro/BrightData/...) liefern die
    # echten Engine-Antworten. Werte werden NIE ausgegeben, nur gesetzt/nicht.
    local -a llm_keys=(OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY MISTRAL_API_KEY)
    local -a scraper_keys=(CLORO_API_KEY BRIGHTDATA_API_TOKEN SEARCHAPI_API_KEY OLOSTEP_API_KEY OXYLABS_USERNAME DATAFORSEO_LOGIN)
    local -a llm_set=() llm_missing=() scraper_set=() llm_any=false
    local k v
    for k in "${llm_keys[@]}"; do
        v=$(pct exec "$ct_id" -- sed -n "s/^${k}=//p" "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
        if [[ -n "$v" ]]; then llm_set+=("$k"); llm_any=true; else llm_missing+=("$k"); fi
    done
    for k in "${scraper_keys[@]}"; do
        v=$(pct exec "$ct_id" -- sed -n "s/^${k}=//p" "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
        [[ -n "$v" ]] && scraper_set+=("$k")
    done
    if $llm_any; then
        ok "LLM-Key:   gesetzt (${llm_set[*]}) – Onboarding/Opportunities können laufen"
    else
        warn "LLM-Key:   NICHT gesetzt – die UI zeigt 'Missing environment configuration'!"
        warn "           Onboarding/Opportunities brauchen EINEN Key:"
        warn "             ${ONE_LINER} --update --onboarding-key sk-or-v1-..."
        warn "           (oder OPENAI_API_KEY/ANTHROPIC_API_KEY/MISTRAL_API_KEY in ${APP_DIR}/.env)"
    fi
    if [[ ${#scraper_set[@]} -gt 0 ]]; then
        ok "Scraper:   gesetzt (${scraper_set[*]}) – echte Engine-Antworten möglich"
    else
        warn "Scraper:   KEINER gesetzt – Worker läuft im Stub-Modus (keine echten"
        warn "           ChatGPT-/Gemini-/Google-AI-Antworten). Keys: CLORO_API_KEY,"
        warn "           BRIGHTDATA_API_TOKEN, SEARCHAPI_API_KEY, OLOSTEP_API_KEY, ..."
    fi

    local ip code=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${UI_PORT}/" || true)
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Web-UI:    http://${ip}:${UI_PORT}  (HTTP ${code})"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${UI_PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
