#!/usr/bin/env bash
# Start OpenBot so it SURVIVES closing the terminal.
#
#   ./run-openbot.sh                 start everything, models through the gateway in .env
#   ./run-openbot.sh --local         start everything, every model call answered on this Mac
#   ./run-openbot.sh status          see what is running
#   ./run-openbot.sh stop            stop everything, including the Ollama this script started
#   ./run-openbot.sh ollama          (re)start only the local model server, with OpenBot's settings
#
# --local needs Ollama (`brew install ollama`) and the model pulled first
# (`ollama pull qwen3.5:4b`, or whatever OPENBOT_LOCAL_MODEL names). It changes nothing in .env:
# the overrides are exported for this run only, and every reader of .env lets the environment win.
# See "Local models" in docs/configuration.md.
#
# Why this exists rather than just `bash scripts/start.sh`:
#   1. start.sh must be piped (| cat) or Docker Compose fails with
#      "failed to get console: provided file is not a console".
#   2. start.sh exits 1 at "3/4 Runtime health" because managed Intelligence
#      reports licence 'unknown'. That is cosmetic -- the deployment works --
#      but it means start.sh never reaches 4/4 and never starts the app.
#   3. start.sh launches the server and worker attached to your terminal, so
#      they die when you close the tab. The routines worker dying is the one
#      that matters: no worker, no scheduled dispute checks, and it fails
#      SILENTLY -- the Routines page still shows a healthy next-run time.
#
# Tokens below are the dev defaults from scripts/start.sh (lines 36, 37, 46).
# They are empty in .env, so the script falls back to these. Loopback only.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
mkdir -p .logs

WORKER_PAT="bun worker/src/index.ts"
SERVER_PAT="src/production-entry.ts"
APP_PAT="vite.js --port"

usage() {
  echo "usage: ./run-openbot.sh [start|status|stop|ollama] [--local]"
}

COMMAND=""
LOCAL=false
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=true ;;
    -h|--help) usage; exit 0 ;;
    start|status|stop|ollama)
      # One command. Anything else used to fall through to start, silently.
      [ -z "$COMMAND" ] || { usage >&2; exit 2; }
      COMMAND="$arg"
      ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
COMMAND="${COMMAND:-start}"

# Ollama has no sign-in, so it must never listen beyond this machine. Every URL below names
# 127.0.0.1; the containers reach it through Docker Desktop's host.docker.internal.
OLLAMA_ADDR="127.0.0.1:11434"
# 64K because opencode requires it (docs.ollama.com/integrations/opencode).
OLLAMA_CONTEXT=65536
LOCAL_COMPOSE_FILES="docker-compose.yml:compose.override.yml:compose.local.yml"

# The environment first, then the last line in .env, then the default: the same order start.sh uses.
setting() {
  local name="$1" fallback="$2" value="${!1:-}"
  if [ -z "$value" ] && [ -f .env ]; then
    value="$(grep -E "^$name=" .env | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" || true)"
  fi
  printf '%s' "${value:-$fallback}"
}

ollama_up() {
  curl -fsS --max-time 2 "http://$OLLAMA_ADDR/api/version" >/dev/null 2>&1
}

# Whether the Ollama listening now was started with the settings below. Any other one runs on its
# own defaults, and on a 16 GB Mac Ollama picks a 4096-token context (its log says so: "vram-based
# default context"). Too short is not an error: the prompt is cut from the front and the Bot answers
# without its instructions.
ollama_pid() {
  lsof -nP -t -iTCP:11434 -sTCP:LISTEN 2>/dev/null | head -1
}

ollama_ours() {
  local pid
  pid="$(ollama_pid)"
  [ -n "$pid" ] && ps eww -o command= -p "$pid" | grep -q "OLLAMA_CONTEXT_LENGTH=$OLLAMA_CONTEXT"
}

start_ollama() {
  echo "   starting Ollama on $OLLAMA_ADDR (log: .logs/ollama.log)"
  # In a session of its own, not merely under nohup. nohup only ignores SIGHUP, and Ollama installs
  # its own SIGINT handler, which undoes the ignore a script gives background jobs: a Ctrl-C in this
  # terminal, even after the script was done, reached it through the shared process group and
  # stopped it, and the Bots then failed with nothing on screen saying why. setsid gives it its own
  # group and no terminal. macOS ships no setsid command; perl's POSIX module is always there.
  #
  # One model resident at a time: on 16 GB a second one pushes the machine into swap.
  perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' env \
    OLLAMA_HOST="$OLLAMA_ADDR" \
    OLLAMA_CONTEXT_LENGTH="$OLLAMA_CONTEXT" \
    OLLAMA_FLASH_ATTENTION=1 \
    OLLAMA_KV_CACHE_TYPE=q8_0 \
    OLLAMA_MAX_LOADED_MODELS=1 \
    OLLAMA_KEEP_ALIVE=30m \
    ollama serve < /dev/null >> .logs/ollama.log 2>&1 &
  for _ in $(seq 1 20); do ollama_up && break; sleep 1; done
  ollama_up || { echo "Ollama did not start; see .logs/ollama.log" >&2; exit 1; }
}

