+++
title = "Tips and Tricks for Nix Flakes"
description = "Tips and tricks to keep in mind when working with Nix flakes"
date = 2021-12-12

[taxonomies]
tags = ["NixOS", "flakes"]
+++

After working with Nix flakes for a while you develop a sense for how to
interact with them in more efficient or ergonomic ways. That said, a number of
the interactions I'm about to describe were _extremely non-obvious_ to me,
especially as someone who had never peeked at their actual implementation.

This is the cheat-sheet I wish someone had shown me when I first started
tinkering with flakes. I hope you find it useful.

<!-- more -->

# Wrangling Flake Inputs

The flake input schema allows for:

1. Having your flake pull in _another flake_ as an input
1. Having your flake pull in an input that is specified by _another flake_
1. Forcing _another flake_ to use an input specified in your flake
1. Forcing _another flake_ to use an input specified by **yet a different
   flake**

Being aware of this functionality can be useful in ensuring that all inputs
agree on the same common dependency: for example, using the same revision of
`nixpkgs` can avoid having multiple versions of the same package floating in the
output closure, each built with slightly different dependencies coming from
different `nixpkgs` commits.

Let's take a look at some examples.

```nix
{
  inputs = {
    # Case 1, pulling in some flake(s) we care about, locked to some revision
    dotfiles.url = "github:ipetkov/dotfiles";
    mypinned-nixpkgs.url = "github:NixOS/nixpkgs/34ad3ffe08adfca17fcb4e4a47bb5f3b113687be";

    # Case 2, pulling in an input specified by another flake. In this case
    # we may want to treat the `dotfiles` flake as some common source-of-truth
    # and use the nixpkgs version from there
    mynixpkgs.follows = "dotfiles/nixpkgs";

    # Case 3, forcing another flake to use one of our inputs
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "mypinned-nixpkgs";
    };

    # Case 4, forcing another falke to use a _different flake's input_ as its
    # own, but without pulling said input in our scope
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.flake-compat.follows = "dotfiles/flake-compat";
    };
  };

  outputs = {
    self,
    dotfiles,
    mypinned-nixpkgs,
    mynixpkgs,
    home-manager,
    deploy-rs,
    # NB: no ... wildcard here, these are all the inputs we have declared for
    # our flake!
  }: {
    # Rest of flake...
  };
}
```

When in doubt, `nix flake info` will show all inputs and what revision (or
other flake's inputs) are being tracked!

## Updating Inputs

1. `nix flake update` will try to update _all_ inputs where possible
   - Inputs pinned to specific revisions will, of course, remain pinned
   - Easiest way to ensure everything stays up to date
1. `nix flake lock --update-input $NAME` will only try to update the `$NAME`
input
   - Useful for updating one particular input more frequently (e.g. via
     automation) without necessarily updating other _unpinned_ inputs (like
     `nixpkgs`)
1. The common flake option `--override-input $INPUT $NEW` can be used to
substitute a different input for the current invocation _without_ updating the
lock file
   - This could be useful for building the current flake while programmatically
     bisecting an input

# Flake Checks

The `nix flake check` command is a great way to ensure that the entire flake
configuration is up to snuff with a single invocation. It's also a great target
for your CI system to run so you don't have to keep reconfiguring it whenever a
new package or system configuration is added.

Other benefits include:

* All `nixosConfigurations` are evaluated (but not built) to check for any
  option/configuration collisions without needing to go through `nixos-rebuild
  dry-build --flake .`
* Checks can include any arbitrary derivation. I personally like to include all
  of my package definitions as well so that they can be built with the same `nix
  flake check` invocation (caching will take care of this being fast).
* You can include extra targets in there, especially stuff like
  linters/formatters which you would want to gate CI on (but not necessarily
  prevent downstream consumers from building packages if these tests fail).

# Exploring Flake Contents

Sometimes it can be useful to (interactively) explore what a flake holds which
you can't easily spot via something like `nix flake show` (things like "what is
the actual derivation for _X_ check", or exploring the fully evaluated
configurations of a NixOS configuration, etc.). This is where `nix repl` becomes
very useful.

In the same way that `:l <nixpkgs>` can be invoked to load a Nix expression and
bring it into scope, `:lf .` will load a Nix flake from the current directory
and add it to the scope. The `output` attribute will already be evaluated so
tab-completion will work with something like
`outputs.nixosConfigurations.<TAB>`.

Note that the `:lf` built-in is available in Nix 2.4 or later. Flakes can also
be loaded via `builtins.getFlake (toString ./.)` on earlier Nix versions which
have the experimental flakes feature enabled.

# Shell Completions

Check to see if you have shell completions enabled for your favorite shell, if
they aren't already. I like to use [fish] which has really good completion
support out of the box, especially with completions already configured for other
packages via NixOS/home-manager configs.

Completions didn't used to work a while back, but they sure do now! So next time
you invoke a command on a flake, try out something like `nix build
.#packages.x86_64-linux.<TAB>`.

# General Flake Consumption

Contrary to how it appears at first, there are only a handful of flake
properties which are ~~magical~~ built-in and understood by Nix itself:

1. Reading/managing the `flake.lock` file
1. Pulling in input sources to the store
1. Evaluating the `outputs` function with the inputs passed in

Besides that, everything else behaves like any other nix expression. Sure, the
CLI is aware of things like `checks`/`packages`/`devShells`, or it may expect
certain formats like `checks` being derivations or `nixosConfigurations` nix
modules, but it won't mind or stop you from defining your own attributes on the
flake itself. It will just ignore them.

For example, here's how we can define our own home-manager configuration.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, home-manager }: {
    homeManagerConfigurations.x86_64-linux = {
      myConfig = home-manager.lib.homeManagerConfiguration {
        system = "x86_64-linux";
        username = "ivan";
        homeDirectory = "/home/ivan";
        stateVersion = "21.03";
        configuration = {...}: {
          # Some config
        };
      };
    };
  };
}
```

If we want to manually build (and cache) the packages associated with the
configuration, we can invoke `nix build
.#homeManagerConfigurations.x86_64-linux.myConfig.activationPackage`.

If we wanted to automate building all home-manager configurations for a
particular system in our CI, we can add the file below and configure our CI to
execute `nix build -f ciHomeManagerConfigurations.nix`!

```nix
# ciHomeManagerConfigurations.nix
{ system ? builtins.currentSystem }:

let
  flake = builtins.getFlake (toString ./.);
  inherit (flake.inputs.nixpkgs) lib;

  homeManagerConfigsForSystem = lib.attrByPath
    [system]
    {}
    flake.homeManagerConfigurations;
in
  # Return all home-manager configuration derivations matching the current system
  lib.attrsets.mapAttrs
    (_: hmConfig: hmConfig.activationPackage)
    homeManagerConfigsForSystem
```

[fish]: https://fishshell.com/
