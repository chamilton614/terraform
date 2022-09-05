#!/bin/bash

# This script is used to create iso files
#clear

# Set the Script Dir
SCRIPT_PATH=`readlink -f "$0"`
SCRIPT_DIR=`dirname "$SCRIPT_PATH"`
#echo "SCRIPT_DIR = $SCRIPT_DIR"

# Set the ISO Bin Dir
ISO_TOOL_DIR=$SCRIPT_DIR/../bin/$ISO_TOOL
#echo "ISO_TOOL_DIR = $ISO_TOOL_DIR"

# Set the ISO Tool - mkisofs out of others seemed to be the only to work
TOOL=$SCRIPT_DIR/../bin/$ISO_TOOL_FILE
# Set the ISO Tool as executable
chmod +x $TOOL
# Unzip ISO Tool
unzip -q -j -o $TOOL -d $ISO_TOOL_DIR

# Generate ISO for Scripts
#cdbxpcmd --burn-data -file:"./package/scripts/ks.cfg" -iso:"./package/ks.iso" -format:iso
# cdbxpcmd --burn-data -folder:"./package/scripts" -iso:"./ks.iso" -format:iso
# folder2iso "<input>" "<output iso>" "LabelName" 0 0 0 "UTF-8"

# Separator
echo "========================="
