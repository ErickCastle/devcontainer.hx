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
;; * work   : (-> any?)      -- must not touch the editor
;; * finish : (-> any? void) -- runs on the main thread, may touch the editor
;;
;; Errors raised by `work` are turned into an editor error rather than killing the
;; thread silently.
(define (run-async work finish)
  (spawn-native-thread (lambda ()
                         (define outcome (with-handler (lambda (err) (cons 'error err)) (cons 'ok (work))))
                         (hx.block-on-task (lambda ()
                                             (if (equal? (car outcome) 'ok)
                                                 (finish (cdr outcome))
                                                 (fail (string-append "Dev container operation failed: "
                                                                      (to-string (cdr outcome))))))))))
