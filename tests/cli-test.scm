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

(define up-ok (up workspace #f #f #f))

(check-equal? "up succeeds" (outcome-ok? up-ok) #t)

(check-equal? "up reports the container id"
              (json-ref (outcome-data up-ok) 'containerId #f)
              "deadbeef1234")

(check-equal? "up reports the remote user" (json-ref (outcome-data up-ok) 'remoteUser #f) "vscode")

(check-equal? "up reports the container-side workspace folder"
              (json-ref (outcome-data up-ok) 'remoteWorkspaceFolder #f)
              "/workspaces/fixture")

(define config-ok (read-configuration workspace #f))

(check-equal? "read-configuration succeeds" (outcome-ok? config-ok) #t)

(check-equal? "read-configuration exposes the container-side workspace folder"
              (json-ref (json-ref (outcome-data config-ok) 'workspace #f) 'workspaceFolder #f)
              "/workspaces/fixture")

(check-equal? "cli is detected on PATH" (cli-available?) #t)

;;;; ---------------------------------------------------------------------------
;;;; Arguments are passed as argv, never through a shell
;;;; ---------------------------------------------------------------------------

(define exec-ok (exec workspace #f (list "echo" "hello world")))

(check-equal? "exec succeeds" (outcome-ok? exec-ok) #t)

(check-equal? "exec forwards the command verbatim"
              (trim (hash-ref (outcome-data exec-ok) 'stdout))
              "ran: echo hello world")

;; A real workspace whose directory name would be catastrophic if it were ever
;; concatenated into a shell command. It must survive as a single opaque argument.
(define hostile-workspace "tests/fixtures/my project; touch pwned #")

(define hostile (up hostile-workspace #f #f #f))

(check-equal? "a shell-hostile workspace path still runs" (outcome-ok? hostile) #t)

(check-equal? "a shell-hostile workspace path executes nothing extra"
              (path-exists? (string-append hostile-workspace "/pwned"))
              #f)

(check-equal? "a shell-hostile workspace path is passed through as one argument"
              (trim (hash-ref (outcome-data (exec hostile-workspace #f (list "pwd")))
                             'stdout))
              "ran: pwd")

;;;; ---------------------------------------------------------------------------
;;;; Structured CLI errors
;;;; ---------------------------------------------------------------------------

(set-mode! "error-outcome")

(define up-err (up workspace #f #f #f))

(check-equal? "a structured error is a failure" (outcome-ok? up-err) #f)

(check-equal? "the CLI message becomes the headline"
              (outcome-message up-err)
              "docker: command not found")

;;;; ---------------------------------------------------------------------------
;;;; The reason for a failure is recovered from the log
;;;;
;;;; The CLI's JSON envelope only names the command that failed, so the useful
;;;; explanation has to come from stderr.
;;;; ---------------------------------------------------------------------------

(set-mode! "image-missing")

(define missing-image (up workspace #f #f #f))

(check-equal? "a failed image pull is a failure" (outcome-ok? missing-image) #f)

(check-equal? "the headline explains why, not just which command failed"
              (outcome-message missing-image)
              "Error response from daemon: No such image: example.com/nope:1-alpine")

(check-equal? "the log timestamp is stripped from the headline"
              (starts-with? (outcome-message missing-image) "[")
              #f)

(check-equal? "the failing command is kept as the detail"
              (outcome-detail missing-image)
              "Command failed: docker pull example.com/nope:1-alpine")

(check-equal? "the full transcript is retained"
              (string-contains? (outcome-logs missing-image) "Retrying (Attempt 3)")
              #t)

(set-mode! "daemon-down")

(check-equal? "an unreachable daemon is explained"
              (outcome-message (up workspace #f #f #f))
              "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.")

;;;; ---------------------------------------------------------------------------
;;;; Unstructured failures
;;;; ---------------------------------------------------------------------------

(set-mode! "crash")

(define crashed (up workspace #f #f #f))

(check-equal? "a non-zero exit without JSON is a failure" (outcome-ok? crashed) #f)

(check-equal? "stderr is surfaced as the detail"
              (string-contains? (outcome-detail crashed) "Is the docker daemon running?")
              #t)

(set-mode! "garbage")

(define garbled (up workspace #f #f #f))

(check-equal? "unparseable output is a failure" (outcome-ok? garbled) #f)

;;;; ---------------------------------------------------------------------------
;;;; A failing command inside the container
;;;; ---------------------------------------------------------------------------

(set-mode! "nonzero-exec")

(define exec-failed (exec workspace #f (list "false")))

(check-equal? "a non-zero command is reported as a failure" (outcome-ok? exec-failed) #f)

(check-equal? "the exit code is reported"
              (string-contains? (outcome-message exec-failed) "exit 7")
              #t)

;;;; ---------------------------------------------------------------------------
;;;; Large log volume
;;;; ---------------------------------------------------------------------------

(set-mode! "noisy-success")

(define noisy (up workspace #f #f #f))

(check-equal? "a build producing megabytes of logs still completes" (outcome-ok? noisy) #t)

(check-equal? "the result is parsed from behind the log noise"
              (json-ref (outcome-data noisy) 'containerId #f)
              "noisy999")

(set-mode! "success")

;;;; ---------------------------------------------------------------------------
;;;; Progress while starting
;;;; ---------------------------------------------------------------------------

(define (recorded-args)
  (let* ([port (open-input-file "tests/tmp/fake-args")] [text (read-port-to-string port)])
    (close-input-port port)
    (filter (lambda (line) (not (equal? line ""))) (split-many text "\n"))))

(define (value-after args flag)
  (cond
    [(or (empty? args) (empty? (cdr args))) #f]
    [(equal? (car args) flag) (cadr args)]
    [else (value-after (cdr args) flag)]))

(define progress-lines (box '()))

(define streamed-up
  (up workspace #f #f #f #:on-progress (lambda (text) (set-box! progress-lines (cons text (unbox progress-lines))))))

(check-equal? "a streamed up still succeeds" (outcome-ok? streamed-up) #t)

(check-equal? "progress is reported line by line, without timestamps"
              (reverse (unbox progress-lines))
              (list "dev-containers-cli 0.80.0." "Start: Run: docker start"))

(check-equal? "the streamed transcript is retained"
              (string-contains? (outcome-logs streamed-up) "Start: Run: docker start")
              #t)

(set-mode! "noisy-success")

(define noisy-count (box 0))

(define noisy-streamed (up workspace #f #f #f #:on-progress (lambda (text) (set-box! noisy-count (+ 1 (unbox noisy-count))))))

(check-equal? "a noisy streamed build still completes" (json-ref (outcome-data noisy-streamed) 'containerId #f) "noisy999")
(check-equal? "every progress line is delivered" (unbox noisy-count) 20000)

(set-mode! "image-missing")

(check-equal? "a streamed failure still explains itself"
              (outcome-message (up workspace #f #f #f #:on-progress (lambda (text) void)))
              "Error response from daemon: No such image: example.com/nope:1-alpine")

(set-mode! "success")

(check-equal? "blank log lines are not progress" (progress-text "[2026-08-30T13:43:20.038Z] ") #f)
(check-equal? "timestamps are stripped" (progress-text "[12 ms] Start: Run: docker build") "Start: Run: docker build")
(check-equal? "long lines are shortened" (string-length (progress-text (make-string 300 #\x))) 100)

;;;; ---------------------------------------------------------------------------
;;;; Flags for the SSH relay
;;;; ---------------------------------------------------------------------------

(up workspace #f #f #f #:mounts (list "type=bind,source=/a b,target=/c") #:remote-env (list "SSH_AUTH_SOCK=/c/s.sock"))

(check-equal? "the configuration is requested, for shutdownAction"
              (if (member "--include-configuration" (recorded-args)) #t #f)
              #t)

(check-equal? "mounts are passed as single arguments"
              (value-after (recorded-args) "--mount")
              "type=bind,source=/a b,target=/c")

(check-equal? "remote environment is passed to up"
              (value-after (recorded-args) "--remote-env")
              "SSH_AUTH_SOCK=/c/s.sock")

(check-equal? "remote environment is passed to exec, before the command"
              (trim (hash-ref (outcome-data (exec workspace #f (list "env") #:remote-env (list "A=1"))) 'stdout))
              "ran: env")

(check-equal? "exec received the pair"
              (value-after (recorded-args) "--remote-env")
              "A=1")

(check-equal? "a file is fed to exec's stdin"
              (trim (hash-ref (outcome-data (exec workspace
                                                  #f
                                                  (list "read-stdin")
                                                  #:stdin-file "tests/fixtures/e2e-dir/.devcontainer/devcontainer.json"))
                              'stdout))
              (string-append "stdin: " (trim (let* ([port (open-input-file "tests/fixtures/e2e-dir/.devcontainer/devcontainer.json")]
                                                    [text (read-port-to-string port)])
                                               (close-input-port port)
                                               text))))
