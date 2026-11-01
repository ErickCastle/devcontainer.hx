;; Structured subprocess execution.
;;
;; Every external process in this plugin is spawned here. Commands are built from an
;; explicit argument vector via `command`, which execs directly without a shell, so
;; workspace paths, container names and configuration values are never parsed as
;; shell syntax.

;; Note: `require-builtin` supports only whole-module or prefixed imports, and the
;; prefixed form does not resolve for `steel/process` or `steel/filesystem`. These
;; therefore import unprefixed, which makes names like `wait` and `set-env-var!`
;; (an alias of `with-env-var`) visible to modules that require this one.
(require-builtin steel/process)
(require-builtin steel/filesystem)
(require-builtin steel/time)
(require "steel/result")

(provide run/capture
         run/stream
         spawn/background
         background-send!
         background-close!
         binary-path
         binary-available?
         proc-code
         proc-stdout
         proc-stderr
         proc-spawn-failed?
         proc-success?)

;;;; ---------------------------------------------------------------------------
;;;; Temporary files
;;;; ---------------------------------------------------------------------------

(define *temp-counter* (box 0))

(define (next-temp-id)
  (set-box! *temp-counter* (+ 1 (unbox *temp-counter*)))
  (unbox *temp-counter*))

(define (temp-dir)
  (let ([found (maybe-get-env-var "TMPDIR")])
    (if (and (Ok? found) (not (equal? (unwrap-ok found) "")))
        (unwrap-ok found)
        "/tmp")))

(define (stderr-temp-path)
  (string-append (temp-dir)
                 "/hx-devcontainer-"
                 (number->string (current-milliseconds))
                 "-"
                 (number->string (next-temp-id))
                 ".stderr"))

(define (read-file-to-string path)
  (with-handler (lambda (err) "")
                (let* ([port (open-input-file path)] [contents (read-port-to-string port)])
                  (close-input-port port)
                  contents)))

(define (try-delete-file path)
  (with-handler (lambda (err) void) (when (path-exists? path) (delete-file! path))))

;;;; ---------------------------------------------------------------------------
;;;; Result accessors
;;;; ---------------------------------------------------------------------------

