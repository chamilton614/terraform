#!/bin/bash

# Set the Script Dir
SCRIPT_PATH=`readlink -f "$0"`
SCRIPT_DIR=`dirname "$SCRIPT_PATH"`

# Get the Callers Path
CPWD=$(pwd)
echo "CPWD = ${CPWD}"

# Clean up extracted files
# Remove ISO Tool Files  $SCRIPT_DIR/../../common/bin/mkisofs/mkisofs.exe $SCRIPT_DIR/../../common/bin/mkisofs $SCRIPT_DIR/../../common/bin
if [ -e $ISO_TOOL_BIN/$ISO_TOOL.exe ]
then
    # Remove mkisofs
    echo 'Removing ISO Tool Directory'
    rm -rf $ISO_TOOL_BIN
     # Remove all files except the zip files
    if [ -n "$(find $COMMON_BIN -type f -not -name '*.zip' -print -quit)" ]
    then
        echo 'Removing ISO Tool files except Zips'
        find $COMMON_BIN -type f -not -name '*.zip' -print0 | xargs -0 rm --
    fi
fi

# Delete Previous ISO files
if [ -e ${CPWD}/package/*.iso ]
then
    echo 'Removing Temp ISOs'
    rm -f ${CPWD}/package/*.iso
fi

# Cleanup Packer Cache
if [ -d ${CPWD}/packer_cache/ ]
then
    echo 'Removing Packer Cache'
    rm -rf ${CPWD}/packer_cache/
fi



