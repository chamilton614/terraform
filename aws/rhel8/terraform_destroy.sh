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
# Check AWS_ACCESS_KEY_ID
if [ -z "${AWS_ACCESS_KEY_ID}" ] 
then
    echo "Enter the AWS_ACCESS_KEY_ID"
    read AWS_ACCESS_KEY_ID
    export AWS_ACCESS_KEY_ID
    echo ""
fi
# Check AWS_SECRET_ACCESS_KEY
if [ -z "${AWS_SECRET_ACCESS_KEY}" ] 
then
    echo "Enter the AWS_SECRET_ACCESS_KEY"
    read AWS_SECRET_ACCESS_KEY
    export AWS_SECRET_ACCESS_KEY
    echo ""
fi

# Start the Terraform Destroy Process
terraform destroy -auto-approve

# Cleanup
#${COMMON_SCRIPTS}/cleanup.sh