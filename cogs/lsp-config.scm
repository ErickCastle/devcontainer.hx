;; Pure logic for routing language servers through the dev container.
;;
;; Deliberately free of any Helix dependency so it can be tested with the plain
;; Steel interpreter; `lsp.scm` applies these results to the editor.

(require "cli.scm")

(provide wrapped-config
         restored-config
         path-mismatch?
         remote-workspace-folder)

;; Helix reports a server's configuration with symbol keys, and omits keys that
;; are unset.
(define (config-field config key default)
  (let ([found (hash-try-get config key)])
    (if (or (not found) (void? found)) default found)))

;;@doc
;; Rewrite an LSP configuration so the server is launched inside the container:
;;
;;   rust-analyzer -> devcontainer exec --workspace-folder <ws> rust-analyzer
;;
;; * config            : hash?   -- the server's current configuration
;; * workspace         : string? -- host path, passed as a single argument
;; * fallback-command  : string? -- used when the config has no explicit command
;;
;; Only the keys being changed are returned, with string keys. `get-lsp-config`
;; hands back symbol keys and values such as a void `required-root-patterns`,
;; neither of which `set-lsp-config!` can convert, so the original map must not be
;; passed back wholesale.
(define (wrapped-config config workspace fallback-command)
  (let ([program (config-field config 'command fallback-command)]
        [args (config-field config 'args '())])
    (hash "command"
          "devcontainer"
          "args"
          (append (list "exec" "--workspace-folder" workspace program) args))))

;;@doc
;; The subset of a saved configuration needed to put a server back on the host.
(define (restored-config config fallback-command)
  (hash "command" (config-field config 'command fallback-command) "args" (config-field config 'args '())))

;;@doc
;; Whether the workspace is mounted at a different path inside the container.
;;
;; LSP messages carry `file://` URIs; when the host and container paths differ the
;; server's replies point at paths the editor cannot resolve.
(define (path-mismatch? workspace remote-folder)
  (and (string? remote-folder) (not (equal? workspace remote-folder))))

;;@doc
;; The container-side path for the workspace, or #false if it cannot be determined.
(define (remote-workspace-folder workspace)
  (let ([outcome (read-configuration workspace #f)])
    (if (outcome-ok? outcome)
        (json-ref (json-ref (outcome-data outcome) 'workspace (hash)) 'workspaceFolder #f)
        #f)))
