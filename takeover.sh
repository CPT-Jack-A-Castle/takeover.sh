#!/bin/bash
set -e

TO=/takeover
OLD_INIT=$(readlink /proc/1/exe)
PORT=80

echo "Preparing tmpfs..."

mkdir $TO
mount -t tmpfs none $TO
mkdir $TO/{proc,sys,dev,run,usr,var,tmp,oldroot}
cp -ax /{bin,etc,mnt,sbin,lib,lib64} $TO/
cp -ax /usr/{bin,sbin,lib,lib64,share} $TO/usr/
cp -ax /var/{backups,cache,lib,local,lock,log,mail,opt,run,spool,tmp} $TO/var/
cp -ax /run/* $TO/run/

apt install build-essential wget
wget -O $TO/busybox https://www.busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox 
chmod +x $TO/busybox
gcc fakeinit.c -o fakeinit 
cp fakeinit $TO/

cd "$TO"

if [ ! -e fakeinit ]; then
    ./busybox echo "Please compile fakeinit.c first"
    exit 1
fi

./busybox echo "Please set a root password for sshd"

./busybox chroot . /bin/passwd

./busybox echo "Setting up target filesystem..."
./busybox rm -f etc/mtab
./busybox ln -s /proc/mounts etc/mtab
./busybox mkdir -p old_root

./busybox echo "Mounting pseudo-filesystems..."
./busybox mount -t tmpfs tmp tmp
./busybox mount -t proc proc proc
./busybox mount -t sysfs sys sys
if ! ./busybox mount -t devtmpfs dev dev; then
    ./busybox mount -t tmpfs dev dev
    ./busybox cp -a /dev/* dev/
    ./busybox rm -rf dev/pts
    ./busybox mkdir dev/pts
fi
./busybox mount --bind /dev/pts dev/pts

TTY="$(./busybox tty)"

./busybox echo "Checking and switching TTY..."

exec <"$TO/$TTY" >"$TO/$TTY" 2>"$TO/$TTY"

./busybox echo "Type 'OK' to continue"
./busybox echo -n "> "
read a
if [ "$a" != "OK" ] ; then
    exit 1
fi

./busybox echo "Preparing init..."
./busybox cat >tmp/${OLD_INIT##*/} <<EOF
#!${TO}/busybox sh

exec <"${TO}/${TTY}" >"${TO}/${TTY}" 2>"${TO}/${TTY}"
cd "${TO}"

./busybox echo "Init takeover successful"
./busybox echo "Pivoting root..."
./busybox mount --make-rprivate /
./busybox pivot_root . old_root
./busybox echo "Chrooting and running init..."
exec ./busybox chroot . /fakeinit
EOF
./busybox chmod +x tmp/${OLD_INIT##*/}

./busybox echo "Starting secondary sshd"

./busybox chroot . /usr/bin/ssh-keygen -A
./busybox chroot . /usr/sbin/sshd -p $PORT -o PermitRootLogin=yes

./busybox echo "You should SSH into the secondary sshd now."
./busybox echo "Type OK to continue"
./busybox echo -n "> "
read a
if [ "$a" != "OK" ] ; then
    exit 1
fi

./busybox echo "About to take over init. This script will now pause for a few seconds."
./busybox echo "If the takeover was successful, you will see output from the new init."
./busybox echo "You may then kill the remnants of this session and any remaining"
./busybox echo "processes from your new SSH session, and umount the old root filesystem."

./busybox mount --bind tmp/${OLD_INIT##*/} ${OLD_INIT}

telinit u

./busybox sleep 10

./busybox echo "Killing all old processes!"

nohup ./busybox kill -9 $(lsof +D /old_root/ | awk '{if (NR>1) {print $2}}' | uniq) &