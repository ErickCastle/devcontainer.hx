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

Like VS Code, it can also offer to start the container when you open the project,
show the container's state and build progress in the statusline, forward your SSH
agent and Git configuration, and stop the container when Helix exits.

## Requirements

| | |
|---|---|
| Helix | the [`steel-event-system`](https://github.com/mattwparas/helix/tree/steel-event-system) fork, built with `cargo xtask steel` |
| Dev Container CLI | `npm install -g @devcontainers/cli` |
| A container runtime | Docker, or anything the CLI can drive |
| `socat` (optional) | on the host, to forward the SSH agent into the container |

`docker` is additionally used to report container state and to stop containers,
because the CLI has no command that inspects a container without also creating or
starting one. Without `docker` those features degrade gracefully; everything
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

### Editor integration

To get the startup prompt and the statusline indicator, call `devcontainer-setup!`
from `~/.config/helix/init.scm`:

```scheme
;; init.scm
(require "devcontainer.hx/devcontainer.scm")

(devcontainer-setup!)
```

Every feature is on by default; turn off the ones you don't want:

```scheme
(devcontainer-setup! #:prompt-on-open #f       ; don't offer to start the container
                     #:status-indicator #t     ; container state in the statusline
                     #:indicator-side 'left    ; 'left, 'center or 'right (default)
                     #:stop-on-exit #t         ; stop the container when Helix exits
                     #:forward-ssh-agent #t    ; relay the host's SSH agent
                     #:copy-gitconfig #t)      ; copy ~/.gitconfig into the container
```

Without the call, stopping on exit, SSH agent forwarding and `.gitconfig` copying
still happen with their defaults; only the prompt and the indicator need it.

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
$ hx                              → "Dev container configuration found. Start the dev container? [y/N]"
y                                 → "⣾ Starting dev container: #6 [2/3] RUN apt-get install ..."
                                  → "Dev container ready (a1b2c3d4e5f6)", statusline shows "● devcontainer"
:devcontainer-exec cargo test     → results in a scratch buffer
:q                                → Helix exits and the container is stopped
```

Long operations run on a background thread, so the editor stays responsive while an
image builds. Only one operation runs per workspace at a time; a second is refused
rather than queued.

When something fails, the statusline carries a one-line summary and
`:devcontainer-logs` has the complete CLI transcript.

## Working with the container

### Progress and status

While `:devcontainer-up` or `:devcontainer-rebuild` runs, the message area shows a
spinner, the operation and the latest line of the CLI's output (image pulls,
`Dockerfile` steps, lifecycle commands), updated live. The statusline indicator
shows:

| Indicator | Meaning |
|---|---|
| `⣾ devcontainer` | an operation is running |
| `● devcontainer` | the container is running |
| `○ devcontainer (stopped)` | the container exists but is stopped |
| `○ devcontainer` | no container has been created yet |
| `✗ devcontainer` | the last operation failed; see `:devcontainer-logs` |

Nothing is shown in workspaces without a configuration. The state is re-checked
every 10 seconds, so changes made outside Helix show up too.

### Prompt on open

When Helix starts in a workspace with a configuration, it asks whether to start the
dev container (or, if it is already running, whether to use it from this session).
Answering `y` runs `:devcontainer-up`; anything else, or `Esc`, leaves it alone.

### Stopping on exit

Like VS Code, the container is stopped when Helix exits, following the
`shutdownAction` property in `devcontainer.json`:

| `shutdownAction` | On exit |
|---|---|
| `stopContainer` (default for `image`/`Dockerfile`) | stop the container |
| `stopCompose` (default for Docker Compose) | stop every container in the Compose project |
| `none` | leave it running |

Only containers this session started or joined (through `:devcontainer-up` or the
prompt) are stopped, and only when the last Helix session using them exits: if
two editors share a container, it keeps running until both have closed.
`:devcontainer-stop` stops it straight away.

Helix has no exit hook, so the plugin starts a small helper process attached to
Helix by a pipe. When Helix exits, for any reason including a crash, the pipe
closes and the helper stops the container. Stopping happens in the background, so
the terminal is returned immediately.

### SSH agent and Git configuration

As in VS Code, the container gets:

- **Your SSH agent.** `git` over SSH, `ssh` and `ssh-add -l` inside the container use
  the keys loaded on the host. The plugin runs `socat` on the host to relay
  `$SSH_AUTH_SOCK` through a private directory (`~/.local/state/devcontainer.hx/ssh`)
  that is mounted into the container, and sets `SSH_AUTH_SOCK` for lifecycle
  commands, `:devcontainer-exec` and language servers.
- **Your `~/.gitconfig`**, copied into the container user's home after each
  `:devcontainer-up`, unless the container already has one.

The relay directory is mounted when a container is created, so a container created
before forwarding was available needs one `:devcontainer-rebuild`; the plugin says
so when that is the case. If forwarding is impossible (no `socat`, for example),
the reason is shown once the container is ready.

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
| Git credential helper forwarding (HTTPS) | Not implemented; use SSH remotes, which are forwarded |
| GPG agent forwarding (commit signing) | Not implemented |
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
- **No progress for `:devcontainer-exec`.** Its output is shown when the command
  finishes; only `up` and `rebuild` stream progress.
- **SSH agent forwarding needs a local Docker engine.** The relay is a Unix socket
  in a bind-mounted directory, which works when the engine shares the host's
  kernel (Docker Engine on Linux, rootless or not). It does not cross the VM
  boundary of Docker Desktop.
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
devcontainer.scm       public commands and setup, the only module a user requires
cogs/proc.scm          subprocess execution - the one place processes are spawned
cogs/cli.scm           Dev Container CLI adapter: flags, JSON results, progress, error mapping
cogs/config.scm        configuration discovery
cogs/docker.scm        container inspection and shutdown
cogs/state.scm         per-workspace session state
cogs/job.scm           background execution and progress polling
cogs/session.scm       the helper that stops containers on exit and runs the SSH relay
cogs/forwarding.scm    SSH agent relay planning and .gitconfig copying
cogs/indicator.scm     statusline indicator and spinner
cogs/lsp-config.scm    language server rewriting (pure, testable)
cogs/lsp.scm           applying that configuration to the editor
```

Modules under `cogs/` other than `job.scm`, `indicator.scm` and `lsp.scm` have no
Helix dependency and are tested directly with the Steel interpreter. The helper and
SSH relay tests use a fake `docker` in `tests/fake-docker/` and, when `socat` is
installed, a real relay.

### Notes on security

Commands are built as argument vectors and executed with `steel/process`'s
`command`, which `exec`s directly, so workspace paths, container names and
configuration values are never re-parsed as shell syntax. A workspace called
`my project; touch pwned #` is covered by the tests. The only shell scripts are
the exit helper and the `.gitconfig` copy, both fixed text passed to `sh -c`; every
variable part reaches them as a positional argument or on stdin, and container ids
are checked to be hexadecimal before they are sent to the helper.

The SSH relay socket is created with mode `600` in a directory with mode `700`.

`run/capture` pipes stdout but redirects stderr to a temporary file. The CLI writes
megabytes of progress logging to stderr and only emits its JSON result on stdout at
the very end, so draining two pipes in sequence from one thread would deadlock once
the stderr pipe buffer filled.

## Licence

MIT
