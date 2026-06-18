# Home Manager module for CyberGroupmate.
#
# Wraps the packaged derivation as a hardened systemd *user* service.
#
# Option design:
#   services.cybergroupmate.settings  — free-form attrset that maps 1:1 to the
#                                       upstream `config.yaml` schema (this is
#                                       the canonical HM pattern for complex
#                                       upstream config files; every YAML key
#                                       is a Nix key with the same name).
#   services.cybergroupmate.configFile — alternatively point at a pre-built
#                                        config file (e.g. a secret-bearing
#                                        store path).
#   services.cybergroupmate.extraSystemdService — extra attrs merged into
#                                            the generated `systemd.user.services.<name>`
#                                            definition, so callers can tweak
#                                            or override hardening / env / etc.
#
# The service is locked down as strictly as possible while still allowing
# networking (which the bot needs to reach LLM + platform APIs). Everything
# else — devices, kernel knobs, the rest of the filesystem — is denied.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cybergroupmate;

  # `pkgs.formats.yaml` gives a {type, generate} pair; `.generate name value`
  # produces a store path containing the YAML serialization of `value`.
  yamlFormat = pkgs.formats.yaml { };

  # Resolve the config file the service will load. Preference order:
  #   1. explicit `configFile` path
  #   2. declarative `settings` -> generated YAML
  #   3. nothing (the app falls back to whatever `config.yaml` already lives
  #      in the data dir, or errors out if absent).
  resolvedConfigFile =
    if cfg.configFile != null then
      cfg.configFile
    else if cfg.settings != { } then
      yamlFormat.generate "cybergroupmate-config.yaml" cfg.settings
    else
      null;

  # systemd-style "KEY=VALUE" list for the Environment= directive.
  environmentList = lib.mapAttrsToList (k: v: "${k}=${v}") (
    {
      CYBERGROUPMATE_WORKDIR = cfg.dataDir;
      NODE_ENV = "production";
      # Sanitized PATH: only the runtime bits the bot and its child processes
      # (node-pty shells, the CodeAct sandbox) are allowed to find.
      PATH = lib.makeBinPath [
        cfg.package
        pkgs.nodejs
        pkgs.coreutils
      ];
    }
    // cfg.environment
  );

  # Pre-start script: ensure the data dir exists and, when the config is
  # declared in Nix, stage the generated `config.yaml` into it (a read-only
  # store path must be copied somewhere writable so the app — and the
  # Dashboard's "save config" flow — can rewrite it; it is refreshed on every
  # service start). Written as its own shell script so the two steps read as
  # plain lines rather than an `&&`-chained one-liner.
  startPreScript = pkgs.writeShellScript "cybergroupmate-start-pre" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg cfg.dataDir}
    ${lib.optionalString (resolvedConfigFile != null) ''
      ${pkgs.coreutils}/bin/cp -f \
        ${lib.escapeShellArg resolvedConfigFile} \
        ${lib.escapeShellArg "${cfg.dataDir}/config.yaml"}
    ''}
  '';

  # Recursively wrap every leaf value of an attrset in `lib.mkDefault`, so the
  # module's own (hardened) defaults yield to anything the user sets via
  # `extraSystemdService` at normal priority.
  mkDefaultDeep = v: if lib.isAttrs v then lib.mapAttrs (_: mkDefaultDeep) v else lib.mkDefault v;
