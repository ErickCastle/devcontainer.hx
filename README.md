# devcontainer.hx

Dev Container support for [Helix](https://helix-editor.com), built on the
[Steel](https://github.com/mattwparas/helix/tree/steel-event-system) plugin fork.

Helix runs on your machine. The plugin manages a
[Dev Container](https://containers.dev) for the *project* and runs project tooling —
builds, tests, language servers — inside it, using the official
[Dev Container CLI](https://github.com/devcontainers/cli) as its backend.

```
:devcontainer-up                 build and start the project's container
:devcontainer-exec cargo test    run the test suite inside it
:devcontainer-status             what exists, and what state is it in
```

## Requirements

| | |
|---|---|
| Helix | the [`steel-event-system`](https://github.com/mattwparas/helix/tree/steel-event-system) fork, built with `cargo xtask steel` |
| Dev Container CLI | `npm install -g @devcontainers/cli` |
| A container runtime | Docker, or anything the CLI can drive |

`docker` is additionally used to report container state and to stop containers,
because the CLI has no command that inspects a container without also creating or
starting one. Without `docker` those two features degrade gracefully; everything
else still works.

## Installation

```sh
forge pkg install --git https://github.com/ErickCastle/devcontainer.hx.git
```

Then require it from `~/.config/helix/helix.scm` and re-export the commands you
want. **Only names you `provide` from `helix.scm` become typed commands.**

```scheme
(require "devcontainer.hx/devcontainer.scm")

(provide devcontainer-status
         devcontainer-up
         devcontainer-rebuild
         devcontainer-exec
         devcontainer-stop
         devcontainer-config
         devcontainer-logs
         devcontainer-lsp-enable
         devcontainer-lsp-disable)
```

To work from a checkout instead, `require` the absolute path to
`devcontainer.scm`.

### Optional keybindings

```scheme
;; init.scm
(require "helix/configuration.scm")

(add-global-keybinding
 (hash "normal" (hash "space" (hash "D" (hash "u" ":devcontainer-up"
                                             "s" ":devcontainer-status"
                                             "e" ":devcontainer-exec"
                                             "l" ":devcontainer-logs")))))
```

## Commands

| Command | Description |
|---|---|
| `:devcontainer-status` | Whether a configuration was found, whether the container exists, and its state |
| `:devcontainer-up` | Create and start the container, building the image if needed |
| `:devcontainer-rebuild` | Discard the container and rebuild it, ignoring the layer cache |
| `:devcontainer-exec <cmd> [args...]` | Run a command inside the container; output goes to a scratch buffer |
| `:devcontainer-stop` | Stop the container without deleting it |
| `:devcontainer-config` | Open the discovered `devcontainer.json` |
| `:devcontainer-logs` | Show the full transcript of the last operation |
| `:devcontainer-lsp-enable <server>` | Run a language server inside the container |
| `:devcontainer-lsp-disable <server>` | Return that server to the host |

The workspace is whatever Helix reports as its working directory, so start Helix
from the project root.

## Typical workflow

```
:devcontainer-status              → ".devcontainer/devcontainer.json - no container yet"
:devcontainer-up                  → "Starting dev container..." then "Dev container ready (a1b2c3d4e5f6)"
:devcontainer-exec cargo test     → results in a scratch buffer
:devcontainer-stop                → "Dev container stopped"
```

Long operations run on a background thread, so the editor stays responsive while an
image builds. Only one operation runs per workspace at a time; a second is refused
rather than queued.

When something fails, the statusline carries a one-line summary and
`:devcontainer-logs` has the complete CLI transcript.

## Configuration discovery

Searched in the same order the CLI uses:

1. `.devcontainer/devcontainer.json`
2. `.devcontainer.json`
3. `.devcontainer/<folder>/devcontainer.json`

The CLI performs its own lookup; the plugin's copy exists so `:devcontainer-status`
and `:devcontainer-config` still work when the CLI is missing or failing.

## Language servers in the container

`:devcontainer-lsp-enable rust-analyzer` rewrites that server's configuration to

```
devcontainer exec --workspace-folder <workspace> rust-analyzer
```

and restarts it. The CLI applies `remoteUser`, `remoteEnv` and the container's
`PATH`, so the server sees the project's toolchain rather than your host's.
`:devcontainer-lsp-disable` restores the original configuration.

> **This only works when the project sits at the same path inside the container as
> outside.** LSP messages carry `file://` URIs; Helix sends host paths and the
> server replies with container paths. Nothing rewrites them, so if the paths
> differ, go-to-definition and diagnostics will point at the wrong place. The
> plugin compares the two and warns when they disagree.

By default the CLI mounts a project at `/workspaces/<name>` (or, inside a git
repository, mounts the repository root), so the paths usually *do not* match. Pin
them in `devcontainer.json` to make the language server work:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/rust:1-bookworm",
  // Mount the project at the same path it has on the host.
  "workspaceMount": "source=${localWorkspaceFolder},target=${localWorkspaceFolder},type=bind",
  "workspaceFolder": "${localWorkspaceFolder}"
}
```

With that in place `:devcontainer-lsp-enable rust-analyzer` starts the server
inside the container and navigation works normally.

## What is and is not supported

Because the official CLI does the work, every `devcontainer.json` feature that
affects **container creation** is honoured: `image`, `build`/`Dockerfile`,
`dockerComposeFile`, `features`, `mounts`, `workspaceMount`, `workspaceFolder`,
`remoteUser`, `containerEnv`, `remoteEnv`, `runArgs`, and the full lifecycle
(`initializeCommand` through `postAttachCommand`).

Not supported, and why:

| VS Code capability | Status |
|---|---|
| Reopen the editor inside the container | Not applicable — Helix stays on the host |
| `forwardPorts` / `portsAttributes` | Not implemented; publish ports via `runArgs` or `appPort` |
| `customizations.vscode` (extensions, settings) | Ignored; there is no Helix equivalent |
| Dotfiles repositories | Not exposed |
| Volume-only workspaces (clone-in-volume) | Unsupported; the source must exist on the host |
| Integrated terminal in the container | Not implemented; `:devcontainer-exec` is capture-and-display |
| Attaching to an already-running arbitrary container | Not implemented |

## Known limitations

- **No LSP URI translation.** Correct only when the host and container paths
  match; pin `workspaceMount`/`workspaceFolder` as shown above, or the plugin
  warns and navigation will be wrong. Fixing this in general needs a stdio proxy
  that rewrites `file://` URIs in both directions, or path-mapping support in
  Helix's LSP client.
- **`:devcontainer-exec` is not interactive.** Output is captured and shown after
  the command exits, so REPLs and anything needing a TTY will not work. An
  embedded terminal would need [`steel-pty`](https://github.com/mattwparas/helix-config).
- **No progress during a build.** Output is shown when the operation finishes.
  The CLI streams progress to stderr; surfacing it live would need incremental
  reads posting to the statusline.
- **Container state and stop require `docker`.** The CLI has no
  inspect-without-starting command, and its `stop`/`down` subcommands are absent
  from released versions despite being documented (confirmed against 0.88.0), so
  both go through `docker` and the `devcontainer.local_folder` label the CLI sets.
- **One workspace per Helix instance.** The workspace is Helix's working
  directory.

### Nothing outside the plugin had to change

This is implemented entirely as a Steel plugin; no patches to Helix or Steel were
needed. Two things would have to change upstream for closer parity:

1. **LSP path mapping** in `helix-lsp`, so a server can be told that
   `/host/path` and `/container/path` are the same tree. This is the single
   blocker for reliable language servers in a container.
2. **A process/PTY API for plugins**, to host an interactive shell inside the
   editor. `steel-pty` exists out of tree but is not part of the plugin API.

## Development

```sh
./scripts/setup-dev.sh   # builds the Steel toolchain and the Helix fork into .build/
./tests/run.sh           # unit tests - needs only `steel`
./tests/e2e.sh           # end-to-end tests - needs `devcontainer` and a container runtime
```

`run.sh` uses a fake CLI in `tests/fake-bin/` and needs neither Docker nor the
real Dev Container CLI. `e2e.sh` drives the real CLI against small Alpine-based
fixtures, exercises the full lifecycle, and removes the containers it creates; it
skips itself if the prerequisites are missing.

```
devcontainer.scm       public commands, the only module a user requires
cogs/proc.scm          subprocess execution - the one place processes are spawned
cogs/cli.scm           Dev Container CLI adapter: flags, JSON results, error mapping
cogs/config.scm        configuration discovery
cogs/docker.scm        container inspection and shutdown
cogs/state.scm         per-workspace session state
cogs/job.scm           background execution
cogs/lsp-config.scm    language server rewriting (pure, testable)
cogs/lsp.scm           applying that configuration to the editor
```

Modules under `cogs/` other than `job.scm` and `lsp.scm` have no Helix dependency
and are tested directly with the Steel interpreter.

### Notes on security

Commands are built as argument vectors and executed with `steel/process`'s
`command`, which `exec`s directly. No shell is involved anywhere, so workspace
paths, container names and configuration values are never re-parsed as shell
syntax. A workspace called `my project; touch pwned #` is covered by the tests.

`run/capture` pipes stdout but redirects stderr to a temporary file. The CLI writes
megabytes of progress logging to stderr and only emits its JSON result on stdout at
the very end, so draining two pipes in sequence from one thread would deadlock once
the stderr pipe buffer filled.

## Licence

MIT
