;; Applying container-routed language server configuration to the editor.
;;
;; Helix spawns language servers itself, so a plugin cannot intercept them. What it
;; can do is rewrite a server's configured command to run inside the container, via
;; `set-lsp-config!`. The rewriting itself lives in `lsp-config.scm`; this module
;; only reads, applies and restores editor configuration.

(require "cli.scm")
(require "lsp-config.scm")
(require "helix/configuration.scm")

(provide enable-server!
         disable-server!)

;; Original configurations, so `disable-server!` can put things back.
(define *saved* (box (hash)))

(define (saved name)
  (hash-try-get (unbox *saved*) name))

;;@doc
;; Point `name` at the container. Returns a (ok? . message) pair; on success the
;; message is a warning to show anyway, or "" if there is nothing to warn about.
(define (enable-server! name workspace)
  (cond
    [(not (cli-available?)) (cons #f (string-append "Dev Container CLI not found. " cli-install-hint))]
    [(saved name) (cons #f (string-append name " is already routed through the dev container"))]
    [else
     (let ([config (get-lsp-config name)])
       (if (not (hash? config))
           (cons #f (string-append "No language server configuration found for " name))
           (begin
             (set-box! *saved* (hash-insert (unbox *saved*) name config))
             (set-lsp-config! name (wrapped-config config workspace name))
             (cons #t (mismatch-warning workspace)))))]))

(define (mismatch-warning workspace)
  (let ([remote (remote-workspace-folder workspace)])
    (if (path-mismatch? workspace remote)
        (string-append "Workspace is mounted at "
                       remote
                       " inside the container but Helix sees "
                       workspace
                       "; go-to-definition and diagnostics will be wrong")
        "")))

;;@doc
;; Restore `name` to the configuration it had before it was routed through the
;; container. Returns a (ok? . message) pair.
(define (disable-server! name)
  (let ([original (saved name)])
    (if (not original)
        (cons #f (string-append name " is not routed through the dev container"))
        (begin
          (set-lsp-config! name (restored-config original name))
          (set-box! *saved* (hash-remove (unbox *saved*) name))
          (cons #t "")))))
