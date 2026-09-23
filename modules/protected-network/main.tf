locals {
  common_labels = merge(
    var.labels,
    {
      "app.kubernetes.io/managed-by"    = "terraform"
      "platform.harvester.io/protected" = "true"
    }
  )
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
