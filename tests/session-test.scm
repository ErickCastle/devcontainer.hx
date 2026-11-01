;; Tests for the editor-lifetime helper: stopping containers when the editor
;; exits, sharing them between editors, and relaying the SSH agent.
;;
;; "The editor exits" is simulated by closing the helper's stdin, which is what
;; the operating system does when Helix goes away.
(require "steel/tests/unit-test.scm")
(require "../cogs/proc.scm")
(require "../cogs/session.scm")
(require "../cogs/forwarding.scm")
(require-builtin steel/time)
(require-builtin steel/filesystem)

(create-directory! "tests/tmp/session")
(define tmp (canonicalize-path "tests/tmp/session"))
(define fake-docker (canonicalize-path "tests/fake-docker/docker"))
(define calls-file (string-append (canonicalize-path "tests/tmp") "/docker-calls"))
(define locks (string-append tmp "/locks"))

(define (read-file path)
  (if (path-exists? path)
      (let* ([port (open-input-file path)] [text (read-port-to-string port)])
        (close-input-port port)
        text)
      ""))

(define (reset!)
  (when (path-exists? calls-file)
    (delete-file! calls-file)))

;; Poll until `predicate` holds, for up to about two seconds.
(define (eventually predicate)
  (let loop ([tries 40])
    (cond
      [(predicate) #t]
      [(= tries 0) #f]
      [else
       (time/sleep-ms 50)
       (loop (- tries 1))])))

(define (calls)
  (read-file calls-file))

;; Give a helper time to settle when checking that something does *not* happen.
(define (settle)
  (time/sleep-ms 300))

;;;; ---------------------------------------------------------------------------
;;;; shutdownAction
;;;; ---------------------------------------------------------------------------

(check-equal? "an image configuration stops the container" (shutdown-action (hash 'image "alpine")) "stopContainer")
(check-equal? "a compose configuration stops the project"
              (shutdown-action (hash 'dockerComposeFile "compose.yml"))
              "stopCompose")
(check-equal? "an explicit shutdownAction wins"
              (shutdown-action (hash 'dockerComposeFile "compose.yml" 'shutdownAction "stopContainer"))
              "stopContainer")
(check-equal? "none is honoured" (shutdown-action (hash 'shutdownAction "none")) "none")
(check-equal? "an unknown value falls back to the default" (shutdown-action (hash 'shutdownAction "bogus")) "stopContainer")
(check-equal? "a missing configuration falls back to the default" (shutdown-action #f) "stopContainer")

;;;; ---------------------------------------------------------------------------
;;;; Container ids sent to the helper
;;;; ---------------------------------------------------------------------------

(check-equal? "a hex id is valid" (valid-container-id? "a1b2c3") #t)
(check-equal? "an empty id is invalid" (valid-container-id? "") #f)
(check-equal? "an id with shell syntax is invalid" (valid-container-id? "abc; rm -rf /") #f)
(check-equal? "an id with a glob is invalid" (valid-container-id? "*") #f)
(check-equal? "only valid ids are armed" (arm-line (list "abc; rm" "fff" "*" "012")) "arm fff 012")
(check-equal? "nothing valid means nothing to arm" (arm-line (list "x y")) #f)

;;;; ---------------------------------------------------------------------------
;;;; Stopping on exit
;;;; ---------------------------------------------------------------------------

(reset!)
(define single (start-helper fake-docker locks #f))
(check-equal? "the helper starts" (if single #t #f) #t)
(helper-arm! single (list "abc123"))
(settle)
(check-equal? "nothing is stopped while the editor runs" (calls) "")
(helper-close! single)
(check-equal? "the container is stopped when the editor exits"
              (eventually (lambda () (equal? (calls) "stop abc123\n")))
              #t)

(reset!)
(define compose (start-helper fake-docker locks #f))
(helper-arm! compose (list "aaa111" "bbb222"))
(helper-close! compose)
(check-equal? "every container of a compose project is stopped"
              (eventually (lambda () (equal? (calls) "stop aaa111 bbb222\n")))
              #t)

(reset!)
(define rearmed (start-helper fake-docker locks #f))
(helper-arm! rearmed (list "0a0a0a"))
(helper-arm! rearmed (list "1b1b1b"))
(helper-close! rearmed)
(check-equal? "re-arming after a rebuild replaces the old container"
              (eventually (lambda () (equal? (calls) "stop 1b1b1b\n")))
              #t)

(reset!)
(define disarmed (start-helper fake-docker locks #f))
(helper-arm! disarmed (list "ccc333"))
(helper-disarm! disarmed)
(helper-close! disarmed)
(settle)
(check-equal? "a disarmed helper stops nothing" (calls) "")

(reset!)
(define unarmed (start-helper fake-docker locks #f))
(helper-close! unarmed)
(settle)
(check-equal? "a helper that was never armed stops nothing" (calls) "")

;; A lock directory that cannot be created (here, beneath a regular file) must not
;; turn the scan for other editors into a scan of `/`.
(reset!)
(define unlockable (start-helper fake-docker (string-append fake-docker "/locks") #f))
(helper-arm! unlockable (list "eee555"))
(helper-close! unlockable)
(check-equal? "without lock files the container is still stopped on exit"
              (eventually (lambda () (equal? (calls) "stop eee555\n")))
              #t)

;;;; ---------------------------------------------------------------------------
;;;; Several editors sharing one container
;;;; ---------------------------------------------------------------------------

(reset!)
(define first-editor (start-helper fake-docker locks #f))
(define second-editor (start-helper fake-docker locks #f))
(helper-arm! first-editor (list "ddd444"))
(helper-arm! second-editor (list "ddd444"))
(settle)
(helper-close! first-editor)
(settle)
(check-equal? "the container keeps running while another editor uses it" (calls) "")
(helper-close! second-editor)
(check-equal? "the last editor to exit stops it" (eventually (lambda () (equal? (calls) "stop ddd444\n"))) #t)

;;;; ---------------------------------------------------------------------------
;;;; SSH agent relay
;;;; ---------------------------------------------------------------------------

(define socat (binary-path "socat"))

(define (via-socket path text)
  (trim (proc-stdout (run/capture "sh"
                                  (list "-c" "printf '%s\\n' \"$2\" | \"$1\" -t 1 - \"UNIX-CONNECT:$3\"" "sh" socat text path)
                                  #f))))

(if (not socat)
    (displayln "socat not found; skipping the SSH relay tests")
    (let* ([agent-path (string-append tmp "/agent.sock")]
           [relay-dir (string-append tmp "/relay")]
           [relay-path (string-append relay-dir "/agent-test.sock")]
           ;; An "agent" that echoes whatever it receives.
           [agent (spawn/background socat (list (string-append "UNIX-LISTEN:" agent-path ",fork,unlink-early") "EXEC:cat"))]
           [_ (eventually (lambda () (path-exists? agent-path)))]
           [helper (start-helper #f locks (hash 'socket relay-path 'agent agent-path 'socat socat))])
      (check-equal? "the relay socket appears" (eventually (lambda () (path-exists? relay-path))) #t)
      (check-equal? "connections are forwarded to the agent" (via-socket relay-path "ping") "ping")
      (check-equal? "the relay directory is private"
                    (trim (proc-stdout (run/capture "stat" (list "-c" "%a" relay-dir) #f)))
                    "700")
      (helper-close! helper)
      (check-equal? "the relay socket is removed when the editor exits"
                    (eventually (lambda () (not (path-exists? relay-path))))
                    #t)
      (kill (hash-ref agent 'child))))

;;;; ---------------------------------------------------------------------------
;;;; Forwarding plan
;;;; ---------------------------------------------------------------------------

;; tests/run.sh points SSH_AUTH_SOCK at an existing file and XDG_STATE_HOME at
;; tests/tmp/state.
(define plan (ssh-relay-plan))

(if (not socat)
    (check-equal? "without socat there is no relay" plan #f)
    (begin
      (check-equal? "nothing stands in the way of the relay" (ssh-relay-problem) #f)
      (check-equal? "a relay is planned when an agent and socat exist" (hash? plan) #t)
      (check-equal? "the relay lives under the state directory"
                    (starts-with? (hash-ref plan 'socket) (string-append (state-home) "/ssh/"))
                    #t)
      (check-equal? "the mount source is created" (path-exists? (hash-ref plan 'dir)) #t)
      (check-equal? "the directory is mounted at a fixed container path"
                    (relay-mount plan)
                    (string-append "type=bind,source=" (hash-ref plan 'dir) ",target=" ssh-mount-target))
      (check-equal? "tools in the container are pointed at the relay"
                    (relay-remote-env plan)
                    (string-append "SSH_AUTH_SOCK=" ssh-mount-target "/" (list-ref (split-once (hash-ref plan 'socket) "/ssh/") 1)))))
