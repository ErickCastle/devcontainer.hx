;; The status indicator: a statusline element showing the container's state, and
;; a spinner that animates while an operation is running.
;;
;; Rendering happens on every redraw, so the element only reads cached state.
;; Helix redraws after each job callback, so a self-rescheduling callback is
;; enough to keep the spinner moving while an operation runs.

(require "state.scm")
(require "helix/components.scm")
(require "helix/misc.scm")

(provide install-indicator!
         start-spinner!
         spinner-frame
         indicator-text)

;; The same frames Helix uses for its LSP progress spinner.
(define frames (list "⣾" "⣽" "⣻" "⢿" "⡿" "⣟" "⣯" "⣷"))
(define frame-interval-ms 80)

(define *frame* (box 0))
(define *spinning* (box #f))

;;@doc
;; The spinner's current frame.
(define (spinner-frame)
  (list-ref frames (modulo (unbox *frame*) (length frames))))

;;@doc
;; Animate the spinner until `active?` returns #false, calling `on-frame` after
;; each step. Does nothing if the spinner is already running.
;;
;; * active?  : (-> boolean?)
;; * on-frame : (-> void) -- e.g. to refresh a status message carrying the frame
(define (start-spinner! active? on-frame)
  (unless (unbox *spinning*)
    (set-box! *spinning* #t)
    (letrec ([tick (lambda ()
                     (if (active?)
                         (begin
                           (set-box! *frame* (+ 1 (unbox *frame*)))
                           (on-frame)
                           (enqueue-thread-local-callback-with-delay frame-interval-ms tick))
                         (set-box! *spinning* #f)))])
      (enqueue-thread-local-callback-with-delay frame-interval-ms tick))))

;;@doc
;; What the indicator shows for `workspace`, as a (text . scope) pair, or #false
;; when there is nothing to show. `scope` is a theme scope name or #false.
(define (indicator-text workspace)
  (let ([status (cached-status workspace)])
    (cond
      [(equal? status 'no-config) #f]
      [(busy? workspace) (cons (string-append (spinner-frame) " devcontainer") "info")]
      [(last-failed? workspace) (cons "✗ devcontainer" "error")]
      [(equal? status 'running) (cons "● devcontainer" "hint")]
      [(equal? status 'stopped) (cons "○ devcontainer (stopped)" #f)]
      [(equal? status 'none) (cons "○ devcontainer" #f)]
      [else (cons "devcontainer" #f)])))

(define (render workspace-fn)
  (lambda (view-id focused?)
    (let ([shown (indicator-text (workspace-fn))])
      (if shown
          (list (span (string-append " " (car shown) " ")
                      (if (cdr shown) (theme-scope-ref (cdr shown)) (theme-scope-ref "ui.statusline"))))
          '()))))

;;@doc
;; Add the indicator to the statusline.
;;
;; * side         : symbol?      -- 'left, 'center or 'right
;; * workspace-fn : (-> string?) -- the workspace to report on
(define (install-indicator! side workspace-fn)
  (push-status-element! side (status-element (render workspace-fn))))
