# forge — Claude Code orkiestruje, Codex buduje

Zestaw skryptów do workflow: **tmux + git worktree + Claude Code (orkiestrator) + Codex CLI (workerzy)**,
ze stroną statusu wystawianą przez Cloudflare.

```
tmux session "forge"
├── orchestrator   Claude Code w katalogu repo — planuje, zleca, robi review, merguje
├── dashboard      strona statusu na 127.0.0.1:8787 (+ feedback od klienta)
├── <worker-1..N>  Codex `exec` — każdy na własnym branchu agent/<name> i worktree
│                  (build = zmienia kod, analysis = czyta i pisze raport)
└── tunnel         cloudflared → publiczny URL do dashboardu (FORGE_TUNNEL=1)
```

![dashboard](docs/dashboard.png)

## Instalacja (macOS) — raz, nie w projekcie

Folder `forge` to narzędzie wspólne dla wszystkich projektów. Trzymaj go w jednym stałym
miejscu (np. `~/tools/forge`), **nie kopiuj go do repo**. Do projektów trafiają tylko pliki
z `forge-init` (sekcja niżej).

Komendy `forge-*` uruchamiaj **w repozytorium projektu**, nie w katalogu narzędzia —
inaczej forge potraktowałby sam siebie jako projekt. Jest na to blokada z komunikatem.

```bash
# zależności
brew install tmux jq git python
npm i -g @anthropic-ai/claude-code @openai/codex
claude          # zaloguj się raz
codex login     # zaloguj się raz
brew install cloudflared          # opcjonalnie, do wystawienia dashboardu

# forge
mkdir -p ~/tools && unzip forge.zip -d ~/tools   # → ~/tools/forge
~/tools/forge/install.sh   # instaluje komendy forge-* do ~/.local/bin i sprawdza zależności
```

Jeśli później przeniesiesz folder `forge`, uruchom `install.sh` ponownie.

