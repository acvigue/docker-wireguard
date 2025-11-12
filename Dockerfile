FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
	findutils openresolv iptables ip6tables iproute2 wireguard-tools curl

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
	CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
