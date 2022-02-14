+++
title = "Crane Support for Alternative Registries and Git Dependencies"
description = "Crane now supports building cargo projects with alternative registries and git dependencies!"
date = 2022-02-13
updated = 2022-02-14

[taxonomies]
tags = ["NixOS", "rust", "cargo", "crane"]
+++

Since the initial release of [Crane], I've been busy hacking on adding support
for building projects which may pull in dependencies from alternative registries
as well as git repositories. I wanted to share how it works, so let's dive right
in!

<!-- more -->

# Alternative Registries

Although crates.io is the default registry for the majority of (public) Rust
projects, cargo _does_ allow for configuring any other crate registry/index to
be used for dependencies. So far, the main use-case for alternative registries
seems to be for privately publishing crates (e.g. on an enterprise network)
judging by the lack of other _public_ registries present in the ecosystem (well,
except for [Alexandrie] which was very useful for my testing!).

The workflow for vendoring crates is pretty much the same, regardless if the
crates come from crates.io or some other index:
1. We check the project's `.cargo/config.toml` file (if it exists) to see what
   registries are defined (specifically their unique index URL and the name used
   to link them to dependency definitions in `Cargo.toml`)
1. We then crawl the `Cargo.lock` file to find out the name, version, checksum,
   and (registry) source (i.e. the index URL) for each dependency package
1. Using this information we can construct the download URL for the crate and
   pull down the source to the Nix store. __We'll come back to this step in a bit.__
1. The sources are then grouped by the registry they come from, and are unpacked
   in a format that cargo can understand
   * The sources are basically tarballs which are extracted into directories
     named after the crate's name and version, along with some checksum metadata
     used by cargo to validate the sources are as expected.
1. Finally, we write some configuration which can instruct cargo to look at the
   directories we've prepared when building the project, instead of trying to
   access the network itself (which would fail if running inside of a sandboxed
   build).

So how does cargo figure out what the download URL is for a particular crate?

The [specification] requires that the index contain a `config.json` file at its
root which defines the endpoint and path that should be used for downloading
crate sources. This definition can also contain placeholders (like the crate's
name and version among other things) which need to be substituted to create the
final URL used for fetching the source.

How does Crane figure out the download configuration for each registry?
Unfortunately, we _have to tell it_. We can take a look at a [full example] in
context, but in summary, we have two options to take:
1. The first option is to straight up copy the configuration out of the index's
   `config.json` file and tell Crane about it. This is the simplest and most
   lightweight option we can employ, especially if the download endpoint and
   path virtually never change.
   ```nix
   craneLibOrig = crane.lib.${system};
   craneLib = craneLibOrig.appendCrateRegistries [
     (craneLibOrig.registryFromDownloadUrl {
       indexUrl = "https://github.com/Hirevo/alexandrie-index";
       dl = "https://crates.polomack.eu/api/v1/crates/{crate}/{version}/download";
     })
   ];
   ```
1. The second option is to tell Crane about a particular revision of the index
   and let it figure out the download template on its own. This option has the
   benefit of having a single canonical source of truth (without copying URLs
   around by hand), and, if the download endpoint or path changes from time to
   time, it can easily be remedied by updating the index snapshot to a newer
   revision (which is especially nice if it needs to be automated). The cost of
   this option, however, is needing to check out the _entire index_ at that
   revision and put a copy of it in the store before we can evaluate the
   derivation. Note that this revision only needs to be updated if the
   `config.json` file changes, so it is safe to pin to a version for as long as
   that takes.
   ```nix
   craneLibOrig = crane.lib.${system};
   craneLib = craneLibOrig.appendCrateRegistries [
     (craneLibOrig.registryFromGitIndex {
       indexUrl = "https://github.com/Hirevo/alexandrie-index";
       rev = "90df25daf291d402d1ded8c32c23d5e1498c6725";
     })
   ];
   ```

Technically, we could try to automate this away completely by always fetching
the latest version of the index and looking at the configuration before
downloading any crate sources. Even ignoring issues with requiring impure
evaluations to make this work, this would make for a really bad default from a
performance standpoint.

You see, cargo keeps a checked out version of every registry index that has ever
been used (usually somewhere in your home directory). It used during dependency
resolution (such as what are the latest published/yanked version, etc.) and
incrementally fetched as needed.

