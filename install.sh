#!/bin/bash

# Install Ubuntu 18.04 onto a ZFS ROOT.  Only single disk or mirrored
# configurations are supported (multiple VDEV's are not supported).  MBR
# booting is no supported, the system must boot in UEFI mode.

DEBUG=1
LOGFILE=zfs_root.log


RESULTS="$(mktemp)"
BACKTITLE="Installing Ubuntu 18.04 on ZFS ROOT pool..."
RPOOL="rpool"
DISKS=()
FILESYSTEMS=()
USERNAME="admin"
SWAP=""
CHANGES=0


function finish {
    clear
    rm "$RESULTS"
}
trap finish EXIT


function ctrl_c {
    cancel
    finish
}
trap ctrl_c INT


function cmd {
    echo "$@" >>"$LOGFILE"
    if [ "$DEBUG" -eq 0 ]; then
        $(echo "$@") >>"$LOGFILE" 2>&1 
        echo "" >> "$LOGFILE"
    fi
}


function append {
    echo "echo -e \"$1\" > \"$2\"" >>"$LOGFILE"
    if [ "$DEBUG" -eq 0 ]; then
        echo -e "$1" >> "$2"
    fi
}


function info() {
    dialog \
        --backtitle "$BACKTITLE"  \
        --infobox "$1" 3 70;
}


function cancel {
    if [[ "$CHANGES" == 0 ]]; then
        msg="No changes made to disk."
    else
        msg="Disk is in an unknown state."
    fi
    dialog \
        --title "Installation Canceled" \
        --backtitle "$BACKTITLE"  \
        --msgbox "$msg" 6 40
    exit 0;
}


function init {
    info "Installing dependencies..."
    cmd apt-add-repository universe
    cmd apt update
    cmd apt install --yes gdisk zfs-initramfs mdadm dialog dosfstools grub-pc
}


function get_username() {
    msg="Specify username of the first user (UID=1000):"
    dialog \
        --title "Username" \
        --backtitle "$BACKTITLE"  \
        --inputbox "$msg" 11 70 "$USERNAME" 2>"$RESULTS"
    EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        cancel
    fi
    USERNAME="$(<"$RESULTS")"
    echo "$RPOOL"
    while [[ ("$USERNAME" == "") || ("$USERNAME" =~ [^a-zA-Z0-9]) ]]; do
        msg="Usernames must consists only of alphanumeric strings " \
        msg+="without spaces.\\n\\n"
        msg+="Specify username of the first user (UID=1000):"
        dialog \
            --title "Username" \
            --backtitle "$BACKTITLE"  \
            --inputbox "$msg" 11 70 "$USERNAME" 2>"$RESULTS"
        EXIT=$?
        if [ "$EXIT" -ne 0 ]; then
            cancel
        fi
        USERNAME=$(<"$RESULTS")
    done
}


function get_rpool_name() {
    msg="While \"rpool\" is standard among automated installation's you may
    whish to use the hostname instead.\\n\\n"
    msg+="Specify the name of the ROOT ZFS pool:"
    dialog \
        --title "ROOT Pool Name" \
        --backtitle "$BACKTITLE"  \
        --inputbox "$msg" 11 70 "$RPOOL" 2>"$RESULTS"
    EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        cancel
    fi
    RPOOL="$(<"$RESULTS")"
    echo "$RPOOL"
    while [[ ("$RPOOL" == "") || ("$RPOOL" =~ [^a-zA-Z0-9]) ]]; do
        msg="Pool names must consists only of alphanumeric strings " \
        msg+="without spaces.\\n\\n"
        msg+="Specify the name of the ROOT ZFS pool:"
        dialog \
            --title "ROOT Pool Name" \
            --backtitle "$BACKTITLE"  \
            --inputbox "$msg" 11 70 "$RPOOL" 2>"$RESULTS"
        EXIT=$?
        if [ "$EXIT" -ne 0 ]; then
            cancel
        fi
        RPOOL=$(<"$RESULTS")
    done
}


get_filesystems() {
    msg="Select which directories you want separate ZFS filesystems for."
    dialog \
        --title "Optional Filesystems" \
        --backtitle "$BACKTITLE" \
        --separate-output \
        --checklist "$msg" \
        17 60 9 \
        "local" "/usr/local" ON \
        "opt" "/opt" ON \
        "srv" "/var/srv" OFF \
        "games" "/var/games" OFF \
        "mongodb" "/var/lib/mongodb" OFF \
        "mysql" "/var/lib/mysql" OFF \
        "postgres" "/var/lib/postgres" OFF \
        "nfs" "/var/lib/nfs" OFF \
        "mail" "/var/mail" OFF \
        2>"$RESULTS"
    EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        cancel
    fi
    mapfile -t FILESYSTEMS < "$RESULTS"
}


