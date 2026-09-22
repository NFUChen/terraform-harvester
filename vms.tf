data "harvester_image" "ubuntu_24_04_noble_cloud" {
  name      = "ubuntu-24-04-noble-server-cloudimg-amd64"
  namespace = "harvester-public"
}

# module "web" {
#   source = "./modules/virtual-machine"

#   name_prefix    = "web"
#   instance_count = 3
#   namespace      = "default"

#   cpu    = 2
#   memory = "4Gi"

#   root_image     = data.harvester_image.ubuntu_24_04_noble_cloud.id
#   root_disk_size = "40Gi"

#   network_interfaces = [
#     {
#       name           = "nic-1"
#       wait_for_lease = true
#     }
#   ]

#   cloudinit = {
#     user_data = <<-YAML
#       #cloud-config
#       package_update: true
#       packages:
#         - qemu-guest-agent
#       runcmd:
#         - systemctl enable --now qemu-guest-agent
#       chpasswd:
#         list: |
#             ubuntu:YourPasswordHere
#     YAML
#   }

#   tags = {
#     "ssh-user" = "ubuntu"
#   }
# }

# output "web_instance_names" {
#   value = module.web.instance_names
# }

# output "web_primary_ip_addresses" {
#   value = module.web.primary_ip_addresses
# }
