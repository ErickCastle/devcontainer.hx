;; Sharing the host's SSH agent and Git configuration with the container, as
;; VS Code does.
;;
;; * SSH agent: VS Code relays the agent through its server process. The plugin has
;;   no process inside the container, so the relay runs on the host instead:
;;   `socat` listens on a socket in a private directory that is bind-mounted into
;;   the container, and forwards each connection to `$SSH_AUTH_SOCK`. The
;;   directory, unlike the agent's own socket, survives reboots, so the mount
;;   never goes stale.
;; * Git configuration: `~/.gitconfig` is copied into the container when the
;;   container does not already have one.

(require "proc.scm")
(require "cli.scm")
(require-builtin steel/filesystem)
(require-builtin steel/time)
(require "steel/result")

(provide state-home
         lock-dir
         ssh-mount-target
         ssh-relay-plan
         ssh-relay-problem
         relay-mount
         relay-remote-env
         host-gitconfig
         copy-gitconfig!)

(define (env name)
  (let ([found (maybe-get-env-var name)])
    (if (and (Ok? found) (not (equal? (unwrap-ok found) ""))) (unwrap-ok found) #f)))

;;@doc
;; Where the plugin keeps files that must outlive a single editor session.
(define (state-home)
  (string-append (or (env "XDG_STATE_HOME") (string-append (or (env "HOME") "/tmp") "/.local/state"))
                 "/devcontainer.hx"))

;;@doc
;; Directory holding the lock files that track which editors use which container.
(define (lock-dir)
  (string-append (state-home) "/sessions"))

;;@doc
;; Where the relay directory appears inside the container.
(define ssh-mount-target "/tmp/devcontainer.hx-ssh")

(define (relay-dir)
  (string-append (state-home) "/ssh"))

;; Unix socket paths are limited to 108 bytes including the terminator.
(define max-socket-path 107)

(define (relay-socket-name)
  (string-append "agent-" (number->string (current-milliseconds)) ".sock"))

;;@doc
;; Why the SSH agent cannot be forwarded although there is one to forward, or
;; #false. Having no agent at all is not a problem worth reporting.
(define (ssh-relay-problem)
  (let ([agent (env "SSH_AUTH_SOCK")] [dir (relay-dir)])
    (cond
      [(not (and agent (path-exists? agent))) #f]
      [(not (binary-path "socat")) "install socat on the host to forward the SSH agent"]
      [(string-contains? dir ",") (string-append dir " contains a comma and cannot be mounted")]
      [(> (string-length (string-append dir "/" (relay-socket-name))) max-socket-path)
       (string-append dir " is too long for a Unix socket path")]
      [else #f])))

;;@doc
;; How to relay the host's SSH agent into the container, or #false when it cannot
;; be done (see `ssh-relay-problem`).
;;
;; Returns a hash with 'socket (host path of the relay socket), 'agent, 'socat,
;; 'dir (host directory to mount) and 'container-socket.
(define (ssh-relay-plan)
  (let ([agent (env "SSH_AUTH_SOCK")] [dir (relay-dir)] [name (relay-socket-name)])
    (if (and agent (path-exists? agent) (not (ssh-relay-problem)))
        (begin
          ;; The mount source must exist before the container is created; the
          ;; helper tightens its permissions when it starts the relay.
          (with-handler (lambda (err) void) (create-directory! dir))
          (hash 'socket
                (string-append dir "/" name)
                'agent
                agent
                'socat
                (binary-path "socat")
                'dir
                dir
                'container-socket
                (string-append ssh-mount-target "/" name)))
        #f)))

;;@doc
;; The `--mount` specification that exposes the relay directory to the container.
(define (relay-mount plan)
  (string-append "type=bind,source=" (hash-ref plan 'dir) ",target=" ssh-mount-target))

;;@doc
;; The `--remote-env` pair that points tools in the container at the relay.
(define (relay-remote-env plan)
  (string-append "SSH_AUTH_SOCK=" (hash-ref plan 'container-socket)))

;;@doc
;; The host's `~/.gitconfig`, or #false if there is none.
(define (host-gitconfig)
  (let ([home (env "HOME")])
    (if home
        (let ([path (string-append home "/.gitconfig")]) (if (and (path-exists? path) (is-file? path)) path #f))
        #f)))

;; Runs in the container as the remote user. It is fixed text; the configuration
;; itself arrives on stdin.
(define copy-script "if [ -e \"$HOME/.gitconfig\" ]; then exit 0; fi; cat > \"$HOME/.gitconfig\"")

;;@doc
;; Copy the host's `~/.gitconfig` into the container unless it already has one.
;; Returns #true if there was nothing to do or the copy succeeded.
(define (copy-gitconfig! workspace)
  (let ([source (host-gitconfig)])
    (if (not source)
        #t
        (outcome-ok? (exec workspace #f (list "sh" "-c" copy-script) #:stdin-file source)))))
