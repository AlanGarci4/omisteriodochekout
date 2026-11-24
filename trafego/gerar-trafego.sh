#!/bin/sh
# ABOUTME: Gera tráfego contínuo contra a loja com vários "clientes" em paralelo.
# ABOUTME: A concorrência no /checkout é o que esgota o pool de conexões do banco.

APP=${APP:-http://loja:8080}
CLIENTES=${CLIENTES:-8}

sorteio() {
  echo $(( $(od -An -N1 -tu1 /dev/urandom) % 100 ))
}

cliente() {
  while true; do
    n=$(sorteio)
    if [ "$n" -lt 25 ]; then
      curl -s -o /dev/null "$APP/"
    elif [ "$n" -lt 55 ]; then
      curl -s -o /dev/null "$APP/produtos"
    else
      curl -s -o /dev/null "$APP/checkout"
    fi
    sleep 0.1
  done
}

i=0
while [ "$i" -lt "$CLIENTES" ]; do
  cliente &
  i=$((i + 1))
done
wait
