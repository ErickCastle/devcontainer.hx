;; Per-workspace session state.
;;
;; All mutation is expected to happen on the editor's main thread (worker threads
;; hand results back through `job.scm` before touching this), so no locking is
;; needed here.

(provide record-up!
         forget!
         container-id
         remote-user
         remote-workspace
         begin-operation!
         end-operation!
         current-operation
         busy?
         set-last-logs!
         last-logs)

(define *state* (box (hash)))

(define (entry workspace)
  (let ([found (hash-try-get (unbox *state*) workspace)])
    (if found found (hash))))

(define (field workspace key default)
  (let ([found (hash-try-get (entry workspace) key)])
    (if found found default)))

(define (set-field! workspace key value)
  (set-box! *state* (hash-insert (unbox *state*) workspace (hash-insert (entry workspace) key value))))

;;;; ---------------------------------------------------------------------------
;;;; Container identity, as reported by the last successful `up`
;;;; ---------------------------------------------------------------------------

;;@doc
;; Remember the identity reported by a successful `devcontainer up`.
(define (record-up! workspace id user remote-folder)
  (set-field! workspace 'container-id id)
  (set-field! workspace 'remote-user user)
  (set-field! workspace 'remote-workspace remote-folder))

;;@doc
;; Drop everything remembered about a workspace's container.
(define (forget! workspace)
  (set-field! workspace 'container-id #f)
  (set-field! workspace 'remote-user #f)
  (set-field! workspace 'remote-workspace #f))

(define (container-id workspace)
  (field workspace 'container-id #f))
(define (remote-user workspace)
  (field workspace 'remote-user #f))
(define (remote-workspace workspace)
  (field workspace 'remote-workspace #f))

;;;; ---------------------------------------------------------------------------
;;;; In-flight operations
;;;;
;;;; Container operations are slow and mutate shared Docker state, so only one is
;;;; allowed per workspace at a time.
;;;; ---------------------------------------------------------------------------

;;@doc
;; Claim the workspace for `label`. Returns #false if an operation is already
;; running, in which case the caller must not start another.
(define (begin-operation! workspace label)
  (if (current-operation workspace)
      #f
      (begin
        (set-field! workspace 'operation label)
        #t)))

(define (end-operation! workspace)
  (set-field! workspace 'operation #f))

(define (current-operation workspace)
  (field workspace 'operation #f))

(define (busy? workspace)
  (if (current-operation workspace) #t #f))

;;;; ---------------------------------------------------------------------------
;;;; Transcript of the last operation
;;;; ---------------------------------------------------------------------------

(define (set-last-logs! workspace text)
  (set-field! workspace 'logs text))

(define (last-logs workspace)
  (field workspace 'logs ""))
