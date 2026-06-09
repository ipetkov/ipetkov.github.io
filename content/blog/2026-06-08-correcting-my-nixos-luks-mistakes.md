+++
title = "Correcting my NixOS LUKS mistakes"
description = ""
date = 2026-06-09

[taxonomies]
tags = [ "luks", "NixOS" ]
+++

I [have](@/blog/2021-12-13-installing-nixos-and-zfs-on-my-desktop.md) previously
[written](@/blog/2023-02-19-nixos-on-the-pibox.md) about how I setup full disk
encryption via LUKS on my NixOS machines. There I made the mistake of not
initializing a filesystem on the (encrypted) partition meant to hold the key to
unlock the other disks.

This apparently only worked on NixOS on the happenstance that systemd was
patched up to make it work. Recently (just before the NixOS 26.05 release) that
patch [was dropped](https://github.com/NixOS/nixpkgs/pull/488508) which ends up
breaking this setup (systemd will decrypt the device but other units depending
on it end up hanging).

Here's how I chose to correct this mistake.

<!-- more -->

# Background

I don't fully remember exactly why I used this setup in the way that I did. It
was my first ever ("real") desktop Linux installation so I ended up following
whatever random guides I could find online about setting up LUKS for NixOS. The
premise is:

1. Create an encrypted partition which is unlocked with a passphrase (called
   `cryptkey` in my configs)
1. Unlock the partition and (mistakenly!) fill it with random bytes. The correct
   thing would have been to create a filesystem on the unlocked device, and
   create a file with random bytes instead.
1. Create additional encrypted partitions for the system (e.g. `cryptroot` for
   the root, `cryptswap` for swap, etc.) and use (some) of the random bytes
   above
1. Also add a (secondary) passphrase to the encrypted root partition so that it
   can still be unlocked and recovered if the keyfile was destroyed or corrupted

The idea is that at boot you'd only need to type in the passphrase for the
encrypted keyfile once and everything else would get automatically unlocked
afterwards.

Why not just reuse the same passphrase for all encrypted partitions? Maybe at
the time support for passphrase reuse was flaky (or old habits or different threat
models?) so the guides I found suggested this route instead of reusing
passphrases. I ended up replicating this pattern (mistakes and all) across all
my machines; at the very least at least I had the same, familiar setup
everywhere.

# The easy way out

Today, systemd can handle reusing typed in passphrases out of the box, so if all
you care about is not having to type the same passphrase in multiple times, one
easy solution if you've made the same mistake is to ensure all encrypted
partitions are enrolled to unlock with the same passphrase. Run `cryptsetup
luksAddKey /path/to/device` on every such device and you're good to go.

The downside with this approach is if you ever want to rotate the passphrase
you'll have to remember to do that to all such partitions.

# The more involved way

If the easy way out is not particularly satisfying, the more involved way is to:

1. (carefully) copy the keyfile
1. wipe the previous (encrypted) partition
1. initialize it with a filesystem
1. copy the keyfile back
1. rework the NixOS configuration to properly mount the filesystem and use the
   keyfile to unlock the rest of the partitions

Let me spell out exactly how I went about it (across my four machines) for
anyone who finds this after the fact.

## 0. Optional practice

I practiced this procedure by creating a VM and installing NixOS on it with the
same encryption setup as my machines. You'd probably want a very minimal setup
(just to make the installation and boot faster) enough to verify unlocking
works. I ran through the steps below, including making changes to the NixOS
configuration itself to gain the confidence that I wouldn't screw it up when
doing the procedure for real.

## 1. Preparation

First, make sure your backups (you do have backups, right?) are good and *you
have tested recovering* from them. If something goes wrong and the drive is
rendered impossible to decrypt, your data will effectively be lost so don't skip
this step!

Second, make sure each partition whose contents you care about (e.g. you care
about your encrypted root partition, you may not care about your encrypted swap
partition) has an additional passphrase enrolled (i.e. besides unlocking with a
keyfile) and you know the passphrase or have otherwise securely stored it in a
password manager. You can test the passphrase via `cryptsetup open
--test-passphrase /path/to/device && echo success`; add one via `cryptsetup
luksAddKey /path/to/device` if you haven't already or you couldn't unlock it
with a previous such passphrase.

## 2. Interim NixOS configuration

As it currently stands, we likely have a NixOS configuration which can boot and
unlocking using our keyfile-not-on-a-filesystem. We want to get to a state where
the same keyfile is present on a filesystem. But if we get anything wrong we'll
render the system unable to boot (at which point we can recover using a NixOS
installer image/usb but it gets more annoying).

One way to make this nicer is to create an _interim_ NixOS configuration which
effectively disables using the keyfile. Instead, we'll rely on that secondary
passphrase to unlock the root partition. This way we can still successfully
boot the system even if we've wiped the previous keyfile storage but haven't
fully wired everything up yet.

We'll want to:

1. Comment out `swapDevices` in the NixOS configuration if they are encrypted
1. Comment out `boot.initrd.luks.devices.cryptkey` and any other partitions
   which do not have a passphase enrolled (e.g. `boot.initrd.luks.devices.cryptswap`)
1. Comment out `keyFile` and `keyFileSize` (if used) from
   `boot.initrd.luks.devices.cryptroot` (and any other such partitions if you
   use mirrored disks for example)
1. Do a `nixos-rebuild boot` and reboot

At this point we should be able to boot the system by typing in that secondary
passphrase (NOT the passphrase we previously used to unlock `cryptkey`). If
something doesn't work here, reboot to an earlier NixOS configuration (and
unlock with the usual passphrase for `cryptkey`) and start over.

