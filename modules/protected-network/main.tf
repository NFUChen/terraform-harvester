locals {
  common_labels = merge(
    var.labels,
    {
      "app.kubernetes.io/managed-by"    = "terraform"
      "platform.harvester.io/protected" = "true"
    }
  )

  dhcp_services = {
    for name, network in var.networks : name => network
    if network.services != null && network.services.enable_dhcp
  }

  nat_services = {
    for name, network in var.networks : name => network
    if network.services != null && network.services.enable_nat
  }

  default_dhcp_image = "docker.io/jpillora/dnsmasq@sha256:34132cc95b1b8c124d2402b0da53995e68d2d46b8d0020d63cac9ecccb0e8008"
  default_nat_image  = "docker.io/nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b"
}

# This fails fast at plan time if the ClusterNetwork does not exist. The
# provider still performs its own hardcoded one-minute Ready-condition wait
# during create/update; this module intentionally does not manage the
# ClusterNetwork or its node-level VLANConfigs.
data "harvester_clusternetwork" "this" {
  name = var.cluster_network_name
}

resource "harvester_network" "this" {
  for_each = var.networks

  name      = each.key
  namespace = var.namespace

  vlan_id              = each.value.vlan_id
  cluster_network_name = data.harvester_clusternetwork.this.name

  route_mode           = each.value.route.mode
  route_dhcp_server_ip = each.value.route.dhcp_server_ip
  route_cidr           = each.value.route.cidr
  route_gateway        = each.value.route.gateway

  description = each.value.description

  labels = merge(
    each.value.labels,
    local.common_labels,
    {
      "app.kubernetes.io/instance" = each.key
    }
  )

  tags = merge(var.tags, each.value.tags)

  timeouts {
    create = var.timeouts.create
    read   = var.timeouts.read
    update = var.timeouts.update
    delete = var.timeouts.delete
  }

  lifecycle {
    # Deleting/replacing a NAD does not delete VM resources, but any VM Pod
    # recreated while the NAD is absent cannot attach the interface. A same-
    # name replacement with different topology can also split running and
    # restarted VMs across VLANs.
    prevent_destroy = true

    # Harvester's controller mutates labels and auto-route fields after create.
    # Provider 1.9.0 then imports those values into Optional+Computed state and
    # feeds them back into any later Update, where route_mode=auto plus the
    # computed CIDR/gateway fails constructor validation. Treat production
    # NADs as create-once objects: every config/controller drift is ignored,
    # and any intended change is a blue/green migration to a new network name.
    ignore_changes = all
  }
}

module "dhcp" {
  source   = "../vlan-dhcp"
  for_each = local.dhcp_services

  network_id = harvester_network.this[each.key].id
  cidr       = each.value.services.cidr

  pool_start_offset = each.value.services.pool_start_offset
  pool_end_offset   = each.value.services.pool_end_offset
  dns_servers       = each.value.services.dns_servers
  lease_time        = each.value.services.lease_time
  node_selector     = each.value.services.node_selector
  image             = coalesce(each.value.services.dhcp_image, local.default_dhcp_image)
}

module "nat" {
  source   = "../vlan-nat-gateway"
  for_each = local.nat_services

  network_id = harvester_network.this[each.key].id
  cidr       = each.value.services.cidr

  node_selector = each.value.services.node_selector
  image         = coalesce(each.value.services.nat_image, local.default_nat_image)
}