# Checked on the socket, not on OLLAMA_HOST: an Ollama somebody started elsewhere with
# OLLAMA_HOST=0.0.0.0 is reachable from the whole network whatever this shell says.
ollama_loopback_only() {
  local listener
  while read -r listener; do
    case "$listener" in
      127.0.0.1:11434|\[::1\]:11434) ;;
      *)
        echo "refusing: Ollama is listening on $listener, which other machines can reach." >&2
        echo "Stop it (pkill -f 'ollama serve') and run: ./run-openbot.sh ollama" >&2
        exit 1
        ;;
    esac
  done < <(lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u)
}

require_ollama() {
  command -v ollama >/dev/null 2>&1 || {
    echo "local models need Ollama: brew install ollama   (or https://ollama.com/download)" >&2
    exit 1
  }
}

OLLAMA_NOT_OURS="Ollama is running with its own settings, not OpenBot's 64K context. Restart it: pkill -f 'ollama serve' && ./run-openbot.sh ollama"

# Brings up the local model server, checks it is loopback only and holds the models, then exports
# the overrides. Fails before Docker starts, with the command that fixes it.
use_local_models() {
  local model code_model
  model="$(setting OPENBOT_LOCAL_MODEL qwen3.5:4b)"
  code_model="$(bun -e 'const config = await Bun.file("agent-computer/opencode.local.json").json(); console.log(String(config.model).replace(/^ollama\//, ""))')" || {
    echo "could not read opencode's model from agent-computer/opencode.local.json" >&2
    exit 1
  }

  require_ollama
  if ! ollama_up; then
    start_ollama
  elif ! ollama_ours; then
    echo "   $OLLAMA_NOT_OURS"
  fi
  ollama_loopback_only

  for wanted in "$model" "$code_model"; do
    ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -Fxq "$wanted" || {
      echo "the local model $wanted is not downloaded yet: ollama pull $wanted" >&2
      exit 1
    }
  done

  echo "   agents: $model   opencode: $code_model"
  export OPENBOT_LOCAL_MODELS=true
  export OPENAI_BASE_URL="http://$OLLAMA_ADDR/v1"
  export OPENAI_CONTAINER_BASE_URL="http://host.docker.internal:11434/v1"
  # A placeholder: Ollama ignores it, and the Bots refuse to start without one.
  export OPENAI_API_KEY="ollama"
  export BOT_PROVIDER="openai" BOT_MODEL="$model" AGENT_BOT_MODEL="$model"
  export BOT_RESPONSES_API="false" BOT_REASONING_EFFORT=""
  export CLAUDE_CODE_OAUTH_TOKEN="" CHATGPT_AUTH_FILE=""
  export AI_GATEWAY_API_KEY=""
  # Generated interfaces ride on every request: the A2UI component schema and its guides alone are
  # about 60,000 characters, two thirds of what a "hi" cost. A laptop model reads that at a few
  # hundred tokens a second, so it is a minute and a half before the first word. The gallery
  # components (charts, tables, forms) are separate tools and stay.
  export OPENBOT_GENERATIVE_UI="false"
  export COMPOSE_FILE="$LOCAL_COMPOSE_FILES"
}