`install.sh` nie zmienia zmiennych środowiskowych ani plików konfiguracyjnych powłoki. Jeśli
`~/.local/bin` nie ma w `PATH` (na macOS domyślnie nie ma), wypisze linię do dodania ręcznie:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Opcjonalnie [lemux](https://github.com/Photon48/lemux) — forkowanie rozmów z orkiestratorem
w osobne okna tmux. Działa obok forge bez konfiguracji.

## Start w projekcie

Wszystkie komendy `forge-*` to skrypty z katalogu `bin/` tego zestawu (nie zewnętrzne narzędzia).
`./install.sh` tworzy dla nich krótkie launchery w `~/.local/bin`, więc działają z dowolnego katalogu.

```bash
cd ~/code/moj-projekt
forge-init                       # PROJECT.md, CLAUDE.md, AGENTS.md, FORGE.md, .claude/settings.json
git add -A && git commit -m "forge setup"   # ważne: workerzy startują z commita, muszą widzieć AGENTS.md
forge-doctor                     # sprawdza, czy wszystko jest gotowe (zależności, pliki ról, modele)
forge-up                         # otwiera sesję tmux z Claude Code w oknie 0
```

W Claude Code po prostu opisz cel, np.:

> Dodaj endpoint /api/orders/export (CSV), testy i przycisk w UI. Rozdziel na workerów.

Claude rozpisze plan, po Twoim „ok” odpali workerów, poczeka, przejrzy diffy i zmerguje.
Między oknami tmux skaczesz `Ctrl-b w` (lista) lub `Ctrl-b <numer>`.

**Mysz w sesji jest wyłączona** i tak ma być — przy `mouse on` kółko nie
przewija okna z Claude Code, tylko wrzuca je w tryb kopiowania tmuxa.
Szczegóły i jak to włączyć z powrotem: sekcja [Przewijanie i mysz](#przewijanie-i-mysz).

## Dwa typy zadań: build i analysis

Worker Codex nie musi zmieniać kodu — może też **analizować**. To ten sam
agent, inny kontrakt na wynik:

| Typ | `--kind` | Wynik | Gotowe, gdy |
|---|---|---|---|
| **build** | `build` (domyślny) | zmieniony kod | check akceptacyjny przechodzi |
| **analysis** | `analysis` | raport | raport odpowiada na pytanie z dowodami |

```bash
forge-spawn --kind analysis audyt-cusip "Sprawdź pokrycie CUSIP→CIK w .work/..."
```

Typ `analysis` używaj, gdy zadanie polega na **ustaleniu**, nie na zmianie:
audyt danych, weryfikacja wyniku innego workera, zbadanie buga przed naprawą,
przegląd implementacji. Nie wciskaj takiego zadania w brief typu build — nie ma
tam testu do przejścia, a worker, któremu kazano zmieniać kod, zmieni kod,
który miał tylko przeczytać.

**Raport jest wynikiem, nie notatką.** Worker pisze go do `reports/<name>.md`
i harness **commituje go razem z pracą** — nie jest kasowany ani ucinany.
W `.forge/agents/<name>.json` (a więc w `forge-status`, `forge-review`
i na dashboardzie) ląduje tylko podgląd pierwszych 4 KB z odnośnikiem do
pełnej treści. Starsze `FORGE_REPORT.md` w katalogu głównym nadal działa —
harness przenosi go do `reports/<name>.md`.

Dla zadań analitycznych `AGENTS.md` wymaga wprost: źródło przy każdym
twierdzeniu (ścieżka, wiersz, hash), rozdzielenie obserwacji od wnioskowania
oraz tego, że **„nierozstrzygnięte" jest poprawną odpowiedzią** — lepszą od
zgadywania.

### Niezależna weryfikacja

Żeby worker sprawdził pracę innego **niezależnie**, daj mu bazę sprzed tej
pracy, a nie jego branch — inaczej odziedziczy jego uzasadnienie:

```bash
forge-spawn --kind analysis weryfikacja --base main "Sprawdź raport z agent/audyt..."
```

`--base <ref>` działa jak `FORGE_BASE`, ale per worker. Flagi można podawać
przed nazwą albo po niej.

### Dostęp do danych poza repo (`--link`)

Worktree zawiera **tylko pliki śledzone przez gita**, więc wszystko z
`.gitignore` (virtualenv, duże dane) w nim nie istnieje. Dowiąż to jawnie:

```bash
forge-spawn --kind analysis audyt --link .venv --link .work "Sprawdź ..."
```

`--link` tworzy symlink z głównego repo do worktree i dopisuje ścieżkę do
lokalnego `info/exclude` — wzorce typu `.venv/` ze slashem **nie łapią
symlinków**, więc bez tego pokazywałyby się jako untracked i worker mógłby je
scommitować. Można też ustawić `FORGE_LINK=".venv .work"`.

Sandbox `-s workspace-write` **pozwala czytać** dowiązane katalogi, ale
**blokuje zapis** poza worktree — sprawdzone: `mkdir` w dowiązanym `.work`
zwraca `Operation not permitted`. Dlatego artefakty pisz do worktree, a po
review przenieś je do docelowego katalogu. Nie używaj `--add-dir` na katalog
tylko do czytania: dałoby prawo zapisu tam, gdzie nie wolno modyfikować.

## Wybór modeli i dostawców

Worker może działać na trzech CLI: **codex** (OpenAI), **claude** (Anthropic)
i **antigravity** (`agy`, Google). Jedna lista w `~/tools/forge/models.conf`
mówi, który model należy do którego dostawcy i do jakiej roli się nadaje:

```
<nazwa>        <dostawca>  <rola>        <kiedy użyć>

gpt-6.1-sol    codex       both          codzienne kodowanie i analiza
opus           claude      both          review, sprzeczne dowody, architektura
haiku          claude      worker        mechaniczne edycje, ekstrakcja
agy-sonnet     antigravity worker        Sonnet na kredytach Google
default gpt-6.1-sol

slug agy-sonnet  claude-sonnet-4-6
```

- **dostawca**: `codex` \| `claude` \| `antigravity` — decyduje, które CLI
  zostanie uruchomione i jak zostaną zbudowane argumenty.
- **`slug`**: tylko dla `antigravity`. Mapuje nazwę z forge na nazwę, którą
  przyjmuje `agy --model`. Jest potrzebny, bo ten sam model bywa dostępny
  dwiema drogami (`agy-sonnet` vs `sonnet`), więc sama nazwa nie mówi, które
  CLI uruchomić. Sprawdź `agy models` po aktualizacji CLI.
- **rola**: `worker` \| `orchestrator` \| `both`. `forge-spawn` odmówi modelu
  oznaczonego jako `orchestrator`, zamiast startować workera, który nie umie
  pracować.
- Opis po roli to wskazówka dla Claude'a, kiedy użyć danego modelu — pisz go konkretnie.
- `default` — model dla zadań bez `--model`.
- Nazwa spoza listy jest odrzucana, więc Claude nie wymyśli nieistniejącego modelu.
- Model i dostawcę widać w `forge-status`, w logu workera i na dashboardzie.
- Inny plik dla projektu: `FORGE_MODELS_FILE=/ścieżka/models.conf forge-up`.
- `forge-models` pokazuje też, których CLI **nie masz zainstalowanych** — ich
  modeli nie da się uruchomić.

Stary dwukolumnowy `models.conf` (`<nazwa> <opis>`) nadal działa: taki wpis
jest czytany jako `codex` + `worker`.

### Kto jest orkiestratorem

Orkiestratorem jest Claude Code — to on czyta `FORGE.md` i zleca zadania.
Model wybierasz Ty:

```bash
FORGE_ORCH_MODEL=opus forge-up      # tylko model z models.conf o roli both/orchestrator
FORGE_ORCH_CMD="claude --model opus" forge-up   # pełna kontrola nad komendą
```

`FORGE_ORCH_MODEL` jest walidowany: model spoza listy, model o roli `worker`
albo model nie-Claude'owy zostanie odrzucony przy starcie, a nie w trakcie pracy.

### Antigravity (`agy`) — dostawca zamiast Gemini CLI

Dostawca `gemini` został **usunięty 2026-10-30**. Google przestał obsługiwać
Gemini CLI na kontach osobistych — logowanie przechodzi, a potem każde
wywołanie kończy się błędem:

```
IneligibleTierError: This client is no longer supported for Gemini Code Assist
for individuals.  →  https://antigravity.google
```

Antigravity to ta ścieżka, na którą Google przekierował te konta, i **działa**
na koncie osobistym (sprawdzone 2026-10-30 na `agy` 1.4.11: headless `agy -p`
uruchamia się, edytuje pliki i raportuje tokeny). Jedno CLI daje dostęp do
trzech rodzin modeli:

```
$ agy models
gemini-3.8-flash-high/medium/low    Gemini 3.8 Flash
claude-sonnet-4-6                   Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking            Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium                 GPT-OSS 120B
```

**Uwaga na rachunek:** `agy-sonnet` i `agy-opus` to te same modele co `sonnet`
i `opus` u dostawcy `claude`, ale idą z kredytów Google, nie z Twojej
subskrypcji Claude. Używaj ich, żeby oszczędzić limit Claude'a — nie po to, by
dostać inną odpowiedź.

#### `FORGE_AGY_COMMANDS` — bez tego worker nic nie uruchomi

W trybie headless `agy` **automatycznie odrzuca** każde narzędzie, o które
musiałby zapytać — i **mimo to kończy z `status: SUCCESS` i kodem 0**. Worker,
któremu nie wolno było nic zrobić, wygląda wtedy identycznie jak worker, który
uznał, że nie ma nic do roboty.

forge radzi sobie z tym dwojako:

1. Przekazuje jawną listę uprawnień (`write_file(*)`, `replace(*)`, `read_file(*)`
   i pozostałe odczyty) przez `--settings`, czyli **sesyjnie** — Twój
   `~/.gemini/antigravity-cli/settings.json` nie jest modyfikowany.
2. Traktuje niepuste `denied_actions` jako **błąd workera** (`failed`), nie
   `done`. Inaczej forge raportowałby sukces workera, który nic nie zrobił.

Polecenia shell to osobna sprawa i wymagają Twojej decyzji:

```bash
export FORGE_AGY_COMMANDS="pytest python3 git ls cat find grep"
```

Reguła dopasowuje się do **pierwszego słowa** polecenia i **nie** obsługuje
glob (sprawdzone na `agy` 1.4.11):

| Reguła | `pytest test.py` | `python3 -m pytest` | `curl ...` |
|---|---|---|---|
| `command(pytest)` | ✅ | ❌ | ❌ |
| `command(python3)` | ❌ | ❌ | ❌ |
| `command(python3*)` | ❌ | ❌ | ❌ |
| `command(*)` | ✅ | ✅ | ✅ |

Czyli `command(python3)` **nie** wystarczy na `python3 -m pytest`. W praktyce
`agy` sięga też po `ls` na rozeznanie się w katalogu, zanim cokolwiek zrobi, więc
lista musi obejmować narzędzia do czytania repo, nie tylko sam test. Bez
`FORGE_AGY_COMMANDS` workerzy `--kind build` nie wykonają acceptance checku —
`forge-doctor` o tym ostrzega.

`command(*)` pozwala na dowolne polecenie w worktree. To Twoja decyzja, nie
domyślna wartość forge.

#### Reasoning effort jest w nazwie modelu

Dla modeli `agy` poziom rozumowania jest częścią sluga (`-high`/`-medium`/`-low`),
a podanie dodatkowo `--effort` to twardy błąd (`--model X conflicts with
--effort=Y`). forge **pomija** `--effort` dla tych modeli i wypisuje o tym
notkę, zamiast wywalić spawn.

**Lista modeli się zmienia.** Jest odświeżana z serwera, więc `models.conf`
może się zdezaktualizować. Jak sprawdzić, co przyjmuje twoje CLI:

```bash
# co konto ma dostępne (lista z serwera, bywa nieaktualna w cache)
python3 -c "import json,re;s=open('$HOME/.codex/.codex-global-state.json').read();\
print(json.loads(re.search(r'"eligible_codex_model_slugs":\s*(\[[^]]*\])',s).group(1)))"

# co faktycznie było używane
grep -rho '"model":"[^"]*"' ~/.codex/sessions --include='*.jsonl' | sort | uniq -c | sort -rn

# test rozstrzygający (w katalogu repo git); zła nazwa → model_not_found
codex exec -s read-only -m <nazwa> "Reply with exactly: OK" < /dev/null
```

Tylko trzeci sposób jest dowodem — lista z cache i historia sesji mogą być
niepełne albo przestarzałe. Dla claude i antigravity odpowiednikiem jest
`forge-doctor --spawn`, które woła każde CLI raz, z tymi flagami, których
forge faktycznie używa.

## Reasoning effort

`--effort low|medium|high|xhigh|max|ultra` ustawia nakład rozumowania workera.
Wyższy to więcej czasu i tokenów; **nie jest gwarancją poprawności** i nie
zastępuje źródeł, testów ani oznaczania przypadków nierozstrzygniętych.
Pominięty — model używa swojego domyślnego.

```bash
forge-spawn --model gpt-6-astra --effort xhigh --kind analysis audyt "Sprawdź ..."
```

| Effort | Kiedy |
|---|---|
| `low` | ekstrakcja danych, drobna edycja, jeden jednoznaczny krok |
| `medium` | domyślny punkt startowy do zwykłego kodowania i analizy |
| `high` | trudne błędy, projektowanie rozwiązania, wnioskowanie z kilku źródeł |
| `xhigh` | złożone audyty, sprzeczne dowody, wiele zależności |
| `max` | wyjątkowo trudne przypadki, gdy dodatkowy czas jest uzasadniony |
| `ultra` | dostępny, ale bez udokumentowanej przewagi nad `max` |

Technicznie: `codex exec` **nie ma** flagi effortu — forge przekazuje go jako
`-c model_reasoning_effort="<poziom>"`. Klucz `reasoning_effort` (bez prefiksu
`model_`) jest po cichu ignorowany z ostrzeżeniem o nierozpoznanym ustawieniu,
więc nie wpisuj go z pamięci. Sprawdzone 2026-10-28 na codex-cli 0.163.0:
przyjęte są wszystkie sześć poziomów, a nazwa spoza listy jest odrzucana.

## Komendy

| Komenda | Co robi |
|---|---|
| `forge-spawn [--model <m>] [--effort <poziom>] [--kind build\|analysis] [--base <ref>] [--link <path>] <name> "<zadanie>"` | branch `agent/<name>` + worktree + Codex w nowym oknie tmux. Zadanie może iść też przez stdin. `--model` tylko z listy w `models.conf`. `--effort` = nakład rozumowania. `--kind analysis` = worker pisze raport, nie zmienia kodu. `--base` = inny punkt startu. `--link` = dowiąż gitignorowaną ścieżkę. |
| `forge-models [--workers]` | lista modeli z dostawcą i rolą; `--workers` ukrywa modele tylko-orkiestratorskie |
| `forge-usage [--json] [--all] [--since <dni>]` | zużycie tokenów per dostawca i model + kontekst/limit planu per sesja |
| `forge-wait [names…] [--timeout s]` | czeka aż workerzy skończą, potem pokazuje status |
| `forge-status [--json] [name]` | tabela workerów; z nazwą — raport i ostatnie linie logu |
| `forge-review <name> [--stat]` | raport workera, commity, diff względem punktu startu |
| `forge-merge <name> [--keep]` | `merge --no-ff` do bieżącego brancha; przy konflikcie robi abort i oznacza `conflict` |
| `forge-cancel <name>` | zatrzymuje workera, ale **zachowuje** branch i commituje to, co już zrobił |
| `forge-drop <name>` | **odrzuca** pracę workera (okno, worktree, branch) — Claude musi pytać |
| `forge-clean [--merged\|--dropped\|--finished\|--all] [--yes] [--dry-run]` | sprząta po skończonych workerach: pliki stanu, worktree, branche |
| `forge-doctor [--spawn]` | sprawdza, czy wszystko jest gotowe, zanim zlecisz pierwsze zadanie |
| `forge-up [-d]` | startuje całą sesję |
| `forge-init` | instaluje pliki ról w repo |
| `test/forge-test [filtr]` | testy end-to-end całego zestawu (atrapa `codex`, nic nie dzwoni do modelu) |

Statusy workera: `queued → running → done | nochanges | failed`, potem
`merged | conflict | cancelled | dropped`.
`nochanges` znaczy, że worker nic nie wniósł — dla typu build brak zmian w kodzie,
dla analysis brak raportu. Worker analityczny, który napisał raport, kończy jako `done`.
Stan leży w `.forge/` (automatycznie wykluczone z gita przez `.git/info/exclude`),
worktree w `../.forge-wt/<repo>/<name>`.

## Role — trzy pliki

`forge-init` instaluje układ, w którym **żadne narzędzie nie czyta roli drugiego**:

```
PROJECT.md   zasady projektu — JEDYNE źródło prawdy
   ↑ @PROJECT.md              ↑ @PROJECT.md
CLAUDE.md                  AGENTS.md
(orkiestrator)             (worker Codex)
   ↑ @FORGE.md                + reguły workera
FORGE.md
```

- **`PROJECT.md`** — zasady wspólne: środowisko, brama jakości, konwencje,
  pułapki. **Tu piszesz zasady projektu.** `forge-init` tworzy go jako szkielet
  do wypełnienia i **nigdy nie nadpisuje**, jeśli już istnieje.
- **`CLAUDE.md`** — rola orkiestratora; importuje `@PROJECT.md` + `@FORGE.md`.
- **`AGENTS.md`** — rola workera Codex; importuje `@PROJECT.md` i dokłada reguły
  workera: tylko swój zakres, bez commitów (robi to harness), raport do
  `reports/<name>.md`. Osobne reguły dla build (check akceptacyjny) i analysis
  (dowód przy każdym twierdzeniu, „nierozstrzygnięte" dozwolone).
- **`FORGE.md`** — pętla orkiestratora: plan → spawn → wait → review → merge →
  raport. Zakazy: push, przepisywanie historii, merge bez przeczytania diffa,
  `forge-drop` bez pytania. **Właścicielem jest forge** — `forge-init` odświeża
  ten plik przy każdym uruchomieniu, więc nie dopisuj tu swoich zasad.
- **`.claude/settings.json`** — komendy forge-* dozwolone bez pytania; `forge-drop`, `git push/reset/rebase`
  wymagają potwierdzenia; `.env`, `secrets/`, `*.pem`, `*.key` zablokowane do czytania.

Dostosuj do projektu: w `PROJECT.md` opisz, jak uruchamiać testy
(`./gradlew test`, `npm test`, `pytest`) i co jest checkiem akceptacyjnym.

`forge-init` można **uruchamiać wielokrotnie**. Nadpisuje tylko `FORGE.md`;
pozostałe pliki tworzy, gdy ich nie ma, albo dokłada brakujący import. Jeśli
wykryje stary układ jednoplikowy (`CLAUDE.md` jako symlink do `AGENTS.md`, albo
`@FORGE.md` w `AGENTS.md`), **nie zmienia go sam** — wypisuje ostrzeżenie, bo
to decyzja operatora.

## Zanim zlecisz pierwsze zadanie

Cztery awarie na pięć uruchomień w sesji 2026-10-28 wyszłyby na jednym
próbnym spawnie. Dlatego jest `forge-doctor` — jedna komenda zamiast listy
ręcznych sprawdzeń:

```bash
forge-doctor            # zależności, pliki ról, czy są scommitowane, modele, końce linii
forge-doctor --spawn    # dodatkowo jedno prawdziwe wywołanie codexa (kilka sekund)
```

Kody wyjścia: `0` wszystko gra, `2` tylko ostrzeżenia, `1` coś jest zepsute.
Dwa ostrzeżenia warte uwagi, bo nie widać ich inaczej niż po śmierci workera:

- **„invisible to workers"** — pliki ról nie są scommitowane. Worker startuje
  z commita, więc niescommitowany `AGENTS.md` dla niego nie istnieje.
- **„PROJECT.md is still the unfilled stub"** — nie ma zdefiniowanego checku
  akceptacyjnego, więc każdy worker build wymyśli własny.

Co `forge-doctor` wyłapuje poza tym: brakujące zależności, launchery w
`~/.local/bin` wskazujące na przeniesiony katalog forge, `CLAUDE.md` jako
symlink do `AGENTS.md` (oba narzędzia dostają wtedy rolę drugiego), `@FORGE.md`
w `AGENTS.md`, `default` w `models.conf` spoza listy modeli, oraz
`core.autocrlf`, który psuje testy tylko u workerów.

- **`error: unexpected argument '--full-auto'`** — masz Codex CLI ≥ 0.163.0,
  gdzie tej flagi już nie ma. Domyślna wartość w forge to teraz
  `-s workspace-write`; jeśli widzisz ten błąd, masz starą wersję forge.
- **Zmienna przed `forge-spawn` nie działa?** `tmux new-window` dziedziczy
  środowisko **serwera tmux**, nie twojej powłoki. `forge-spawn` przekazuje
  dziś `FORGE_*` jawnie przez `-e`, ale dla innych zmiennych użyj
  `tmux set-environment -t forge NAZWA wartość`.
- **Worker nie znajduje `.venv` / danych?** To nie jest w gicie, więc nie ma
  tego w worktree. Użyj `--link` (sekcja wyżej) **przed** spawnem.
- **`forge-models: command not found`** — launchery w `~/.local/bin` są
  nieaktualne; uruchom ponownie `./install.sh`.
- **Testy porównujące hashe plików padają tylko u workerów?** To końce linii.
  Przy `core.autocrlf=true|input` git normalizuje CRLF przy commicie: twój
  katalog główny zachowuje oryginalne bajty i testy przechodzą, a worker
  dostaje z gita wersję znormalizowaną. `forge-init` ostrzega o tym układzie.
  Naprawa: `-text` w `.gitattributes` dla tych ścieżek **i** ponowny zapis
  (`git add --renormalize -- <ścieżka>/`) — sam atrybut nie przywróci bajtów
  usuniętych z istniejących blobów. Sprawdzaj w świeżym worktree.

**Status `done` nie znaczy, że jest produkt.** Worker może skończyć z commitem,
którego jedyną treścią jest raport „nie dało się nic zmierzyć". Zawsze czytaj
raport, nie tylko status.

## Zatrzymywanie i sprzątanie

**`forge-cancel` vs `forge-drop`.** Oba zatrzymują workera, ale różnią się tym,
co zostaje:

| | worker | branch i worktree | to, co już zrobił |
|---|---|---|---|
| `forge-cancel <name>` | zatrzymany | **zostają** | **commitowane** jako `[agent:<name>] cancelled: partial work` |
| `forge-drop <name>` | zatrzymany | usunięte | przepada bezpowrotnie |

`forge-cancel` jest do sytuacji „idzie w złą stronę / utknął / zadanie się
zmieniło, ale chcę zobaczyć, co zrobił". Status `cancelled` można zmergować
(`forge-merge` ostrzega, że check akceptacyjny nigdy nie przeszedł) albo
odrzucić później przez `forge-drop`.

**`forge-clean`** sprząta po skończonych workerach — pliki stanu w `.forge/`
oraz worktree i branche tych, które je zachowały. Worker ze statusem `failed`
zostawia worktree **celowo**, do wglądu, i nic innego go nie usuwa.

```bash
forge-clean                       # tylko zmergowane — bezpieczne, to domyślny zakres
forge-clean --dry-run             # pokaż, co by poszło, nie zmieniaj nic
forge-clean --dropped             # + porzucone
forge-clean --finished            # + done/nochanges/failed — TO JEST NIEZMERGOWANA PRACA
forge-clean --all                 # + queued/running (najpierw je zatrzyma)
```

Każdy zakres szerszy niż `--merged` może usunąć pracę, która nie istnieje nigdzie
indziej, więc pyta o potwierdzenie — trzeba wpisać słowo `delete`. `--yes`
pomija pytanie (do skryptów).

**Limit równoległych workerów.** `forge-spawn` odmawia startu, gdy biegnie już
`FORGE_MAX_WORKERS` (domyślnie 4):

```
forge: 4 worker(s) already active (limit 4): a b c d
```

To limit w kodzie, nie prośba w prompcie — każdy worker to model plus jego check
akceptacyjny, więc niekontrolowany fan-out potrafi położyć maszynę. Podnieś go
przez `FORGE_MAX_WORKERS=6`, albo obejdź jednorazowo przez `--force`.
`FORGE_MAX_WORKERS=0` wyłącza limit.

## Zużycie tokenów

```bash
forge-usage                  # ten projekt: per model + kontekst/limit per sesja
forge-usage --all            # wszystkie lokalne sesje, nie tylko tego repo
forge-usage --since 7        # tylko ostatnie 7 dni
forge-usage --json           # do skryptów
```

Nic nie dzwoni do API i żaden klucz nie jest potrzebny — czytane są wyłącznie
lokalne logi sesji, które każde CLI i tak zapisuje. To samo widać na
dashboardzie w kafelku **Tokens**.

**Jakość danych różni się per dostawca** i to nie jest decyzja forge, tylko
to, co dostawcy w ogóle zapisują:

| Dostawca | Skąd | Tokeny | Limit planu |
|---|---|---|---|
| codex | `~/.codex/sessions/**/rollout-*.jsonl` | pełne, kumulatywnie per sesja | **tak** — `rate_limits.used_percent` |
| claude | `~/.claude/projects/<repo>/<sesja>.jsonl` | pełne, sumowane per wiadomość | nie — tylko kontekst |
| antigravity | `.forge/usage/<worker>.json` (zapisane przez forge) | pełne, z koperty `usage` | nie |

Dlatego **tylko codex** pokazuje realny procent wypalonego planu. Dla pozostałych
kolumna `PLAN QUOTA` to `n/a` — forge nie zgaduje i nie przelicza tego na złotówki,
bo nie zna cen Twojego planu.

Kolumna `CONTEXT USED` to `kontekst_szczytowy / okno_modelu` — czyli jak blisko
sesja była wymuszonej kompaktacji. Liczony jest **szczyt**, nie ostatnia
wiadomość: po kompaktacji ostatnia wiadomość znów jest mała, co ukrywałoby fakt,
że sesja się zapchała.

Antigravity nie trzyma trwałego logu tokenów jak codex — podaje je tylko w
kopercie JSON na końcu biegu `-p`. Dlatego `forge-run` zapisuje ją do
`.forge/usage/<worker>.json` w momencie zakończenia workera. Bez tego nie ma
czego czytać, a nieudane sparsowanie JSON-a **nie** jest traktowane jako błąd
workera — praca może być całkowicie dobra.

Jedna pułapka w arytmetyce: `total_tokens` z `agy` to `input + output` i
**nie zawiera** `cache_read_tokens` (zmierzone: 9169+355=9524 przy cache
15628). forge dolicza cache, żeby `TOTAL` pokazywał realny przepływ.

W tabeli `MODEL` widnieje nazwa z forge (`agy-sonnet`), nie slug — bo to ona
mówi, z czyich kredytów poszedł bieg. `agy-sonnet` i `sonnet` to ten sam model
na dwóch różnych rachunkach i zlanie ich w jedno ukryłoby właśnie tę różnicę.

## Testy

```bash
test/forge-test             # wszystko
test/forge-test merge       # tylko testy, których nazwa zawiera "merge"
```

Każdy test dostaje własne repo w katalogu tymczasowym i **atrapę `codex`**, więc
nic nie dzwoni do modelu i nic nie dotyka twoich projektów. Sesja tmux i katalog
worktree są unikalne per uruchomienie, więc testy nie kolidują z działającą
sesją `forge`. Pokrycie: obsługa argumentów każdej komendy, cykl życia workera
(build/analysis/nochanges/failed), merge z konfliktem i abortem, `--base`,
`--link`, limit równoległości, `forge-cancel`, `forge-clean`, `forge-doctor`.

## Wrażliwe dane

Claude Code i Codex działają w chmurze, więc wszystko, co czytają, wychodzi z maszyny.
Przed użyciem na repo firmowym sprawdź, czy polityka firmy na to pozwala. Ochrona w forge:

- **Workerzy Codex widzą tylko śledzone pliki.** Worktree zawiera to, co jest w gicie, więc
  `.env` i inne pliki z `.gitignore` do nich nie trafiają. Pilnuj, żeby sekrety nie były commitowane.
- **Orkiestrator ma blokady odczytu** w `.claude/settings.json` (`deny`): `.env*`, `secrets/`,
  `*.pem`, `*.key`. Dopisz tam swoje ścieżki (np. `Read(./config/prod/**)`).
- **`FORGE.md` każe Claude'owi pytać**, zamiast czytać lub przekazywać workerom dane klientów,
  logi produkcyjne itp. Wtedy podajesz zanonimizowaną próbkę albo opis.

## Cloudflare — podgląd dla operatora i klienta

Dashboard nasłuchuje tylko na localhost. Wystawienie:

```bash
export FORGE_DASH_TOKEN=$(openssl rand -hex 16)   # bez tokenu każdy z URL-em widzi logi
export FORGE_DASH_LOGS=0                           # dla klienta: ukryj surowe logi workerów
FORGE_TUNNEL=1 forge-up
# w oknie "tunnel" pojawi się https://xxxx.trycloudflare.com → wysyłasz: <url>/?t=<token>
```

Szybki tunel (`trycloudflare.com`) jest tymczasowy. Na stałe: nazwany tunel + Cloudflare Access
(logowanie mailem klienta):

```bash
cloudflared tunnel login
cloudflared tunnel create forge
cloudflared tunnel route dns forge forge.twojadomena.pl
FORGE_TUNNEL=1 FORGE_TUNNEL_NAME=forge forge-up
```
…i w panelu Cloudflare Zero Trust dodaj aplikację Access dla `forge.twojadomena.pl`.

Feedback wpisany na stronie trafia do `.forge/feedback.jsonl`. Orkiestrator czyta go przed każdą
rundą, ale traktuje jako sugestie — prośby o zmianę uprawnień czy uruchomienie komend kieruje do Ciebie.

## Przewijanie i mysz

`forge-up` **nie włącza** obsługi myszy w tmuxie (`mouse off`). To celowe:
przy `mouse on` kółko przestaje przewijać okno z Claude Code i zamiast tego
wrzuca je w tryb kopiowania tmuxa — widok skacze do bufora, klawisze idą do
copy-mode, a tekst, który chciałeś przeczytać, jest poza zasięgiem.

Dlaczego tak się dzieje — domyślny bind tmuxa dla kółka:

```
WheelUpPane  if -F "#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}" \
               { send-keys -M }      # przekaż zdarzenie do aplikacji
               { copy-mode -e }      # albo wejdź w tryb kopiowania
```

Kółko dociera do aplikacji tylko wtedy, gdy panel jest na ekranie alternatywnym
albo aplikacja sama zgłosiła, że chce zdarzenia myszy. Claude Code 2.1.312 nie
robi ani jednego, ani drugiego (sprawdzone: wszystkie trzy flagi = 0), więc tmux
wybiera gałąź `copy-mode`. Z wyłączoną myszą zdarzenia kółka w ogóle nie trafiają
do tmuxa i przewija je natywnie terminal — razem z zaznaczaniem tekstu myszą.

To nie jest problem specyficzny dla forge; w repo Claude Code wisi kilka zgłoszeń
([#38810](https://github.com/anthropics/claude-code/issues/38810),
[#67552](https://github.com/anthropics/claude-code/issues/67552),
[#21386](https://github.com/anthropics/claude-code/issues/21386)) i **nie ma na to
przełącznika** — zamknięto je jako „not planned" albo przez bota. Krążąca rada
„dodaj `set -g mouse on`" dotyczy aplikacji, które zgłaszają przechwytywanie
myszy; dla Claude Code działa odwrotnie. `CLAUDE_CODE_DISABLE_MOUSE=1` nic tu nie
zmienia (sprawdzone — `mouse_any_flag` zostaje 0).

Co tracisz: kółko w oknach workerów. Logi workerów są na dashboardzie, a panel
nadal przewiniesz z klawiatury:

| Skrót | Co robi |
|---|---|
| `Ctrl-b [` | tryb kopiowania: strzałki, `PgUp`/`PgDn`, `/` szuka, `q` wychodzi |
| `Ctrl-b w` | lista okien (bez klikania) |

Jeśli wolisz mysz w tmuxie, włącz ją z powrotem:

```bash
FORGE_MOUSE=on forge-up                      # dla nowej sesji
tmux set-option -t forge mouse on            # albo w już działającej
```

W już działającej sesji (ta opcja jest per sesja, więc zmiana działa od razu):

```bash
tmux set-option -t forge mouse off           # wyłącz, gdy przewijanie wariuje
```

## Konfiguracja (zmienne środowiskowe)

| Zmienna | Domyślnie | |
|---|---|---|
| `FORGE_SESSION` | `forge` | nazwa sesji tmux |
| `FORGE_BASE` | bieżący branch | z czego workerzy startują (per worker: `--base`) |
| `FORGE_LINK` | — | gitignorowane ścieżki dowiązywane do worktree (per worker: `--link`) |
| `FORGE_CODEX_ARGS` | `-s workspace-write` | argumenty `codex exec`. Codex CLI 0.163.0 **nie ma już `--full-auto`** — używa `-s read-only\|workspace-write\|danger-full-access` |
| `FORGE_CODEX_CMD` | `codex` | inny CLI z interfejsem `exec <prompt>` |
| `FORGE_ORCH_CMD` | `claude` | komenda w oknie orkiestratora (pełna kontrola) |
| `FORGE_ORCH_MODEL` | — | model orkiestratora z `models.conf` (rola `both`/`orchestrator`) |
| `FORGE_CLAUDE_CMD` | `claude` | CLI dla dostawcy `claude` |
| `FORGE_CLAUDE_ARGS` | `--permission-mode acceptEdits` | argumenty `claude -p` dla workera |
| `FORGE_AGY_CMD` | `agy` | CLI dla dostawcy `antigravity` |
| `FORGE_AGY_ARGS` | `--output-format json` | argumenty `agy`; `json` jest potrzebne, bo z niego czytane są tokeny |
| `FORGE_AGY_COMMANDS` | — | polecenia, które wolno uruchomić workerowi `agy` (pierwsze słowo, bez globów) |
| `FORGE_KEEP_WINDOW` | `1` | okno workera zostaje otwarte po zakończeniu |
| `FORGE_REPORT_DIR` | `reports` | katalog na raporty workerów (commitowane) |
| `FORGE_MAX_WORKERS` | `4` | limit równolegle biegnących workerów (`0` = bez limitu, `--force` = obejście) |
| `FORGE_WT_ROOT` | `../.forge-wt/<repo>` | gdzie trzymać worktree |
| `FORGE_DASH_PORT` | `8787` | port dashboardu |
| `FORGE_DASH_TOKEN` | — | token dostępu do dashboardu |
| `FORGE_DASH_LOGS` | `1` | `0` ukrywa logi na stronie |
| `FORGE_MOUSE` | `off` | mysz w tmuxie; `on` przywraca kółko w oknach workerów, ale psuje przewijanie w oknie Claude Code ([dlaczego](#przewijanie-i-mysz)) |

## Wskazówki

- Dziel pracę po granicach modułów — dwóch workerów na jednym pliku = konflikt przy merge.
  Przy konflikcie: `FORGE_BASE=main forge-spawn <name>-fix "Przenieś zmiany z agent/<name> na aktualny main…"`
  albo w oknie workera `git merge main`, rozwiąż konflikt, commit, i ponów `forge-merge <name>`.
- Zacznij od 2–3 workerów; więcej zwykle oznacza więcej review niż oszczędności.
- Okno workera po zakończeniu zostaje otwarte — możesz w nim od razu uruchomić testy.
