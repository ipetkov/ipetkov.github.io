+++
title = "Building with SQLx on Nix"
date = 2021-12-09

[taxonomies]
tags = ["NixOS", "naersk", "rust"]
+++

[SQLx] is a Rust crate for asynchronously accessing SQL databases. It works by
checking all queries at compile time, which means it needs access to the
database when building.

Although it supports an offline-mode (intended for CI or network-blocked
builds), I prefer avoiding having to remember to manually run commands to keep
schemas in sync.

Let's take a look at how we can efficiently automate this with [Naersk]!
<!-- more -->

```nix
# mycrate.nix
{ naersk
, runCommand
, sqlx-cli
, targetPlatform
}:

let
  src = ./mycrate;                                                # 1
  srcMigrations = src + /migrations;                              # 2

  sqlx-db = runCommand "sqlx-db-prepare"                          # 3
    {
      nativeBuildInputs = [ sqlx-cli ];
    } ''
    mkdir $out
    export DATABASE_URL=sqlite:$out/db.sqlite3
    sqlx database create
    sqlx migrate --source ${srcMigrations} run
  '';
in
naersk.lib."${targetPlatform.system}".buildPackage {
  inherit src;

  doCheck = true;
  CARGO_BUILD_INCREMENTAL = "false";
  RUST_BACKTRACE = "full";
  copyLibs = false;

  overrideMain = old: {                                           # 4
    linkDb = ''
      export DATABASE_URL=sqlite:${sqlx-db}/db.sqlite3            # 5
    '';

    preBuildPhases = [ "linkDb" ] ++ (old.preBuildPhases or [ ]); # 6
  };
}

```

At a high level, Naersk builds the crate in two parts: one derivation builds all
cargo dependencies on their own, and second derivation uses the artifacts from
the first when building the actual crate source. This pattern can be extended by
adding a *third* derivation which can prepare a SQLite database which `sqlx` can
use for query validation.

Let's break down the configuration above:

1. We define a path to the cargo root. I prefer to keep the crate files in their
   own sub-directory so that builds don't get accidentally invalidated when
   other files get changed (e.g. extra nix files, READMEs, etc.). It is possible
   to use `cleanSourceWith` or [`nix-gitignore`] to filter out extra files, but
   it can get a bit fiddly at times, and easy to forget to allow/block list new
   files.
1. Regardless of where the crate source is hosted, we want to make sure that the
   source we pass into `sqlx` *only contains the `migrations`* directory. This
   will avoid having to rebuild the database unnecessarily.
1. This command defines the script for having `sqlx` create the database and
   perform any migrations, using the source from step #2, and saving the result
   to the derivation's `$out` directory.
1. Naersk will, by default, pass all of its inputs to *both* the crate and deps
   derivations. Here we use `overrideMain` such that our changes apply _only to
   the final crate derivation_. Since the deps derivation does not need to use
   `sqlx` we can avoid having to rebuild it if the database schema changes.
1. We define our `linkDb` step which will set the `DATABASE_URL` variable that
   `sqlx` will use when doing the query validation.
1. And lastly, we register the step as a `preBuildPhase` since it needs to run
   before all cargo build steps are invoked.

This leaves us  with the following (minimal) dependency tree:

```
+--------------------+    +------------+
|./mycrate/Cargo.lock|--->|mycrate-deps|
+--------------------+    +------------+
                              |
                              V
+------------+            +---------+
|sqlx-prepare|----------->| mycrate |
+------------+            +---------+
        ^                     ^
        |                     |
+--------------------+    +---------+
|./mycrate/migrations|~~~>|./mycrate|
+--------------------+    +---------+
```

<details>
  <summary>Auxiliary example files can be found here.</summary>

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    utils = {
      url = "github:numtide/flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, naersk, utils, ... }:
    utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        defaultPackage = pkgs.callPackage ./mycrate.nix {
          inherit naersk;
        };

        devShell = pkgs.mkShell {
          inputsFrom = [
            self.defaultPackage.${system}
          ];

          buildInputs = with pkgs; [
            sqlx-cli
          ];
        };
      });
}
```

```sh
# mycrate/.env
DATABASE_URL=sqlite:./db.sqlite3
```

```toml
# mycrate/Cargo.toml
[package]
name = "mycrate"
version = "0.1.0"
edition = "2021"

[dependencies.sqlx]
version = "0.5.9"
features = [
  "macros",
  "migrate",
  "runtime-tokio-rustls",
  "sqlite",
]

[dependencies.tokio]
version = "1.14"
features = [
  "macros",
]
```

```sql
/* mycrate/migrations/20211209212234_first.sql */
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  favorite_song TEXT
)
```

```sql
/* mycrate/migrations/20211209212255_second.sql */
ALTER TABLE users
ADD COLUMN favorite_color TEXT;
```

```rust
// mycrate/src/main.rs
use sqlx::{Connection, SqliteConnection, migrate::Migrator};

static MIGRATOR: Migrator = sqlx::migrate!("./migrations");

#[tokio::main]
async fn main() {
    let mut conn = SqliteConnection::connect("sqlite:./db.sqlite3").await
        .expect("failed to get conn");

    MIGRATOR
        .run(&mut conn)
        .await
        .expect("failed to run migrations");

        let result = sqlx::query_scalar!("SELECT count(*) FROM users WHERE favorite_color = 'green'")
            .fetch_one(&mut conn)
            .await
            .expect("failed to count users");

    println!("number of users: {}", result);
}
```
</details>


[Naersk]: https://github.com/nix-community/naersk
[`nix-gitignore`]: https://nixos.org/manual/nixpkgs/unstable/#sec-pkgs-nix-gitignore
[SQLx]: https://github.com/launchbadge/sqlx
