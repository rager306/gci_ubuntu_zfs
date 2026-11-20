variable cpus {
  type    = number
  default = 4
}

variable memory {
  type    = number
  default = 4096
}

# At least same as original Ubuntu image
variable disk_size {
  type    = string
  default = "3.5G"
}

variable img_format {
  type    = string
  default = "qcow2"
}

variable output_directory {
  type    = string
  default = "./output"
}

# --- Contabo-specific values, see contabo.auto.pkrvars.hcl ---

variable "contabo_ipv4" {
  type        = string
  description = "Main IPv4 with prefix length, e.g. 203.0.113.10/24"
}

variable "contabo_ipv4_gateway" {
  type        = string
  description = "IPv4 default gateway"
}

variable "contabo_ipv6" {
  type        = string
  description = "Main IPv6 with prefix length, empty string for an IPv4-only instance"
  default     = ""
}

variable "contabo_ipv6_gateway" {
  type        = string
  description = "IPv6 default gateway, usually the link-local fe80::1"
  default     = "fe80::1"
}

variable "contabo_dns" {
  type        = list(string)
  description = "Resolver addresses"
}

variable "contabo_hostname" {
  type        = string
  description = "Hostname baked into the image"
}

variable "contabo_ssh_key" {
  type        = string
  description = "Public SSH key allowed to log in as root"
}

variable "contabo_root_password" {
  type        = string
  description = "Optional root password for the VNC console (SSH stays key-only); empty = keep locked"
  default     = ""
}

variable "contabo_arc_max_bytes" {
  type        = string
  description = "ZFS ARC limit in bytes (written to modprobe.d before update-initramfs)"
}

source "qemu" "ubuntu-24-contabo-zfs" {
  iso_url                   = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  iso_checksum              = "file:https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS"
  accelerator               = "kvm"
  cpus                      = var.cpus
  memory                    = var.memory
  disk_image                = true
  disk_size                 = "4G"
  boot_wait                 = "3s"
  # Main disk for ZFS root partition
  disk_additional_size      = [var.disk_size]
  disk_cache                = "unsafe"
  disk_discard              = "unmap"
  disk_detect_zeroes        = "unmap"
  format                    = var.img_format
  net_device                = "virtio-net"
  headless                  = true
  qemu_binary               = "qemu-system-x86_64"
  ssh_timeout               = "10m"
  cd_files                  = ["./cloud-init/*"]
  cd_label                  = "cidata"
  ssh_password              = "ubuntu"
  ssh_username              = "ubuntu"
  qemuargs                  = [["-serial", "stdio"]]
  output_directory          = var.output_directory
  vm_name                   = "${source.name}.${var.img_format}"
}

build {
  sources = ["source.qemu.ubuntu-24-contabo-zfs"]

	provisioner "file" {
		content = templatefile("files/contabo.conf.tpl", {
			ipv4     = var.contabo_ipv4
			ipv4_gw  = var.contabo_ipv4_gateway
			ipv6     = var.contabo_ipv6
			ipv6_gw  = var.contabo_ipv6_gateway
			dns      = join(", ", var.contabo_dns)
			hostname = var.contabo_hostname
			ssh_key  = var.contabo_ssh_key
			root_password = var.contabo_root_password
			arc_max  = var.contabo_arc_max_bytes
		})
		destination = "/tmp/contabo.conf"
	}

	provisioner "file" {
		source = "files/zfs-growpart-root.cfg"
		destination = "/tmp/zfs-growpart-root.cfg"
	}

	provisioner "file" {
		source = "scripts/chroot-bootstrap.sh"
		destination = "/tmp/chroot-bootstrap.sh"
	}

  provisioner "shell" {
    scripts = [
      "scripts/prepare-zfs-root.sh",
    ]
  }
}