in
{
  options.services.cybergroupmate = {
    enable = lib.mkEnableOption "CyberGroupmate, a code-driven group chat social agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.cybergroupmate;
      defaultText = lib.literalExpression "pkgs.cybergroupmate";
      description = ''
        The CyberGroupmate derivation to run. Defaults to the one provided by
        this flake's overlay (`pkgs.cybergroupmate`). Add the flake's overlay
        or override this option if you build it elsewhere.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "${config.xdg.dataHome}/cybergroupmate";
      defaultText = lib.literalExpression "\${config.xdg.dataHome}/cybergroupmate";
      description = ''
        Writable working directory for the service. The app resolves
        `config.yaml`, `workspace/`, `workspace/memory.db`, Telegram/Discord
        sessions, media, etc. relative to this directory (its `process.cwd()`).
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Declarative CyberGroupmate configuration, mapped 1:1 to the upstream
        `config.yaml` schema. Every key uses the same name as the YAML field
        (e.g. `llm_profiles`, `llm_routing`, `telegram`, `discord`, `onebot`,
        `persona`, `dashboard`, ...). See `config.example.yaml` for the full
        schema.

        The generated file is copied to `<dataDir>/config.yaml` on each
        service start; runtime edits made via the Dashboard are overwritten
        on the next restart.
      '';
      example = {
        persona.name = "CyberGroupmate";
        llm_profiles.default = {
          provider = "openai";
          api_key = "\${LLM_API_KEY}";
          model = "gpt-4o-mini";
        };
      };
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a complete `config.yaml` to use instead of {option}`settings`.
        Useful when the config contains secrets that should live in a
        separately-managed store path. Takes precedence over {option}`settings`.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra environment variables to pass to the service. Merged on top of
        the module's own `CYBERGROUPMATE_WORKDIR`, `NODE_ENV`, and `PATH`.
      '';
      example = {
        LOG_LEVEL = "info";
        HTTPS_PROXY = "http://127.0.0.1:7890";
      };
    };

    extraSystemdService = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra attributes merged into the generated
        `systemd.user.services.cybergroupmate` definition, after the module's
        own (hardened) defaults. Use this to tweak timers, resources, or even
        loosen hardening (with `lib.mkForce`) when you know what you are doing.
      '';
      example = {
        Service.RestartSec = 10;
        Unit.After = [ "my-proxy.service" ];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.configFile != null || cfg.settings != { };
        message = "services.cybergroupmate: you must set either `settings` or `configFile` so the bot has a config.yaml to load.";
      }
    ];

    systemd.user.services.cybergroupmate = lib.mkMerge [
      # The module's own (hardened) defaults are wrapped in `mkDefault` so that
      # any key the user overrides via `extraSystemdService` wins at normal priority.
      (mkDefaultDeep {
        Unit = {
          Description = "CyberGroupmate — code-driven group chat agent";
          Documentation = "https://github.com/Archeb/CyberGroupmate";
          # User-manager equivalent of waiting for networking.
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };

        Service = {
          Type = "simple";
          ExecStartPre = "${startPreScript}";
          ExecStart = "${cfg.package}/bin/cybergroupmate";
          WorkingDirectory = cfg.dataDir;
          Environment = environmentList;

          Restart = "on-failure";
          RestartSec = 5;
          TimeoutStopSec = 30;
          KillSignal = "SIGTERM";

          # ─── Hardening ───
          # Goal: grant *only* networking. Everything else (devices, kernel
          # knobs, the rest of the filesystem, extra privileges) is denied.

          # No capabilities / no privilege escalation. Networking does not
          # require any Linux capability.
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "" ];
          AmbientCapabilities = [ "" ];

          # Private device namespace. node-pty only needs `/dev/ptmx` + the
          # per-PTY `/dev/pts/*` entries, both of which `PrivateDevices=yes`
          # still provides.
          PrivateDevices = true;
          DevicePolicy = "closed";

          # Private /tmp and IPC namespace; reclaim IPC on stop.
          PrivateTmp = true;
          PrivateIPC = true;
          RemoveIPC = true;

          # Filesystem: make the whole host tree read-only and grant write
          # access to the data dir only.
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ReadWritePaths = [ cfg.dataDir ];

          # Kernel surfaces.
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";

          # Personality / realtime / setuid hardening.
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;

          # Syscall allow-list. `@system-service` already includes all the
          # networking syscalls (`socket`, `connect`, `accept`, `bind`, ...),
          # so the bot can still reach LLM + platform APIs. We additionally
          # deny `@privileged` and `@resources` to drop the rest.
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@resources"
          ];
          # Errno returned for any filtered syscall.
          SystemCallErrorNumber = "EPERM";

          # Address-family allow-list: keep IPv4/IPv6 (networking), Unix
          # sockets (local IPC), and NETLINK (DNS / routing lookups). Drop
          # everything else (raw packet, bluetooth, CAN, ...).
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];

          # Resource limits.
          LimitNOFILE = 65536;

          # NOTE: `MemoryDenyWriteExecute` is deliberately NOT set. Node.js /
          # V8 (and tsx) rely on JIT, which requires W^X pages; enabling this
          # would crash the runtime on startup.
        };

        Install = {
          WantedBy = [ "default.target" ];
        };
      })

      # User-provided overrides / extensions. These win at normal priority
      # over the `mkDefault`-wrapped defaults above; use `lib.mkForce` to
      # override values that are themselves `mkForce`d elsewhere.
      cfg.extraSystemdService
    ];
  };
}
