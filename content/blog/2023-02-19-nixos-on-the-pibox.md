+++
title = "NixOS on the PiBox"
description = "NixOS, LUKS, and ZFS on the PiBox"
date = 2023-02-19
updated = 2023-06-04

[taxonomies]
tags = [ "luks", "NixOS", "raspberrypi", "zfs" ]
+++

The [PiBox] is a small personal server powered by a Raspberry Pi CM4. It comes
in a nice enclosure which has a fan, an LCD screen, and has two bays for SATA
SSDs. [KubeSail], the company behind it, offers backup storage and proxy traffic
as a service. They also support a bunch of templates for easily self hosting
apps like Jellyfin or NextCloud.

But, since I'm already very comfortable with NixOS and deploy a bunch of custom
workloads with it, I wanted to try using it instead of the OS that ships with
the PiBox.

Here's how I went about it, and how you can too!

<!-- more -->

# Preparing the CM4 for boot
Although the CM4 (technically) supports booting from a variety of different
targets besides its EEPROM (like an NVMe drive, a USB stick, and even the
network!), it doesn't actually support booting from a SATA drive. I guess most
people either boot from a USB drive or go all in with an NVMe drive, so for
whatever reason direct boot from SATA was never designed into the firmware. The
good thing is we can still boot from the EEPROM itself but keep the OS and all
other data on the SSD drive, so that's what we'll do here.

The first step is to optionally update the board's firmware and change the boot
order. The default configuration tries a whole bunch of boot options which
likely will never be used which means it takes it a while to actually boot.

