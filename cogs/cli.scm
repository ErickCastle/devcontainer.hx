;; Adapter over the official Dev Container CLI (https://github.com/devcontainers/cli).
;;
;; This module owns every piece of knowledge about the CLI's flags and output
;; format. Nothing else in the plugin should know that `devcontainer` is the
;; backend.
;;
;; The CLI writes human-readable progress logging to stderr and a single-line
;; machine-readable JSON result to stdout, so stdout can be parsed directly.

(require "proc.scm")
(require-builtin steel/json)
(require "steel/result")

(provide cli-name
         cli-available?
         cli-install-hint
         devcontainer-read-configuration
         devcontainer-up
         devcontainer-exec
         outcome-ok?
         outcome-data
         outcome-message
         outcome-detail
         outcome-logs
         json-ref)

(define cli-name "devcontainer")

(define cli-install-hint
  "Install it with `npm install -g @devcontainers/cli`, or see https://github.com/devcontainers/cli")

;;@doc
;; Whether the dev container CLI is on PATH.
(define (cli-available?)
  (binary-available? cli-name))

;;;; ---------------------------------------------------------------------------
;;;; Outcomes
;;;;
;;;; Every operation returns a hash with:
;;;;   'ok?     -- boolean
;;;;   'data    -- parsed JSON result, or #false
;;;;   'message -- short single-line summary, suitable for the statusline
;;;;   'detail  -- longer explanation / recovery hint, may be ""
;;;;   'logs    -- captured stdout+stderr, for the output buffer
;;;; ---------------------------------------------------------------------------

(define (ok-outcome data logs)
  (hash 'ok? #t 'data data 'message "" 'detail "" 'logs logs))

(define (err-outcome message detail logs)
  (hash 'ok? #f 'data #f 'message message 'detail detail 'logs logs))

(define (outcome-ok? o)
  (hash-ref o 'ok?))
(define (outcome-data o)
  (hash-ref o 'data))
(define (outcome-message o)
  (hash-ref o 'message))
(define (outcome-detail o)
  (hash-ref o 'detail))
(define (outcome-logs o)
  (hash-ref o 'logs))

;;;; ---------------------------------------------------------------------------
;;;; JSON helpers
;;;; ---------------------------------------------------------------------------

;;@doc
;; Look up `key` in a decoded JSON object, returning `default` when the object is
;; not a hash or the key is absent.
(define (json-ref obj key default)
  (if (and (hash? obj) (hash-contains? obj key)) (hash-ref obj key) default))

(define (blank? line)
  (equal? (trim line) ""))

;; The result envelope is the last non-blank line of stdout that looks like a JSON
;; object. For `up` and `read-configuration` stdout contains nothing else, but
;; being lenient here keeps us working if the CLI ever interleaves output.
(define (last-json-line text)
  (let loop ([lines (reverse (split-many text "\n"))])
    (cond
      [(empty? lines) #f]
      [(blank? (car lines)) (loop (cdr lines))]
      [(starts-with? (trim (car lines)) "{") (trim (car lines))]
      [else (loop (cdr lines))])))

(define (parse-json text)
  (with-handler (lambda (err) #f) (string->jsexpr text)))

;;;; ---------------------------------------------------------------------------
;;;; Running the CLI
;;;; ---------------------------------------------------------------------------

;; Combined transcript shown to the user; stderr carries the CLI's progress log.
(define (transcript result)
  (string-append (proc-stderr result)
                 (if (equal? (proc-stdout result) "") "" (string-append "\n" (proc-stdout result)))))

(define (run-cli args cwd)
  (if (not (cli-available?))
      (err-outcome (string-append "Dev Container CLI (`" cli-name "`) not found on PATH")
                   cli-install-hint
                   "")
      (let ([result (run/capture cli-name args cwd)])
        (if (proc-spawn-failed? result)
            (err-outcome (string-append "Could not run `" cli-name "`")
                         (proc-stderr result)
                         (proc-stderr result))
            result))))

;; Interpret a completed CLI run that is expected to emit a JSON envelope.
(define (interpret-json-result result operation)
  (if (hash-contains? result 'ok?)
      result ;; already an outcome from run-cli
      (let* ([logs (transcript result)]
             [json (let ([line (last-json-line (proc-stdout result))])
                     (if line (parse-json line) #f))]
             [outcome (json-ref json 'outcome #f)])
        (cond
          ;; The CLI reported a structured failure.
          [(equal? outcome "error")
           (err-outcome (json-ref json 'description (string-append operation " failed"))
                        (json-ref json 'message "")
                        logs)]
          ;; Exited non-zero without a usable envelope: surface stderr.
          [(not (proc-success? result))
           (err-outcome (string-append operation
                                       " failed (exit "
                                       (to-string (proc-code result))
                                       ")")
                        (tail-lines (proc-stderr result) 20)
                        logs)]
          [(not json)
           (err-outcome (string-append operation " returned no parseable JSON result")
                        (tail-lines (proc-stderr result) 20)
                        logs)]
          [else (ok-outcome json logs)]))))

(define (tail-lines text n)
  (let ([lines (filter (lambda (l) (not (blank? l))) (split-many text "\n"))])
    (string-join (if (> (length lines) n) (list-tail lines (- (length lines) n)) lines) "\n")))

;;;; ---------------------------------------------------------------------------
;;;; Commands
;;;; ---------------------------------------------------------------------------

(define (workspace-args workspace config)
  (append (list "--workspace-folder" workspace) (if config (list "--config" config) '())))

;;@doc
;; Read the resolved configuration for a workspace without starting a container.
;;
;; * workspace : string?          -- absolute path to the project folder
;; * config    : (or string? #f)  -- explicit devcontainer.json path
;;
;; The result carries `configuration` and `workspace` (whose `workspaceFolder` is
;; the path the project is mounted at *inside* the container).
(define (devcontainer-read-configuration workspace config)
  (interpret-json-result (run-cli (append (list "read-configuration")
                                          (workspace-args workspace config)
                                          (list "--include-merged-configuration"))
                                  workspace)
                         "Reading dev container configuration"))

;;@doc
;; Create and start the dev container, building the image if necessary.
;;
;; * remove-existing? : boolean? -- discard and recreate an existing container
;; * no-cache?        : boolean? -- rebuild the image ignoring the layer cache
;;
;; On success the result carries `containerId`, `remoteUser` and
;; `remoteWorkspaceFolder`.
(define (devcontainer-up workspace config remove-existing? no-cache?)
  (interpret-json-result (run-cli (append (list "up")
                                          (workspace-args workspace config)
                                          (if remove-existing? (list "--remove-existing-container") '())
                                          (if no-cache? (list "--build-no-cache") '()))
                                  workspace)
                         "Starting dev container"))

;;@doc
;; Run a command inside the running dev container.
;;
;; * argv : (listof string?) -- program and arguments, passed through as argv
;;
;; Unlike the other commands this forwards the child's own stdout rather than a
;; JSON envelope, so the raw output and exit code are returned instead.
(define (devcontainer-exec workspace config argv)
  (let ([result (run-cli (append (list "exec") (workspace-args workspace config) argv) workspace)])
    (if (hash-contains? result 'ok?)
        result
        (if (proc-success? result)
            (ok-outcome (hash 'stdout (proc-stdout result)) (transcript result))
            (err-outcome (string-append "Command failed inside container (exit "
                                        (to-string (proc-code result))
                                        ")")
                         (tail-lines (proc-stderr result) 20)
                         (transcript result))))))
