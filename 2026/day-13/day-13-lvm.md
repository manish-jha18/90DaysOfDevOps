# Day 13 – Linux Volume Management (LVM)

My VM has no spare disk, so I created a virtual one with a loop device as the tutorial suggests.

A note on prompts: the README says to switch to root with `sudo -i`. I used `sudo` on each command instead, so it is always visible which commands actually need root. Same result, and I am less likely to forget I am root and delete something.

---

## What LVM is, in one paragraph

Without LVM, a partition is a fixed slice of a disk. If it fills up, the only options are moving data or repartitioning. LVM adds a layer in between: physical disks become **Physical Volumes**, PVs get pooled into a **Volume Group**, and slices of that pool become **Logical Volumes** that you format and mount. Because the pool can span several disks and volumes can grow while mounted, running out of space stops being an emergency.

```
Physical disks  →  PV  →  VG (the pool)  →  LV  →  filesystem  →  mount point
  /dev/loop0      pvcreate  vgcreate       lvcreate   mkfs.ext4     mount
```

---

## Setup: create a virtual disk

```
devops@testvm:~$ sudo dd if=/dev/zero of=/tmp/disk1.img bs=1M count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 1.82134 s, 590 MB/s

devops@testvm:~$ sudo losetup -fP /tmp/disk1.img

devops@testvm:~$ sudo losetup -a
/dev/loop0: [2049]:262401 (/tmp/disk1.img)
```

`dd` wrote a 1 GiB file full of zeros, and `losetup` attached it to `/dev/loop0` so Linux treats the file as a block device. `-f` picks the first free loop device, so I did not have to guess the name.

---

## Task 1: Check current storage

```
devops@testvm:~$ lsblk
NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0    1G  0 loop
sda       8:0    0   20G  0 disk
├─sda1    8:1    0 19.9G  0 part /
├─sda14   8:14   0    4M  0 part
└─sda15   8:15   0  106M  0 part /boot/efi
```

`/dev/loop0` shows up as a 1 G device with no mount point. Ready to use.

```
devops@testvm:~$ sudo pvs
devops@testvm:~$ sudo vgs
devops@testvm:~$ sudo lvs
```

All three returned nothing — no LVM on this box yet. That is the expected starting point.

```
devops@testvm:~$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/root        19G  7.6G   11G  42% /
tmpfs           1.9G     0  1.9G   0% /dev/shm
/dev/sda15      105M  6.1M   99M   6% /boot/efi
```

---

## Task 2: Create the Physical Volume

```
devops@testvm:~$ sudo pvcreate /dev/loop0
  Physical volume "/dev/loop0" successfully created.

devops@testvm:~$ sudo pvs
  PV         VG Fmt  Attr PSize PFree
  /dev/loop0    lvm2 ---  1.00g 1.00g
```

`pvcreate` writes an LVM label onto the device. The `VG` column is empty because it does not belong to a volume group yet. 1.00g free out of 1.00g.

```
devops@testvm:~$ sudo pvdisplay
  "/dev/loop0" is a new physical volume of "1.00 GiB"
  --- NEW Physical volume ---
  PV Name               /dev/loop0
  VG Name
  PV Size               1.00 GiB
  Allocatable           NO
  PE Size               0
  Total PE              0
  Free PE               0
  Allocated PE          0
```

---

## Task 3: Create the Volume Group

```
devops@testvm:~$ sudo vgcreate devops-vg /dev/loop0
  Volume group "devops-vg" successfully created

devops@testvm:~$ sudo vgs
  VG        #PV #LV #SN Attr   VSize    VFree
  devops-vg   1   0   0 wz--n- 1020.00m 1020.00m
```

1 GiB became 1020 MiB. The missing 4 MiB is LVM metadata. Space is handed out in **physical extents** of 4 MiB each, so 255 extents of 4 MiB = 1020 MiB.

```
devops@testvm:~$ sudo vgdisplay devops-vg
  --- Volume group ---
  VG Name               devops-vg
  Format                lvm2
  VG Size               1020.00 MiB
  PE Size               4.00 MiB
  Total PE              255
  Alloc PE / Size       0 / 0
  Free  PE / Size       255 / 1020.00 MiB
```

