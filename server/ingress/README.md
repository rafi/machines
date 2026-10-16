# ingress

nginx on the server: port 443 forwards SSH to the node and every TLS
connection, untouched and with a PROXY header, to the cluster
(`files/snippets/stream.nginx`); port 80 redirects to HTTPS.

Deploy: `just server apply <host> ingress`. The installer runs `nginx -t`
before reloading.