When we build with Nix, however, we don't care about re-resolving dependencies
since the Cargo.lock file already pins everything into place; checking out the
entire index to the store, just to peek at a small configuration file and throw
the results away seems wasteful. Even the store is regularly cleaned out, we
would still need to fetch the index again and again any time the derivation is
evaluated. That's a lot of wasted bandwidth, especially as the index accrues
newly published crates. And lets not forget that Nix doesn't keep the repository
around such that it can be incrementally fetched, either.

I really wish this paper cut experience of having to manually specify
alternative registries can be improved in the future, but for now, it seems like
the best choice available.

# Git Dependencies

Vendoring crate sources from git repositories is roughly the same as vendoring
from registries:
1. We crawl the `Cargo.lock` file to look for any packages originating from git
   sources, and find out the repository's URL as well as the revision that has
   been locked
1. We then pass the git URL and revision to Nix which will pull down the source
   for us
   * Note: this does not pull down the entire repository, we _only_ get a
     checkout of the revision.
   * Fetching a git repository is not reproducible, as any new commit or branch
     would add new data which would result in invalidating all of our build
     caches
1. The one main difference between a git dependency and a registry tarball is
   that the tarball always contains a single crate. The git repository could
   contain an entire workspace of crates. To handle this, we crawl the source
   looking for `Cargo.toml` files as a proxy for identifying what crates are
   present.
   * Looking for `Cargo.toml` is a simple heuristic which goes a long way.
     Although there can be a false-positive (we vendor a crate not part of the
     actual workspace), we cannot have a false-negative (accidentally ignore a
     real crate) since you cannot define a crate without a `Cargo.toml` file.
   * Ultimately, cargo will ignore the crates it does not care about which gives
     us some flexibility here.
   * Why not ask `cargo metadata` to tell us about the workspace members?
     - Doing so will make cargo try to pull down the sources from the network to
       tell us about them. Since this whole exercise is to pull the sources down
       _for_ cargo, we need to avoid this chicken-egg problem somehow.
   * Why not look at the `[workspace]` definition in the `Cargo.toml` file if it
     exists?
     - Cargo supports glob patterns both for including **and** excluding
       members. Re-implementing this logic ourselves is way too overkill when a
       simple search can get us where we need.
1. We then transform the crates into the same vendor directory structure as for
   registries (i.e. each crate goes into its own sub-directory using the crate's
   name and version).
1. And finally, we generate some configuration that can instruct cargo to look
   at these vendored directories as is appropriate.

One interesting thing to note that whereas the "unique unit of vendoring" for a
registry is the _index itself_, for git dependencies it is _the specific
revision of a particular repository_. In other words, all crates coming from the
same registry/index are vendored in one directory which is registered as a
single source replacement with cargo. All crates coming from the same git
repository **and** revision are also vendored in one directory and registered as
a single source replacement with cargo, but more git revisions in the dependency
closure will result in more cargo sources behind the scenes.

There's several benefits to this approach:
1. First and foremost we don't have to care (or worry) about whether there is a
   name/version collision between crates coming from a registry or from a git
   repository. Each will get their own unique "vendor space" for which we know
   is impossible to have collisions!
1. Even if we do get a collision, we can avoid the risks of having to establish
   which source would take precedence! We simply make the sources _available_ to
   cargo, and it is free to use (or ignore them) based on how the project
   authors' have dictated via the `Cargo.toml` and `Cargo.lock` files
   * To illustrate this point a bit further, consider the following: you may
     have a workspace which may contain an auxillary crate used for running
     tests. Perhaps this crate pins to some ancient git revision of a dependency
     crate to perform some compatibility testing.
   * We wouldn't want this dependency to get selected when building our
     production binaries as we would likely want to use the latest and greatest
     version of that dependency as pinned by the `Cargo.lock` file
   * At the same time, we wouldn't want to ignore the pinned git version as that
     could break the tests that we thought were running
   * All in all, this means that cargo will behave the same when running under
     Nix as it does outside of it, without any unexpected surprises!

Oh and the other cool thing about this implementation is there is nothing to
configure! Everything should Just Work™ out of the box :)

# Feedback

As always, if something doesn't seem quite right or you have any feedback, feel
free to let me know on the [project repo]!

[Alexandrie]: https://github.com/Hirevo/alexandrie
[Crane]: https://github.com/ipetkov/crane
[full example]: https://github.com/ipetkov/crane/blob/fc7a94f841347c88f2cb44217b2a3faa93e2a0b2/examples/alt-registry/flake.nix#L25-L47
[project repo]: https://github.com/ipetkov/crane
[specification]: https://doc.rust-lang.org/cargo/reference/registries.html#index-format
