+++
title = "Configuring Gitea/Forgejo to Sign Merge Commits"
description = "How to configure Gitea to sign merge commits with GPG"
date = 2024-05-05
updated = 2025-04-26

[taxonomies]
tags = [ "forgejo", "gitea", "gpg", "self-hosting" ]
+++

Gitea supports [automatically signing commits] it generates (such as when
merging pull requests, or editing files through the web editor). Sadly there is
no documentation on how to actually configure this, besides vague references
that it is left up to the server administrator to achieve.

Secure key management is a topic fraught with complexity and trade off
decisions, and the Gitea development team holds a (sensible) position that it is
preferable to give no advice than it is to give _bad_ advice.

A position that I, as an internet rando, am absolutely not bound by, so here's
what I did!

_Edit 2024-08-19: these exact steps also work for Forgejo! Just use
`/var/lib/forgejo` instead of `/var/lib/gitea` for all instructions below_

<!-- more -->

> Seriously though, take a close look at your own threat model and security
> posture before you apply any of the following instructions, which are,
> frankly, provided for free, as in _used mattress_. These are educational
> instructions, and you bear all responsibility for the consequences of
> following them.

# Overview

Under the hood, Gitea basically has its own `.gitconfig` which is applied to all
git operations that it performs. At the end of the day, all we need to do is
ensure a GPG signing key is available inside Gitea's "home" directory and make
sure that Gitea can interact with it unattended.

> Which is easier said than done as GPG strongly insists on passphrase prompts
> and is otherwise hostile to unattended interaction. Perhaps it is possible to
> achieve this by starting and priming a `gpg-agent` instance to be used by
> Gitea, but I did not bother investigating it as it adds more complexity, and
> still requires automating entering the passphrase to it. At that rate, a
> secret of one form or another needs to be available.
>
> I also have not (yet) tried using SSH signing. Since git already supports it
> with some config changes, it might be possible that it "just works", but I
> don't know if there might be other GPG-assumptions baked into Gitea (like the
> `/api/v1/signing-key.gpg` endpoint.

# Generating a new key

First we want to create a brand new GPG key for this Gitea instance. Note that
this key only needs to be configured _for signing_ as we'll only use it to
generate a _second_ signing subkey that will be used by Gitea.

```sh
gpg --full-generate-key
```

