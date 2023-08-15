####################################################################################################################################
## Nagios Core Builder
####################################################################################################################################
FROM ghcr.io/linuxserver/baseimage-debian:bookworm as core-builder
ARG NAGIOS_VERSION=4.4.14

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y apache2 apache2-utils autoconf bc build-essential dc gawk gcc gettext libc6 libgd-dev libmcrypt-dev libnet-snmp-perl libssl-dev make openssl php procps snmp unzip wget

WORKDIR /code

RUN groupadd -g 5001 nagios \
 && useradd -ms /bin/bash -u 5001 -g 5001 nagios \
 && mkdir -p /app /app/var/rw /config /data /data/log/archives \
 && chown -R nagios: /code /app /config /data

ADD https://github.com/NagiosEnterprises/nagioscore/archive/nagios-${NAGIOS_VERSION}.tar.gz /code/nagioscore.tar.gz
# COPY nagios-${NAGIOS_VERSION}.tar.gz /code/nagioscore.tar.gz
RUN tar xvf nagioscore.tar.gz --strip-components=1 \
 && chown -R nagios: /code /app /config /data

# USER nagios

RUN htpasswd -bc /config/htpasswd.users nagiosadmin nagiosadmin

RUN ./configure --prefix=/app --exec-prefix=/app --sysconfdir=/config --enable-event-broker --with-command-user=nagios --with-command-group=nagios --with-nagios-user=nagios --with-nagios-group=nagios

RUN make all install install-config install-commandmode install-html install-webconf

####################################################################################################################################
## Plugin Builder
####################################################################################################################################
FROM ghcr.io/linuxserver/baseimage-debian:bookworm as plugin-builder
ARG PLUGIN_VERSION=2.4.6

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y apache2 apache2-utils autoconf bc build-essential dc gawk gcc gettext libc6 libgd-dev libmcrypt-dev libnet-snmp-perl libssl-dev make openssl php procps snmp unzip wget

WORKDIR /code

RUN groupadd -g 5001 nagios \
 && useradd -ms /bin/bash -u 5001 -g 5001 nagios \
 && mkdir -p /app /app/var/rw /config /data /data/log/archives \
 && chown -R nagios: /code /app /config /data

ADD https://github.com/nagios-plugins/nagios-plugins/archive/release-${PLUGIN_VERSION}.tar.gz /code/nagios-plugins.tar.gz
# COPY release-${PLUGIN_VERSION}.tar.gz /code/nagios-plugins.tar.gz
RUN tar xvf nagios-plugins.tar.gz --strip-components=1 \
 && chown -R nagios: /code /app /config /data

# USER nagios

RUN ./tools/setup

RUN ./configure --prefix=/app --exec-prefix=/app --sysconfdir=/config --with-nagios-user=nagios --with-nagios-group=nagios

RUN make install

####################################################################################################################################
## Main
####################################################################################################################################
FROM ghcr.io/linuxserver/baseimage-debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y wget unzip openssl procps socat apache2 apache2-utils php iputils-ping

RUN groupadd -g 5001 nagios \
 && useradd -ms /bin/bash -u 5001 -g 5001 nagios \
 && gpasswd -a www-data nagios

VOLUME [ "/config", "/data" ]

COPY --from=core-builder --chown=nagios:nagios /app /app
COPY --from=plugin-builder --chown=nagios:nagios /app /app
COPY --from=core-builder --chown=nagios:nagios /config /config
COPY --from=core-builder --chown=nagios:nagios /data /data
COPY --from=core-builder /etc/apache2/sites-available/ /etc/apache2/sites-available/
RUN ln -s ../sites-available/nagios.conf /etc/apache2/sites-enabled/nagios.conf \
 && chown root /app/libexec/* \
 && chmod ug+s /app/libexec/*

RUN sed -ri -e 's!^log_file=.*!log_file=/data/log/nagios.log!g' /config/nagios.cfg \
 && sed -ri -e 's!^log_archive_path=.*!log_archive_path=/data/log/archives!g' /config/nagios.cfg \
 && sed -ri -e 's!^use_syslog=.*!use_syslog=0!g' /config/nagios.cfg \
 && sed -ri -e 's!^object_cache_file=.*!object_cache_file=/data/objects.cache!g' /config/nagios.cfg \
 && sed -ri -e 's!^precached_object_file=.*!precached_object_file=/data/objects.precache!g' /config/nagios.cfg \
 && sed -ri -e 's!^status_file=.*!status_file=/data/status.dat!g' /config/nagios.cfg \
 && sed -ri -e 's!^state_retention_file=.*!state_retention_file=/data/retention.dat!g' /config/nagios.cfg

ENV APACHE_CONFDIR /etc/apache2
ENV APACHE_ENVVARS $APACHE_CONFDIR/envvars

RUN set -eux; \
# generically convert lines like
#   export APACHE_RUN_USER=www-data
# into
#   : ${APACHE_RUN_USER:=www-data}
#   export APACHE_RUN_USER
# so that they can be overridden at runtime ("-e APACHE_RUN_USER=...")
	sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS"; \
	\
# setup directories and permissions
	. "$APACHE_ENVVARS"; \
	for dir in \
		"$APACHE_LOCK_DIR" \
		"$APACHE_RUN_DIR" \
		"$APACHE_LOG_DIR" \
	; do \
		rm -rvf "$dir"; \
		mkdir -p "$dir"; \
		chown "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir"; \
# allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
		chmod 1777 "$dir"; \
	done; \
	\
# delete the "index.html" that installing Apache drops in here
	rm -rvf /var/www/html/*; \
	\
# logs should go to stdout / stderr
	ln -sfT /dev/stderr "$APACHE_LOG_DIR/error.log"; \
	ln -sfT /dev/stdout "$APACHE_LOG_DIR/access.log"; \
	ln -sfT /dev/stdout "$APACHE_LOG_DIR/other_vhosts_access.log"; \
	chown -R --no-dereference "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$APACHE_LOG_DIR"

RUN a2enmod rewrite \
 && a2enmod cgi \
 && rm /etc/apache2/conf-enabled/serve-cgi-bin.conf \
 && echo "<html></html>" | tee /var/www/html/index.html

WORKDIR /app

ENV PATH /app/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

EXPOSE 80

COPY root/ /