case "$COMMAND" in
  ollama)
    # Only the model server. OpenBot needs no restart: it dials the address on every call.
    require_ollama
    if ! ollama_up; then
      start_ollama
    elif ollama_ours; then
      echo "Ollama is already running with OpenBot's settings."
    else
      # Not stopped from here: it may be somebody's own Ollama, doing other work.
      echo "$OLLAMA_NOT_OURS"
    fi
    ollama_loopback_only
    ollama ps
    exit 0
    ;;
  status)
    echo "== Docker =="
    docker compose ps --format '{{.Service}}\t{{.Status}}' 2>/dev/null || echo "  (docker not running)"
    echo "== Host processes =="
    for p in "$WORKER_PAT:worker" "$SERVER_PAT:server" "$APP_PAT:app"; do
      pat="${p%:*}"; name="${p##*:}"
      pid="$(pgrep -f "$pat" | head -1)"
      if [ -n "$pid" ]; then
        tty="$(ps -o tty= -p "$pid" | tr -d ' ')"
        [ "$tty" = "??" ] && echo "  $name: running (pid $pid, detached)" \
                          || echo "  $name: running (pid $pid, ATTACHED to $tty - dies with terminal)"
      else
        echo "  $name: NOT running"
      fi
    done
    echo "== Models =="
    server_pid="$(pgrep -f "$SERVER_PAT" | head -1)"
    local_mode=false
    if [ -n "$server_pid" ] && ps eww -o command= -p "$server_pid" | grep -q "OPENBOT_LOCAL_MODELS=true"; then
      local_mode=true
      echo "  mode: local"
    elif [ -n "$server_pid" ]; then
      echo "  mode: online (gateway in .env)"
    else
      echo "  mode: - (server not running)"
    fi
    if ! ollama_up; then
      # The script starts Ollama once, at launch. Nothing restarts it, and a Bot on a dead endpoint
      # just fails its next turn, so this is the line that has to say so.
      $local_mode && echo "  ollama $OLLAMA_ADDR DOWN: local Bots cannot answer. Run: ./run-openbot.sh ollama" \
                  || echo "  ollama $OLLAMA_ADDR not running"
    elif ollama_ours; then
      echo "  ollama $OLLAMA_ADDR ok ($OLLAMA_CONTEXT-token context)"
    else
      echo "  ollama $OLLAMA_ADDR ok, but: $OLLAMA_NOT_OURS"
    fi
    echo "== Endpoints =="
    curl -fsS --max-time 3 http://localhost:3001/health >/dev/null 2>&1 && echo "  api  3001 ok" || echo "  api  3001 DOWN"
    curl -fsS --max-time 3 http://localhost:3010/ >/dev/null 2>&1 && echo "  app  3010 ok" || echo "  app  3010 DOWN"
    exit 0
    ;;
  stop)
    pkill -f "$APP_PAT" 2>/dev/null
    pkill -f "$SERVER_PAT" 2>/dev/null
    pkill -f "$WORKER_PAT" 2>/dev/null
    bash scripts/stop.sh 2>&1 | cat
    # Only the Ollama this script started: one started any other way may be serving something else.
    if ollama_ours; then
      kill "$(ollama_pid)" 2>/dev/null
      for _ in $(seq 1 10); do ollama_up || break; sleep 1; done
      ollama_up && echo "Ollama did not stop; stop it with: pkill -f 'ollama serve'" \
                || echo "  Ollama: stopped"
    elif ollama_up; then
      echo "  Ollama: left running, it was not started by this script."
    fi
    echo "stopped."
    exit 0
    ;;
esac

if $LOCAL; then
  echo "0) Local models"
  use_local_models
fi

echo "1) Docker services, migrations, (transient) server + worker"
# Piped through cat on purpose: see note 1 above. Exit 1 at 3/4 is expected.
bash scripts/start.sh 2>&1 | cat || true

echo
echo "2) Relaunching server + worker detached from this terminal"
pkill -f "$SERVER_PAT" 2>/dev/null
pkill -f "$WORKER_PAT" 2>/dev/null
sleep 2

DB_URL="$(grep '^DATABASE_URL=' .env | cut -d= -f2-)"

nohup env \
  DATABASE_URL="$DB_URL" \
  SERVER_INTERNAL_URL="http://localhost:3001" \
  WORKER_SHARED_SECRET="openbot-dev-worker-secret" \
  bun worker/src/index.ts > .logs/worker.log 2>&1 &
disown

# COMPUTER_SUPERVISOR_URL is deliberately NOT set below.
#
# Set, the supervisor gives every Bot its own sealed container: its own /workspace
# volume, no host bind mounts and none of this deployment's secrets (see
# supervisor/src/environment.ts and supervisor/src/docker.ts, which say so outright).
# That is the right posture, but it also means the Dev Agent's computer has no
# ~/Documents and no AI_GATEWAY_API_KEY, so opencode there has nothing to read and
# no model to read it with.
#
# Unset, every Bot shares the compose-managed computer on AGENT_COMPUTER_URL
# (:4100), which compose.override.yml has already given the projects mount, the
# gateway key and opencode's config.
#
# THE TRADE: one workspace, one browser profile and one key for ALL Bots. Any Bot
# with a shell can read every .env under ~/Documents. Acceptable on a single-user
# laptop; restore the line once the supervisor can pass mounts and an env allowlist.
( cd server && nohup env \
    PORT=3001 \
    SUPERVISOR_TOKEN="openbot-dev-supervisor-token" \
    COMPUTER_TOKEN="openbot-dev-computer-token" \
    WORKER_SHARED_SECRET="openbot-dev-worker-secret" \
    bun --env-file=../.env src/production-entry.ts > ../.logs/server.log 2>&1 & disown )

for i in $(seq 1 40); do
  curl -fsS --max-time 2 http://localhost:3001/health >/dev/null 2>&1 && break
  sleep 1
done

echo "3) App (UI) detached"
( cd app && nohup bun run dev --port 3010 --strictPort > ../.logs/app.log 2>&1 & disown )
for i in $(seq 1 40); do
  curl -fsS --max-time 2 http://localhost:3010/ >/dev/null 2>&1 && break
  sleep 1
done

echo
"$ROOT/run-openbot.sh" status
echo
echo "Open http://localhost:3010   -- safe to close this terminal."
