+++
title = "Bisecting Nix Configurations"
description = "Using Nix Flakes to quickly find a commit breaking my workflow"
date = 2022-07-29
aliases = ["/blog/bisecting-nix-configsurations/"]

[taxonomies]
tags = ["NixOS", "flakes", "debugging"]
+++

I live my life dangerously. And by that I mean I like to run _unstable_
versions of various software that I use daily and prefer to work as I expect
them. Sometimes a change will land and break my workflow, though Nix makes this
tolerable since I can always switch back to an older version of my
configuration.

Except sometimes the breakage isn't due to a bug but an intentional change
in upstream defaults, and in those cases the solution is to update my configs
appropriately. The hard part is figuring out _how and why_ they broke especially
since I don't always pay close attention to every change landing upstream.

Here's how I used Nix to find out what broke my workflow.

<!-- more -->

# Background

I run a nightly version of Neovim which I update about once a week. A few days
ago I suddenly noticed a change in behavior which I didn't like. The specific
change in question isn't so important, the key part is that I had no idea what
led to it or what was to blame, so the technique I'm about to demonstrate is a
good aid for diagnosing when something previously unnoticed goes wrong.

> In this case Neovim changed the default behavior of scrolling the mouse.
> Previously it would move the cursor, but the new default scrolls the screen
> without moving the cursor. I wasn't sure what option controls this value, and
> neither digging into the help pages, nor stackoverflow, nor glancing at the
> recent issues and commits on the Neovim repo answered my question.
> 
> Ultimately I could have probably trawled through the changelog but a) that did
> not cross my mind, and b) I wanted to quickly get to the bottom of the exact
> commit which landed the change instead of spending more time guessing.

# Bisecting a Nix Flake

I deploy my [dotfiles] through a Nix flake whose git history contains a paper
trail of every change I've ever made on my systems. They use a number of
different inputs (other dependencies) such as [nixpkgs], [home-manager], and
[neovim-nightly-overlay] and sometimes it isn't clear if undesired behavior is
due to a bug in a specific package or from a misconfiguration in a Nix module
somewhere. The situation is also exacerbated since I tend to update all inputs
at once meaning there isn't one obvious culprit.

Git has a feature to allow _bisecting_ the commit history: basically you mark
some commit known _to include_ the behavior and another commit known _to not include_
the behavior and git will begin checking commits "halfway" between them
(handling merge commits for you automatically). At each step on the way it asks
"does this commit contain the behavior?" and your response allows it to steer
its search appropriately.

In my case I knew the bad behavior showed up recently, so I randomly picked a
commit of my dotfiles to double check as a "good" commit. The latest commit was
obviously "bad".

```sh
git clone https://github.com/ipetkov/dotfiles
cd dotfiles

# Check out a random commit a week or two back
git checkout e5f21cebb9a4323fcc14397136dac6780a05ec87
# Test out the config to see the behavior
sudo nixos-rebuild --flake .# test
# Check for offending behavior, looks good
vim some_long_file

# Start a git bisect and mark the "good" and "bad" commits
git bisect start
git bisect good e5f21cebb9a4323fcc14397136dac6780a05ec87
# current HEAD
git bisect bad 09e21eede76234ff66a539079ff14f5b170e56d5

# Optional visualize the bisection progress
git bisect visualize
```

Then for each commit of my dotfiles I would deploy my configuration and verify
if the undesired behavior is there or not. It was a bit annoying having to wait
for systemd to reload random services, but I pushed through since there weren't
that many revisions to test and checking for the offending behavior was very
fast.

```sh
# For each commit git 
sudo nixos-rebuild --flake .# test

# Check for offending behavior
vim some_long_file

# If the behavior was gone, mark the commit as good
git bisect good

# Otherwise mark it as bad
git bisect bad
```

Eventually I landed on this [bad commit] which shows exactly to which commit
each dependency was updated, meaning this gives a finite set of changes to
continue testing which _must_ include the reason for the behavior change.

> Cleaning up before continuing on is as easy as `git bisect reset`

# Verifying Inputs

The next step was to figure out which input led to the change in behavior. I
started by updating my `flake.lock` file to use the all the commits from before
the bad update was applied. One by one I updated them to their version found in
the [bad commit], testing each time.

> There is a way to accomplish this without editing the `flake.lock` file and
> specify commit overrides directly when invoking Nix like: `nixos-rebuild
> --flake .# --override-input nixpkgs github:NixOS/nixpkgs/$COMMIT_SHA`. I
> didn't bother doing that since editing the `flake.lock` was faster without
> having to juggle multiple input overrides on the command line each time.

1. First I changed the `nixpkgs-stable` input (which I know was not used in the
   configuration for the machine I was using, but it was a good sanity check)
   and the behavior did not show up (as expected).
1. Next I changed the `nixpkgs` input and the behavior did not show up. Clearly
   this was not introduced by a change there
1. Next I changed the `home-manager` input and the behavior did not show up
   either. Clearly the change was not introduced due to a configuration issue
   there
1. Then I changed the `neovim-nightly-overlay` input and the behavior did not
   show up. This input largely exists to keep track of the `neovim` input, and
   since I was manually updating the input hashes it clearly did not result in
   the bad behavior showing up.
1. Lastly I changed the `neovim` input and _bingo_ the behavior showed up. Now I
   knew that the change must have happened somewhere between
   [9777907467b29e890556db287b6a9995c0024896](https://github.com/neovim/neovim/commit/9777907467b29e890556db287b6a9995c0024896)
   and
   [bb7853a62dc32baafa7416b94c97f985287f39e2](https://github.com/neovim/neovim/commit/bb7853a62dc32baafa7416b94c97f985287f39e2)

# Bisecting Neovim

Knowing the exact range which includes the behavior change means we can run
another git bisect. In this case I directly checked out the Neovim repo since I
could test more quickly that way without having to redeploy my NixOS
configuration.

```sh
git clone https://github.com/neovim/neovim.git
cd neovim/contrib

git bisect start
git bisect good 9777907467b29e890556db287b6a9995c0024896
git bisect bad bb7853a62dc32baafa7416b94c97f985287f39e2
```

Then for each commit we test for the undesired behavior.

```sh
# Build and run all in one step to check for offending behavior
nix run .#neovim -- some_file

# If the behavior was gone, mark the commit as good
git bisect good

# Otherwise mark it as bad
git bisect bad

# Alternatively skip if a commit can't build
git bisect skip
```

At last, this process yields the [exact commit] which introduced a change in
default behavior. It was pretty easy to [apply the fix] when that was all I had
to review.

# Conclusion

In the end I was able to go from noticing an unexpected behavior to finding _a
single commit introducing the behavior_ in less than an hour. Thanks to git and
Nix I was able to do it without even having to know where to look on my own.

Can your configuration system do that?

[apply the fix]: https://github.com/ipetkov/dotfiles/commit/353aaa909d384127ff573d3b7d881b249b2295cd
[bad commit]: https://github.com/ipetkov/dotfiles/commit/4e5969ce2a88dc79c81334cc557cfc3e32bfa03b
[dotfiles]: https://github.com/ipetkov/dotfiles
[exact commit]: https://github.com/neovim/neovim/commit/eb9b93b5e025386ec9431c9d35a4a073d6946d1d
[home-manager]: https://github.com/nix-community/home-manager
[neovim-nightly-overlay]: https://github.com/nix-community/neovim-nightly-overlay
[nixpkgs]: https://github.com/NixOS/nixpkgs
