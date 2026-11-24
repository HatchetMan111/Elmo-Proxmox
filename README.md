# 🔍 Elmo – Proxmox-Installer

Ein-Klick-Installer für [Elmo](https://github.com/elmohq/elmo) (MIT) auf Proxmox VE –
im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

**Elmo** ist eine Self-Hosted **AI-Visibility-Plattform** (AEO/GEO/LLMO): Sie trackt,
wie AI-Engines (ChatGPT, Gemini, Google AI Overviews, Perplexity, …) deine Marke
erwähnen und zitieren – inkl. Sentiment, Positions-Analyse, Citation-Tracking,
Wettbewerber-Benchmark und priorisierten Optimierungs-Empfehlungen. Mit eingebautem
**MCP-Server** (`/api/mcp`) für Claude & Co.

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget --no-cache --no-cookies --header="Cache-Control: no-cache" -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)"
```

Das Script:

> ⚠️ **`--no-cache --no-cookies`** im Einzeiler ist Absicht — ein schlichter
> `wget -qLO -` kann einen STALE-Cache-Treffer landen (Live-Grube 2026-11-23:
> ein alter Installer lief und neuere Fixes fehlten). Die `INSTALLER_VERSION`
> am Anfang der Ausgabe zeigt immer, welchen Stand man wirklich erwischt hat.

- erstellt einen **unprivilegierten LXC** (Default: 2 vCPU, 6 GB RAM, 12 GB Disk,
  Debian 13 bevorzugt, `nesting=1 keyctl=1`, `onboot=1`, Hostname `elmo`, nächste
  freie CT-ID ab 200)
- installiert Docker CE und startet die **4 offiziellen elmo-Images** (kein Build im CT):
  `elmohq/elmo-web:<pin>`, `elmo-worker:<pin>`, `elmo-db-migrate:<pin>` + `postgres:18-alpine`
- generiert `.env` mit Secrets (`BETTER_AUTH_SECRET`, `ELMO_ENCRYPTION_KEY`,
  `DEPLOYMENT_ID`) nach dem exakten Schema der offiziellen `@elmohq/cli`
- **Telemetrie ist standardmäßig AUS** (`DISABLE_TELEMETRY=1`)
- härtet den Stack: Postgres bleibt komplett im internen Compose-Netz (die
  CLI-Vorlage exponiert 5432 – hier nicht), nur die Web-UI ist im LAN erreichbar
- richtet **systemd** ein (`elmo.service`, `Restart=always`) → reboot-sicher
- verifiziert: Service aktiv, Compose-Services oben, Web-UI antwortet, vom Host erreichbar

Am Ende bekommst du die URL: `http://<LXC-IP>:1515` (1515 = Default der offiziellen CLI).

### Optionen (hinter dem schließenden Anführungszeichen anhängen)

```bash
... " --id 210 --memory 6144 --port 1515
... " --ip 192.168.1.50/24 --gateway 192.168.1.1     # statische IP
... " --scrape-targets "chatgpt:openrouter:openai/gpt-5-mini:online,google-ai-mode:openrouter:openai/gpt-5-mini:online"
... " --onboarding-key sk-or-v1-...                   # LLM-Key + Auto-Target (Schnellweg, empfohlen)
... " --openrouter-key sk-or-v1-...                   # nur den OpenRouter-Key setzen
... " --version 0.7.12                                # Image-Pin überschreiben
... " --force                                         # bestehenden CT neu aufsetzen
```

**Schnellster Weg zu einem Setup ohne „Missing environment configuration“-Meldung:**
`--onboarding-key <OpenRouter-Key>` — setzt den LLM-Key (Onboarding + Opportunities)
und schaltet `SCRAPE_TARGETS` automatisch auf ein passendes Echt-Target
(`chatgpt:openrouter:openai/gpt-5-mini:online`) um. Volle Kontrolle über beides
getrennt: `--openrouter-key` + `--scrape-targets`.

## ⚠️ Provider-Keys (wichtig)

Elmo fragt **echte AI-Engines** ab – dafür braucht es eigene Accounts/Keys (BYOA):

