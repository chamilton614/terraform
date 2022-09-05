# Terraform 

## RHEL8
This will create a RHEL 8 VMWare VM from a VM Template using Terraform
Requirements:
 - Terraform installed
 - This Repo Cloned locally
 - User Credentials to vSphere
 - VM Network to use
 - Temporary IP Information - ip, subnet mask, gateway

1. Clone this [Repo](https://gitlab.aimspecialtyhealth.com/CHamilton/tf-vcenter-vms.git)
2. Browse to the terraform/rhel8 directory
3. Update variables.auto.tfvars
4. Run terraform_build.sh