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
(require "cogs/forwarding.scm")
(require "cogs/indicator.scm")
(require "cogs/job.scm")
(require "cogs/session.scm")
(require "cogs/state.scm")
(require (prefix-in lsp. "cogs/lsp.scm"))

(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")

(provide devcontainer-setup!
         devcontainer-status
         devcontainer-up
         devcontainer-rebuild
         devcontainer-exec
         devcontainer-stop
         devcontainer-config
         devcontainer-logs
         devcontainer-lsp-enable
         devcontainer-lsp-disable)

;;;; ---------------------------------------------------------------------------
;;;; Settings
;;;; ---------------------------------------------------------------------------

(define *settings*
  (box (hash 'prompt-on-open #t 'stop-on-exit #t 'status-indicator #t 'forward-ssh-agent #t 'copy-gitconfig #t)))

(define (setting key)
  (hash-ref (unbox *settings*) key))

(define *installed* (box #f))

;; How often the indicator re-checks the container's state, to notice changes
;; made outside the editor.
(define status-refresh-ms 10000)

;;@doc
;; Turn on the editor integration. Call it once from `init.scm`:
;;
;; ```scheme
;; (require "devcontainer.hx/devcontainer.scm")
;; (devcontainer-setup!)
;; ```
;;
;; * #:prompt-on-open    -- offer to start the container when Helix opens a
;;                          workspace that has a configuration (default #t)
;; * #:status-indicator  -- show the container's state in the statusline (default #t)
;; * #:indicator-side    -- 'left, 'center or 'right (default 'right)
;; * #:stop-on-exit      -- stop the container when Helix exits, following
;;                          `shutdownAction` (default #t)
;; * #:forward-ssh-agent -- relay the host's SSH agent into the container (default #t)
;; * #:copy-gitconfig    -- copy `~/.gitconfig` into the container (default #t)
;;
;; The last three also apply when `devcontainer-setup!` is never called.
(define (devcontainer-setup! #:prompt-on-open [prompt-on-open #t]
                             #:status-indicator [status-indicator #t]
                             #:indicator-side [indicator-side 'right]
                             #:stop-on-exit [stop-on-exit #t]
                             #:forward-ssh-agent [forward-ssh-agent #t]
                             #:copy-gitconfig [copy-gitconfig #t])
  (set-box! *settings*
            (hash 'prompt-on-open
                  prompt-on-open
                  'stop-on-exit
                  stop-on-exit
                  'status-indicator
                  status-indicator
                  'forward-ssh-agent
                  forward-ssh-agent
                  'copy-gitconfig
                  copy-gitconfig))
  (unless (unbox *installed*)
    (set-box! *installed* #t)
    (when status-indicator
      (install-indicator! indicator-side workspace)
      (refresh-status! (workspace))
      (enqueue-thread-local-callback-with-delay status-refresh-ms periodic-refresh))
    (when prompt-on-open
      ;; Wait until the editor has finished starting up and opening files.
      (enqueue-thread-local-callback-with-delay 200 offer-to-start)))
  void)

;;;; ---------------------------------------------------------------------------
;;;; Helpers
;;;; ---------------------------------------------------------------------------

(define (workspace)
  (helix.static.get-helix-cwd))

(define (show-buffer name text)
  (helix.hsplit-new)
  (set-scratch-buffer-name! name)
  (helix.static.insert_string text))

;; Report a failed outcome on the statusline. The statusline is one line and gets
;; truncated, so the specific cause goes first and the full transcript is left for
;; :devcontainer-logs.
(define (report-failure! ws outcome)
  (set-last-logs! ws (cli.outcome-logs outcome))
  (set-last-failed! ws #t)
  (fail (string-append (cli.outcome-message outcome) " - run :devcontainer-logs for details")))

;; Refuse to start a second operation on the same workspace.
(define (with-claim ws label thunk)
  (if (begin-operation! ws label)
      (begin
        (set-last-failed! ws #f)
        (set-progress! ws "")
        (start-spinner! (lambda () (busy? ws)) (lambda () (show-progress! ws)))
        (thunk))
      (warn (string-append "Dev container busy: " (current-operation ws) " - try again when it finishes"))))

(define (release-and ws action)
  (end-operation! ws)
  (set-progress! ws "")
  (action)
  (refresh-status! ws))

;; For `#:on-error`: an exception in the worker must still release the workspace,
;; or every later command would be refused as busy.
(define (release-on-error ws)
  (lambda (message)
    (release-and ws
                 (lambda ()
                   (set-last-failed! ws #t)
                   (fail message)))))

;; The message area shows the running operation with a spinner and the latest
;; line of output, so a long build visibly makes progress.
(define (show-progress! ws)
  (when (busy? ws)
    (let ([line (progress ws)])
      (notify (string-append (spinner-frame)
                             " "
                             (current-operation ws)
                             (if (equal? line "") "..." (string-append ": " line)))))))

;; Extra `--remote-env` pairs for commands run in the container.
(define (remote-env ws)
  (if (and (relay-active? ws) (relay ws)) (list (relay-remote-env (relay ws))) '()))

;;;; ---------------------------------------------------------------------------
;;;; Container status, for the indicator
;;;; ---------------------------------------------------------------------------

(define (container-status ws)
  (let ([id (container-for-workspace ws)])
    (cond
      [(not (docker-available?)) 'unknown]
      [(not id) 'none]
      [(equal? (container-state id) "running") 'running]
      [else 'stopped])))

;; Update the cached status in the background. Without a configuration there is
;; nothing to ask Docker about.
(define (refresh-status! ws)
  (if (not (has-config? ws))
      (set-cached-status! ws 'no-config)
      (run-async (lambda () (container-status ws)) (lambda (status) (set-cached-status! ws status)))))

(define (periodic-refresh)
  (let ([ws (workspace)])
    (unless (busy? ws)
      (refresh-status! ws)))
  (enqueue-thread-local-callback-with-delay status-refresh-ms periodic-refresh))

;;;; ---------------------------------------------------------------------------
;;;; Prompt on open
;;;; ---------------------------------------------------------------------------

(define (offer-to-start)
  (let ([ws (workspace)])
    (when (and (has-config? ws) (cli.cli-available?) (not (busy? ws)))
      (run-async (lambda () (container-status ws))
                 (lambda (status)
                   (set-cached-status! ws status)
                   (push-component!
                    (prompt (if (equal? status 'running)
                                "Dev container is running. Use it from this session? [y/N] "
                                "Dev container configuration found. Start the dev container? [y/N] ")
                            (lambda (answer)
                              (when (member (string-downcase (trim answer)) (list "y" "yes"))
                                (devcontainer-up))))))))))

;;;; ---------------------------------------------------------------------------
;;;; Stopping on exit, and the SSH relay
;;;; ---------------------------------------------------------------------------

;; Start this workspace's helper if it is not running yet. The SSH relay is
;; decided once, when the helper starts, since it lives as long as the helper.
(define (ensure-helper! ws)
  (unless (helper ws)
    (let* ([plan (if (setting 'forward-ssh-agent) (ssh-relay-plan) #f)]
           [child (start-helper (docker-path) (lock-dir) plan)])
      (when child
        (set-helper! ws child)
        (set-relay! ws plan)))))

;; Which containers to stop when the editor exits; runs on the worker thread.
(define (exit-targets id configuration)
  (let ([action (shutdown-action configuration)])
    (cond
      [(equal? action "none") '()]
      [(equal? action "stopCompose") (compose-containers id)]
      [else (list id)])))

(define (arm-for-exit! ws targets)
  (if (and (setting 'stop-on-exit) (not (empty? targets)))
      (helper-arm! (helper ws) targets)
      (helper-disarm! (helper ws))))

;;;; ---------------------------------------------------------------------------
;;;; Starting and rebuilding
;;;; ---------------------------------------------------------------------------

(define (start-container! ws label remove-existing? no-cache?)
  (with-claim
   ws
   label
   (lambda ()
     (when (or (setting 'stop-on-exit) (setting 'forward-ssh-agent))
       (ensure-helper! ws))
     (show-progress! ws)
     ;; Everything the worker needs is captured here, on the main thread.
     (let* ([plan (relay ws)]
            [mounts (if plan (list (relay-mount plan)) '())]
            [env (if plan (list (relay-remote-env plan)) '())]
            [copy-gitconfig? (setting 'copy-gitconfig)])
       (run-async/progress
        (lambda (report)
          (let ([outcome (cli.up ws
                                 #f
                                 remove-existing?
                                 no-cache?
                                 #:mounts mounts
                                 #:remote-env env
                                 #:on-progress report)])
            (if (cli.outcome-ok? outcome)
                (let* ([data (cli.outcome-data outcome)] [id (cli.json-ref data 'containerId #f)])
                  (report "Preparing the container for this session")
                  (hash 'outcome
                        outcome
                        'targets
                        (if id (exit-targets id (cli.json-ref data 'configuration (hash))) '())
                        'relay-listening?
                        (if plan (path-exists? (hash-ref plan 'socket)) #f)
                        'relay-mounted?
                        (if (and plan id) (container-has-mount? id (hash-ref plan 'dir) ssh-mount-target) #f)
                        'gitconfig-ok?
                        (if copy-gitconfig? (copy-gitconfig! ws) #t)))
                (hash 'outcome outcome))))
        (lambda (result)
          (release-and ws (lambda () (finish-start! ws plan result))))
        (lambda (line)
          (set-progress! ws line)
          (show-progress! ws))
        #:on-error
        (release-on-error ws))))))

(define (finish-start! ws plan result)
  (let ([outcome (hash-ref result 'outcome)])
    (if (not (cli.outcome-ok? outcome))
        (report-failure! ws outcome)
        (let ([data (cli.outcome-data outcome)])
          (set-last-logs! ws (cli.outcome-logs outcome))
          (record-up! ws
                      (cli.json-ref data 'containerId #f)
                      (cli.json-ref data 'remoteUser #f)
                      (cli.json-ref data 'remoteWorkspaceFolder #f))
          (set-cached-status! ws 'running)
          (set-relay-active! ws (and (hash-ref result 'relay-listening?) (hash-ref result 'relay-mounted?)))
          (arm-for-exit! ws (hash-ref result 'targets))
          (let ([notes (filter string?
                               (list (cond
                                       [(and (not plan) (setting 'forward-ssh-agent) (ssh-relay-problem))
                                        (string-append "SSH agent not forwarded: " (ssh-relay-problem))]
                                       [(not plan) #f]
                                       [(not (hash-ref result 'relay-listening?))
                                        "SSH agent not forwarded: the relay did not start"]
                                       [(not (hash-ref result 'relay-mounted?))
                                        "SSH agent not forwarded: run :devcontainer-rebuild to add the relay mount"]
                                       [else #f])
                                     (if (hash-ref result 'gitconfig-ok?) #f "could not copy ~/.gitconfig")))]
                [ready (string-append "Dev container ready (" (short-id (cli.json-ref data 'containerId "?")) ")")])
            (if (empty? notes)
                (notify ready)
                (warn (string-append ready " - " (string-join notes "; ")))))))))

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
        (string-append "Running `" (string-join args " ") "`")
        (lambda ()
          (show-progress! ws)
          (let ([env (remote-env ws)])
            (run-async
             (lambda () (cli.exec ws #f args #:remote-env env))
             (lambda (outcome)
               (release-and ws
                            (lambda ()
                              (set-last-logs! ws (cli.outcome-logs outcome))
                              (if (cli.outcome-ok? outcome)
                                  (begin
                                    (show-buffer (string-append "*devcontainer: " (string-join args " ") "*")
                                                 (hash-ref (cli.outcome-data outcome) 'stdout))
                                    (notify "Command finished"))
                                  (report-failure! ws outcome)))))
             #:on-error
             (release-on-error ws)))))])))

;;;; ---------------------------------------------------------------------------
;;;; Stopping
;;;; ---------------------------------------------------------------------------

;;@doc
;; Stop this workspace's dev container. The container is kept, so a later
;; `:devcontainer-up` restarts it without rebuilding.
(define (devcontainer-stop)
  (let ([ws (workspace)])
    (with-claim ws
                "Stopping dev container"
                (lambda ()
                  (show-progress! ws)
                  (run-async (lambda () (stop-container (container-for-workspace ws)))
                             (lambda (result)
                               (release-and ws
                                            (lambda ()
                                              (if (car result)
                                                  (begin
                                                    ;; Nothing is left to stop when the editor exits.
                                                    (helper-disarm! (helper ws))
                                                    (set-cached-status! ws 'stopped)
                                                    (notify "Dev container stopped"))
                                                  (begin
                                                    (set-last-failed! ws #t)
                                                    (fail (string-append "Could not stop dev container: "
                                                                         (cdr result))))))))
                             #:on-error
                             (release-on-error ws))))))

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
       (run-async (lambda () (cons (describe-container ws) (container-status ws)))
                  (lambda (described)
                    (set-cached-status! ws (cdr described))
                    (notify (string-append (relative-to ws config)
                                           " - "
                                           (car described)
                                           (if (busy? ws) (string-append " - busy: " (current-operation ws)) "")))))])))

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
  (let* ([ws (workspace)] [result (lsp.enable-server! name ws #:remote-env (remote-env ws))])
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
