#!/bin/ash

set -e

default_route_ip=$(ip route | grep default | awk '{print $3}')
if [[ -z "$default_route_ip" ]]; then
	echo "No default route configured" >&2
	exit 1
fi

configs=`find /etc/wireguard -type f -printf "%f\n"`
if [[ -z "$configs" ]]; then
	echo "No configuration file found in /etc/wireguard" >&2
	exit 1
fi

config=`echo $configs | head -n 1`
interface="${config%.*}"

if [[ "$(cat /proc/sys/net/ipv4/conf/all/src_valid_mark)" != "1" ]]; then
	echo "sysctl net.ipv4.conf.all.src_valid_mark=1 is not set" >&2
	exit 1
fi

# The net.ipv4.conf.all.src_valid_mark sysctl is set when running the container, so don't have WireGuard also set it
sed -i "s:sysctl -q net.ipv4.conf.all.src_valid_mark=1:echo Skipping setting net.ipv4.conf.all.src_valid_mark:" /usr/bin/wg-quick

# Preserve Docker's DNS server before WireGuard overwrites it
docker_dns_servers=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}')
echo "Preserving Docker DNS servers: $docker_dns_servers" >&2

# Start WireGuard
wg-quick up $interface

# Restore Docker's DNS servers alongside WireGuard's DNS
if [[ ! -z "$docker_dns_servers" ]]; then
	echo "Restoring Docker DNS servers to /etc/resolv.conf" >&2
	# Backup current resolv.conf set by WireGuard
	cp /etc/resolv.conf /etc/resolv.conf.wg
	# Prepend Docker DNS servers so they are tried first for local resolution
	for dns in $docker_dns_servers; do
		if ! grep -q "nameserver $dns" /etc/resolv.conf; then
			sed -i "1i nameserver $dns" /etc/resolv.conf
		fi
	done
fi

# IPv4 kill switch: traffic must be either (1) to the WireGuard interface, (2) marked as a WireGuard packet, (3) to a local address, or (4) to the container network
container_ipv4_network="$(ip -o addr show dev eth0 | awk '$3 == "inet" {print $4}')"
container_ipv4_network_rule=$([ ! -z "$container_ipv4_network" ] && echo "! -d $container_ipv4_network" || echo "")
iptables -I OUTPUT ! -o $interface -m mark ! --mark $(wg show $interface fwmark) -m addrtype ! --dst-type LOCAL $container_ipv4_network_rule -j REJECT

# IPv6 kill switch: traffic must be either (1) to the WireGuard interface, (2) marked as a WireGuard packet, (3) to a local address, or (4) to the container network
container_ipv6_network="$(ip -o addr show dev eth0 | awk '$3 == "inet6" && $6 == "global" {print $4}')"
if [[ "$container_ipv6_network" ]]; then
	container_ipv6_network_rule=$([ ! -z "$container_ipv6_network" ] && echo "! -d $container_ipv6_network" || echo "")
	ip6tables -I OUTPUT ! -o $interface -m mark ! --mark $(wg show $interface fwmark) -m addrtype ! --dst-type LOCAL $container_ipv6_network_rule -j REJECT
else
	echo "IPv6 interface not found, skipping IPv6 kill switch" >&2
fi

# Allow traffic to RFC1918 private addresses and other local ranges to bypass the tunnel
# This enables Docker DNS (127.0.0.11) and communication with other containers on bridge networks
rfc_local_subnets=(
	"10.0.0.0/8"        # RFC1918 Class A
	"172.16.0.0/12"     # RFC1918 Class B
	"192.168.0.0/16"    # RFC1918 Class C
	"169.254.0.0/16"    # RFC3927 Link-local
	"127.0.0.0/8"       # Loopback (includes Docker DNS at 127.0.0.11)
)

for local_subnet in "${rfc_local_subnets[@]}"
do
	echo "Allowing traffic to local subnet ${local_subnet}" >&2
	# Add route to send traffic via default gateway instead of VPN
	ip route add $local_subnet via $default_route_ip || true
	# Allow traffic in iptables (insert at the beginning to take priority)
	iptables -I OUTPUT 1 -d $local_subnet -j ACCEPT
done

# IPv6 local addresses
ipv6_local_subnets=(
	"fc00::/7"          # RFC4193 Unique Local Addresses
	"fe80::/10"         # RFC4291 Link-local
	"::1/128"           # Loopback
)

for local_subnet in "${ipv6_local_subnets[@]}"
do
	echo "Allowing IPv6 traffic to local subnet ${local_subnet}" >&2
	ip -6 route add $local_subnet via $(ip -6 route | grep default | awk '{print $3}') dev eth0 2>/dev/null || true
	ip6tables -I OUTPUT 1 -d $local_subnet -j ACCEPT 2>/dev/null || true
done

# Allow traffic to local subnets specified by user
for local_subnet in ${LOCAL_SUBNETS//,/$IFS}
do
	echo "Allowing traffic to user-specified local subnet ${local_subnet}" >&2
	ip route add $local_subnet via $default_route_ip
	iptables -I OUTPUT -d $local_subnet -j ACCEPT
done

shutdown () {
	wg-quick down $interface
	exit 0
}

trap shutdown SIGTERM SIGINT SIGQUIT

sleep infinity &
wait $!
