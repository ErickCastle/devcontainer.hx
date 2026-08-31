(require "steel/tests/unit-test.scm")
(require "../cogs/config.scm")

(define (fixture name)
  (string-append "tests/fixtures/" name))

(check-equal? "finds .devcontainer/devcontainer.json"
              (find-config-path (fixture "dot-devcontainer-dir"))
              "tests/fixtures/dot-devcontainer-dir/.devcontainer/devcontainer.json")

(check-equal? "finds .devcontainer.json"
              (find-config-path (fixture "dot-devcontainer-file"))
              "tests/fixtures/dot-devcontainer-file/.devcontainer.json")

(check-equal? "finds .devcontainer/<folder>/devcontainer.json"
              (find-config-path (fixture "nested"))
              "tests/fixtures/nested/.devcontainer/rust/devcontainer.json")

(check-equal? "reports no configuration" (find-config-path (fixture "no-config")) #f)

(check-equal? "has-config? is false without configuration" (has-config? (fixture "no-config")) #f)

(check-equal? "has-config? is true with configuration"
              (has-config? (fixture "dot-devcontainer-dir"))
              #t)

(check-equal? "a malformed config file is still discovered"
              (has-config? (fixture "invalid"))
              #t)

(check-equal? "missing workspace directory is handled"
              (find-config-path (fixture "does-not-exist"))
              #f)

(check-equal? "nested configurations are only found under .devcontainer"
              (length (config-candidates (fixture "nested")))
              1)
