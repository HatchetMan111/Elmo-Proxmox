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
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)"
```

Das Script:

- erstellt einen **unprivilegierten LXC** (Default: 2 vCPU, 4 GB RAM, 12 GB Disk,
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
... " --id 210 --memory 4096 --port 1515
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
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)" --update --onboarding-key sk-or-v1-...

# oder Key + Targets getrennt steuern:
... " --update --openrouter-key sk-or-v1-...
... " --update --scrape-targets "chatgpt:openrouter:openai/gpt-5-mini:online"

# danach Stack neu durchziehen (erkennt Änderungen automatisch):
... " --update
```

`--status` zeigt jederzeit, welche Keys gesetzt sind (nur Namen, **nie** Werte) –
inkl. „LLM-Key“ (Onboarding/Opportunities) und „Scraper“ (echte Engine-Antworten).

`SCRAPE_TARGETS` bestimmt, welche Engines getrackt werden (Format
`modell:provider[:version][:online]`, kommasepariert). Default: **`stub:main`**
(der keyless-„Stub“-Provider – der Worker bootet damit garantiert ohne API-Keys,
antwortet aber nur mit dem Prompt selbst, „no network“). **Wichtig:** Jeder
Provider in `SCRAPE_TARGETS` braucht beim Boot seinen Key (sonst verweigert der
Worker den Start und crash-looped). Echte Targets:

```bash
# Ein Target mit OpenRouter-Key (Judge + Onboarding laufen damit auch):
... " --update --openrouter-key sk-or-v1-... \
    --scrape-targets "chatgpt:openrouter:openai/gpt-5-mini:online,google-ai-mode:openrouter:openai/gpt-5-mini:online"
```

## Web-UI & APP_URL (Loopback-Pin)

`APP_URL` wird vom Installer auf `http://127.0.0.1:<PORT>` **gepinnt** (nicht
die CT-IP) – Grund: elmo-web startet sonst nicht (die MCP-Auth verlangt für
ihre Resource-ID zwingend `https://` **oder** `localhost`/`127.x`; im Container
ist `NODE_ENV=production`, „localhost“ greift also nicht). Die Web-UI ist
trotzdem von außen erreichbar (Browser lädt nur HTML+Assets, relative Pfade
bleiben relativ). Für den **MCP-Server** (`/api/mcp`) oder saubere Links
`APP_URL=https://deine-domain.example` in `/opt/elmo/.env` setzen
(Reverse-Proxy/TLS) – der Loopback-Pin erkennt `https://` und greift dann nicht
mehr.

## Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Elmo-Proxmox/main/install/elmo.sh)" --update
```

- zieht die im Installer gepinnte Image-Version (der Pin im Repo wird bei Releases aktualisiert)
- `.env` inkl. Secrets und Keys bleibt erhalten
- Daten (Postgres-Volume `postgres_data`) bleiben erhalten
- beliebige Version: `... " --update --version 0.8.0`

## Status / Deinstallation / Debug

```bash
... " --status      # Service, Stack, Keys-Status, Web-UI-Erreichbarkeit
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
│            sync-app-url.sh → APP_URL = 127.0.0.1-Pin)      │
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
ebenso) – der Loopback-Pin beim Boot erkennt `https://` und greift dann **nicht mehr**,
deine Domain bleibt erhalten. Dahinter kannst du einen Reverse-Proxy deiner Wahl
hängen.

## Backup

```bash
vzdump <CT-ID> --mode snapshot        # oder pct backup <CT-ID>
```

Alle getrackten Antworten/Konfigurationen liegen im Docker-Volume `postgres_data`.

## Lizenz

MIT – siehe [LICENSE](LICENSE). Elmo selbst: MIT ([elmohq/elmo](https://github.com/elmohq/elmo)).
