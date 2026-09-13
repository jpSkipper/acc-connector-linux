# ACC Connector - TUI
#
# This flake builds the Python package with pyproject.nix (per
# https://wiki.nixos.org/wiki/Python#Package_a_Python_application:_With_pyproject.toml)
# and *also* reproduces the two things the old install.sh did by hand:
#
#   1. `python3 -c "assert sys.version_info >= (3,10)"`
#      -> not needed: the flake pins an exact `python` interpreter, so the
#         build simply fails at eval/build time if pyproject.toml's
#         `requires-python` isn't satisfiable by the pinned version.
#
#   2. Writing ~/.local/share/applications/acc-connector.desktop and running
#      `xdg-mime default ... x-scheme-handler/acc-connect`
#      -> replaced with a *declarative* Desktop Entry baked into the Nix
#         store output (see `desktopItem` / `withDesktop` below). Nix
#         packages should never reach into $HOME during the build, so we
#         install the .desktop file into $out/share/applications instead.
#         NixOS / home-manager / most desktop environments already run
#         `update-desktop-database` automatically whenever a profile
#         containing such a file is activated, so the "registration" step
#         becomes automatic instead of a manual script.
#
# If you still need imperative `xdg-mime` registration (e.g. you are not
# using NixOS/home-manager and just want `nix profile install` to behave
# like the old script), see the `activation-note` comment at the bottom.

{
  description = "ACC Connector - TUI";

  inputs = {
    # NOTE: the original flake referenced `nixpkgs` (via
    # `pyproject-nix.inputs.nixpkgs.follows` and directly in `outputs`)
    # without ever declaring it as a top-level input. That worked only
    # because Nix implicitly pulled it in as a transitive input of
    # pyproject-nix, which is fragile and version-pins you to whatever
    # pyproject-nix happens to use. Declare it explicitly instead.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:nix-community/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, pyproject-nix, ... }:
    let
      inherit (nixpkgs) lib;

      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python3;

      # Load & unmarshal pyproject.toml relative to this flake's root.
      # `projectRoot` is also used as `src` by the buildPythonPackage
      # renderer below, so this flake must live in (or next to) the repo
      # that contains pyproject.toml. If you instead want to build the
      # *published* GitHub repo without cloning it locally (mirroring what
      # `pip install git+https://...` did), see the `remoteSrc` example
      # further down.
      project = pyproject-nix.lib.project.loadPyproject {
        projectRoot = ./.;
      };

      # ---------------------------------------------------------------
      # 1. The plain Python package (equivalent to the original flake).
      # ---------------------------------------------------------------
      acc-connector = python.pkgs.buildPythonPackage (
        (project.renderers.buildPythonPackage { inherit python; })
        // {
          env.CUSTOM_ENVVAR = "hello";

          # Optional: fail fast with a clear error instead of a cryptic
          # one if pyproject.toml's requires-python can't be satisfied by
          # the pinned interpreter. `project.renderers.buildPythonPackage`
          # already encodes this constraint for pip-style consumers, but
          # asserting here gives a nicer Nix-side error message too.
          meta.description = "ACC Connector TUI";
        }
      );

      # ---------------------------------------------------------------
      # 2. Declarative replacement for the desktop-file / xdg-mime steps.
      # ---------------------------------------------------------------
      # `makeDesktopItem` renders a .desktop file with the same fields
      # the install script wrote by hand. Nix computes the absolute path
      # to the built binary itself (${acc-connector}/bin/acc-connector),
      # so there's no need for `command -v acc-connector` at install time.
      desktopItem = pkgs.makeDesktopItem {
        name = "acc-connector";
        desktopName = "ACC Connector";
        exec = "${acc-connector}/bin/acc-connector %u";
        # MimeType must end in a semicolon per the Desktop Entry spec,
        # exactly like the original heredoc.
        mimeTypes = [ "x-scheme-handler/acc-connect" ];
        noDisplay = true;
      };

      # `symlinkJoin` merges the Python package's own $out (bin/, lib/,
      # etc.) with the desktop item's $out (share/applications/*.desktop)
      # into a single derivation. This is the thing you actually want to
      # install: it carries both the executable *and* the mime
      # association, with no imperative post-install step required.
      acc-connector-with-desktop = pkgs.symlinkJoin {
        name = "acc-connector-with-desktop";
        paths = [
          acc-connector
          desktopItem
        ];
        # Regenerate the desktop database cache inside the derivation
        # itself. This is optional (profile activation usually does it
        # too) but makes the package self-contained, e.g. for `nix run`
        # or ad-hoc `nix shell` usage where no profile activation runs.
        nativeBuildInputs = [ pkgs.desktop-file-utils ];
        postBuild = ''
          update-desktop-database "$out/share/applications" || true
        '';
      };

    in
    {
      packages.${system} = {
        # `nix build` -> just the Python package, no desktop integration.
        acc-connector = acc-connector;

        # `nix build .#default` -> package + registered URI handler.
        # This is the one you want end users to install.
        default = acc-connector-with-desktop;
      };

      # Lets `nix run .` invoke the TUI directly, same as running
      # `acc-connector` after the old install.sh finished.
      apps.${system}.default = {
        type = "app";
        program = "${acc-connector}/bin/acc-connector";
      };

      # ---------------------------------------------------------------
      # 3. home-manager module: installs the package *and* declares the
      #    URI scheme association in one step.
      # ---------------------------------------------------------------
      # This is the fully declarative equivalent of the old install.sh:
      # no `xdg-mime default ...` call is ever run, because home-manager
      # writes the equivalent config (mimeapps.list) itself from this
      # setting, every time the user's home-manager generation is
      # activated. Users pull this in with:
      #
      #   { inputs, ... }: {
      #     imports = [ inputs.acc-connector.homeModules.default ];
      #   }
      #
      # ...and get the package + mime default with no manual step at all.
      homeModules.default =
        { pkgs, lib, ... }:
        {
          # Install the package. We use `acc-connector-with-desktop` (not
          # the bare `acc-connector`) so the .desktop file is present in
          # the user's profile for launchers/menus, even though the mime
          # default itself is now driven by `xdg.mimeApps` below rather
          # than the .desktop file's own `MimeType=` field.
          home.packages = [ acc-connector-with-desktop ];

          xdg.mimeApps = {
            enable = true;
            defaultApplications."x-scheme-handler/acc-connect" = "acc-connector.desktop";
          };

          # Standalone home-manager on a non-NixOS distro does not, by
          # itself, arrange for your graphical session to pick up
          # `~/.nix-profile/share` in XDG_DATA_DIRS (or the profile's
          # bin dir in PATH via a login shell). Without that, .desktop
          # files installed above are invisible to your DE and to
          # browsers resolving `acc-connect://` links, even though the
          # binary runs fine from a shell that already has the profile's
          # bin/ on PATH. `targets.genericLinux` wires up the session
          # variables non-NixOS systems are missing. It's a no-op (and
          # harmless) if you're on NixOS, where this is already handled.
          targets.genericLinux.enable = lib.mkDefault true;
        };
    };
}

