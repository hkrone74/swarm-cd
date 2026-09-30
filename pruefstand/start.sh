#!/bin/sh
# Wegwerf-Swarm (docker:dind) aufsetzen, swarm-cd aus diesem Checkout darin bauen und
# pruefen.sh laufen lassen. Braucht nur ein lokales Docker. Aufräumen nach Rückfrage.
#
#   pruefstand/start.sh            # baut den Arbeitsstand
#   pruefstand/start.sh <abbild>   # prüft ein fertiges Abbild, z. B. ghcr.io/m-adawi/swarm-cd:1.11.0
#
# Das Skript läuft innen losgelöst und schreibt in eine Datei; ein langer `docker exec` verliert
# hinter manchem Docker-Socket (Devcontainer) seine Ausgabe.
set -eu
NAME=scd-pruefstand
HIER=$(cd "$(dirname "$0")" && pwd)
QUELLE=$(dirname "$HIER")
DIND=docker:29-dind

if docker inspect $NAME >/dev/null 2>&1; then
  echo "$NAME läuft schon; erst entfernen: docker rm -f $NAME -v"; exit 1
fi
docker run -d --privileged --name $NAME --hostname $NAME $DIND >/dev/null
i=0; until docker exec $NAME docker info >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -lt 60 ] || { echo "dockerd im Prüfstand startet nicht"; exit 2; }; sleep 1
done
docker exec $NAME sh -c 'docker swarm init >/dev/null && apk add -q git curl'

innen() {  # innen <log> <befehl> — losgelöst ausführen, Log mitlesen, Rückgabewert liefern
  docker exec -d $NAME sh -c "($2) > /tmp/$1.log 2>&1; echo \$? > /tmp/$1.rc"
  zeile=0
  while :; do
    sleep 3
    docker exec $NAME sh -c "tail -n +$((zeile + 1)) /tmp/$1.log" 2>/dev/null
    zeile=$(docker exec $NAME sh -c "wc -l < /tmp/$1.log" 2>/dev/null || echo "$zeile")
    rc=$(docker exec $NAME cat /tmp/$1.rc 2>/dev/null) && break
  done
  docker exec $NAME sh -c "tail -n +$((zeile + 1)) /tmp/$1.log" 2>/dev/null
  return "$rc"
}

tar -C "$HIER" -cf - pruefen.sh | docker exec -i $NAME tar -xf - -C /
if [ $# -ge 1 ]; then
  ABBILD=$1
else
  echo "== Abbild aus $QUELLE bauen"
  tar -C "$QUELLE" --exclude=.git --exclude=ui/node_modules -cf - . \
    | docker exec -i $NAME sh -c 'mkdir -p /b/swarm-cd && tar -xf - -C /b/swarm-cd'
  innen bau 'cd /b/swarm-cd && docker build -q -t swarm-cd:pruefstand .'
  ABBILD=swarm-cd:pruefstand
fi

set +e
innen pruefen "sh /pruefen.sh $ABBILD"
rc=$?
set -e

antwort=n
if [ -t 0 ]; then printf '\nPrüfstand %s entfernen? [j/N] ' $NAME; read -r antwort; fi
case $antwort in
  j|J) docker rm -f -v $NAME >/dev/null && echo "entfernt" ;;
  *) echo "bleibt stehen: docker exec -it $NAME sh; entfernen mit docker rm -f -v $NAME" ;;
esac
exit $rc
