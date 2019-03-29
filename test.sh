#!/bin/bash
set -e
source ./scripts/create-image/common/basic

error() {
    echo "ERROR: Disk layout -- $1" >&2
    return 1
}

check_integer() {
    case "$1" in
        ''|*[!0-9]*)
            return 1 ;;   # not a number
        *)
            return 0 ;;   # number
    esac
}

save_volume_info() {
    voltype="$1"
    voldir="$2"
    shift 2
    # check number of args
    [ "$4" != "" ] || error "invalid syntax '$*'"
    shift
    # check mountpoint
    [ "$1" = "none" -o "${1:0:1}" = "/" ] || \
        error "invalid mount point: '$1' (should start with '/')"
    # check type
    case $2 in
        fat|ext4)       # ok
            ;;
        efi|bios|lvm)
            [ "$voltype" = "part" ] || \
                error "'$2' type is allowed for partitions, not LVM volumes"
            [ "$2" = "efi" -o "$1" = "none" ] || \
                error "'$2' partitions cannot be mounted, use 'none' as a mountpoint"
            ;;
        *)
            [ "$voltype" = "lvm" ] && \
                error "unknown lvm volume type '$2' -- allowed types: fat, ext4"
            [ "$voltype" = "part" ] && \
                error "unknown partition type '$2' -- allowed types: fat, ext4, efi, bios, lvm"
            ;;
    esac
    # check size
    case $3 in
        max)       # ok
            ;;
        auto)
            [ "$2" = "bios" -o "$1" != "none" ] || \
                error "cannot set size of '$2' partition to 'auto' unless you specify the mountpoint"
            ;;
        *[0-9][%GM])
            check_integer ${3%?}    # last char removed, must be an integer
            ;;
        *)
            error "invalid size '$3'"
            ;;
    esac
    # ok save info
    mkdir -p $voldir
    echo "$1" > $voldir/mountpoint
    echo "$2" > $voldir/type
    echo "$3" > $voldir/size
}

get_vol_attr_files() {
    attr="$1"
    ls -1 | sort -n | sed -e "s/$/\/$attr/"
}

count_attr_matches() {
    cd "$1"
    files="$(get_vol_attr_files $2)"
    grep $3 $files | wc -l
    cd - >/dev/null
}

check_layout() {
    in_layout_dir=$1

    # check that partition table type was defined
    [ -f "$in_layout_dir/part_type" ] || \
        error "partition table type is not defined (gpt or dos)"

    # check that at least one partition was defined
    [ -d "$in_layout_dir/partitions" ] || \
        error "no partitions defined"

    # check that, except for the last one, size of partitions is not "max" or "<xx>%"
    cd "$in_layout_dir/partitions"
    size_files="$(get_vol_attr_files size | head -n -1)"
    [ $(grep max $size_files | wc -l) -eq 0 ] || \
        error "'max' keyword is only allowed for the last partition"
    [ $(grep "%$" $size_files | wc -l) -eq 0 ] || \
        error "only the last partition can have its size declared as a percentage"
    cd - >/dev/null

    # check that no more than 1 lvm volume has size="max"
    if [ -d "$in_layout_dir/lvm_volumes" ]
    then
        [ $(count_attr_matches "$in_layout_dir/lvm_volumes" size max) -lt 2 ] || \
            error "'max' keyword is only allowed for at most 1 lvm volume"
    fi

    # check that at most one lvm, efi, bios partition is declared
    for special_type in lvm efi bios
    do
        [ $(count_attr_matches "$in_layout_dir/partitions" type $special_type) -lt 2 ] || \
            error "cannot have several partitions with type '$special_type'"
    done

    # if lvm volumes are declared, check that an lvm partition exists
    if [ $(ls -1 "$in_layout_dir/lvm_volumes" | wc -l) -gt 0 ]
    then
        [ $(count_attr_matches "$in_layout_dir/partitions" type lvm) -eq 1 ] || \
            error "cannot declare lvm volumes unless you declare a partition with type lvm"
    fi

    # check that mount points are not repeated
    mountpoints="$(cat "$in_layout_dir"/*/*/mountpoint | grep -vx none)"
    [ $(echo "$mountpoints" | wc -w) -eq $(echo "$mountpoints" | uniq | wc -w) ] || \
        error "repeated mount point"
}

volume_is_partition() {
    parent_dir="$(basename "$(dirname "$1")")"
    [ "$parent_dir" = "partitions" ] && return 0    # yes
    return 1                                        # no
}

