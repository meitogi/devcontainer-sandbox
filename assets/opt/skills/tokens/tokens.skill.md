# Tokens — récap consommation

Frontend Claude pour le CLI standalone
[`recap.js`](.devcontainer/skills/tokens/recap.js) — walk les logs
JSONL sous `<project-root>/.claude/tokens/logs/YYYY-MM/*.jsonl`,
filtre par fenêtre temporelle, agrège par projet / session / jour /
modèle, imprime une table SI-compacte.

## Arguments

$ARGUMENTS

## Exécution

Exécute `node /workspace/.devcontainer/skills/tokens/recap.js
$ARGUMENTS` (via l'outil Bash) et affiche la sortie brute — elle
est déjà formatée en table Markdown, ne la reformate pas.

Si aucun argument n'est fourni **et que stdin est un TTY**, le CLI
ouvre un menu interactif. Depuis Claude, préfère toujours passer
des flags explicites (ex : `--since-reset`, `--by-day`, `--json`) —
le menu interactif est destiné à un usage humain direct dans un
terminal.

## Flags principaux

- Fenêtre (exclusives, défaut `--since-reset`) :
  `--since-reset` (samedi 20h UTC, limite Anthropic hebdo),
  `--week` (lundi 00h UTC), `--month`, `--last=7d|24h|3h`,
  `--from=YYYY-MM-DD [--to=…]`, `--all`.
- Groupement (défaut auto — `by-session` si un seul projet,
  `by-project` sinon) : `--by-project`, `--by-session`, `--by-day`,
  `--by-model`.
- Filtres : `--project=<title>` (répétable), `--json` (sortie
  machine), `--no-color`, `--no-interactive`.
- `--help` : aide complète.

## Exemples

- `/user:tokens --since-reset` → sessions depuis samedi 20h UTC.
- `/user:tokens --last=24h --by-day` → 24 dernières heures, une
  ligne par jour.
- `/user:tokens --all --json` → tout l'historique en JSON pour
  post-traitement.