function list_disks() {
    lsblk --noheadings --output TYPE,NAME | awk '$1 == "disk"{print $2}'
}


function disk_id() {
    find /dev/disk/by-id -name '*' \
        -exec echo -n {}" " \; -exec readlink -f {} \; | \
        awk -v sdx="$1" \
        '($2 ~ sdx"$") && ($1 !~ "wwn|eui|ieee"){print $1}'
    }


function disk_size() {
    lsblk "/dev/$1" --noheadings --output SIZE | head -n 1
}


function get_rpool_disks() {
    DISKS=()
    for sdx in $(list_disks); do
        id=$(disk_id "$sdx")
        DISKS+=("$sdx")
        DISKS+=("$(printf "%3s  %6s  %s" "$sdx" "$(disk_size "$sdx")" "$id")")
        DISKS+=(OFF)
    done
    msg="Select disks to use for the root pool.  "
    msg+="Only single disk and mirrored configurations are supported at " \
    msg+="this time.  ALL DATA on chosen disks will be LOST."
    dialog \
        --title "Select Root Drives" \
        --backtitle "$BACKTITLE" \
        --notags --separate-output \
        --checklist "$msg" \
        $((8+${#DISKS[@]})) 90 ${#DISKS[@]} "${DISKS[@]}" 2>"$RESULTS"
    EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        cancel
    fi
    mapfile -t DISKS < "$RESULTS"
    if [ "${#DISKS[@]}" -eq 0 ]; then
        msg="No disks where selected.  "
        msg+="Would you like to cancel the installation?"
        dialog \
            --title "No Drives Selected" \
            --backtitle "$BACKTITLE"  \
            --yesno "$msg" 7 60
        EXIT=$?
        if [ "$EXIT" -eq 1 ]; then
            get_rpool_disks
            return 0
        else
            cancel
        fi
    fi
}


function prepare_disk() {
    cmd mdadm --zero-superblock --force "$1"
    cmd sgdisk --zap-all "$1"
    cmd sgdisk -n3:1M:+512M -t3:EF00 "$1"
    cmd sgdisk -n1:0:0 -t1:BF01 "$1"
}


function create_rpool() {
    if [ "${#DISKS[@]}" -eq 1 ]; then
        local sdx=${DISKS[0]}
        local id=$(disk_id "$sdx")
        local size=$(disk_size "$sdx")
        msg="WARNING: All data will be lost on disk:\\n\\n"
        msg+="    "
        msg+=$(printf "%3s  %6s  %s" "$sdx" "$(disk_size "$sdx")" "$id")
        msg+="\\n\\n"
        msg+="WARNING: Single disk layouts do not have any redundancy "
        msg+="against disk failures.\\n\\n"
        msg+="Do you wish to proceed?"
        if dialog \
            --title "WARNING: DATA LOSS" \
            --backtitle "$BACKTITLE"  \
            --defaultno \
            --yesno "$msg" 12 70;
        then
            CHANGES=1
            prepare_disk "$id"
            cmd sleep 1
            cmd zpool create -f -o ashift=12 \
              -O atime=off -O canmount=off -O compression=lz4 \
              -O normalization=formD -O xattr=sa -O mountpoint=/ -R /mnt \
              "$RPOOL" "$id-part1"
        else
            cancel
        fi
    else
        msg="WARNING: All data will be lost on disks:\\n\\n"
        for sdx in "${DISKS[@]}"; do
            local id=$(disk_id "$sdx")
            local size=$(disk_size "$sdx")
            msg+="    "
            msg+=$(printf "%3s  %6s  %s" "$sdx" "$(disk_size "$sdx")" "$id")
            msg+="\\n"
        done
        msg+="\\n"
        msg+="Do you wish to proceed?"
        if dialog \
            --title "WARNING: DATA LOSS" \
            --backtitle "$BACKTITLE"  \
            --defaultno \
            --yesno "$msg" $((8+${#DISKS[@]})) 70;
        then
            CHANGES=1
            info "Partitioning drives..."
            local partitions=()
            for disk in "${DISKS[@]}"; do
                local id=$(disk_id "$sdx")
                prepare_disk "$id"
                partitions+=("$id""-part1")
            done
            cmd sleep 5
            info "Creating ZFS pool..."
            cmd zpool create -f -o ashift=12 \
              -O atime=off -O canmount=off -O compression=lz4 \
              -O normalization=formD -O xattr=sa -O mountpoint=/ -R /mnt \
              "$RPOOL" mirror "${partitions[@]}"
        else
            cancel
        fi
    fi
}


function create_filesystems() {
    info "Creating filesystems..."

    # / and root
    cmd zfs create -o canmount=off -o mountpoint=none "$RPOOL"/ROOT
    cmd zfs create -o canmount=noauto -o mountpoint=/ "$RPOOL"/ROOT/ubuntu
    cmd zfs mount "$RPOOL"/ROOT/ubuntu
    cmd zfs create -o setuid=off "$RPOOL"/home
    cmd zfs create -o mountpoint=/root "$RPOOL"/home/root

    # var
    cmd zfs create -o canmount=off -o setuid=off -o exec=off "$RPOOL"/var
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/cache
    cmd zfs create -o acltype=posixacl -o xattr=sa "$RPOOL"/var/log
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/spool
    cmd zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/tmp

    # optional filesystems
    for option in "${FILESYSTEMS[@]}"; do
        case "$option" in
            local)
                cmd zfs create -o canmount=off "$RPOOL/usr"
                cmd zfs create "$RPOOL/usr/local"
                ;;
            opt)
                cmd zfs create "$RPOOL/opt"
                ;;
            srv)
                cmd zfs create -o setuid=off -o exec=off "$RPOOL/srv"
                ;;
            games)
                cmd zfs create -o exec=on "$RPOOL/games"
                ;;
            mongodb)
                cmd zfs create -o mountpoint=/var/lib/mongodb \
                    "$RPOOL"/var/mongodb
                ;;
            mysql)
                cmd zfs create -o mountpoint=/var/lib/mysql \
                    "$RPOOL"/var/mysql
                ;;
            postgres)
                cmd zfs create -o mountpoint=/var/lib/postgres \
                    "$RPOOL"/var/postgres
                ;;
            nfs)
                cmd zfs create -o com.sun:auto-snapshot=false -o \
                    mountpoint=/var/lib/nfs "$RPOOL"/var/nfs
                ;;
            mail)
                cmd zfs create "$RPOOL/var/mail"
                ;;
        esac
    done

    # EFI partition(s)
    for sdx in "${DISKS[@]}"; do
        local id=$(disk_id "$sdx")
        cmd mkdosfs -F 32 -n EFI "$id-part3"
        # local partuuid=$(blkid -s PARTUUID -o value "$id-part3")
        # local fstab="$(partuuid)    /boot/efi    vfat    "
        # fstab+="nofail,x-systemd.device-timeout=1    0    1"
        # append "$fstab" /etc/fstab
    done
    cmd mkdir /mnt/boot
    cmd mount "$(disk_id "${DISKS[0]}")" /mnt/boot

    # ubiquity install target
    cmd zfs create -V 10G "$RPOOL/ubiquity"
}


