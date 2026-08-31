(require "steel/tests/unit-test.scm")
(require "../cogs/cli.scm")
(require-builtin steel/filesystem)

;; The fake CLI on PATH reads its behaviour from this file.
(define mode-file "tests/tmp/fake-mode")

(define (set-mode! mode)
  (when (not (path-exists? "tests/tmp"))
    (create-directory! "tests/tmp"))
  ;; open-output-file refuses to truncate an existing file.
  (when (path-exists? mode-file)
    (delete-file! mode-file))
  (let ([port (open-output-file mode-file)])
    (display mode port)
    (close-output-port port)))

(define workspace "tests/fixtures/dot-devcontainer-dir")

;;;; ---------------------------------------------------------------------------
;;;; Success
;;;; ---------------------------------------------------------------------------

(set-mode! "success")

(define up-ok (devcontainer-up workspace #f #f #f))

(check-equal? "up succeeds" (outcome-ok? up-ok) #t)

(check-equal? "up reports the container id"
              (json-ref (outcome-data up-ok) 'containerId #f)
              "deadbeef1234")

(check-equal? "up reports the remote user" (json-ref (outcome-data up-ok) 'remoteUser #f) "vscode")

(check-equal? "up reports the container-side workspace folder"
              (json-ref (outcome-data up-ok) 'remoteWorkspaceFolder #f)
              "/workspaces/fixture")

(define config-ok (devcontainer-read-configuration workspace #f))

(check-equal? "read-configuration succeeds" (outcome-ok? config-ok) #t)

(check-equal? "read-configuration exposes the container-side workspace folder"
              (json-ref (json-ref (outcome-data config-ok) 'workspace #f) 'workspaceFolder #f)
              "/workspaces/fixture")

(check-equal? "cli is detected on PATH" (cli-available?) #t)

;;;; ---------------------------------------------------------------------------
;;;; Arguments are passed as argv, never through a shell
;;;; ---------------------------------------------------------------------------

(define exec-ok (devcontainer-exec workspace #f (list "echo" "hello world")))

(check-equal? "exec succeeds" (outcome-ok? exec-ok) #t)

(check-equal? "exec forwards the command verbatim"
              (trim (hash-ref (outcome-data exec-ok) 'stdout))
              "ran: echo hello world")

;; A real workspace whose directory name would be catastrophic if it were ever
;; concatenated into a shell command. It must survive as a single opaque argument.
(define hostile-workspace "tests/fixtures/my project; touch pwned #")

(define hostile (devcontainer-up hostile-workspace #f #f #f))

(check-equal? "a shell-hostile workspace path still runs" (outcome-ok? hostile) #t)

(check-equal? "a shell-hostile workspace path executes nothing extra"
              (path-exists? (string-append hostile-workspace "/pwned"))
              #f)

(check-equal? "a shell-hostile workspace path is passed through as one argument"
              (trim (hash-ref (outcome-data (devcontainer-exec hostile-workspace #f (list "pwd")))
                             'stdout))
              "ran: pwd")

;;;; ---------------------------------------------------------------------------
;;;; Structured CLI errors
;;;; ---------------------------------------------------------------------------

(set-mode! "error-outcome")

(define up-err (devcontainer-up workspace #f #f #f))

(check-equal? "a structured error is a failure" (outcome-ok? up-err) #f)

(check-equal? "the CLI description becomes the message"
              (outcome-message up-err)
              "An error occurred setting up the container.")

(check-equal? "the CLI message becomes the detail"
              (outcome-detail up-err)
              "docker: command not found")

;;;; ---------------------------------------------------------------------------
;;;; Unstructured failures
;;;; ---------------------------------------------------------------------------

(set-mode! "crash")

(define crashed (devcontainer-up workspace #f #f #f))

(check-equal? "a non-zero exit without JSON is a failure" (outcome-ok? crashed) #f)

(check-equal? "stderr is surfaced as the detail"
              (string-contains? (outcome-detail crashed) "Is the docker daemon running?")
              #t)

(set-mode! "garbage")

(define garbled (devcontainer-up workspace #f #f #f))

(check-equal? "unparseable output is a failure" (outcome-ok? garbled) #f)

;;;; ---------------------------------------------------------------------------
;;;; A failing command inside the container
;;;; ---------------------------------------------------------------------------

(set-mode! "nonzero-exec")

(define exec-failed (devcontainer-exec workspace #f (list "false")))

(check-equal? "a non-zero command is reported as a failure" (outcome-ok? exec-failed) #f)

(check-equal? "the exit code is reported"
              (string-contains? (outcome-message exec-failed) "exit 7")
              #t)

;;;; ---------------------------------------------------------------------------
;;;; Large log volume
;;;; ---------------------------------------------------------------------------

(set-mode! "noisy-success")

(define noisy (devcontainer-up workspace #f #f #f))

(check-equal? "a build producing megabytes of logs still completes" (outcome-ok? noisy) #t)

(check-equal? "the result is parsed from behind the log noise"
              (json-ref (outcome-data noisy) 'containerId #f)
              "noisy999")

(set-mode! "success")
