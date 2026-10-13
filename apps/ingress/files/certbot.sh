#!/usr/bin/env bash
set -xeuo pipefail

CERT_EMAIL="${CERT_DEFAULT_EMAIL}"

sudo certbot certonly --manual --preferred-challenges=dns --agree-tos \
	--email "$CERT_EMAIL" \
	--server https://acme-v02.api.letsencrypt.org/directory \
	-d ${SECRET_DOMAIN} -d '*.${SECRET_DOMAIN}'

# sites="$(sudo -- find /etc/nginx/sites-enabled/* -maxdepth 0 -type f -printf "%f\n")"
# for site in $sites; do
# 	sudo certbot run --nginx -n -m "$CERT_EMAIL" -d "${site}"
# 	# sudo certbot certonly --nginx -m ${CERT_DEFAULT_EMAIL} --domains ldap.${SECRET_DOMAIN}
# 	#	sudo chown -R root:www-data /etc/letsencrypt/{archive,live}/
# 	#	sudo chmod -R g+r /etc/letsencrypt/{archive,live}
# done
# # sudo certbot renew --nginx