We'll start by [opening up the PiBox and carefully separating the carrier board from
the backplane](https://web.archive.org/web/20230219020754/https://docs.kubesail.com/guides/pibox/rpiboot/),
then flip the "boot mode" switch to `rpiboot` and connect the board with a USB-C
cable to a PC. To change the boot config we'll need to use the raspberrypi
`usbboot` toolkit:

```sh
git clone https://github.com/raspberrypi/usbboot ~/usbboot
cd ~/usbboot/recovery

# Edit the `boot.conf` file and set the `BOOT_ORDER` variable
# I noticed that if the "SD" (same as the EEPROM on CM4) option (1) is set to
# run first the board doesn't actually boot from it but tries everything else
# first. Maybe there's some kind of delay the hardware needs to warm up but I
# found if I set `BOOT_ORDER=0xf514` then things work pretty smoothly. This
# configuration basically tries things in the following order:
# - 4: USB mass storage device: don't care about this, try anything first
# - 1: SD card (or the EEPROM for the CM4), where we would normally boot from
# - 5: BCM-USB: boot from the board hardware headers or something idk
# - f: Restart if all else fails
#
# Also note that you can keep `ENABLE_SELF_UPDATE=1` to allow updating the
# firmware directly from a booted OS in the future without having to reconnect
# to the board like we are doing here
vim boot.conf

# Then apply the changes and flash the firmware, if it went well the lights
# should start blinking red and green
./update-pieeprom.sh
nix shell nixpkgs#rpiboot --command sudo rpiboot -d .
```

Disconnect and reconnect the board to the PC again. This time we'll mount the
CM4's EEPROM storage as a generic device we can manipulate from the PC.

```sh
nix shell nixpkgs#rpiboot --command sudo rpiboot -d ~/usbboot/mass-storage-gadget
```

```sh
# The disk should show up as something like /dev/sda, though if the system
# already has other disks present it might show up as /dev/sdb or /dev/sdc, etc.
# so DOUBLE CHECK THIS!
SD_DISK="/dev/sd..."
```

> Note: I noticed that sometimes the mount would randomly disconnect and
> reconnect on its own (usually showing up as a _new_ device like `/dev/sdb` if
> it was previously `/dev/sda`). Not sure if this was due to my cable connection
> or something else, so I highly recommend double checking things before doing
> any operations on the EEPROM.

Next we'll partition the EEPROM and initialize a file system on it:

```sh
nix shell nixpkgs#parted --command sudo parted --align optimal "${SD_DISK}" <<EOF
    mklabel gpt \
    mkpart primary fat32 1MiB 100% \
    name 1 'EFI system partition' \
    set 1 esp on \
    print \
    quit
EOF

nix shell nixpkgs#dosfstools --command sudo mkfs.vfat "${SD_DISK}1"

# Write down UUIDs for what will become our boot partition
# and add it to the NixOS config
ls -l /dev/disk/by-uuid
```

Finally, disconnect the CM4, but don't reassemble it quite yet as we'll write
some more data to it later!

# Preparing a builder VM
I had originally set out to plug the new SSD into my desktop and do the
partitioning and installation from there, in the hope that it would be faster
and save me various reboot and debug cycles. Even though I have binfmt enabled
(let's me run aarch64 binaries via QEMU) and I can successfully do remote
aarch64 deployments from my x86 desktop via `nixos-rebuild switch`, I was not
able to get `nixos-install` to work despite my best efforts.

I was also unsuccessful in booting the PiBox from a USB stick (though maybe I
made a mistake with the firmware config or my USB image). I briefly considered
flashing the NixOS installer directly on the EEPROM and doing the installation
from there, but I wasn't sure if it could cope with doing the installation
directly on the partition it was booted from.

Instead I decided to spin up a quick QEMU VM and trick `nixos-install` into
working. To save you some effort, copy the config below a `flake.nix` in a new
directory, then `nix build -L && ./result`.

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      DISK = throw "REPLACE ME: /dev/disk/by-id/ata-...";
      sshKey = throw "REPLACE ME: ssh-ed25519 ...";

      pkgs = import nixpkgs {
        system = "x86_64-linux";
      };
      pkgsAarch64 = import nixpkgs {
        system = "aarch64-linux";
      };

      isoConfiguration = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ({ modulesPath, ... }: {
            imports = [
              "${modulesPath}/installer/cd-dvd/iso-image.nix"
            ];
            isoImage.makeEfiBootable = true;

            boot.supportedFilesystems = [ "zfs" ];

            networking.hostId = "a7dbd851"; # random value

            environment.systemPackages = with pkgsAarch64; [
              coreutils
              cryptsetup
              dosfstools
              gitMinimal
              htop
              openssh
              parted
              smartmontools
              unzip
              util-linux
              wget
              zfs
            ];

            services.openssh.enable = true;
            users.users.root.openssh.authorizedKeys.keys = [ sshKey ];
          })
        ];
      };

      iso = isoConfiguration.config.system.build.isoImage;
      vmScript = pkgs.writeScript "run-nixos-vm" ''
        #!${pkgs.runtimeShell}
        ${pkgs.qemu}/bin/qemu-system-aarch64 \
          -machine virt,gic-version=max \
          -cpu max \
          -m 4G \
          -smp 4 \
          -drive file=$(echo ${iso}/iso/*.iso),format=raw,readonly=on \
          -drive file=${DISK},format=raw,readonly=off \
          -nic user,hostfwd=tcp::3333-:22 \
          -nographic \
          -bios ${pkgsAarch64.OVMF.fd}/FV/QEMU_EFI.fd
      '';
    in
    {
      packages.x86_64-linux.default = vmScript;
    };
}
```

Now that we have a VM running we can connect to it using

```sh
ssh -p 3333 root@localhost \
  -o "UserKnownHostsFile=/dev/null" \
  -o "StrictHostKeyChecking=no"
```

Unless specified otherwise, the below commands should be run within this
session.

## Partitioning the SSD
I like to partition my drives as follows:

1. 1MiB for the GPT partition metadata
1. 1023MiB for the boot partition
   * Although we're going to be booting from the EEPROM, I'm still going to
   reserve a boot partition in case the drive needs to be salvaged and booted
   elsewhere. That way it won't be necessary to add a partition later and risk
   destroying the existing data.
1. 32MiB for storing LUKS keys and metadata
1. 8GiB for (encrypted) swap (same size as the RAM on the device)
1. The remainder of the space for the (encrypted) data

```sh
# The disk should show up at /dev/vdb on the VM, change this if it doesn't
VDISK=/dev/vdb

# Confirm this we've chosen the right disk
smartctl -a ${VDISK}
```

```sh
# Do the actual partition as described above
parted --align optimal ${VDISK} -- \
    mklabel gpt \
    mkpart primary fat32 1MiB 1024MiB \
    name 1 'EFI system partition' \
    set 1 esp on \
    mkpart primary 1024MiB 1056MiB \
    name 2 'luks key' \
    mkpart primary 1056MiB 9248MiB \
    name 3 'swap' \
    mkpart primary 9248MiB 100% \
    name 4 'root' \
    print \
    quit

# Lastly, write down the UUIDs for the LUKS, swap, and root partitions
# and add them to the NixOS config
ls -l /dev/disk/by-uuid
```

## LUKS Configuration
Encrypting the SSD('s non-boot partitions) works just like on any other machine.
To give a concrete example, we're going to set up things in the following manner:
* `cryptkey` - this is the second partition we created above, and will be
  unlocked with a password we remember. Its contents will be a bunch of random
  data which will be used for unlocking the rest of the encrypted partitions
* `cryptswap` - this is the third partition we created above, and will be
  unlocked using the decrypted `cryptkey` partition. It will be used for the
  system's swap.
* `cryptroot` - this is the fourth partition we created above, and will be
  unlocked using the decrypted `cryptkey` partition; it will also have a
  _backup_ password (which we need not remember, but should store a copy in a
  safe place) in case `cryptkey` is corrupted. It will contain the actual root
  filesystem for the device.

> Note: I choose to enable `--allow-discards` which instructs the mapper to
> propagate trim commands issued by the underlying filesystem, allowing the SSD
> to better perform wear leveling. This option is disabled by default since
> there are some theoretical attack vectors from having it enabled and allowing
> an attacker to physically access the disk (namely leaking which blocks are
> trimmed, an some potential oracle attacks if the attacker can influence what
> data is written to the disk). Consult your threat model if this option is
> appropriate for you.

```sh
# Note set the password you will use for "day-to-day" unlocking of the system
# at boot, and make it a good one!
cryptsetup luksFormat --type luks1 "${VDISK}2"
cryptsetup open --type luks1 "${VDISK}2" cryptkey
# Fill the (decrypted) cryptkey partition full of random data
# This invocation will fail with a "device out of space" error which is expected
dd if=/dev/urandom of=/dev/mapper/cryptkey bs=1024 status=progress

# Create and mount the encrypted swap partition
cryptsetup luksFormat \
  --type luks1 \
  --keyfile-size 8192 \
  --key-file /dev/mapper/cryptkey \
  "${VDISK}3"
cryptsetup open \
  --type luks1 \
  --keyfile-size 8192 \
  --key-file /dev/mapper/cryptkey \
  "${VDISK}3" \
  cryptswap

# Create and mount the data partition.
# Use a strong backup unlock phrase (e.g. dice ware) and write this down someplace safe!
cryptsetup luksFormat --type luks1 "${VDISK}4"
cryptsetup luksAddKey \
  --new-keyfile-size 8192 \
  "${VDISK}4" \
  /dev/mapper/cryptkey
cryptsetup open \
  --type luks1 \
  --keyfile-size 8192 \
  --key-file /dev/mapper/cryptkey \
  --allow-discards \
  "${VDISK}4" \
  cryptroot
```

Finally, we initialize the (unencrypted) boot partition with an empty FAT32
partition, and initialize and enable the (decrypted) swap partition.

```sh
mkfs.vfat "${VDISK}1"
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap
```

> Remember to update the configuration with a `postDeviceCommand` to `cryptsetup
> close cryptkey` so that the contents of the `cryptkey` partition don't remain
> accessible after booting!

## ZFS Configuration
There's nothing specific to this setup which dictates how ZFS must be
configured, but as a complete example I want to describe my approach with the
following dataset hierarchy:

* `local` - for data which is either ephemeral or does not need to be backed up
  * `root` - mounted as the system root, reverted to a blank snapshot on every
  boot so I can [Erase My Darlings]
  * `nix` - mounted as `/nix/store`, no need to snapshot as it can be trivially
  rebuilt if necessary
* `persist` - for all data that should be persisted across reboots, snapshotted
  by default
  * `journal` - systemd logs, mounted at `/var/log/journal`
  * `lib` - catchall for application state, mounted at `/var/lib`. Normally I
  like to split out services into their own datasets (for independent
  snapshotting and rollback), though this acts as a good safety to avoid
  forgetting to persist a particular service's state directories and losing them
  on reboot.
  * `system` - miscellaneous system-specific files which should be persisted
  across reboots, mounted at `/persist`
  * `user` - parent dataset for users' data/home directories
* `reserved` - used for over-provisioning the disk (i.e. no data will be written
  here to allow the SSD to move blocks and maintain the health of the
  flash storage)

```sh
# Configure the pool and user names we want to use
POOL=phlegethon
MY_USER=ivan
```

```sh
# Note: when creating the pool, lower case `-o` is used to configure properties at
# the _pool_ level, while upper case `-O` is used to configure properties at the
# _dataset_ level
#
# Note: ashift MUST BE SET or there will be horrible horrible write performance
# using the default value ZFS selects. If you aren't sure what to pick and
# have a modern drive, just take my word for it and set it to 13.
zpool create \
  -o ashift=13 \
  -o autotrim=on \
  -O acltype=posixacl \
  -O atime=off \
  -O canmount=off \
  -O compression=lz4 \
  -O xattr=sa \
  -m legacy \
  ${POOL} /dev/mapper/cryptroot

# Reserve (i.e. overprovision) ~10% of the disk (assuming 1TB disk)
zfs create \
    -o reservation=200G \
    -o quota=200G \
    -o canmount=off \
    ${POOL}/reserved

# systemd-remount-fs.service complains if mountpoint not set
zfs create -o canmount=off -o mountpoint=/ ${POOL}/local
zfs create ${POOL}/local/nix
zfs create ${POOL}/local/root

# Snapshot the root while still empty so we can easily revert it back
zfs snapshot ${POOL}/local/root@blank

zfs create -o com.sun:auto-snapshot=true -o canmount=off ${POOL}/persist
zfs create ${POOL}/persist/system
zfs create ${POOL}/persist/lib
zfs create ${POOL}/persist/journal
zfs create -o canmount=off ${POOL}/persist/user
zfs create ${POOL}/persist/user/${MY_USER}
```

Finally, mount all datasets at their appropriate paths _before_ doing the
installation (lest the data be written in the wrong spot and missing during
boot):

```sh
mkdir /mnt
mount -t zfs "${POOL}/local/root" /mnt

mkdir -p /mnt/{boot,home/${MY_USER},nix,persist,var/{lib,log/journal}}

mount "${VDISK}1" /mnt/boot
mount -t zfs "${POOL}/local/nix" /mnt/nix
mount -t zfs "${POOL}/persist/user/${MY_USER}" /mnt/home/${MY_USER}
mount -t zfs "${POOL}/persist/system" /mnt/persist
mount -t zfs "${POOL}/persist/lib" /mnt/var/lib
mount -t zfs "${POOL}/persist/journal" /mnt/var/log/journal
```

## (Optional) Remote LUKS Unlock
Having to plug in a keyboard and monitor to the PiBox to unlock after a restart
can be a chore, so being able to unlock the drive remotely via SSH can be much
more convenient. First we need to generate a unique host key for the _boot_
stage.

> Note that although the key itself will be stored on the encrypted partition,
> it will be copied to the initrd stored on the _unecrypted_ boot partition
> since the CM4 has no TPM that can be used to further encrypt secrets.
> Therefore, this needs to be a unique host key that is _only_ used for remote
> unlocking and not shared with other hosts. Once the root drive is unlocked,
> the machine will use another host key which is protected by the disk
> encryption.

```sh
# This can be stored anywhere on the host, so long as the path is accessible
# when the system activation script is run. When doing remote deployments it
# _need not_ be accessible by the deploying host
mkdir -p /mnt/persist/etc/ssh
ssh-keygen -t ed25519 -N "" -f /mnt/persist/etc/ssh/initrd_ssh_host_ed25519_key
```

> Note the generated fingerprint here and add it to `~/.ssh/known_hosts` (for the
> correct address and port) so you can be (more) sure you are connecting to the
> correct host before entering the unlock password.

Next, pick a port and update the NixOS configuration with the following:
```nix
boot.network = {
  enable = true;
  ssh = {
    enable = true;
    port = 9999;
    authorizedKeys = [ (throw "add an authorized key here") ];
    hostKeys = [
      # Note this file lives on the host itself,
      # and isn't passed in by the deployer
      "/persist/etc/ssh/initrd_ssh_host_ed25519_key"
    ];
  };
};
```

Also note that when connecting over SSH during boot you'll need to use the port
defined above (to avoid ambiguity with connecting to the default port (22) after
unlocking) and you will need to set the user as `root`. These can be configured
with a host alias in `~/.ssh/config`:

```
Host boot-unlock
  Hostname = REPLACE_WITH_IP_FOR_THE_HOST
  User root
  Port 9999
```

Then, to unlock the host, simply run `ssh boot-unlock` and execute
`cryptsetup-askpass` to enter the password. You might get a warning about
"Passphrase is not requested now" after 10 seconds, but this is completely
normal. I've noticed that it takes about 15 seconds before the disk and CPU LEDs
start blinking, and about 45 more seconds until the actual boot sequence starts.

> Also note that it is probably worth making sure the PiBox has an ethernet
> cable plugged in, as it will not be able to connect to WiFi during boot,
> unless the SSID password is also stored (unprotected) on the initrd

## NixOS Installation
To set a password for the root user which persists across unlocks we'll need to
use a password file:

```sh
sudo mkpasswd -m sha-512 > /persist/root/passwordfile
```

And update the configuration with:

```nix
users.users.root.passwordFile = "/persist/root/passwordfile";
fileSystems."/persist".neededForBoot = true;
```

Next we need to get the configuration on to the VM. A quick and dirty solution
is to `scp` it over:

```sh
# In a fresh terminal
scp -P 3333 -r ~/dotfiles root@localhost:/root \
  -o "UserKnownHostsFile=/dev/null" \
  -o "StrictHostKeyChecking=no"
```

Then, back in the VM session we can finally install NixOS on the SSD
```sh
HOST=asphodel
```

```sh
cd ~/dotfiles
nixos-install --root /mnt --flake .#${HOST} --no-channel-copy

# Gracefully detach the disks and exit
umount /mnt/boot
zpool export "${POOL}"
halt
# Afterwards, hit "Ctrl-a", then "x" on the QEMU window to terminate the image
```

# Firmware and Bootloader Installation
The last few things we need to do are installing the firmware needed to boot the
CM4 (as well as inform the kernel about the fan and LCD peripherals) and the
EFI/bootloader files generated by the NixOS installation.

I've already done the hard part of writing a flake which can prepare the
firmware, as well as enable the fan and display services bundled with the
PiBox OS so checkout [the repo] for more info!

> 2023-06-04: Hello from the future! If you are updating from 22.11 to 23.05
> you may need to build and copy the firmware before updating (but take a backup
> of your existing `/boot` directory first)! There was a kernel update (from
> 5.15 to 6.1) between the two releases and the device tree definitions need to
> be updated or the new kernel may not recognize the fan and display hardware!

```sh
# Build and prepare the raspberrypi firmware and apply the device tree
# overrides to make the PWM fan and LCD discoverable by the kernel.
# Results will be found in `./result`
nix build github:ipetkov/nixos-pibox#packages.aarch64-linux.firmware -L

# Prepare mount paths for the disks
sudo mkdir -p /mnt /mnt_ssd

# Reconnect the CM4 as a mass storage device
nix shell nixpkgs#rpiboot --command sudo rpiboot -d ~/usbboot/mass-storage-gadget
```

Double check the disks paths here again:

```sh
DISK="/dev/disk/by-id/ata-..."
SD_DISK="/dev/sd..."
```

```sh
# Mount the "boot" partition of the SSD
sudo mount "${DISK}-part1" /mnt_ssd
# Mount the CM4's EEPROM
sudo mount "${SD_DISK}1" /mnt

# Copy the firmware and EFI/bootloader
sudo cp -r ./result/* /mnt_ssd/* /mnt

# Cleanup
sudo umount /mnt
sudo umount /mnt_ssd
sudo rmdir /mnt /mnt_ssd
```

Et voilà, the installation is complete! Flip the "boot mode" switch back to
`normal`, put the SSD in, and reassemble the PiBox case. If all else has gone
well you should be able to power on, unlock the disk, and boot and into NixOS.

Happy hacking!

> A quick aside on installing the firmware directly instead of using something
> like the `boot.loader.raspberryPi` NixOS module: the [plans for NixOS on ARM]
> highlight that this module largely exists for legacy reasons and should not be
> used going forward. Even though the raspberrypi was designed to have this
> firmware written to its boot partition, it's more akin to the BIOS of a PC
> motherboard: it's not something NixOS should be attempting to manage as
> without it the hardware can't even _boot_, so getting something wrong means we
> can't even use a "previous generation". Hence these files should be installed
> once and not touched further (unless you have a backup ready and are willing
> to physically restore the files if something goes wrong).

# Appendix
## References
* [https://github.com/ipetkov/nixos-pibox](https://github.com/ipetkov/nixos-pibox)
* [https://github.com/kubesail/pibox-os/tree/main/lcd-display](https://github.com/kubesail/pibox-os/tree/main/lcd-display)
* [https://github.com/raspberrypi/usbboot](https://github.com/raspberrypi/usbboot)
* [https://carjorvaz.com/posts/nixos-on-raspberry-pi-4-with-uefi-and-zfs](https://web.archive.org/web/20230219015339/https://carjorvaz.com/posts/nixos-on-raspberry-pi-4-with-uefi-and-zfs)
* [https://mth.st/blog/nixos-initrd-ssh](https://web.archive.org/web/20230219015443/https://mth.st/blog/nixos-initrd-ssh)
* [https://mgdm.net/weblog/nixos-on-raspberry-pi-4](https://web.archive.org/web/20230219015738/https://mgdm.net/weblog/nixos-on-raspberry-pi-4)
* [https://www.jeffgeerling.com/blog/2022/how-update-raspberry-pi-compute-module-4-bootloader-eeprom](https://web.archive.org/web/20230219015836/https://www.jeffgeerling.com/blog/2022/how-update-raspberry-pi-compute-module-4-bootloader-eeprom)
* [https://discourse.nixos.org/t/planning-for-a-better-nixos-on-arm/15346](https://web.archive.org/web/20230219015849/https://discourse.nixos.org/t/planning-for-a-better-nixos-on-arm/15346)
* [https://grahamc.com/blog/erase-your-darlings](https://web.archive.org/web/20230216224910/https://grahamc.com/blog/erase-your-darlings)
* [https://jrs-s.net/2018/08/17/zfs-tuning-cheat-sheet](https://web.archive.org/web/20230219020744/https://jrs-s.net/2018/08/17/zfs-tuning-cheat-sheet)
* [https://docs.kubesail.com/guides/pibox/os](https://web.archive.org/web/20230219020754/https://docs.kubesail.com/guides/pibox/os)

## Sample Configuration
Here's a sample NixOS configuration to get you started with everything we've set
up above. This also includes the systemd services required for controlling the
PWM fan and LCD on the PiBox!

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixos-pibox = {
      url = "github:ipetkov/nixos-pibox";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      # Replace all these placeholders with your actual values!
      deviceBoot = throw "REPLACE ME: /dev/disk/by-uuid/...";
      deviceCryptKey = throw "REPLACE ME: /dev/disk/by-uuid/...";
      deviceCryptRoot = throw "REPLACE ME: /dev/disk/by-uuid/...";
      deviceCryptSwap = throw "REPLACE ME: /dev/disk/by-uuid/...";
      hostId = throw "REPLACE ME: deadbeef";
      hostName = throw "REPLACE ME";
      userSshKey = throw "REPLACE ME: ssh-ed25519 ...";
      user = throw "REPLACE ME";
      zpool = throw "REPLACE ME";
    in
    {
      nixosConfigurations.${hostName} = nixpkgs.lib.nixosSystem {
        modules = [
          ({ config, lib, pkgs, ... }: {
            imports = [
              inputs.nixos-hardware.nixosModules.raspberry-pi-4
              inputs.nixos-pibox.nixosModules.default
            ];

            nixpkgs.overlays = [
              inputs.nixos-pibox.overlays.default
            ];

            boot = {
              extraModulePackages = [ ];

              # !!! cryptkey must be done first, and the list seems to be
              # alphabetically sorted, so take care that cryptroot / cryptswap,
              # whatever you name them, come after cryptkey.
              initrd = {
                luks.devices = {
                  cryptkey = {
                    device = deviceCryptKey;
                  };

                  cryptroot = {
                    allowDiscards = true;
                    device = deviceCryptRoot;
                    keyFile = "/dev/mapper/cryptkey";
                    keyFileSize = 8192;
                  };

                  cryptswap = {
                    allowDiscards = true;
                    device = deviceCryptSwap;
                    keyFile = "/dev/mapper/cryptkey";
                    keyFileSize = 8192;
                  };
                };

                postDeviceCommands = lib.mkAfter ''
                  cryptsetup close cryptkey
                  zfs rollback -r ${zpool}/local/root@blank && echo blanked out root
                '';

                # Support remote unlock. Run `cryptsetup-askpass` to unlock
                network = {
                  enable = true;
                  ssh = {
                    enable = true;
                    authorizedKeys = config.users.users.${user}.openssh.authorizedKeys.keys;
                    port = 9999;
                    hostKeys = [
                      # Note this file lives on the host itself, and isn't passed in by the deployer
                      "/persist/etc/ssh/initrd_ssh_host_ed25519_key"
                    ];
                  };
                };
              };

              loader = {
                efi.canTouchEfiVariables = true;
                generic-extlinux-compatible.enable = false;
                systemd-boot.enable = true;
                timeout = 10; # seconds
              };

              kernelParams = [
                "8250.nr_uarts=1"
                "console=ttyAMA0,115200"
                "console=tty1"
              ];

              supportedFilesystems = [ "zfs" ];
            };

            fileSystems = {
              "/" = {
                device = "${zpool}/local/root";
                fsType = "zfs";
                options = [ "zfsutil" ];
              };

              "/boot" = {
                device = deviceBoot;
                fsType = "vfat";
                options = [ "noatime" ];
              };

              "/home/${user}" = {
                device = "${zpool}/persist/user/${user}";
                fsType = "zfs";
              };

              "/nix" = {
                device = "${zpool}/local/nix";
                fsType = "zfs";
              };

              "/persist" = {
                device = "${zpool}/persist/system";
                fsType = "zfs";
                neededForBoot = true;
              };

              "/var/lib" = {
                device = "${zpool}/persist/lib";
                fsType = "zfs";
              };

              "/var/log/journal" = {
                device = "${zpool}/persist/journal";
                fsType = "zfs";
                neededForBoot = true;
              };
            };

            swapDevices = [
              {
                device = "/dev/mapper/cryptswap";
              }
            ];

            powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

            networking = {
              inherit hostId hostName;
              useDHCP = false;
              interfaces.eth0.useDHCP = true;
            };

            services = {
              openssh = {
                enable = true;
                hostKeys = [
                  {
                    path = "/persist/etc/ssh/ssh_host_ed25519_key";
                    type = "ed25519";
                  }
                ];
              };
              piboxPwmFan.enable = true;
              piboxFramebuffer.enable = true;
              zfs = {
                autoScrub = {
                  enable = true;
                  interval = "monthly";
                };
                autoSnapshot.enable = true;
                trim.enable = true;
              };
            };

            users.users.root.passwordFile = "/persist/root/passwordfile";
            users.users.${user} = {
              isNormalUser = true;
              home = "/home/${user}";
              openssh.authorizedKeys.keys = [
                userSshKey
              ];
            };

            # Other files to persist, e.g. NetworkManager
            # environment.etc."NetworkManager/system-connections" = {
            #   source = "/persist/etc/NetworkManager/system-connections/";
            # };
          })
        ];
      };
    };
}
```

[Erase My Darlings]: https://web.archive.org/web/20230216224910/https://grahamc.com/blog/erase-your-darlings
[KubeSail]: https://web.archive.org/web/20230219021025/https://kubesail.com/homepage
[PiBox]: https://web.archive.org/web/20230219020959/https://pibox.io/
[plans for NixOS on ARM]: https://web.archive.org/web/20230219015849/https://discourse.nixos.org/t/planning-for-a-better-nixos-on-arm/15346
[the repo]: https://github.com/ipetkov/nixos-pibox
