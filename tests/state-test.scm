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

(check-equal? "the status of an unseen workspace is unknown" (cached-status a) 'unknown)
(set-cached-status! a 'running)
(check-equal? "the status is cached" (cached-status a) 'running)
(check-equal? "the status is per workspace" (cached-status b) 'unknown)

(check-equal? "there is no progress at first" (progress a) "")
(set-progress! a "Step 2/5")
(check-equal? "progress is recorded" (progress a) "Step 2/5")

(check-equal? "nothing has failed at first" (last-failed? a) #f)
(set-last-failed! a #t)
(check-equal? "a failure is recorded" (last-failed? a) #t)

(check-equal? "there is no helper at first" (helper a) #f)
(check-equal? "the relay is inactive at first" (relay-active? a) #f)
(set-relay! a (hash 'socket "/s"))
(set-relay-active! a #t)
(check-equal? "the relay plan is recorded" (hash-ref (relay a) 'socket) "/s")
(check-equal? "the relay can be marked active" (relay-active? a) #t)

(forget! a)
(check-equal? "forgetting the container keeps the relay, which outlives it" (relay-active? a) #t)
