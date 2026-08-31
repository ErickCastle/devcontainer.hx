;; Dev container configuration discovery.
;;
;; The dev container CLI performs its own lookup, so this is not used to tell the
;; CLI where the configuration is. It exists so the plugin can report something
;; useful when the CLI is missing or fails, and so `:devcontainer-config` can open
;; the right file.
;;
;; Search order matches the CLI's: `.devcontainer/devcontainer.json`, then
;; `.devcontainer.json`, then `.devcontainer/<folder>/devcontainer.json`.

(require-builtin steel/filesystem)

(provide find-config-path
         config-candidates
         has-config?)

(define (path-join base leaf)
  (string-append base "/" leaf))

(define (existing-file path)
  (if (and (path-exists? path) (is-file? path)) path #f))

;; Single-level scan of .devcontainer/*/devcontainer.json, as used by projects that
;; keep several configurations side by side.
(define (nested-config-paths workspace)
  (let ([dir (path-join workspace ".devcontainer")])
    (if (and (path-exists? dir) (is-dir? dir))
        (filter (lambda (path) (existing-file path))
                (map (lambda (entry) (path-join entry "devcontainer.json"))
                     (filter is-dir? (with-handler (lambda (err) '()) (read-dir dir)))))
        '())))

;;@doc
;; All dev container configuration files discoverable in `workspace`, in the order
;; the CLI would consider them.
(define (config-candidates workspace)
  (filter (lambda (path) path)
          (append (list (existing-file (path-join workspace ".devcontainer/devcontainer.json"))
                        (existing-file (path-join workspace ".devcontainer.json")))
                  (nested-config-paths workspace))))

;;@doc
;; The configuration file the CLI would use for `workspace`, or #false.
(define (find-config-path workspace)
  (let ([found (config-candidates workspace)])
    (if (empty? found) #f (car found))))

;;@doc
;; Whether `workspace` contains any dev container configuration.
(define (has-config? workspace)
  (if (find-config-path workspace) #t #f))
