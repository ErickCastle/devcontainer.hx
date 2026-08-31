;; Dev Container support for Helix.
;;
;; This is the only module intended to be required from a user's `helix.scm`.
;; Everything it provides becomes a typed command, so `:devcontainer-up` and
;; friends are available from the command prompt.
;;
;; Helix itself always runs on the host. These commands manage a container for the
;; *project*, and run project tooling inside it; they do not move the editor.

(require (prefix-in cli. "cogs/cli.scm"))
(require "cogs/config.scm")
(require "cogs/docker.scm")
(require "cogs/job.scm")
(require "cogs/state.scm")
(require (prefix-in lsp. "cogs/lsp.scm"))

(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")

(provide devcontainer-status
         devcontainer-up
         devcontainer-rebuild
         devcontainer-exec
         devcontainer-stop
         devcontainer-config
         devcontainer-logs
         devcontainer-lsp-enable
         devcontainer-lsp-disable)

;;;; ---------------------------------------------------------------------------
;;;; Helpers
;;;; ---------------------------------------------------------------------------

(define (workspace)
  (helix.static.get-helix-cwd))

(define (show-buffer name text)
  (helix.hsplit-new)
  (set-scratch-buffer-name! name)
  (helix.static.insert_string text))

;; Report a failed outcome on the statusline, keeping the longer explanation for
;; the output buffer.
(define (report-failure! ws outcome)
  (set-last-logs! ws (cli.outcome-logs outcome))
  (fail (if (equal? (cli.outcome-detail outcome) "")
            (cli.outcome-message outcome)
            (string-append (cli.outcome-message outcome) " - " (cli.outcome-detail outcome)))))

;; Refuse to start a second operation on the same workspace.
(define (with-claim ws label thunk)
  (if (begin-operation! ws label)
      (thunk)
      (warn (string-append "Dev container busy: " (current-operation ws) " is already running"))))

(define (release-and ws action)
  (end-operation! ws)
  (action))

;;;; ---------------------------------------------------------------------------
;;;; Starting and rebuilding
;;;; ---------------------------------------------------------------------------

(define (start-container! ws label remove-existing? no-cache?)
  (with-claim
   ws
   label
   (lambda ()
     (notify (string-append label "..."))
     (run-async (lambda () (cli.up ws #f remove-existing? no-cache?))
                (lambda (outcome)
                  (release-and ws
                               (lambda ()
                                 (if (cli.outcome-ok? outcome)
                                     (let ([data (cli.outcome-data outcome)])
                                       (set-last-logs! ws (cli.outcome-logs outcome))
                                       (record-up! ws
                                                   (cli.json-ref data 'containerId #f)
                                                   (cli.json-ref data 'remoteUser #f)
                                                   (cli.json-ref data 'remoteWorkspaceFolder #f))
                                       (notify (string-append "Dev container ready ("
                                                              (short-id (cli.json-ref data 'containerId "?"))
                                                              ")")))
                                     (report-failure! ws outcome)))))))))

(define (short-id id)
  (if (and (string? id) (> (string-length id) 12)) (substring id 0 12) (to-string id)))

;;@doc
;; Create and start this workspace's dev container, building the image if needed.
(define (devcontainer-up)
  (let ([ws (workspace)])
    (if (not (has-config? ws))
        (warn "No dev container configuration found in this workspace")
        (start-container! ws "Starting dev container" #f #f))))

;;@doc
;; Discard this workspace's dev container and build it again from scratch.
(define (devcontainer-rebuild)
  (let ([ws (workspace)])
    (if (not (has-config? ws))
        (warn "No dev container configuration found in this workspace")
        (begin
          (forget! ws)
          (start-container! ws "Rebuilding dev container" #t #t)))))

;;;; ---------------------------------------------------------------------------
;;;; Running commands inside the container
;;;; ---------------------------------------------------------------------------

;;@doc
;; Run a command inside the dev container, e.g. `:devcontainer-exec cargo test`.
;; Output is shown in a scratch buffer.
(define (devcontainer-exec . args)
  (let ([ws (workspace)])
    (cond
      [(empty? args) (warn "Usage: :devcontainer-exec <command> [args...]")]
      [(not (has-config? ws)) (warn "No dev container configuration found in this workspace")]
      [else
       (with-claim
        ws
        "exec"
        (lambda ()
          (notify (string-append "Running in container: " (string-join args " ")))
          (run-async
           (lambda () (cli.exec ws #f args))
           (lambda (outcome)
             (release-and ws
                          (lambda ()
                            (set-last-logs! ws (cli.outcome-logs outcome))
                            (if (cli.outcome-ok? outcome)
                                (begin
                                  (show-buffer (string-append "*devcontainer: " (string-join args " ") "*")
                                               (hash-ref (cli.outcome-data outcome) 'stdout))
                                  (notify "Command finished"))
                                (report-failure! ws outcome))))))))])))

;;;; ---------------------------------------------------------------------------
;;;; Stopping
;;;; ---------------------------------------------------------------------------

;;@doc
;; Stop this workspace's dev container. The container is kept, so a later
;; `:devcontainer-up` restarts it without rebuilding.
(define (devcontainer-stop)
  (let ([ws (workspace)])
    (with-claim ws
                "stop"
                (lambda ()
                  (notify "Stopping dev container...")
                  (run-async (lambda () (stop-container (container-for-workspace ws)))
                             (lambda (result)
                               (release-and ws
                                            (lambda ()
                                              (if (car result)
                                                  (notify "Dev container stopped")
                                                  (fail (string-append "Could not stop dev container: "
                                                                       (cdr result))))))))))))

;;;; ---------------------------------------------------------------------------
;;;; Status and diagnostics
;;;; ---------------------------------------------------------------------------

(define (describe-container ws)
  (let* ([id (container-for-workspace ws)] [status (container-state id)])
    (cond
      [(not (docker-available?)) "container state unknown (no Docker CLI)"]
      [(not id) "no container yet"]
      [(equal? status "running") (string-append "running (" (short-id id) ")")]
      [status (string-append status " (" (short-id id) ")")]
      [else (string-append "exists (" (short-id id) ")")])))

;;@doc
;; Report whether this workspace has a dev container and what state it is in.
(define (devcontainer-status)
  (let* ([ws (workspace)] [config (find-config-path ws)])
    (cond
      [(not config) (warn (string-append "No dev container configuration in " ws))]
      [(not (cli.cli-available?))
       (fail (string-append "Config found (" (relative-to ws config) ") but the `devcontainer` CLI is missing. "
                            cli.cli-install-hint))]
      [else
       (run-async (lambda () (describe-container ws))
                  (lambda (description)
                    (notify (string-append (relative-to ws config)
                                           " - "
                                           description
                                           (if (busy? ws) (string-append " - " (current-operation ws) " in progress") "")))))])))

(define (relative-to base path)
  (let ([prefix (string-append base "/")])
    (if (starts-with? path prefix) (substring path (string-length prefix) (string-length path)) path)))

;;@doc
;; Open this workspace's devcontainer.json.
(define (devcontainer-config)
  (let ([config (find-config-path (workspace))])
    (if config
        (helix.open config)
        (warn "No dev container configuration found in this workspace"))))

;;@doc
;; Show the full output of the last dev container operation.
(define (devcontainer-logs)
  (let ([logs (last-logs (workspace))])
    (if (equal? logs "")
        (warn "No dev container output recorded yet")
        (show-buffer "*devcontainer output*" logs))))

;;;; ---------------------------------------------------------------------------
;;;; Language servers
;;;; ---------------------------------------------------------------------------

;;@doc
;; Run a language server inside the dev container, e.g.
;; `:devcontainer-lsp-enable rust-analyzer`. Restarts the server afterwards.
(define (devcontainer-lsp-enable name)
  (let ([result (lsp.enable-server! name (workspace))])
    (if (car result)
        (begin
          (helix.lsp-restart name)
          (if (equal? (cdr result) "")
              (notify (string-append name " now runs inside the dev container"))
              (warn (cdr result))))
        (fail (cdr result)))))

;;@doc
;; Return a language server to running on the host. Restarts the server afterwards.
(define (devcontainer-lsp-disable name)
  (let ([result (lsp.disable-server! name)])
    (if (car result)
        (begin
          (helix.lsp-restart name)
          (notify (string-append name " now runs on the host")))
        (fail (cdr result)))))
