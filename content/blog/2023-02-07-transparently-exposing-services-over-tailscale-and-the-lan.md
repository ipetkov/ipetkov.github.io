+++
title = "Transparently Exposing Services Over Tailscale and the LAN"
description = ""
date = 2023-02-07

[taxonomies]
tags = ["dns", "pihole", "tailscale"]
+++

Suppose we have control of our own domain and a set of services we want to share
with (only) our friends and family. Here's how we can make them accessible over
both Tailscale or when connected to the same physical network while using the
_exact same domain_ in each case.

<!-- more -->

> I personally _love_ Tailscale and it truly makes securely connecting devices
> incredibly easy. That said, it's not always _practical_ to expect all friends
> and family to have Tailscale set up and always connected, so there's
> definitely a value to being able to access services on the local network
> directly.

# Prerequisites
Things we'll need and their example values. Remember to substitute these with your
own!
1. A domain we control: `example.com`
1. A subdomain we would like to use for the service: `rainbows.example.com`
1. A tailnet name: `cat-crocodile.ts.net`
1. A host (on the local network) running the `rainbows` service
   - A machine name assigned to this host in Tailscale: `fido` (meaning the
     host can be reached via `fido.cat-crocodile.ts.net` over Tailscale)
   - A stable local IP address for `fido`: likely something like `192.168.0.42`
1. A(n always reachable) host to run a DNS server: `dennis`
   - A stable local IP address for `dennis`: likely something like `192.168.0.42`
   - The local network's DHCP server (i.e. your router) should assign this
     IP as the primary DNS server for the rest of the local network
1. MagicDNS enabled on the tailnet
1. The appropriate Tailscale ACLs such that `dennis`' port 53 is accessible
 (and whatever other ports the `rainbows` service will use on `fido`, e.g. 443
 for HTTPS)
1. A "base" DNS server:
   - This can be a [Pi-hole](https://pi-hole.net/), though if it is going to be
     running on `dennis` you will need to configure it to listen to _any port
     besides 53_ (the default DNS port).
   - Or this can be any public DNS provider like `9.9.9.9`

# The Approach

First we need to create a CNAME record pointing `rainbows.example.com` to
`fido.cat-crocodile.ts.net`; this should be done on the nameserver for
`example.com`, likely your domain registrar.

Next, we _could_ configure our local DNS server (i.e. our Pi-hole instance
running on `dennis`) to hard-code an address record pointing
`fido.cat-crocodile.ts.net` to `192.168.0.42` _except this will not work_ if
`dennis` is set as the global nameserver for your tailnet: if you ever leave the
local network `dennis` will recursively resolve `rainbows.example.net` to the
"wrong" address.

Instead `dennis` needs to run a recursive DNS server _which can tailor results
based on the requester's address_. Namely, if a request comes from a local
address for `rainbows.example.com` or `fido.cat-crocodile.ts.net` it would need
to respond with `192.168.0.42` directly; otherwise it should use MagicDNS to
resolve to the Tailscale IP.

BIND's `named` fulfills our use-case perfectly: it can present different _views_
of DNS records based on the requester's address (among other things).

# Configuration

Below is the minimal configuration necessary to get things working with `named`.
Remember to change the placeholder values with your own, but otherwise feel free
to tailor it further to your needs:

```
acl tailnet { 100.64.0.0/10; };
acl mynet {
  localnets; # bind builtin, automatically represents all interfaces on the device
  tailnet; # also include tailscale's range (which is the Carrier Grade NAT range)
};

options {
  directory "/run/named";
  querylog no; # Change to `yes` to debug queries

  listen-on { any; };
  listen-on-v6 { any; };

  # Keep this set to `only` if using Pi-hole. Setting it to `first`
  # will result in `named` trying to resolve results on its own which
  # would defeat Pi-hole's filtering
  forward only;

  # Assuming there is a Pi-hole instance running on this host on port 9053,
  # forward requests for any zones not configured here. If you aren't using
  # Pi-hole this can be replaced with any other public DNS (e.g. `9.9.9.9`).
  forwarders { 127.0.0.1 port 9053; };

  # Allow recursive resolution for any LAN/Tailscale queries
  recursion yes;
  allow-query { mynet; };
  allow-recursion { mynet; };
  allow-query-cache { mynet; };
};

# NB: view order is significant here: views are considered one by one and only
# the first one to match is used. Specifically, the `catchall` view will
# effectively be used for non-tailnet clients as they would have otherwise been
# matched by the `tsnet` view
view tsnet {
  match-clients { tailnet; };

  # We forward any queries for our tailnet directly to the MagicDNS server
  # since it should have the results for any hosts on the tailnet (which the
  # upstream DNS likely won't).
  # NB: be _very_ careful that the tailnet name does not change here
  # and also be careful to ensure that this host was initialized with
  # `tailscale up --accept-dns=false` otherwise we could end up recursively
  # ourselves if the MagicDNS forwards any non-tailnet queries back to us
  zone "cat-crocodile.ts.net" IN {
    type forward;
    forward only;
    forwarders { 100.100.100.100; }; # Tailscale's MagicDNS IP
  };
};

# The "catchall" view which will match all clients. Remember
# that the earlier view will filter out any tailnet clients
# maning this view represents clients directly on the local network
view catchall {
  match-clients { any; };

  zone "cat-crocodile.ts.net" IN {
    type primary;
    file "/path/to/file/for/lan/zone/cat-crocodile.ts.net";
  };
};
```

Where the contents of `/path/to/file/for/lan/zone/cat-crocodile.ts.net` are:

```
$TTL 2d
$ORIGIN cat-crocodile.ts.net.
@ IN SOA dns.example.com. hostmaster.example.com. (
                                1          ; serial number
                                12h        ; refresh
                                15m        ; update retry
                                3w         ; expiry
                                2h         ; minimum
                                )
@ IN NS  dns.example.com.
@ IN A   192.168.0.42
```
