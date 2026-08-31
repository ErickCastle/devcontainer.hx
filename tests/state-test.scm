(require "steel/tests/unit-test.scm")
(require "../cogs/state.scm")

(define a "/home/user/project-a")
(define b "/home/user/project-b")

(check-equal? "nothing is known about an unseen workspace" (container-id a) #f)
(check-equal? "an unseen workspace is not busy" (busy? a) #f)
(check-equal? "an unseen workspace has no logs" (last-logs a) "")

(record-up! a "abc123" "vscode" "/workspaces/project-a")

(check-equal? "the container id is remembered" (container-id a) "abc123")
(check-equal? "the remote user is remembered" (remote-user a) "vscode")
(check-equal? "the container-side path is remembered" (remote-workspace a) "/workspaces/project-a")

(check-equal? "workspaces are tracked independently" (container-id b) #f)

(record-up! b "def456" "root" "/workspaces/project-b")
(check-equal? "a second workspace is tracked separately" (container-id b) "def456")
(check-equal? "the first workspace is unaffected" (container-id a) "abc123")

(forget! a)
(check-equal? "forgetting clears the container id" (container-id a) #f)
(check-equal? "forgetting leaves other workspaces alone" (container-id b) "def456")

;;;; Only one operation may run per workspace at a time.

(check-equal? "an operation can be claimed" (begin-operation! a "up") #t)
(check-equal? "the running operation is reported" (current-operation a) "up")
(check-equal? "the workspace is busy" (busy? a) #t)
(check-equal? "a second operation is refused" (begin-operation! a "rebuild") #f)
(check-equal? "another workspace can still be claimed" (begin-operation! b "up") #t)

(end-operation! a)
(check-equal? "releasing clears the operation" (busy? a) #f)
(check-equal? "the operation can be claimed again" (begin-operation! a "exec") #t)
(check-equal? "the other workspace is still busy" (busy? b) #t)

(end-operation! a)
(end-operation! b)

(set-last-logs! a "build output")
(check-equal? "logs are recorded" (last-logs a) "build output")
(check-equal? "logs are per workspace" (last-logs b) "")