(define (proc-code result)
  (hash-ref result 'code))
(define (proc-stdout result)
  (hash-ref result 'stdout))
(define (proc-stderr result)
  (hash-ref result 'stderr))
(define (proc-spawn-failed? result)
  (hash-ref result 'spawn-failed))

(define (proc-success? result)
  (equal? 0 (proc-code result)))

(define (spawn-failure message)
  (hash 'code #f 'stdout "" 'stderr message 'spawn-failed #t))

;;;; ---------------------------------------------------------------------------
;;;; Executing
;;;; ---------------------------------------------------------------------------

;;@doc
;; Look up an executable on PATH, returning its absolute path or #false.
(define (binary-path program)
  (with-handler (lambda (err) #f) (which program)))

;;@doc
;; Whether the named executable can be found on PATH.
(define (binary-available? program)
  (if (binary-path program) #t #f))

;;@doc
;; Run `program` with the given list of arguments and wait for it to exit.
;;
;; ```scheme
;; (run/capture "devcontainer" '("--version") #f)
;; ```
;;
;; * program : string?          -- resolved against PATH, never a shell string
;; * args    : (listof string?) -- passed through verbatim as argv
;; * cwd     : (or string? #f)  -- working directory for the child
;;
;; Returns a hash with 'code (exit status, or #false if it could not be
;; determined), 'stdout, 'stderr and 'spawn-failed.
;;
;; stdout is captured through a pipe; stderr is redirected to a temporary file
;; rather than a second pipe. The dev container CLI writes megabytes of progress
;; logging to stderr but only emits its JSON result on stdout at the very end, so
;; draining the two pipes in sequence from a single thread would deadlock as soon
;; as the stderr pipe buffer filled.
(define (run/capture program args cwd #:stdin-file [stdin-file #f])
  (define err-path (stderr-temp-path))
  (define spawned
    (with-handler
     (lambda (err) (Err (error-object-message err)))
     (let* ([err-port (open-output-file err-path)]
            [builder (with-stderr (with-stdout-piped (command program args)) err-port)]
            [builder (if stdin-file (with-stdin builder (open-input-file stdin-file)) builder)]
            [builder (if cwd (with-current-dir builder cwd) builder)])
       (spawn-process builder))))
  (if (Err? spawned)
      (begin
        (try-delete-file err-path)
        (spawn-failure (to-string (unwrap-err spawned))))
      (let* ([child (unwrap-ok spawned)]
             [out-port (child-stdout child)]
             [stdout (if out-port (read-port-to-string out-port) "")]
             [status (wait child)]
             [stderr (read-file-to-string err-path)])
        (try-delete-file err-path)
        (hash 'code
              (if (Ok? status) (unwrap-ok status) #f)
              'stdout
              stdout
              'stderr
              stderr
              'spawn-failed
              #f))))

(define max-read-failures 1000)

;;@doc
;; Like `run/capture`, but calls `on-line` with each line of stderr as it is
;; written, so long-running commands can report progress.
;;
;; * on-line : (-> string? any?) -- called on the calling thread, without the
;;                                  trailing newline
;;
;; The pipes are swapped relative to `run/capture`: stderr is read incrementally
;; through a pipe and stdout goes to a temporary file, because the CLI's stdout is
;; a single small JSON line written at the very end.
(define (run/stream program args cwd on-line)
  (define out-path (string-append (stderr-temp-path) ".stdout"))
  (define spawned
    (with-handler
     (lambda (err) (Err (error-object-message err)))
     (let* ([out-port (open-output-file out-path)]
            [builder (with-stdout (with-stderr-piped (command program args)) out-port)]
            [builder (if cwd (with-current-dir builder cwd) builder)])
       (spawn-process builder))))
  (if (Err? spawned)
      (begin
        (try-delete-file out-path)
        (spawn-failure (to-string (unwrap-err spawned))))
      (let* ([child (unwrap-ok spawned)]
             [err-port (child-stderr child)]
             [lines (let loop ([acc '()] [failures 0])
                      (let ([line (if err-port
                                      (with-handler (lambda (err) 'unreadable) (read-line-from-port err-port))
                                      (eof-object))])
                        (cond
                          [(eof-object? line) (reverse acc)]
                          ;; A line that is not valid UTF-8 is consumed and skipped.
                          ;; If reading keeps failing, stop the child rather than
                          ;; spin: it would block forever on a pipe nobody drains.
                          [(equal? line 'unreadable)
                           (if (< failures max-read-failures)
                               (loop acc (+ failures 1))
                               (begin
                                 (with-handler (lambda (err) void) (kill child))
                                 (reverse acc)))]
                          [else
                           (let ([clean (trim-end-matches line "\n")])
                             (with-handler (lambda (err) void) (on-line clean))
                             (loop (cons clean acc) 0))])))]
             [status (wait child)]
             [stdout (read-file-to-string out-path)])
        (try-delete-file out-path)
        (hash 'code
              (if (Ok? status) (unwrap-ok status) #f)
              'stdout
              stdout
              'stderr
              (if (empty? lines) "" (string-append (string-join lines "\n") "\n"))
              'spawn-failed
              #f))))

;;;; ---------------------------------------------------------------------------
;;;; Long-lived background processes
;;;; ---------------------------------------------------------------------------

;;@doc
;; Start `program` without waiting for it, with a pipe on its stdin. Returns a
;; handle for `background-send!`/`background-close!`, or #false if the program
;; could not be started.
;;
;; The child is not killed when the editor exits; it sees end-of-file on stdin
;; instead, which is how a background helper learns that the editor has gone,
;; whether it quit normally or crashed. The handle must therefore be kept alive
;; for as long as the child should run: dropping it closes the pipe.
(define (spawn/background program args)
  (let ([spawned (with-handler (lambda (err) (Err (error-object-message err)))
                               (spawn-process (with-stdin-piped (command program args))))])
    (if (Ok? spawned)
        (let ([child (unwrap-ok spawned)])
          ;; `child-stdin` hands over the pipe only once, so it is taken here.
          (hash 'child child 'stdin (child-stdin child)))
        #f)))

;;@doc
;; Write one line to a background child's stdin. Returns #false if the child has
;; gone away.
(define (background-send! handle line)
  (with-handler (lambda (err) #f)
                (let ([port (hash-ref handle 'stdin)])
                  (write-string (string-append line "\n") port)
                  (flush-output-port port)
                  #t)))

;;@doc
;; Close a background child's stdin, as if the editor had exited.
(define (background-close! handle)
  (with-handler (lambda (err) #f) (close-output-port (hash-ref handle 'stdin))))
