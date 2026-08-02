FROM docker.io/bitnami/minideb:trixie@sha256:8e4fbe9a70cd73a40612c1e708512576bd69d6fde98cca95776b8e854ae730e6

ARG DEBIAN_FRONTEND=noninteractive

RUN set -x \
    && apt-get -y update \
    && apt-get -y install wget python3-pip \
    && wget https://dl.k8s.io/release/v1.33.8/bin/linux/amd64/kubectl \
    && chmod +x kubectl \
    && mv ./kubectl /usr/local/bin/kubectl \
    && wget -qO /usr/share/keyrings/postgres.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/keyrings/postgres.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get -y update \
    && apt-get -y install \
        python3-boto3 \
        curl \
        duply \
        ca-certificates \
        gnupg \
        postgresql-client-16 \
    && apt-get clean -y

RUN chown -R 1001:1001 /tmp \
    && chown -R root:1001 /etc/ssl/certs/ca-certificates.crt \
    && chmod g+rw /etc/ssl/certs/ca-certificates.crt \
    && useradd -u 1001 -m nonrootuser
USER 1001