This is the pool. To add more space later I would `pvcreate` another disk and `vgextend devops-vg /dev/loop1`.

---

## Task 4: Create the Logical Volume

```
devops@testvm:~$ sudo lvcreate -L 500M -n app-data devops-vg
  Logical volume "app-data" created.

devops@testvm:~$ sudo lvs
  LV       VG        Attr       LSize   Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  app-data devops-vg -wi-a----- 500.00m

devops@testvm:~$ sudo vgs
  VG        #PV #LV #SN Attr   VSize    VFree
  devops-vg   1   1   0 wz--n- 1020.00m 520.00m
```

500 MiB carved out, 520 MiB still free in the group. That leftover is what I will use to extend in Task 6.

The volume appears at two paths:

```
devops@testvm:~$ ls -l /dev/devops-vg/app-data
lrwxrwxrwx 1 root root 7 Jun 23 10:22 /dev/devops-vg/app-data -> ../dm-0
```

`/dev/devops-vg/app-data` is the friendly name and a symlink to `/dev/dm-0`, the real device mapper node. Use the friendly one — it stays stable.

---

## Task 5: Format and mount

```
devops@testvm:~$ sudo mkfs.ext4 /dev/devops-vg/app-data
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 512000 1k blocks and 128016 inodes
Filesystem UUID: 7f3a91c4-2e58-4d1b-b8a3-6c9e0d4a1f27
Superblock backups stored on blocks:
	8193, 24577, 40961, 57345, 73729, 204801, 221185, 401409

Allocating group tables: done
Writing inode tables: done
Creating journal (8192 blocks): done
Writing superblocks and filesystem accounting information: done
```

The logical volume is only a block device until this point. `mkfs.ext4` puts a filesystem on it so it can hold files.

```
devops@testvm:~$ sudo mkdir -p /mnt/app-data
devops@testvm:~$ sudo mount /dev/devops-vg/app-data /mnt/app-data

devops@testvm:~$ df -h /mnt/app-data
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/devops--vg-app--data  464M   14K  435M   1% /mnt/app-data
```

The device name in `df` is `devops--vg-app--data` with doubled dashes. Device mapper uses a single `-` as the separator between VG and LV, so any real dash in a name gets doubled to avoid ambiguity. Confusing the first time you see it.

500 MiB shows as 464M usable — filesystem metadata and the 5% root reserve account for the difference.

**Write a test file:**

```
devops@testvm:~$ sudo touch /mnt/app-data/test.txt
devops@testvm:~$ echo "LVM works" | sudo tee /mnt/app-data/test.txt
LVM works

devops@testvm:~$ cat /mnt/app-data/test.txt
LVM works
```

---

## Task 6: Extend the volume

This is the point of LVM — growing storage without unmounting or losing data.

**Before:**

```
devops@testvm:~$ df -h /mnt/app-data
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/devops--vg-app--data  464M   15K  435M   1% /mnt/app-data
```

**Step 1 — grow the logical volume:**

```
devops@testvm:~$ sudo lvextend -L +200M /dev/devops-vg/app-data
  Size of logical volume devops-vg/app-data changed from 500.00 MiB (125 extents) to 700.00 MiB (175 extents).
  Logical volume devops-vg/app-data successfully resized.
```

**Step 2 — check df again, deliberately, before resizing the filesystem:**

```
devops@testvm:~$ df -h /mnt/app-data
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/devops--vg-app--data  464M   15K  435M   1% /mnt/app-data
```

Still 464M. This is the part worth understanding: `lvextend` made the *container* bigger, but the ext4 filesystem inside it has no idea. Two separate layers, two separate steps.

**Step 3 — grow the filesystem:**

```
devops@testvm:~$ sudo resize2fs /dev/devops-vg/app-data
resize2fs 1.46.5 (30-Dec-2021)
Filesystem at /dev/devops-vg/app-data is mounted on /mnt/app-data; on-line resizing required
old_desc_blocks = 4, new_desc_blocks = 6
The filesystem on /dev/devops-vg/app-data is now 716800 (1k) blocks long.
```

**After:**

