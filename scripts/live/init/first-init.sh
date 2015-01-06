#!/bin/sh

# remount / read-write
mount -o remount,rw /

# mount compressed image
insmod $(find . -name squashfs.ko)
mount /fs.squashfs /tmp/os_ro
mount -t tmpfs tmpfs /tmp/os_rw # reduce writes
cd /tmp/os_ro
chroot . modprobe overlayfs
mount -t overlayfs -o lowerdir=/tmp/os_ro,upperdir=/tmp/os_rw \
        none /tmp/os

# bind classic mounts
for mp in /proc /sys /dev /dev/pts
do
    mount -o bind $mp /tmp/os$mp
done

# exchange roots
mkdir /tmp/os/old-root
pivot_root /tmp/os /tmp/os/old-root

# run initialization script from the squashfs-based OS
/opt/debootstick/live/init/initialize-stick.sh /old-root /old-root/tmp/os_ro

# reset roots as before
pivot_root /old-root /old-root/tmp/os

# umount things
for mp in /proc /sys /dev/pts /dev
do
    umount /tmp/os$mp
done
cd /
umount /tmp/os /tmp/os_rw /tmp/os_ro

# remove squashfs image (not needed anymore)
rm /fs.squashfs

# restore and start the usual init
rm /sbin/init
mv /sbin/init.orig /sbin/init
exec /sbin/init $*
