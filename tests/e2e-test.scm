;; End-to-end tests against the real Dev Container CLI and a real container
;; runtime. Run via tests/e2e.sh, which checks prerequisites and cleans up.
(require "steel/tests/unit-test.scm")
(require "../cogs/cli.scm")
(require "../cogs/config.scm")
(require "../cogs/docker.scm")

(define dir-fixture "tests/fixtures/e2e-dir")
(define file-fixture "tests/fixtures/e2e-file")
(define invalid-fixture "tests/fixtures/invalid")

(define (stdout-of outcome)
  (trim (hash-ref (outcome-data outcome) 'stdout)))

;;;; ---------------------------------------------------------------------------
;;;; Prerequisites
;;;; ---------------------------------------------------------------------------

(check-equal? "the dev container CLI is available" (cli-available?) #t)
(check-equal? "docker is available" (docker-available?) #t)

;;;; ---------------------------------------------------------------------------
;;;; Reading configuration without starting anything
;;;; ---------------------------------------------------------------------------

(define config (read-configuration dir-fixture #f))

(check-equal? "configuration can be read" (outcome-ok? config) #t)

(check-equal? "the configured name is returned"
              (json-ref (json-ref (outcome-data config) 'configuration (hash)) 'name #f)
              "hx-e2e-dir")

(check-equal? "no container is created by reading configuration"
              (container-for-workspace dir-fixture)
              #f)

;;;; ---------------------------------------------------------------------------
;;;; Creating the container
;;;; ---------------------------------------------------------------------------

(define started (up dir-fixture #f #f #f))

(check-equal? "the container starts" (outcome-ok? started) #t)

(define first-id (json-ref (outcome-data started) 'containerId #f))

(check-equal? "a container id is returned" (if (string? first-id) #t #f) #t)

(check-equal? "the container-side workspace folder is reported"
              (if (string? (json-ref (outcome-data started) 'remoteWorkspaceFolder #f)) #t #f)
              #t)

(check-equal? "docker finds the container by its workspace label"
              (starts-with? first-id (container-for-workspace dir-fixture))
              #t)

(check-equal? "the container is running" (container-state (container-for-workspace dir-fixture)) "running")

;;;; ---------------------------------------------------------------------------
;;;; Running commands inside it
;;;; ---------------------------------------------------------------------------

(check-equal? "a command runs inside the container, not on the host"
              (starts-with? (stdout-of (exec dir-fixture #f (list "cat" "/etc/alpine-release"))) "3.20.")
              #t)

(check-equal? "the workspace is mounted inside the container"
              (stdout-of (exec dir-fixture #f (list "sh" "-c" "ls .devcontainer/devcontainer.json")))
              ".devcontainer/devcontainer.json")

(check-equal? "the postCreateCommand lifecycle hook ran"
              (stdout-of (exec dir-fixture #f (list "cat" "/tmp/lifecycle-ran")))
              "created")

;; Arguments survive as argv rather than being re-parsed by a shell.
(check-equal? "arguments are not interpreted by a shell"
              (stdout-of (exec dir-fixture #f (list "echo" "$HOME; touch /tmp/pwned")))
              "$HOME; touch /tmp/pwned")

(check-equal? "nothing was executed by the previous argument"
              (outcome-ok? (exec dir-fixture #f (list "test" "-e" "/tmp/pwned")))
              #f)

(define failed-command (exec dir-fixture #f (list "sh" "-c" "exit 42")))

(check-equal? "a failing command is reported as a failure" (outcome-ok? failed-command) #f)

(check-equal? "the container command's exit code is surfaced"
              (string-contains? (outcome-message failed-command) "42")
              #t)

;;;; ---------------------------------------------------------------------------
;;;; Stopping and restarting
;;;; ---------------------------------------------------------------------------

(define stopped (stop-container (container-for-workspace dir-fixture)))

(check-equal? "the container stops" (car stopped) #t)

(check-equal? "a stopped container is no longer running"
              (equal? (container-state (container-for-workspace dir-fixture)) "running")
              #f)

(define restarted (up dir-fixture #f #f #f))

(check-equal? "a stopped container can be restarted" (outcome-ok? restarted) #t)

(check-equal? "restarting reuses the same container"
              (json-ref (outcome-data restarted) 'containerId #f)
              first-id)

(check-equal? "the restarted container is running"
              (container-state (container-for-workspace dir-fixture))
              "running")

;;;; ---------------------------------------------------------------------------
;;;; Rebuilding
;;;; ---------------------------------------------------------------------------

(define rebuilt (up dir-fixture #f #t #f))

(check-equal? "the container rebuilds" (outcome-ok? rebuilt) #t)

(check-equal? "rebuilding produces a different container"
              (equal? (json-ref (outcome-data rebuilt) 'containerId #f) first-id)
              #f)

;;;; ---------------------------------------------------------------------------
;;;; The .devcontainer.json layout
;;;; ---------------------------------------------------------------------------

(check-equal? "a root .devcontainer.json is discovered"
              (find-config-path file-fixture)
              "tests/fixtures/e2e-file/.devcontainer.json")

(define file-started (up file-fixture #f #f #f))

(check-equal? "a root .devcontainer.json workspace starts" (outcome-ok? file-started) #t)

(check-equal? "it is a separate container"
              (equal? (json-ref (outcome-data file-started) 'containerId #f) first-id)
              #f)

;;;; ---------------------------------------------------------------------------
;;;; Invalid configuration
;;;; ---------------------------------------------------------------------------

(define broken (up invalid-fixture #f #f #f))

(check-equal? "a malformed configuration fails" (outcome-ok? broken) #f)

(check-equal? "the failure explains itself" (equal? (outcome-message broken) "") #f)
