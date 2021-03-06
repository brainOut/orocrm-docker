#!/bin/bash

export LETSENCRYPT=${LETSENCRYPT:-0}

set -euo pipefail

export SSL_KEY=/certs/ssl.key
export SSL_CRT=/certs/ssl.crt

! [ "${LETSENCRYPT}" == '1' ] \
	|| [ -n "${DOMAIN+x}" ] \
	|| { echo "Letsencrypt activated, but no domain set."; exit 1; }

export DOMAIN=${DOMAIN:-$(hostname --fqdn)}

sed -i "
    s/database_host:.*/database_host: ${ORO_DB_HOST:-null}/;
    s/database_port:.*/database_port: ${ORO_DB_PORT:-null}/;
    s/database_name:.*/database_name: ${ORO_DB_NAME:-null}/;
    s/database_user:.*/database_user: ${ORO_DB_USER:-null}/;
    s/database_password:.*/database_password: ${ORO_DB_PASS:-null}/;
    s/locale:.*/locale: ${ORO_LOCALE:-en}/;
    s/installed:.*/installed: ${ORO_INSTALLED:-null}/;
    s/secret:.*/secret: ${ORO_SECRET:-null}/;
" ${INSTALLDIR}/src/app/config/parameters.yml

# force remove old configuration
# a container restart may still contain it
rm -f /etc/nginx/conf.d/*
envsubst < ${INSTALLDIR}/nginx.template.http \
         > /etc/nginx/conf.d/http.conf

supervisord -nc ${INSTALLDIR}/supervisord.conf &
trap "supervisorctl shutdown && wait" SIGTERM

# crawl letsencrypt certs
if [ "${LETSENCRYPT}" == '1' ]; then
	mkdir -p /run/le-webroot

	if ! [ -e "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
		# nginx may not be fully initialized yet
		until [ -e '/run/nginx.pid' ]; do sleep 1; done
		certbot -q -c ${INSTALLDIR}/letsencrypt.ini certonly \
			--agree-tos --register-unsafely-without-email \
			-d "${DOMAIN}"
	else
		echo "Letsencrypt certificate is available"
	fi

	export SSL_CRT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
	export SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
fi

# enable HTTPS
if   [ -r "${SSL_CRT}" ] \
	&& [ -r "${SSL_KEY}" ]; then
	envsubst < ${INSTALLDIR}/nginx.template.https \
	         > /etc/nginx/conf.d/https.conf

	# nginx may not be fully initialized yet
	until [ -e '/run/nginx.pid'  ]; do sleep 1; done
	nginx -s reload
fi

if [ "${ORO_INSTALLED}" != "null" ]; then
	oro-console fos:js-routing:dump
	oro-console oro:localization:dump
	oro-console oro:assets:install
	oro-console assetic:dump
	oro-console oro:requirejs:build
	oro-console cache:clear
	oro-console oro:translation:dump
	oro-console oro:language:update --language=${ORO_LOCALE:-en}
fi

wait
