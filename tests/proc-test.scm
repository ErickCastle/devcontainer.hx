(require "steel/tests/unit-test.scm")
(require "../cogs/proc.scm")
(require-builtin steel/time)
(require-builtin steel/filesystem)

(define ok (run/capture "echo" (list "hello" "world") #f))

(check-equal? "a successful command exits zero" (proc-code ok) 0)
(check-equal? "stdout is captured" (trim (proc-stdout ok)) "hello world")
(check-equal? "success is reported" (proc-success? ok) #t)

(define failing (run/capture "sh" (list "-c" "echo out; echo problem 1>&2; exit 3") #f))

(check-equal? "the exit code is captured" (proc-code failing) 3)
(check-equal? "stdout and stderr are kept apart" (trim (proc-stdout failing)) "out")
(check-equal? "stderr is captured" (trim (proc-stderr failing)) "problem")
(check-equal? "failure is reported" (proc-success? failing) #f)

(define missing (run/capture "no-such-binary-anywhere-xyz" '() #f))

(check-equal? "a missing binary does not raise" (proc-spawn-failed? missing) #t)
(check-equal? "a missing binary has no exit code" (proc-code missing) #f)

(check-equal? "the working directory is applied"
              (trim (proc-stdout (run/capture "pwd" '() "/tmp")))
              "/tmp")

(check-equal? "arguments are not word-split"
              (trim (proc-stdout (run/capture "echo" (list "one two  three") #f)))
              "one two  three")

;; Arguments reach the child verbatim rather than being reinterpreted by a shell.
(check-equal? "arguments are not interpreted by a shell"
              (trim (proc-stdout (run/capture "echo" (list "$HOME; touch pwned") #f)))
              "$HOME; touch pwned")

(check-equal? "an executable is found on PATH" (if (binary-path "sh") #t #f) #t)
(check-equal? "a missing executable resolves to false" (binary-path "no-such-binary-xyz") #f)
(check-equal? "binary-available? agrees" (binary-available? "sh") #t)

;; The dev container CLI logs heavily to stderr and only writes its result to
;; stdout at the very end. Draining two pipes in sequence would deadlock here.
(define noisy
  (run/capture
   "sh"
   (list "-c" "i=0; while [ $i -lt 20000 ]; do echo 'filler filler filler filler' 1>&2; i=$((i+1)); done; echo done")
   #f))

(check-equal? "a large stderr volume does not deadlock" (trim (proc-stdout noisy)) "done")
(check-equal? "the large stderr volume is captured" (> (string-length (proc-stderr noisy)) 500000) #t)

;;;; ---------------------------------------------------------------------------
;;;; Feeding stdin from a file
;;;; ---------------------------------------------------------------------------

(check-equal? "a file can be fed to stdin"
              (trim (proc-stdout (run/capture "cat" '() #f #:stdin-file "tests/fixtures/e2e-dir/.devcontainer/devcontainer.json")))
              (trim (proc-stdout (run/capture "cat" (list "tests/fixtures/e2e-dir/.devcontainer/devcontainer.json") #f))))

;;;; ---------------------------------------------------------------------------
;;;; Streaming stderr
;;;; ---------------------------------------------------------------------------

(define streamed-lines (box '()))

(define streamed
  (run/stream "sh"
              (list "-c" "echo one 1>&2; echo out; echo two 1>&2; exit 4")
              #f
              (lambda (line) (set-box! streamed-lines (cons line (unbox streamed-lines))))))

(check-equal? "each stderr line is delivered, in order, without its newline"
              (reverse (unbox streamed-lines))
              (list "one" "two"))
(check-equal? "streamed stdout is still captured" (trim (proc-stdout streamed)) "out")
(check-equal? "streamed stderr is still captured" (proc-stderr streamed) "one\ntwo\n")
(check-equal? "the streamed exit code is captured" (proc-code streamed) 4)

(define streamed-count (box 0))

(define streamed-noisy
  (run/stream
   "sh"
   (list "-c" "i=0; while [ $i -lt 20000 ]; do echo 'filler filler filler filler' 1>&2; i=$((i+1)); done; echo done")
   #f
   (lambda (line) (set-box! streamed-count (+ 1 (unbox streamed-count))))))

(check-equal? "streaming a large stderr volume does not deadlock" (trim (proc-stdout streamed-noisy)) "done")
(check-equal? "every streamed line is delivered" (unbox streamed-count) 20000)

(check-equal? "a failing line callback does not abort the stream"
              (proc-code (run/stream "sh" (list "-c" "echo x 1>&2") #f (lambda (line) (error "boom"))))
              0)

(check-equal? "streaming a missing binary does not raise"
              (proc-spawn-failed? (run/stream "no-such-binary-anywhere-xyz" '() #f (lambda (line) void)))
              #t)

(define invalid-lines (box '()))

(define invalid-utf8
  (run/stream "sh"
              (list "-c" "printf 'before\\n\\377\\376 garbage\\nafter\\n' 1>&2; echo done")
              #f
              (lambda (line) (set-box! invalid-lines (cons line (unbox invalid-lines))))))

(check-equal? "a line that is not UTF-8 is skipped, not fatal" (reverse (unbox invalid-lines)) (list "before" "after"))
(check-equal? "the command still completes after an undecodable line" (trim (proc-stdout invalid-utf8)) "done")

;;;; ---------------------------------------------------------------------------
;;;; Background processes
;;;; ---------------------------------------------------------------------------

(define (read-file path)
  (if (path-exists? path)
      (let* ([port (open-input-file path)] [text (read-port-to-string port)])
        (close-input-port port)
        text)
      ""))

(define (wait-for-file path expected tries)
  (cond
    [(equal? (read-file path) expected) #t]
    [(= tries 0) #f]
    [else
     (time/sleep-ms 50)
     (wait-for-file path expected (- tries 1))]))

(define bg-out "tests/tmp/background.out")
(when (path-exists? bg-out)
  (delete-file! bg-out))

(define bg
  (spawn/background "sh"
                    (list "-c" "while IFS= read -r l; do echo \"got $l\" >> \"$1\"; done; echo eof >> \"$1\"" "sh" bg-out)))

(check-equal? "a background process starts" (if bg #t #f) #t)
(check-equal? "lines can be sent to it" (background-send! bg "hello") #t)
(check-equal? "it receives them" (wait-for-file bg-out "got hello\n" 40) #t)
(background-close! bg)
(check-equal? "closing its stdin looks like the editor exiting" (wait-for-file bg-out "got hello\neof\n" 40) #t)
(check-equal? "sending after close reports failure" (background-send! bg "late") #f)
(check-equal? "a missing binary yields no background process" (spawn/background "no-such-binary-anywhere-xyz" '()) #f)