Follow the wizard and fill in the values as appropriate. Note that GPG
will ask for a passphrase. Generate a strong password and save it in your
password manager (as we'll need it in a bit).

```
gpg (GnuPG) 2.4.5; Copyright (C) 2024 g10 Code GmbH
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

Please select what kind of key you want:
   (1) RSA and RSA
   (2) DSA and Elgamal
   (3) DSA (sign only)
   (4) RSA (sign only)
   (9) ECC (sign and encrypt) *default*
  (10) ECC (sign only)
  (14) Existing key from card
Your selection? 10
Please select which elliptic curve you want:
   (1) Curve 25519 *default*
   (4) NIST P-384
   (6) Brainpool P-256
Your selection? 1
Please specify how long the key should be valid.
         0 = key does not expire
      <n>  = key expires in n days
      <n>w = key expires in n weeks
      <n>m = key expires in n months
      <n>y = key expires in n years
Key is valid for? (0) 0
Key does not expire at all
Is this correct? (y/N) y

GnuPG needs to construct a user ID to identify your key.

Real name: Example Gitea
Email address: gitea@git.example.com
Comment:
You selected this USER-ID:
    "Example Gitea <gitea@git.example.com>"

Change (N)ame, (C)omment, (E)mail or (O)kay/(Q)uit? o
We need to generate a lot of random bytes. It is a good idea to perform
some other action (type on the keyboard, move the mouse, utilize the
disks) during the prime generation; this gives the random number
generator a better chance to gain enough entropy.
gpg: revocation certificate stored as
'/home/ivan/.gnupg/openpgp-revocs.d/F41E36D6735FD9BE1B53518EA1596EF2CE56B350.rev'
public and secret key created and signed.

pub   ed25519/0xA1596EF2CE56B350 2024-05-05 [SC]
      Key fingerprint = F41E 36D6 735F D9BE 1B53  518E A159 6EF2 CE56 B350
uid                              Example Gitea <gitea@git.example.com>
```

Note the line about `gpg: revocation certificate stored as
'/home/ivan/.gnupg/openpgp-revocs.d/F41E36D6735FD9BE1B53518EA1596EF2CE56B350.rev'`.
This is a revocation certificate for the new key, generated here in case the
key needs to be revoked in the future (but the secret part of the key is somehow
lost or destroyed). Save this somewhere safe (like a password manager) and
destroy this copy when done (and optionally ensure it is scrubbed from your ZFS
snapshots if you care to).

# Generating a signing subkey

Now it's time to generate a signing subkey that will be used by Gitea directly.
The idea is that this subkey can be rotated at will while the main key remains
offline/in cold storage (so it can be trusted for longer periods of time). Note
that GPG will ask for the password we set earlier.

```sh
gpg --edit-key 0xA1596EF2CE56B350
```

```
gpg (GnuPG) 2.4.5; Copyright (C) 2024 g10 Code GmbH
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

Secret key is available.

sec  ed25519/0xA1596EF2CE56B350
     created: 2024-05-05  expires: never       usage: SC
     trust: ultimate      validity: ultimate
[ultimate] (1). Example Gitea <gitea@git.example.com>

gpg> addkey
Please select what kind of key you want:
   (3) DSA (sign only)
   (4) RSA (sign only)
   (5) Elgamal (encrypt only)
   (6) RSA (encrypt only)
  (10) ECC (sign only)
  (12) ECC (encrypt only)
  (14) Existing key from card
Your selection? 10
Please select which elliptic curve you want:
   (1) Curve 25519 *default*
   (4) NIST P-384
   (6) Brainpool P-256
Your selection? 1
Please specify how long the key should be valid.
         0 = key does not expire
      <n>  = key expires in n days
      <n>w = key expires in n weeks
      <n>m = key expires in n months
      <n>y = key expires in n years
Key is valid for? (0) 0
Key does not expire at all
Is this correct? (y/N) y
Really create? (y/N) y
We need to generate a lot of random bytes. It is a good idea to perform
some other action (type on the keyboard, move the mouse, utilize the
disks) during the prime generation; this gives the random number
generator a better chance to gain enough entropy.

sec  ed25519/0xA1596EF2CE56B350
     created: 2024-05-05  expires: never       usage: SC
     trust: ultimate      validity: ultimate
ssb  ed25519/0xA36F2B11E12C310D
     created: 2024-05-05  expires: never       usage: S
[ultimate] (1). Example Gitea <gitea@git.example.com>

gpg> save
```

# Backing up the newly generated keys

Now is a good time to store a secure copy of the key's we've just generated
(e.g. storing the output somewhere in your password manager). Once again GPG
will ask for the password we created earlier.

```sh
gpg --export-secret-keys --armor --export-options export-backup 0xA1596EF2CE56B350
```

# Transferring the signing subkey

Next we'll need to transfer the signing subkey to the Gitea host itself. Running
the following will print out the secret portion which we'll copy/paste
afterwards. There are other ways to achieve this without leaving traces (either
on disk or through the system clipboard) but that is left as an exercise to the
(sufficiently paranoid) reader.

```sh
gpg --export-secret-subkeys --armor 0xA36F2B11E12C310D
```

Then, we need to ssh to the Gitea host and temporarily take on the `gitea` user.

```sh
ssh giteahost.example.com
sudo su gitea
```

On NixOS, Gitea will use `/var/lib/gitea` as its root directory, and `data/home`
for it's `$HOME` equivalent (though both of these are configurable so consult
your distro docs and replace the values as appropriate).

