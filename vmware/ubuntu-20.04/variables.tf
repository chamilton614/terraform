#https://www.virtjunkie.com/vmware-provisioning-using-hashicorp-terraform/
#https://github.com/jonhowe/Virtjunkie.com/tree/master/Terraform
variable "vsphere_server" {
  description = "vsphere server for the environment - EXAMPLE: vcenter01.hosted.local"
}

variable "vsphere_user" {
    description = "vsphere server for the environment - EXAMPLE: vsphereuser"
    sensitive = true
}

variable "vsphere_password" {
    description = "vsphere server password for the environment"
    sensitive = true
}

variable "datacenter" { 
    description = "Datacenter name in vCenter"
}

variable "datastore" { 
    description = "datastore name in vCenter"
}

variable "cluster" { 
    description = "Cluster name in vCenter"
}

variable "network" { 
    description = "Network the VM will use"
}

variable "domain_name" { 
    description = "Domain Search name"
}
variable "default_gw" { 
    description = "Default Gateway"
}

variable "template_name" { 
    description = "VMware Template Name"
}

variable "vm_name" { 
    description = "New VM Name"

}

variable "vm_ip" { 
    description = "IP Address to assign to VM"
}

variable "vm_cidr" { 
    description = "CIDR Block for VM"
}

variable "name_servers" {
    description = "DNS Name Servers"
}

variable "vcpu_count" { 
    description = "How many vCPUs do you want?"
}

variable "memory" { 
    description = "RAM in MB"
}