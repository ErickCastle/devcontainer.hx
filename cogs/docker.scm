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
         docker-path
         container-for-workspace
         container-state
         compose-containers
         container-has-mount?
         stop-container)

(define docker-name "docker")

(define (docker-available?)
  (binary-available? docker-name))

;;@doc
;; Absolute path to the Docker CLI, or #false.
(define (docker-path)
  (binary-path docker-name))

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

(define (non-blank-lines text)
  (map trim (filter (lambda (line) (not (equal? (trim line) ""))) (split-many text "\n"))))

(define (inspect id template)
  (let ([result (run/capture docker-name (list "inspect" "--format" template id) #f)])
    (if (proc-success? result) (proc-stdout result) #f)))

;;@doc
;; Every container in the Docker Compose project that `id` belongs to, or just
;; `(list id)` when it is not part of one. This is what `stopCompose` stops.
(define (compose-containers id)
  (let* ([project (if (docker-available?)
                      (first-line (or (inspect id "{{index .Config.Labels \"com.docker.compose.project\"}}") ""))
                      #f)])
    (if (or (not project) (equal? project "<no value>"))
        (list id)
        (let ([result (run/capture docker-name
                                   (list "ps" "--quiet" "--filter" (string-append "label=com.docker.compose.project=" project))
                                   #f)])
          (if (proc-success? result)
              (let ([ids (non-blank-lines (proc-stdout result))]) (if (empty? ids) (list id) ids))
              (list id))))))

;;@doc
;; Whether the container has `source` mounted at `target`. Mounts are fixed when a
;; container is created, so this tells whether it needs recreating.
(define (container-has-mount? id source target)
  (let ([text (if (and id (docker-available?))
                  (inspect id "{{range .Mounts}}{{println .Source .Destination}}{{end}}")
                  #f)])
    (if text (if (member (string-append source " " target) (non-blank-lines text)) #t #f) #f)))

;;@doc
;; Stop a running container. Returns a (ok? . message) pair.
(define (stop-container id)
  (cond
    [(not (docker-available?)) (cons #f "Docker CLI not found on PATH")]
    [(not id) (cons #f "No container is associated with this workspace")]
    [else
     (let ([result (run/capture docker-name (list "stop" id) #f)])
       (if (proc-success? result) (cons #t "") (cons #f (trim (proc-stderr result)))))]))
