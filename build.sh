#!/bin/bash

RAID_DEPS=("8.05.06_MegaCLI.zip" "SAS2IRCU_P12.zip")

bc_needs_build() {
    for f in "${RAID_DEPS[@]}"; do
        [[ -f $BC_CACHE/files/dell_raid/tools/$f ]] || exit 0
    done
    exit 1
}

bc_build() {
    exec >&2
    echo "Please download:"
    echo "http://www.lsi.com/downloads/Public/Host%20Bus%20Adapters/Host%20Bus%20Adapters%20Common%20Files/SAS_SATA_6G_P12/SAS2IRCU_P12.zip"
    echo "http://www.lsi.com/downloads/Public/MegaRAID%20Common%20Files/8.05.06_MegaCLI.zip"
    echo
    echo "into $BC_CACHE/files/dell_raid/tools/"
    exit 1
}