function get_swap() {
    msg="Do you want to a ZVOL for swap?"
    dialog \
        --title "Swap File" \
        --backtitle "$BACKTITLE"  \
        --yesno "$msg" 7 60
    EXIT=$?
    if [ "$EXIT" -eq 0 ]; then
        return 0
    elif [ "$EXIT" -eq 1 ]; then
        
        return 0
    else
        cancel
    fi
}

# function get_swap_size() {
#     msg="Specify username of the first user (UID=1000):"
#     dialog \
#         --title "Username" \
#         --backtitle "$BACKTITLE"  \
#         --inputbox "$msg" 11 70 "$USERNAME" 2>"$RESULTS"
#     EXIT=$?
#     if [ "$EXIT" -ne 0 ]; then
#         cancel
#     fi
#     USERNAME="$(<"$RESULTS")"
#     echo "$RPOOL"
#     while [[ ("$USERNAME" == "") || ("$USERNAME" =~ [^a-zA-Z0-9]) ]]; do
#         msg="Usernames must consists only of alphanumeric strings " \
#         msg+="without spaces.\\n\\n"
#         msg+="Specify username of the first user (UID=1000):"
#         dialog \
#             --title "Username" \
#             --backtitle "$BACKTITLE"  \
#             --inputbox "$msg" 11 70 "$USERNAME" 2>"$RESULTS"
#         EXIT=$?
#         if [ "$EXIT" -ne 0 ]; then
#             cancel
#         fi
#         USERNAME=$(<"$RESULTS")
#     done
# }


init
get_swap
get_username
get_rpool_name
get_filesystems
get_rpool_disks
create_rpool
create_filesystems