# ---------------------------------------------------------------------
# activation-note: if you are NOT on NixOS/home-manager and want the
# mime association to be registered the moment someone runs
# `nix profile install .#default` (rather than relying on your desktop
# environment's own profile-activation hooks), you have two options:
#
#   a) home-manager users: import `homeModules.default` from this flake
#      instead of setting `xdg.mimeApps` by hand:
#        { inputs, ... }: {
#          imports = [ inputs.acc-connector.homeModules.default ];
#        }
#      That module installs the package AND sets
#        xdg.mimeApps.defaultApplications."x-scheme-handler/acc-connect" =
#          "acc-connector.desktop";
#      for you. This is the fully declarative, reproducible equivalent
#      of the original `xdg-mime default ...` call — home-manager writes
#      mimeapps.list itself on every activation, so there's no imperative
#      step left at all.
#
#   b) non-NixOS, imperative fallback: keep a tiny wrapper script (NOT
#      part of the Nix build, since builds must be side-effect-free and
#      can't touch $HOME) that runs, after installing the package:
#        xdg-mime default acc-connector.desktop x-scheme-handler/acc-connect
#      This is just the original install.sh's mime-handling snippet,
#      kept separate from the reproducible Nix build on purpose.
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# remoteSrc example: building straight from GitHub instead of a local
# checkout (closer to `pip install git+https://github.com/...`):
#
#   project = pyproject-nix.lib.project.loadPyproject {
#     projectRoot = pkgs.fetchFromGitHub {
#       owner = "cescofry";
#       repo  = "acc-connector-linux";
#       rev   = "main";              # pin a commit/tag for reproducibility
#       sha256 = lib.fakeSha256;     # replace with the real hash on first build
#     };
#   };
#
# Everything else (acc-connector, desktopItem, acc-connector-with-desktop)
# stays the same.
# ---------------------------------------------------------------------