check_layout_updates() {
    in_def_layout_dir=$1
    in_new_layout_dir=$2

    # check that important data was not removed or changed from the default layout
    for defvol in $in_def_layout_dir/*/*
    do
        defvol_type=$(cat "$defvol/type")
        defvol_mountpoint=$(cat "$defvol/mountpoint")

        newvol_found=0
        for newvol in $in_new_layout_dir/*/*
        do
            newvol_type=$(cat "$newvol/type")
            newvol_mountpoint=$(cat "$newvol/mountpoint")
            if [ "$defvol_mountpoint" = "none" -a "$newvol_type" = "$defvol_type" ]
            then
                newvol_found=1
                break
            fi
            if [ "$defvol_mountpoint" != "none" -a "$newvol_mountpoint" = "$defvol_mountpoint" ]
            then
                [ "$newvol_type" = "$defvol_type" ] || \
                    error "'$defvol_mountpoint' volume type cannot be changed from default disk layout ($defvol_type)"
                newvol_found=1
                break
            fi
        done

        if [ $newvol_found -eq 0 ]
        then
            [ "$defvol_mountpoint" = "none" ] && info_vol1="$defvol_type" || info_vol1="'$defvol_mountpoint'"
            volume_is_partition "$defvol" && info_vol2="partition" || info_vol2="lvm volume"
            error "$info_vol1 $info_vol2 was removed from default disk layout"
        fi
    done

    [ $(cat "$in_def_layout_dir/part_type") = $(cat "$in_new_layout_dir/part_type") ] || \
        error "changing partition table type (gpt <-> dos) from default disk layout is not allowed"
}

num_entries() {
    d="$1"
    if [ ! -d "$d" ]
    then
        echo 0
    else
        ls -1 "$d" | wc -l
    fi
}

parse_layout() {
    in_layout_dir=$1
    in_layout_file=$2

    while read inst args
    do
        case "$inst" in
            "")
                ;;
            "partition")
                partnum=$(num_entries "$in_layout_dir/partitions")
                partdir="$in_layout_dir/partitions/$partnum"
                save_volume_info part "$partdir" "$inst" $args
                ;;
            "lvm_volume")
                volnum=$(num_entries "$in_layout_dir/lvm_volumes")
                voldir="$in_layout_dir/lvm_volumes/$volnum"
                save_volume_info lvm "$voldir" "$inst" $args
                ;;
            "gpt"|"dos")
                [ ! -f "$in_layout_dir/part_type" ] || \
                    error "several declarations of the partition table type (gpt|dos)"
                echo "$inst" > $in_layout_dir/part_type
                ;;
            *)
                error "invalid syntax '$inst'"
        esac
    done < <(sed -e 's/#.*$//' $in_layout_file)
}

size_as_kb()
{
    echo $(($(echo $1 | sed -e "s/M/*1024/" -e "s/G/*1024*1024/")))
}

MIN_VOLUME_DATA_SIZE_KB=10*1024
VOLUME_TYPE_OVERHEAD_PERCENT=( ['ext4']=18 ['fat']="10" ['efi']="10" )
LVM_OVERHEAD_PERCENT=4
BIOSBOOT_PARTITION_SIZE_KB=1024
DRAFT_VOLUME_SIZE_ADDUP_KB=1024*1024

estimate_minimal_vol_size_kb()
{
    in_vol="$1"
    in_target_fs="$2"

    vol_mountpoint=$(cat "$in_vol/mountpoint")
    vol_type=$(cat "$in_vol/type")
    target_fs_path="$in_target_fs/$vol_mountpoint"
    echo "target_fs_path=$target_fs_path" >&2

    if [ -d "$target_fs_path" ]
    then
        data_size_kb=$(estimated_size_kb "$target_fs_path")
    else
        data_size_kb=0
    fi

    min_kb=$MIN_VOLUME_DATA_SIZE_KB
    data_size_kb=$((data_size_kb > min_kb ? data_size_kb : min_kb))

    overheads=${VOLUME_TYPE_OVERHEAD_PERCENT[$vol_type]}
    if volume_is_partition "$in_vol"
    then
        overheads="$overheads $LVM_OVERHEAD_PERCENT"
    fi
    echo $(apply_overheads_percent $data_size_kb $overheads)
}

sum_lines() {
    echo $(($(paste -sd+ -)))
}

