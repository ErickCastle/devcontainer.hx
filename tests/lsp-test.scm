;; Tests for the parts of the LSP integration that do not need a running editor.
;; `enable-server!`/`disable-server!` are excluded because they call into Helix's
;; configuration module.
;;
;; Input configurations use symbol keys and output uses string keys, matching what
;; Helix's `get-lsp-config` returns and what `set-lsp-config!` accepts.
(require "steel/tests/unit-test.scm")
(require "../cogs/lsp-config.scm")

(define workspace "/home/user/project")

(define plain (hash 'command "rust-analyzer"))

(check-equal? "the server is launched through the CLI"
              (hash-ref (wrapped-config plain workspace "rust-analyzer") "command")
              "devcontainer")

(check-equal? "the original command becomes an argument"
              (hash-ref (wrapped-config plain workspace "rust-analyzer") "args")
              (list "exec" "--workspace-folder" "/home/user/project" "rust-analyzer"))

(define with-args (hash 'command "gopls" 'args (list "-remote=auto")))

(check-equal? "existing server arguments are preserved after the program"
              (hash-ref (wrapped-config with-args workspace "gopls") "args")
              (list "exec" "--workspace-folder" "/home/user/project" "gopls" "-remote=auto"))

(check-equal? "the workspace path stays a single argument"
              (hash-ref (wrapped-config plain "/home/my project; touch pwned" "rust-analyzer") "args")
              (list "exec" "--workspace-folder" "/home/my project; touch pwned" "rust-analyzer"))

(check-equal? "a config without a command falls back to the server name"
              (hash-ref (wrapped-config (hash) workspace "clangd") "args")
              (list "exec" "--workspace-folder" workspace "clangd"))

;; get-lsp-config hands back symbol keys and values that set-lsp-config! cannot
;; convert, so only the keys being changed may be sent, as strings.
(define realistic (hash 'command "rust-analyzer" 'timeout 20.0 'required-root-patterns void))

(define rewritten (wrapped-config realistic workspace "rust-analyzer"))

(check-equal? "only the changed keys are sent back" (hash-length rewritten) 2)

(check-equal? "unconvertible values are dropped"
              (hash-contains? rewritten 'required-root-patterns)
              #f)

(check-equal? "keys are sent back as strings" (hash-contains? rewritten "command") #t)

;;;; Restoring

(check-equal? "restoring returns the original command"
              (hash-ref (restored-config realistic "rust-analyzer") "command")
              "rust-analyzer")

(check-equal? "restoring clears the injected arguments"
              (hash-ref (restored-config realistic "rust-analyzer") "args")
              '())

(check-equal? "restoring keeps the original arguments"
              (hash-ref (restored-config with-args "gopls") "args")
              (list "-remote=auto"))

;;;; Path mapping

(check-equal? "identical host and container paths are not a mismatch"
              (path-mismatch? "/workspaces/project" "/workspaces/project")
              #f)

(check-equal? "differing host and container paths are a mismatch"
              (path-mismatch? "/home/user/project" "/workspaces/project")
              #t)

(check-equal? "an unknown container path is not reported as a mismatch"
              (path-mismatch? "/home/user/project" #f)
              #f)
