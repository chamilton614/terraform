#https://www.virtjunkie.com/vmware-provisioning-using-hashicorp-terraform/
#https://github.com/jonhowe/Virtjunkie.com/tree/master/Terraform

#The variables are all defined in the variables.tf file. The values assigned to the variables are set in the tfvars file

provider "vsphere" {
  #https://www.terraform.io/docs/providers/vsphere/index.html
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

data "vsphere_datacenter" "dc" {
  #https://www.terraform.io/docs/providers/vsphere/d/datacenter.html
  name = var.datacenter
}

data "vsphere_datastore" "datastore" {
  #https://www.terraform.io/docs/providers/vsphere/d/datastore.html
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  #https://www.terraform.io/docs/providers/vsphere/d/compute_cluster.html
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  #https://www.terraform.io/docs/providers/vsphere/d/network.html
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  #https://www.terraform.io/docs/providers/vsphere/d/virtual_machine.html
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "vm" {
  #https://www.terraform.io/docs/providers/vsphere/r/virtual_machine.html
  name             = var.vm_name
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id

  num_cpus = var.vcpu_count
  memory   = var.memory
  guest_id = data.vsphere_virtual_machine.template.guest_id

  scsi_type = data.vsphere_virtual_machine.template.scsi_type

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  wait_for_guest_net_timeout = 10

  disk {
    label            = "disk0"
    size             = data.vsphere_virtual_machine.template.disks.0.size
    #eagerly_scrub    = data.vsphere_virtual_machine.template.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    #Customize section appears to have issues in RHEL8 changing name and using DHCP from Packer VM template
    #Commented out section below to fix the issue, so computer name will need to be handled by a separate script.
    customize {
      #https://www.terraform.io/docs/providers/vsphere/r/virtual_machine.html#linux-customization-options
      linux_options {
        host_name = var.vm_name
        domain    = var.domain_name
      }

      #This uses DHCP. To switch to Static IP address, comment out this section and uncomment the section below.
      network_interface {}

      #This uses Static IP. To switch to DHCP address, comment out this section and uncomment the section above.
      /*network_interface {
        ipv4_address = var.vm_ip
        ipv4_netmask = var.vm_cidr
      }
      dns_server_list = [var.name_servers]
      ipv4_gateway = var.default_gw
      */
  #
    }

  }
}
