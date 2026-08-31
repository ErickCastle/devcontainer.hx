;; Tests for the parts of the LSP integration that do not need a running editor.
;; `enable-server!`/`disable-server!` are excluded because they call into Helix's
;; configuration module.
(require "steel/tests/unit-test.scm")
(require "../cogs/lsp-config.scm")

(define workspace "/home/user/project")

(define plain (hash "command" "rust-analyzer" "args" '()))

(check-equal? "the server is launched through the CLI"
              (hash-ref (wrapped-config plain workspace "rust-analyzer") "command")
              "devcontainer")

(check-equal? "the original command becomes an argument"
              (hash-ref (wrapped-config plain workspace "rust-analyzer") "args")
              (list "exec" "--workspace-folder" "/home/user/project" "rust-analyzer"))

(define with-args (hash "command" "gopls" "args" (list "-remote=auto")))

(check-equal? "existing server arguments are preserved after the program"
              (hash-ref (wrapped-config with-args workspace "gopls") "args")
              (list "exec" "--workspace-folder" "/home/user/project" "gopls" "-remote=auto"))

(check-equal? "the workspace path stays a single argument"
              (hash-ref (wrapped-config plain "/home/my project; touch pwned" "rust-analyzer") "args")
              (list "exec" "--workspace-folder" "/home/my project; touch pwned" "rust-analyzer"))

(check-equal? "a config without a command falls back to the server name"
              (hash-ref (wrapped-config (hash) workspace "clangd") "args")
              (list "exec" "--workspace-folder" workspace "clangd"))

(check-equal? "unrelated configuration is left alone"
              (hash-ref (wrapped-config (hash "command" "gopls" "timeout" 30) workspace "gopls") "timeout")
              30)

(check-equal? "identical host and container paths are not a mismatch"
              (path-mismatch? "/workspaces/project" "/workspaces/project")
              #f)

(check-equal? "differing host and container paths are a mismatch"
              (path-mismatch? "/home/user/project" "/workspaces/project")
              #t)

(check-equal? "an unknown container path is not reported as a mismatch"
              (path-mismatch? "/home/user/project" #f)
              #f)
