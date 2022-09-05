#!/bin/bash

# This script is used to start the Terraform build process
clear

# Export the variables to make them available to scripts
set -a

# Set the Script Dir
SCRIPT_PATH=`readlink -f "$0"`
SCRIPT_DIR=`dirname "$SCRIPT_PATH"`
#echo "SCRIPT_DIR = $SCRIPT_DIR"

# Set the Common Bin Dir
COMMON_BIN=${SCRIPT_DIR}/../../common/bin

# Set the Common Scripts Dir
COMMON_SCRIPTS=${SCRIPT_DIR}/../../common/scripts

# Set the Environment
source ${COMMON_SCRIPTS}/set_env.sh

# Setup the ISO Tool
$COMMON_SCRIPTS/setup_iso_tool.sh

# Set the ISO Tool Bin Dir
ISO_TOOL_BIN=$COMMON_BIN/$ISO_TOOL

# Setup the Path to Terraform and MKISOFS
export PATH=$PATH:${TERRAFORM_PATH}:${COMMON_BIN}:${ISO_TOOL_BIN}
#echo "PATH = $PATH"

# Check Environment Variables
# Check vSphere Username
if [ -z "${TF_VAR_vsphere_user}" ] 
then
    echo "Enter vSphere Username - e.g. domain\\\username"
    read TF_VAR_vsphere_user
    export TF_VAR_vsphere_user
    echo ""
fi
# Check vSphere Password
if [ -z "${TF_VAR_vsphere_password}" ] 
then
    echo "Enter vSphere Password - e.g. if \\ exists use \\\\"
    read TF_VAR_vsphere_password
    export TF_VAR_vsphere_password
    echo ""
fi

# Start the Terraform Init Process
terraform init

# Start the Terraform Plan Process
terraform plan

# Start the Terraform Apply Process
terraform apply -auto-approve

# Cleanup
#${COMMON_SCRIPTS}/cleanup.sh