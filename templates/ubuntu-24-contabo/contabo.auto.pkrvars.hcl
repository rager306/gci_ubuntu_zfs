# Contabo-specific values baked into the image.
# Edit, push — GitHub Actions rebuilds the image automatically.
# Take the network values from the Contabo panel (Server details -> IP data).

# Main IPv4 with prefix length
contabo_ipv4 = "164.68.106.228/24"
contabo_ipv4_gateway = "164.68.106.1"

# Main IPv6 with prefix length; set to "" for an IPv4-only instance
contabo_ipv6 = "2a02:c207:2292:9903::1/64"
# Contabo uses a link-local gateway, hence "scope: link" in the netplan
contabo_ipv6_gateway = "fe80::1"

contabo_dns = ["8.8.8.8", "1.1.1.1"]

contabo_hostname = "vmi2929903"

# Public key allowed to log in as root (single line, key type + key + comment)
contabo_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJt9f8RyvEMGx2ZmzFrNs80a1FJ/Wx3QEod2D69A1n3P lan\\acc16@acc16"

# ZFS ARC limit in bytes (12 GiB on a 48 GiB RAM host)
contabo_arc_max_bytes = "12884901888"