compute_applied_sizes()
{
    in_mode="$1"
    in_layout_dir="$2"
    in_target_fs="$3"

    # estimate data size of each volume with a mountpoint
    #
    # we have to take care not adding up size of sub-mounts
    # such as in the case of '/' and '/boot' for instance.
    #
    # precedure:
    # 1 - 1st loop: estimate whole tree size at each mountpoint
    #     (ignoring existence of possible sub-mounts)
    # 2 - intermediary line (with 'sort | tac' processing):
    #     sort to get deepest sub-mounts first
    # 3 - 2nd loop: remove from first datasize estimation
    #     the datasize of sub-mounts. To ease this, we use
    #     a temporary file hierarchy "$data_size_tree":
    #     for each mountpoint, we record in parent dirs, up to "/",
    #     the datasize we already counted at this step.
    data_size_tree=$(mktemp -d)
    for vol in $(ls -1d "$in_layout_dir"/*/* | sort -n)
    do
        vol_mountpoint=$(cat "$vol/mountpoint")
        if [ "$vol_mountpoint" != "none" ]
        then
            target_fs_path="$in_target_fs/$vol_mountpoint"
            if [ -d "$target_fs_path" ]
            then
                data_size_kb=$(estimated_size_kb "$target_fs_path")
            else
                data_size_kb=0
            fi
            echo "$vol_mountpoint" "$data_size_kb" "$vol"
        fi
    done | sort | tac | while read vol_mountpoint data_size_kb vol
    do
        mp=$vol_mountpoint
        mkdir -p "$data_size_tree/$mp"
        if [ -f "$data_size_tree/$mp/.submounts_data_size_kb" ]
        then
            submounts_data_size_kb=$(cat $data_size_tree/$mp/.submounts_data_size_kb)
            data_size_kb=$((data_size_kb-submounts_data_size_kb))
        fi
        echo $data_size_kb > $vol/data_size_kb
        while [ "$mp" != "/" ]
        do
            mp=$(dirname $mp)
            if [ -f "$data_size_tree/$mp/.submounts_data_size_kb" ]
            then
                submounts_data_size_kb=$(cat $data_size_tree/$mp/.submounts_data_size_kb)
            else
                submounts_data_size_kb=0
            fi
            echo $((data_size_kb+submounts_data_size_kb)) > \
                        "$data_size_tree/$mp/.submounts_data_size_kb"
        done
    done
    rm -rf $data_size_tree

    # compute the size we will apply to each volume.
    #
    # we sort volumes to list lvm volumes before partitions.
    # this allows to know the size of all lvm volumes when
    # we have to compute the size of the lvm-type partition.
    for vol in $(ls -1d "$in_layout_dir"/*/* | sort -n)
    do
        vol_size=$(cat "$vol/size")
        vol_type=$(cat "$vol/type")
        if [ $(echo $vol_size | grep "[GM]$" | wc -l) -eq 1 ]
        then
            # fixed size
            size_as_kb $vol_size > $vol/applied_size_kb
        elif [ "$vol_type" = "bios" ]
        then
            # bios boot partition is special, we know which size is recommended
            echo $BIOSBOOT_PARTITION_SIZE_KB > $vol/applied_size_kb
        elif [ "$vol_type" = "lvm" ]
        then
            # lvm-type partition => sum the size of all lvm volumes
            cat "$in_layout_dir"/lvm_volumes/*/applied_size_kb | \
                    sum_lines > $vol/applied_size_kb
        else
            # variable size
            estimate_minimal_vol_size_kb $vol $in_target_fs > $vol/applied_size_kb
        fi

        if [ "$in_mode" = "draft" -a "$vol_type" != "lvm" ]
        then
            # apply a big margin
            size=$(cat $vol/applied_size_kb)
            size=$((size + DRAFT_VOLUME_SIZE_ADDUP_KB))
            echo $size > $vol/applied_size_kb
        fi
    done
}

partition_image_gpt() {

    efi_partition_size_kb=$(get_efi_partition_size_kb)
    quiet sgdisk \
            -n 1:0:+${efi_partition_size_kb}K -t 1:ef00 \
            -n 2:0:+${BIOSBOOT_PARTITION_SIZE_KB}K -t 2:ef02 \
            -n 3:0:0 -t 3:8e00 $device
}

partition_image()
{
    device=$1
    sfdisk $device >/dev/null << EOF
label: dos

size=${BOOT_PARTITION_SIZE_MB}MiB,type=c
type=83
EOF
}

TEST_LAYOUT="""
# gpt or dos partition table
gpt

# oredered list of partitions (with mountpoint, type, size)
partition   /boot/efi  efi     auto
partition   none       bios    auto
partition   none       ext4    2G
partition   none       lvm     max

# lvm volumes (with mountpoint, type, size)
lvm_volume  /boot      ext4    10%
lvm_volume  /          ext4    max
"""

layout_dir=$(mktemp -d)
def_layout_dir=$(mktemp -d)
parse_layout $layout_dir <(echo "$TEST_LAYOUT")
check_layout $layout_dir
parse_layout $def_layout_dir disk-layouts/target/pc/disk-layout
check_layout_updates $def_layout_dir $layout_dir
compute_applied_sizes final $layout_dir /tmp

echo OK $layout_dir
echo "$TEST_LAYOUT"
for vol in $layout_dir/*/*
do
    echo $vol $(cat $vol/*)
done
