# Чистая система с systemd — как свежий VPS. WireGuard, Python-окружение и прочее ставит сам установщик.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
# Зеркала иногда отваливаются — пусть apt повторяет попытки, в том числе при запусках установщика
# python3 нужен поддельному Telegram API, expect — сценариям с вопросами
RUN echo 'Acquire::Retries "5";' >/etc/apt/apt.conf.d/80-retries \
 && apt-get update \
 && apt-get install -y systemd systemd-sysv iproute2 procps python3 expect ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
# В Docker /etc/resolv.conf подмонтирован, и resolvconf на Debian падает, пытаясь заменить его
# ссылкой. На настоящем сервере такого нет, поэтому просто просим его не трогать файл
RUN echo "resolvconf resolvconf/linkify-resolvconf boolean false" | debconf-set-selections
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