```sh
# NB: using --batch here will suppress password prompts, meaning the key will
# be imported without any (password) protection. Make sure Gitea's root
# directory is fully sandboxed away from other users
gpg --homedir /var/lib/gitea/data/home/.gnupg --batch --import
# Paste the output from the previous command here.
# Hit Enter then Ctrl+D to finish
#
# Note: if importing fails, kill all instances of `gpg-agent` and try again.
```

Now that the (subkey) is imported, we need to update its trust level:

```sh
gpg --homedir /var/lib/gitea/data/home/.gnupg --edit-key 0xA36F2B11E12C310D
```

```
gpg (GnuPG) 2.4.5; Copyright (C) 2024 g10 Code GmbH
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

Secret subkeys are available.

gpg: /var/lib/gitea/data/home/.gnupg/trustdb.gpg: trustdb created
pub  ed25519/A1596EF2CE56B350
     created: 2024-05-05  expires: never       usage: SC
     trust: unknown       validity: unknown
ssb  ed25519/A36F2B11E12C310D
     created: 2024-05-05  expires: never       usage: S
[ unknown] (1). Example Gitea <gitea@git.example.com>

gpg> trust
pub  ed25519/A1596EF2CE56B350
     created: 2024-05-05  expires: never       usage: SC
     trust: unknown       validity: unknown
ssb  ed25519/A36F2B11E12C310D
     created: 2024-05-05  expires: never       usage: S
[ unknown] (1). Example Gitea <gitea@git.example.com>

Please decide how far you trust this user to correctly verify other users' keys
(by looking at passports, checking fingerprints from different sources, etc.)

  1 = I don't know or won't say
  2 = I do NOT trust
  3 = I trust marginally
  4 = I trust fully
  5 = I trust ultimately
  m = back to the main menu

Your decision? 5
Do you really want to set this key to ultimate trust? (y/N) y

pub  ed25519/A1596EF2CE56B350
     created: 2024-05-05  expires: never       usage: SC
     trust: ultimate      validity: unknown
ssb  ed25519/A36F2B11E12C310D
     created: 2024-05-05  expires: never       usage: S
[ unknown] (1). Example Gitea <gitea@git.example.com>
Please note that the shown key validity is not necessarily correct
unless you restart the program.

gpg> quit
```

Lastly, we need to configure Gitea to not even attempt to open a pinentry prompt
since there isn't going to be anyone around to answer it. We can achieve this by
configuring git to call a wrapper program which invokes GPG with `--batch`
(which will disable these prompts)

```sh
# On NixOS, system-wide packages show up in /run/current-system/sw/bin/
# swap it out with the appropriate location on your system
echo >/var/lib/gitea/data/home/gpg-nopinentry <<'EOF'
#!/usr/bin/env bash
exec /run/current-system/sw/bin/gpg --batch "$@"
EOF
chmod +x /var/lib/gitea/data/home/gpg-nopinentry

echo >>/var/lib/gitea/data/home/.gitconfig <<EOF
[gpg]
	program = "/var/lib/gitea/data/home/gpg-nopinentry"
EOF
```

# Telling Gitea about the new key

Gitea still needs to be instructed to use the key. There are a number of
[configuration options] to consider but here are the most important ones to set.
Make sure they match the values that were originally set when generating the
root key.

```ini
[repository.signing]
SIGNING_KEY=0xA36F2B11E12C310D
SIGNING_NAME=Example Gitea
SIGNING_EMAIL=gitea@git.example.com
```

# Clean up

Back on the original host we can now purge the secret keys (assuming they have
been backed up securely) to minimize them getting compromised:

```sh
gpg --delete-secret-keys 0xA1596EF2CE56B350
```

Happy self-hosting!

[automatically signing commits]: https://web.archive.org/web/20240420145934/https://docs.gitea.com/administration/signing#automatic-signing
[configuration options]: https://web.archive.org/web/20240405224925/https://docs.gitea.com/administration/config-cheat-sheet#repository---signing-repositorysigning
