;; Run with a PATH that does not contain the dev container CLI.
(require "steel/tests/unit-test.scm")
(require "../cogs/cli.scm")

(check-equal? "a missing CLI is detected" (cli-available?) #f)

(define result (up "tests/fixtures/dot-devcontainer-dir" #f #f #f))

(check-equal? "operations fail cleanly when the CLI is missing" (outcome-ok? result) #f)

(check-equal? "the message names the missing binary"
              (string-contains? (outcome-message result) "devcontainer")
              #t)

(check-equal? "the detail tells the user how to install it"
              (string-contains? (outcome-detail result) "npm install -g @devcontainers/cli")
              #t)

(check-equal? "reading configuration also fails cleanly"
              (outcome-ok? (read-configuration "tests/fixtures/dot-devcontainer-dir" #f))
              #f)

(check-equal? "exec also fails cleanly"
              (outcome-ok? (exec "tests/fixtures/dot-devcontainer-dir" #f (list "uname")))
              #f)