```
devops@testvm:~$ df -h /mnt/app-data
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/devops--vg-app--data  652M   15K  616M   1% /mnt/app-data

devops@testvm:~$ cat /mnt/app-data/test.txt
LVM works
```

464M to 652M, filesystem still mounted the entire time, test file untouched. `on-line resizing required` in the output means it grew a live filesystem — no downtime.

```
devops@testvm:~$ sudo lvs
  LV       VG        Attr       LSize
  app-data devops-vg -wi-ao---- 700.00m

devops@testvm:~$ sudo vgs
  VG        #PV #LV #SN Attr   VSize    VFree
  devops-vg   1   1   0 wz--n- 1020.00m 320.00m
```

The `Attr` field is now `-wi-ao----`. That `o` means open, in other words currently mounted.

---

## Making the mount permanent

A manual `mount` disappears on reboot. For it to persist it needs an `/etc/fstab` entry:

```
devops@testvm:~$ sudo blkid /dev/devops-vg/app-data
/dev/devops-vg/app-data: UUID="7f3a91c4-2e58-4d1b-b8a3-6c9e0d4a1f27" BLOCK_SIZE="1024" TYPE="ext4"
```

The line to add:

```
UUID=7f3a91c4-2e58-4d1b-b8a3-6c9e0d4a1f27  /mnt/app-data  ext4  defaults  0  2
```

Then test it **before** rebooting:

```
devops@testvm:~$ sudo umount /mnt/app-data
devops@testvm:~$ sudo mount -a
devops@testvm:~$ df -h /mnt/app-data
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/devops--vg-app--data  652M   15K  616M   1% /mnt/app-data
```

`mount -a` mounts everything in fstab. If there is a typo it fails here, harmlessly. Skip this and a bad fstab line can leave the machine unbootable, dropped into emergency mode. Worth doing every time.

---

## Commands Used

| Command | Purpose |
|---|---|
| `dd if=/dev/zero of=/tmp/disk1.img bs=1M count=1024` | Create a 1 GiB file to use as a fake disk |
| `losetup -fP /tmp/disk1.img` | Attach the file to the first free loop device |
| `losetup -a` | List active loop devices |
| `lsblk` | Tree view of block devices and mount points |
| `pvcreate /dev/loop0` | Mark a device as an LVM physical volume |
| `pvs` / `pvdisplay` | Short and detailed PV info |
| `vgcreate devops-vg /dev/loop0` | Create the volume group |
| `vgs` / `vgdisplay` | Short and detailed VG info |
| `lvcreate -L 500M -n app-data devops-vg` | Carve a logical volume out of the group |
| `lvs` / `lvdisplay` | Short and detailed LV info |
| `mkfs.ext4 /dev/devops-vg/app-data` | Put a filesystem on the LV |
| `mount /dev/devops-vg/app-data /mnt/app-data` | Mount it |
| `lvextend -L +200M ...` | Grow the logical volume |
| `resize2fs ...` | Grow the ext4 filesystem to match |
| `blkid` | Get the UUID for fstab |
| `mount -a` | Test fstab without rebooting |
| `vgextend devops-vg /dev/loop1` | Add another disk to the pool |

---

## What I Learned

**1. Extending storage is two steps, not one.** `lvextend` grows the block device and `resize2fs` grows the filesystem inside it. Running only the first and then checking `df` shows no change at all, which looks like the command failed. Seeing that gap made the layering click more than any diagram did. On XFS the second command is `xfs_growfs` instead.

**2. It happens live.** The filesystem stayed mounted and the test file survived. Compare that to a plain partition, where growing it means unmounting, repartitioning and hoping. This is why LVM exists.

**3. The abstraction is what gives the flexibility.** PV, VG and LV look like extra ceremony for one disk. The value shows when the pool spans several disks — a logical volume can be bigger than any single physical disk underneath it, and adding capacity is `pvcreate` plus `vgextend` with nothing unmounted.

**Two extras worth writing down:**

- Device mapper doubles dashes in names, so `devops-vg/app-data` appears as `devops--vg-app--data`. Not a typo.
- Always test `/etc/fstab` with `mount -a` before rebooting. A bad entry can stop the machine booting, and on a cloud VM without console access that is a serious problem.
