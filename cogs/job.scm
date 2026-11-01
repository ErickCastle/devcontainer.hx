;; Running slow container operations without blocking the editor.
;;
;; While a Steel function is executing it holds the Helix context exclusively, so
;; anything that takes more than a moment must move off the main thread. `run-async`
;; spawns a native thread for the work and marshals the result back through
;; `hx.block-on-task`, which is the only safe way to touch the editor from another
;; thread.

(require "helix/ext.scm")
(require "helix/misc.scm")

(provide run-async
         run-async/progress
         notify
         warn
         fail)

(define (notify message)
  (set-status! message))

(define (warn message)
  (set-warning! message))

(define (fail message)
  (set-error! message))

;;@doc
;; Run `work` on a background thread, then call `finish` with its result on the
;; main thread.
;;
;; * work      : (-> any?)      -- must not touch the editor
;; * finish    : (-> any? void) -- runs on the main thread, may touch the editor
;; * #:on-error : (-> string? void) -- runs on the main thread instead of `finish`
;;                when `work` raises; it must undo anything `finish` would have
;;                (such as releasing the workspace). Defaults to reporting the
;;                error.
(define (run-async work finish #:on-error [on-error #f])
  (spawn-native-thread (lambda ()
                         (define outcome (with-handler (lambda (err) (cons 'error err)) (cons 'ok (work))))
                         (hx.block-on-task (lambda ()
                                             (if (equal? (car outcome) 'ok)
                                                 (finish (cdr outcome))
                                                 (let ([message (string-append "Dev container operation failed: "
                                                                               (to-string (cdr outcome)))])
                                                   (if on-error (on-error message) (fail message))))))))
  ;; Helix echoes a command's return value, so the thread handle must not escape.
  void)

(define progress-poll-ms 100)

;; The most recent string waiting on `receiver`, or `last` if there is none.
(define (drain-latest receiver last)
  (let ([value (channel/try-recv receiver)])
    (if (string? value) (drain-latest receiver value) last)))

;;@doc
;; Like `run-async`, but `work` receives a `report` procedure it may call with
;; progress text from the background thread. `on-progress` is called on the main
;; thread with the most recent text, polled every 100 ms, so a build emitting
;; thousands of lines a second costs the editor at most ten updates a second, and
;; the last line before a quiet step is never lost.
;;
;; * work        : (-> (-> string? void) any?)
;; * finish      : (-> any? void)
;; * on-progress : (-> string? void) -- runs on the main thread
;; * #:on-error  : as for `run-async`; polling stops either way
(define (run-async/progress work finish on-progress #:on-error [on-error #f])
  (define channels (channels/new))
  (define sender (channels-sender channels))
  (define receiver (channels-receiver channels))
  (define done? (box #f))
  (define (poll)
    (unless (unbox done?)
      (let ([latest (drain-latest receiver #f)])
        (when latest
          (on-progress latest)))
      (enqueue-thread-local-callback-with-delay progress-poll-ms poll)))
  (enqueue-thread-local-callback-with-delay progress-poll-ms poll)
  (run-async (lambda () (work (lambda (text) (channel/send sender text))))
             (lambda (result)
               (set-box! done? #t)
               (finish result))
             #:on-error
             (lambda (message)
               (set-box! done? #t)
               (if on-error (on-error message) (fail message)))))