| Zweck | Key in `/opt/elmo/.env` | Anbieter |
|---|---|---|
| Judge-Modell („Jev“: Mentions/Sentiment), Onboarding, Opportunities | `OPENROUTER_API_KEY` | [OpenRouter](https://openrouter.ai) – ein Key, viele Modelle |
| Echte ChatGPT-/Gemini-/Google-AI-Antworten liefern | `CLORO_API_KEY`, `BRIGHTDATA_API_TOKEN`, `SEARCHAPI_API_KEY`, `OLOSTEP_API_KEY` oder `OXYLABS_USERNAME`/`OXYLABS_PASSWORD` | Cloro, Bright Data, SearchApi, Olostep, Oxylabs |
| Alternative: direkte Modell-APIs | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `MISTRAL_API_KEY`, `PERPLEXITY_API_KEY` | je nach `SCRAPE_TARGETS` |

Der Stack läuft auch **ohne Keys** hoch – die Web-UI ist erreichbar, aber es laufen
keine Abfragen, bis Keys gesetzt sind (die UI zeigt dann „Missing environment
configuration“). Nachrüsten — am einfachsten mit dem Setup-Schnellweg:

```bash
# LLM-Key + Auto-Target in einem Rutsch (empfohlen):
bash -c "$(wget --no-cache --no-cookies --header="Cache-Control: no-cache" -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)" --update --onboarding-key sk-or-v1-...

# oder Key + Targets getrennt steuern:
... " --update --openrouter-key sk-or-v1-...
... " --update --scrape-targets "chatgpt:openrouter:openai/gpt-5-mini:online"

# danach Stack neu durchziehen (erkennt Änderungen automatisch):
... " --update
```

`--status` zeigt jederzeit, welche Keys gesetzt sind (nur Namen, **nie** Werte) –
inkl. „LLM-Key“ (Onboarding/Opportunities) und „Scraper“ (echte Engine-Antworten).
Außerdem repliziert `--status` den **Env-Check der Web-UI** (elmo 0.7.12
`getEnvValidationState`, Modus `local`): statische Pflicht-Keys
(`DATABASE_URL`, `BETTER_AUTH_SECRET`, `SCRAPE_TARGETS`, `ELMO_ENCRYPTION_KEY`,
`DEPLOYMENT_MODE`), die aus `SCRAPE_TARGETS` abgeleiteten Provider-Keys
(z. B. `cloro` → `CLORO_API_KEY`) und den Research-Provider für
Onboarding/Opportunities (`OPENAI_API_KEY`/`OPENROUTER_API_KEY`/
`ANTHROPIC_API_KEY`/`MISTRAL_API_KEY` – alternativ `ONBOARDING_LLM_TARGET` +
dessen Provider-Key). Fehlt etwas, listet `--status` exakt die Einträge, die die
UI als „Missing environment configuration“ anzeigt. (Hinweis: die UI zählt über
`withStoredCredentials()` zusätzlich in der DB gespeicherte Provider-Keys –
`--status` prüft nur die `.env`.)

`SCRAPE_TARGETS` bestimmt, welche Engines getrackt werden (Format
`modell:provider[:version][:online]`, kommasepariert). Default: **`stub:stub:online`**
(der keyless-„Stub“-Provider – der Worker bootet damit garantiert ohne API-Keys,
antwortet aber nur mit dem Prompt selbst, „no network“). **Wichtig:** Jeder
Provider in `SCRAPE_TARGETS` braucht beim Boot seinen Key (sonst verweigert der
Worker den Start und crash-looped). Echte Targets:

```bash
# Ein Target mit OpenRouter-Key (Judge + Onboarding laufen damit auch):
... " --update --openrouter-key sk-or-v1-... \
    --scrape-targets "chatgpt:openrouter:openai/gpt-5-mini:online,google-ai-mode:openrouter:openai/gpt-5-mini:online"
```

## Web-UI, Login & APP_URL (Loopback-Pin + Trusted Origins)

Elmo 0.7.12 hat zwei gegenläufige URL-Zwänge, die der Installer automatisch auflöst
(korrigiert in Installer v1.0.10 – die frühere „Zwei-URL-Aufteilung“ mit LAN-IP in
`APP_URL` war falsch und endete im Live-Boot-500 vom 2026-11-24):

1. **MCP-Auth** (`packages/lib/src/auth/server.ts:mcpResource`) liest die Auth-
   `baseURL` aus **`APP_URL || VITE_APP_URL`** (`BETTER_AUTH_URL` wird von elmo
   0.7.12 *nicht* gelesen!) und akzeptiert für ihre Resource-ID nur `https://`
   **oder** `localhost`/`127.x`. Ist `APP_URL` eine LAN-IP (`http://<CT-IP>:<PORT>`),
   bootet `web` mit **HTTP 500**: „APP_URL must be an HTTPS URL (or localhost) …“.
2. **Better Auth** prüft beim Login/Registrieren die Browser-Origin gegen die
   trustedOrigins – ohne die LAN-Origin in **`BETTER_AUTH_TRUSTED_ORIGINS`**
   scheitert **jeder** Login/Registrierung vom LAN mit **„Invalid origin“**
   (Live-Grube 2026-11-22).

Lösung (Installer ≥ v1.0.10): **`APP_URL` / `VITE_APP_URL` / `BETTER_AUTH_URL` =
Loopback** (`http://127.0.0.1:<PORT>`) – web bootet garantiert, die MCP-Resource-ID
ist loopback-akzeptiert. Die LAN-Origin `http://<CT-IP>:<PORT>` wandert per
`sync-app-url.sh` (läuft als `ExecStartPre` vor jedem Stack-Start) in
**`BETTER_AUTH_TRUSTED_ORIGINS`** (`http://127.0.0.1:<PORT>,http://<CT-IP>:<PORT>`)
– Login/Registrierung vom LAN klappt. Bestehende Installationen (v1.0.9 mit LAN-IP
in `APP_URL`) migriert `sync-app-url.sh` beim `--update` automatisch auf Loopback +
Trusted Origins. Für externe MCP-Clients oder saubere Links
`APP_URL=https://deine-domain.example` in `/opt/elmo/.env` setzen
(Reverse-Proxy/TLS) – der Sync erkennt `https://` und greift dann nicht mehr.

## Update

```bash
bash -c "$(wget --no-cache --no-cookies --header="Cache-Control: no-cache" -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)" --update
```

- zieht die im Installer gepinnte Image-Version (der Pin im Repo wird bei Releases aktualisiert)
- `.env` inkl. Secrets und Keys bleibt erhalten
- Daten (Postgres-Volume `postgres_data`) bleiben erhalten
- beliebige Version: `... " --update --version 0.8.0`

## Status / Deinstallation / Debug

```bash
... " --status      # Service, Stack, Keys-Status, Env-Check (UI-Missing-env-Liste), Web-UI-Erreichbarkeit
... " --uninstall   # Container stoppen + löschen (ALLE Daten weg!); --yes überspringt Rückfrage
... " --debug       # voller bash -x-Trace
```

Bei Fehlern gibt das Script die **komplette Fehlerkette** aus (Zeile, Befehl,
Exit-Code, Log-Auszüge, Container-Logs) und bleibt zur Inspektion stehen
(`pct enter <CT-ID>`).

## Architektur im LXC

```
┌─ LXC „elmo“ (unprivileged, Docker-in-LXC) ─────────────────┐
│  systemd: elmo.service (Restart=always, ExecStartPre       │
│            sync-app-url.sh → APP_URL = Loopback, LAN-Origin →    │
│                              BETTER_AUTH_TRUSTED_ORIGINS)         │
│                                                            │
│  docker compose (name: elmo):                              │
│   postgres   postgres:18-alpine      intern (KEIN Expose)  │
│   db-migrate elmohq/elmo-db-migrate  One-Shot (Migration)  │
│   web        elmohq/elmo-web         0.0.0.0:<PORT>→3000   │
│   worker     elmohq/elmo-worker      pg-boss-Jobs          │
│                                                            │
│  /opt/elmo/.env  (600) – Secrets, Keys, SCRAPE_TARGETS     │
│  Volume: postgres_data (/var/lib/postgresql)               │
└────────────────────────────────────────────────────────────┘
```

## Domain-Modus (Reverse-Proxy, optional)

Setze in `/opt/elmo/.env` `APP_URL=https://elmo.beispiel.de` (und `VITE_APP_URL`
ebenso) – `sync-app-url.sh` erkennt beim Boot `https://` und greift dann **nicht
mehr**, deine Domain bleibt erhalten. Dahinter kannst du einen Reverse-Proxy deiner
Wahl hängen.

## Backup

```bash
vzdump <CT-ID> --mode snapshot        # oder pct backup <CT-ID>
```

Alle getrackten Antworten/Konfigurationen liegen im Docker-Volume `postgres_data`.

## Lizenz

MIT – siehe [LICENSE](LICENSE). Elmo selbst: MIT ([elmohq/elmo](https://github.com/elmohq/elmo)).

