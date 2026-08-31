;; Container inspection and shutdown via the Docker CLI.
;;
;; The dev container CLI has no command that reports whether a container exists
;; without also creating or starting it, and the `stop`/`down` subcommands
;; advertised in its README are not present in every release. Both gaps are filled
;; here using the `devcontainer.local_folder` label that the CLI stamps onto every
;; container it creates.
;;
;; Everything in this module is optional: when Docker is unavailable the caller
;; degrades to reporting "unknown" rather than failing.

(require "proc.scm")
(require-builtin steel/filesystem)

(provide docker-available?
         container-for-workspace
         container-state
         stop-container)

(define docker-name "docker")

(define (docker-available?)
  (binary-available? docker-name))

(define (label-filter workspace)
  (string-append "label=devcontainer.local_folder=" workspace))

(define (first-line text)
  (let ([lines (filter (lambda (line) (not (equal? (trim line) ""))) (split-many text "\n"))])
    (if (empty? lines) #f (trim (car lines)))))

;;@doc
;; The id of the container the dev container CLI created for `workspace`, or
;; #false if there is none (or Docker is unavailable).
;;
;; The CLI records the absolute host path in the label, so the lookup path must be
;; canonicalised to match.
(define (container-for-workspace workspace)
  (if (not (docker-available?))
      #f
      (let* ([root (with-handler (lambda (err) workspace) (canonicalize-path workspace))]
             [result (run/capture docker-name
                                  (list "ps" "--all" "--quiet" "--filter" (label-filter root))
                                  #f)])
        (if (proc-success? result) (first-line (proc-stdout result)) #f))))

;;@doc
;; The Docker state of a container: "running", "exited", "created", and so on, or
;; #false if it cannot be determined.
(define (container-state id)
  (if (or (not id) (not (docker-available?)))
      #f
      (let ([result (run/capture docker-name (list "inspect" "--format" "{{.State.Status}}" id) #f)])
        (if (proc-success? result) (first-line (proc-stdout result)) #f))))

;;@doc
;; Stop a running container. Returns a (ok? . message) pair.
(define (stop-container id)
  (cond
    [(not (docker-available?)) (cons #f "Docker CLI not found on PATH")]
    [(not id) (cons #f "No container is associated with this workspace")]
    [else
     (let ([result (run/capture docker-name (list "stop" id) #f)])
       (if (proc-success? result) (cons #t "") (cons #f (trim (proc-stderr result)))))]))