## 3. Extract the keyfile

Now we'll unlock `cryptkey` (by default I have this partition closed post-boot)
and back up its contents. Be careful where these copies end up (e.g. so they
don't accidentally show up in backups or someplace else) as anyone with this
keyfile and access to the system will be able to decrypt it.

All of the following commands will likely need to be run as root (`sudo -i` will
drop us into a root shell so we can avoid prefixing them all with `sudo`):

```sh
# Unlock cryptkey
cryptsetup open /path/to/cryptkey/device cryptkey

# Set umask to make sure the file is created with the correct permissions
umask 377
# Copy the contents to a file
dd if=/dev/mapper/cryptkey of=./cryptkey-backup bs=4096 conv=fdatasync

# Compare the two files have the same contents
cmp /dev/mapper/cryptkey ./cryptkey-backup && echo same

# Lastly, double check that the backed up keyfile can successfully open
# the other partitions. Replace the `--keyfile-size` parameter with the
# appropriate value (I used 8192 when creating the system)
cryptsetup open --test-passphrase \
  --key-file ./cryptkey-backup \
  --keyfile-size 8192 \
  /path/to/cryptroot && echo success
```

Optional: consider backing this up further to a password manager if that fits
your threat model.

## 4. Initialize a filesytem on `cryptkey` (DESTRUCTIVE!)

Now we're ready to perform (destructive!) operations on our unlocked `cryptkey`
partition by initializing a file system:

> Aside: assuming you had previously filled the entire contents of `cryptkey`
> with random bytes, you won't actually be able to fit the entire file back on
> the new filesystem, because the filesystem itself usually needs some space for
> its own book keeping. Meaning unless you want to repartition the disk (which
> has its own risks in losing the data), you will not be able to fit all the
> bytes that were previously written to the `cryptkey` partition.
>
> Assuming that you used an explicit length of the key (like 8192 bytes) this
> will be okay because we only need those specific bytes to survive the
> transition. If you used the entire contents of the previous `cryptkey`
> partition, you may need to take an alternative approach (like generating a new
> keyfile and enrolling that as a keyfile to all encrypted disks).

```sh
# Initialize a filesystem. In this case I chose ext4
nix shell nixpkgs#e2fsprogs --command mkfs.ext4 /dev/mapper/cryptkey
# Ensure we have a place to mount the new filesystem
mkdir -p /mnt
# Mount it
mount /dev/mapper/cryptkey /mnt

# Set umask to make sure the file is created with the correct permissions
umask 377
# Copy it over
cp ./cryptkey-backup /mnt/keyfile
# Note, you may see an error like:
# cp: error writing '/mnt/keyfile': No space left on device
# Based on the aside above, this should not cause alarm

# Now we should check that the first N bytes of the two keyfiles match. For me N
# is 8192 but replace this with your keyfile-size parameter
cmp <(head -c 8192 /mnt/keyfile) <(head -c 8192 ./cryptkey-backup)

# Lastly, we double check that the new keyfile can still unlock things
cryptsetup open --test-passphrase \
  --key-file /mnt/keyfile \
  --keyfile-size 8192 \
  /path/to/cryptroot && echo success

# Unmount and close cryptkey
umount /mnt
cryptsetup close cryptkey
```

## 5. Final NixOS configuration

Now its time to update our NixOS configuration so it can boot and unlock with
the changes we just made:

1. Add `boot.initrd.checkJournalingFS = true;` to the configuration: it enables
   running fsck on journaling filesystems (like ext4) after mounting them during
   boot. Not strictly required but felt like a good measure to me
1. Add `boot.initrd.supportedFilesystems = [ "ext4" ];` to the configuration:
   ensures that systemd can successfully mount the new filesystem (normally
   these are inferred via `filesystems`, but since we don't plan on having this
   remain mounted, we need to explicitly ensure the support is enabled)
1. Uncomment any previously commented out `boot.initrd.luks.devices` entries
   (including `cryptkey`)
1. Uncomment out any `keyFileSize` parameters in `boot.initrd.luks.devices`
1. Set `boot.initrd.lusks.devices.*.keyFile = "/keyfile:/dev/mapper/cryptkey";`:
   Here, `/keyfile` is the path to the keyfile relative to the filesystem we just
   created, while [the part after `:` represents the (decrypted) device to
   mount](https://www.freedesktop.org/software/systemd/man/latest/crypttab.html). 
1. Uncomment out any `swapDevices`
1. Do a `nixos-rebuild boot` and reboot

At this point, type in the original passphrase for `cryptkey` and if everything
was done correctly the system should boot!

Optional: at this point, consider deleting `./cryptkey-backup` if you do not
want a copy of it lingering around.
