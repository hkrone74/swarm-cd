#!/bin/sh
# Prüfstand für swarm-cd (Redmine #93). Läuft IM Wegwerf-Swarm (docker:dind), aufgerufen von
# start.sh. Baut Registry, Git-Server über HTTP und ein Test-Repo auf, startet swarm-cd und
# spielt jeden Prüfpunkt durch. Ausgabe je Punkt BESTANDEN/NICHT BESTANDEN, am Ende ein Urteil.
#
#   pruefen.sh <swarm-cd-abbild>
set -u
ABBILD=${1:?Abbild von swarm-cd fehlt}
INTERVALL=10
FEHLER=0
REPO=/work

log() { printf '\n== %s\n' "$*"; }
ok() { printf 'BESTANDEN      %s\n' "$*"; }
nok() { printf 'NICHT BESTANDEN %s\n' "$*"; FEHLER=$((FEHLER + 1)); }

# warte <sekunden> <befehl…> — bis der Befehl gelingt
warte() {
  t=$1; shift
  while [ "$t" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 2; t=$((t - 2)); done
  return 1
}

metrik() { curl -sf localhost:8080/metrics | awk -v m="$1" '$1 == m {print $2}'; }
digest() { docker service inspect "$1" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | sed 's/.*@//'; }
aufgaben() { docker service ps "$1" -q --filter desired-state=running; }
commit() { (cd $REPO && git add -A && git commit -qm "$1" && git push -q origin main && git rev-parse --short=8 HEAD); }
ausgerollt() { metrik "swarmcd_stack_deployed_info{revision=\"$2\",stack=\"$1\"}" | grep -q 1; }
deploys() { metrik "swarmcd_stack_deploys_total{stack=\"$1\"}"; }
ist() { [ "$(metrik "$1")" = "$2" ]; }
# Die Dienst-Version (.Version.Index) taugt nicht als Beleg für „kein deploy“: Swarm zählt sie
# auch hoch, wenn ein laufendes Update abschließt. Beleg sind Log und deploys_total/state_file.
# eine Runde von swarm-cd abwarten: last_check des Stacks muss sich bewegen
runde() {
  a=$(metrik "swarmcd_stack_last_check_timestamp_seconds{stack=\"$1\"}"); i=0
  while [ $i -lt 30 ]; do
    sleep 2; ist "swarmcd_stack_last_check_timestamp_seconds{stack=\"$1\"}" "$a" || return 0; i=$((i + 1))
  done
  return 1
}
laeuft() { [ -n "$(aufgaben "$1")" ]; }
digest_nicht() { [ "$(digest "$1")" != "$2" ]; }
env_hat() { docker service inspect "$1" --format '{{.Spec.TaskTemplate.ContainerSpec.Env}}' | grep -q "$2"; }
liest() { docker exec "$(docker ps -q -f name="$1". | head -1)" cat "$2" | grep -q "$3"; }

# --- Aufbau -----------------------------------------------------------------------------------
log "Aufbau"
docker network create -d overlay --attachable scd >/dev/null 2>&1
docker service create -d -q --name registry -p 5000:5000 registry:2 </dev/null >/dev/null
warte 60 curl -sf localhost:5000/v2/ || { echo "Registry kommt nicht hoch"; exit 2; }
# ein nur lokal gebautes Abbild kann ein Swarm-Dienst nicht ziehen
if docker image inspect "$ABBILD" >/dev/null 2>&1; then
  docker tag "$ABBILD" localhost:5000/swarm-cd:pruefstand
  docker push -q localhost:5000/swarm-cd:pruefstand >/dev/null
  ABBILD=localhost:5000/swarm-cd:pruefstand
fi
echo "swarm-cd: $ABBILD"

mkdir -p /b/gith /b/v1 /b/v2
cat > /b/gith/lighttpd.conf <<'EOF'
server.document-root = "/srv/git"
server.port = 80
server.modules = ("mod_cgi", "mod_alias", "mod_setenv")
alias.url = ("/git/" => "/usr/libexec/git-core/git-http-backend/")
setenv.add-environment = ("GIT_PROJECT_ROOT" => "/srv/git", "GIT_HTTP_EXPORT_ALL" => "1")
cgi.assign = ("" => "")
EOF
cat > /b/gith/Dockerfile <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache git git-daemon lighttpd && git config --system --add safe.directory '*'
COPY lighttpd.conf /etc/lighttpd/lighttpd.conf
CMD ["lighttpd", "-D", "-f", "/etc/lighttpd/lighttpd.conf"]
EOF
for v in v1 v2; do
  printf 'FROM busybox:1.37\nRUN echo %s > /version\nCMD ["sleep","infinity"]\n' $v > /b/$v/Dockerfile
done
docker build -q -t localhost:5000/gith /b/gith >/dev/null && docker push -q localhost:5000/gith >/dev/null
docker build -q -t localhost:5000/app:latest /b/v1 >/dev/null && docker push -q localhost:5000/app:latest >/dev/null
docker pull -q busybox:1.37 >/dev/null

mkdir -p /srv/git && git init -q --bare -b main /srv/git/stacks.git
docker service create -d -q --name git --network scd \
  --mount type=bind,src=/srv/git,dst=/srv/git localhost:5000/gith </dev/null >/dev/null

git config --global user.email pruefstand@example.invalid
git config --global user.name pruefstand
git config --global --add safe.directory '*'
git clone -q /srv/git/stacks.git $REPO 2>/dev/null
mkdir -p $REPO/st
cat > $REPO/st/app.yml <<'EOF'
# Stack: app · dieser Kommentar geht beim Zurückschreiben verloren
services:
  app:
    image: localhost:5000/app:latest
    deploy:
      labels: [io.ssk.autodeploy]
    configs:
      - source: gruss
        target: /gruss.txt
  nebendienst:
    image: busybox:1.37
    command: ["sleep", "infinity"]
    environment:
      STAND: "1"
    configs:
      - source: fest
        target: /fest.txt
  weg:
    image: busybox:1.37
    command: ["sleep", "infinity"]
configs:
  gruss:
    file: ./gruss.txt
  fest:
    file: ./fest.txt
EOF
cat > $REPO/st/pr.yml <<'EOF'
services:
  a:
    image: busybox:1.37
    command: ["sleep", "infinity"]
  b:
    image: busybox:1.37
    command: ["sleep", "infinity"]
EOF
echo hallo > $REPO/st/gruss.txt
echo unverändert > $REPO/st/fest.txt
echo "Prüfstand" > $REPO/README.md
START=$(commit "erster Stand")

mkdir -p /srv/scd/conf
cat > /srv/scd/conf/config.yaml <<EOF
update_interval: $INTERVALL
auto_rotate: true
always_pull_containers: false
deploy_only_on_change: true
state_file: /data/state.json
repos_path: /data/repos
EOF
cat > /srv/scd/conf/repos.yaml <<'EOF'
stacks:
  url: http://git/git/stacks.git
EOF
cat > /srv/scd/conf/stacks.yaml <<'EOF'
app:
  repo: stacks
  branch: main
  compose_file: st/app.yml
pr:
  repo: stacks
  branch: main
  compose_file: st/pr.yml
  prune: true
EOF
docker service create -d -q --name swarm-cd --network scd -p 8080:8080 \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=bind,src=/srv/scd/conf,dst=/conf \
  --mount type=volume,src=scd_data,dst=/data \
  -e CONFIGS_PATH=/conf -e LOG_LEVEL=debug "$ABBILD" </dev/null >/dev/null

if warte 120 ausgerollt app "$START" && warte 60 ausgerollt pr "$START"; then
  echo "swarm-cd hat app und pr mit $START ausgerollt"
else
  echo "swarm-cd rollt nicht aus; Log:"; docker service logs --raw --tail 30 swarm-cd; exit 2
fi
warte 60 laeuft app_app
CHECKOUT=/var/lib/docker/volumes/scd_data/_data/repos/stacks

# --- 4: ohne Änderung kein stack deploy --------------------------------------------------------
log "4 · Commit ohne Stack-Änderung rollt nicht aus"
vorher=$(deploys app)
echo "anders" >> $REPO/README.md; REV=$(commit "nur README")
runde app; runde app; runde app
if [ "$(deploys app)" = "$vorher" ]; then
  ok "drei Runden nach $REV: deploys_total bleibt $vorher"
else
  nok "deploys_total $vorher → $(deploys app)"
fi
if docker service logs --raw --since 40s swarm-cd 2>&1 | grep -q 'stack unchanged since last deploy, skipping.*stack=app'; then
  ok "Log: 'stack unchanged since last deploy, skipping'"
else
  nok "Log zeigt kein Überspringen"
fi

# --- 1: Zurückschreiben verträgt den nächsten Pull ----------------------------------------------
log "1 · Pull nach dem Zurückschreiben der Compose-Datei"
if (cd $CHECKOUT && git status --porcelain | grep -q 'st/app.yml'); then
  echo "Checkout von swarm-cd: st/app.yml ist zurückgeschrieben (erwartet)"
fi
sed -i 's/STAND: "1"/STAND: "2"/' $REPO/st/app.yml
REV=$(commit "nebendienst: STAND=2, dieselbe Datei, die swarm-cd umgeschrieben hat")
if warte 60 ausgerollt app "$REV"; then
  ok "$REV ausgerollt, obwohl die Datei im Checkout verändert war"
else
  nok "$REV nicht ausgerollt"; docker service logs --raw --since 60s swarm-cd 2>&1 | grep -i error | tail -3
fi
if env_hat app_nebendienst STAND=2; then
  ok "nebendienst hat STAND=2"
else
  nok "nebendienst ohne STAND=2"
fi

# --- 2: Shepherds Abbild bleibt stehen ---------------------------------------------------------
log "2 · Abbild von Shepherd bleibt beim Ausrollen stehen"
alt=$(digest app_app)
docker build -q -t localhost:5000/app:latest /b/v2 >/dev/null && docker push -q localhost:5000/app:latest >/dev/null
docker service create -d -q --name shepherd --network host \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  -e SLEEP_TIME=10s -e FILTER_SERVICES=label=io.ssk.autodeploy -e WITH_INSECURE_REGISTRY=true \
  containrrr/shepherd:v1.8.1@sha256:b117c2394832e088932d5e1eebb8df6c1924f47d0fef31788cb310c0fe3bf7db </dev/null >/dev/null
if warte 120 digest_nicht app_app "$alt"; then
  neu=$(digest app_app); echo "Shepherd hat nachgezogen: $alt → $neu"
else
  neu=""; nok "Shepherd hat app_app nicht nachgezogen"
fi
docker service rm shepherd >/dev/null
sed -i 's#^    image: localhost:5000/app:latest#&\n    environment:\n      NEU: "1"#' $REPO/st/app.yml
REV=$(commit "app: Umgebung geändert")
if warte 60 ausgerollt app "$REV" && warte 30 env_hat app_app NEU=1; then
  if [ -n "$neu" ] && [ "$(digest app_app)" = "$neu" ]; then
    ok "$REV ausgerollt (NEU=1), Digest bleibt $neu"
  else
    nok "Digest nach dem Ausrollen: $(digest app_app), erwartet $neu"
  fi
else
  nok "$REV nicht ausgerollt"
fi

# --- 3: Configs rotieren -----------------------------------------------------------------------
log "3 · geänderte Config bekommt neuen Namen, unveränderte nicht"
fest_vorher=$(docker config ls --format '{{.Name}}' | grep '^app-fest-')
gruss_vorher=$(docker config ls --format '{{.Name}}' | grep '^app-gruss-' | tr '\n' ' ')
neben_vorher=$(aufgaben app_nebendienst)
echo "hallo zwei" > $REPO/st/gruss.txt
REV=$(commit "gruss geändert")
if warte 60 ausgerollt app "$REV" && warte 60 liest app_app /gruss.txt "hallo zwei"; then
  ok "app_app liest 'hallo zwei' (Config vorher: $gruss_vorher)"
else
  nok "neue Config nicht im Dienst"
fi
if [ "$(docker config ls --format '{{.Name}}' | grep '^app-fest-')" = "$fest_vorher" ] && [ "$(aufgaben app_nebendienst)" = "$neben_vorher" ]; then
  ok "unveränderte Config $fest_vorher bleibt, nebendienst nicht neu gestartet"
else
  nok "unveränderte Config oder nebendienst hat sich bewegt"
fi

# --- 5: Neustart von swarm-cd rollt nicht aus ---------------------------------------------------
log "5 · Neustart von swarm-cd rollt nichts aus (state_file)"
zeit() { sed -n "/\"$1\"/,/}/s/.*deployed_at\": \"\(.*\)\".*/\1/p" /var/lib/docker/volumes/scd_data/_data/state.json; }
vorher=$(zeit app)
alt_task=$(docker service ps swarm-cd -q --filter desired-state=running)
docker service update -q --force swarm-cd </dev/null >/dev/null
neu_task=$(docker service ps swarm-cd -q --filter desired-state=running)
warte 60 curl -sf localhost:8080/metrics
runde app; runde app
neu_log=$(docker service logs --raw "$neu_task" 2>&1)
if [ "$neu_task" != "$alt_task" ] && [ "$(zeit app)" = "$vorher" ] \
  && echo "$neu_log" | grep -q 'skipping.*stack=app' && ! echo "$neu_log" | grep -q 'deploying stack'; then
  ok "neue Task $neu_task: nur 'skipping', kein 'deploying stack'; deployed_at bleibt $vorher"
else
  nok "nach Neustart: deployed_at $vorher → $(zeit app); Log: $(echo "$neu_log" | grep -c 'deploying stack') × deploying"
fi
if ausgerollt app "$REV"; then ok "deployed_info nach Neustart weiter $REV (aus state_file)"; else nok "deployed_info nach Neustart verloren"; fi

# --- 6: Kennzahlen bei Fehler ------------------------------------------------------------------
log "6 · Kennzahlen: Fehler und Erholung"
cp $REPO/st/app.yml /tmp/app.yml.gut
echo "services: [kaputt" > $REPO/st/app.yml
commit "app.yml kaputt" >/dev/null
if warte 60 ist 'swarmcd_stack_failing{stack="app"}' 1; then
  ok "swarmcd_stack_failing{stack=app} = 1, failures_total = $(metrik 'swarmcd_stack_failures_total{stack="app"}')"
else
  nok "failing geht nicht auf 1"
fi
[ "$(metrik 'swarmcd_stack_failing{stack="pr"}')" = 0 ] && ok "pr unberührt: failing = 0" || nok "pr zeigt Fehler"
cp /tmp/app.yml.gut $REPO/st/app.yml
commit "app.yml repariert" >/dev/null
if warte 60 ist 'swarmcd_stack_failing{stack="app"}' 0; then
  ok "nach Reparatur failing = 0"
else
  nok "failing bleibt nach Reparatur"
fi

# --- 7: --prune je Stack -----------------------------------------------------------------------
log "7 · --prune nur, wo eingeschaltet"
sed -i '/^  b:/,$d' $REPO/st/pr.yml
sed -i '/^  weg:/,/^    command/d' $REPO/st/app.yml
REV=$(commit "b aus pr, weg aus app gestrichen")
warte 60 ausgerollt pr "$REV"; warte 60 ausgerollt app "$REV"
if ! docker service inspect pr_b >/dev/null 2>&1; then ok "pr (prune: true): pr_b entfernt"; else nok "pr_b läuft noch"; fi
if docker service inspect app_weg >/dev/null 2>&1; then ok "app (ohne prune): app_weg bleibt"; else nok "app_weg wurde entfernt"; fi

# --- Urteil ------------------------------------------------------------------------------------
log "Kennzahlen am Ende"
curl -sf localhost:8080/metrics | grep '^swarmcd_stack_' | sort
echo
if [ $FEHLER -eq 0 ]; then echo "URTEIL: BESTANDEN"; else echo "URTEIL: NICHT BESTANDEN ($FEHLER Punkte)"; fi
exit $FEHLER
