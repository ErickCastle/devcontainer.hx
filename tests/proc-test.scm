(require "steel/tests/unit-test.scm")
(require "../cogs/proc.scm")

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
