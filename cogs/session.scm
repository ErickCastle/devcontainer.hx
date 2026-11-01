;; The editor-lifetime helper.
;;
;; Helix has no exit hook, so the plugin starts one small helper process per
;; workspace and keeps a pipe to its stdin. When Helix exits, for any reason
;; including a crash, the pipe closes and the helper sees end-of-file. That is the
;; signal to clean up: stop the SSH agent relay and, if armed, stop the container
;; the way VS Code does when its window closes.
;;
;; The helper is a fixed shell script; every variable part reaches it as a
;; positional argument, never as script text. Messages on its stdin are:
;;
;;   arm <id> [<id>...]   stop these containers when the editor exits
;;   disarm               do not stop anything
;;
;; Several editors may use the same container. Each armed helper leaves a lock
;; file named after its own PID under `<locks>/<first id>/`, and the last one to
;; exit is the one that stops the container.

(require "proc.scm")
(require-builtin steel/filesystem)

(provide helper-script
         shutdown-action
         valid-container-id?
         arm-line
         start-helper
         helper-arm!
         helper-disarm!
         helper-close!)

(define helper-script
  "set -f
trap '' HUP INT
exec >/dev/null 2>&1
docker=$1 locks=$2 sock=$3 agent=$4 socat=$5
relay=
if [ -n \"$sock\" ]; then
	mkdir -p \"${sock%/*}\" && chmod 700 \"${sock%/*}\"
	\"$socat\" \"UNIX-LISTEN:$sock,fork,unlink-early,mode=600\" \"UNIX-CONNECT:$agent\" </dev/null &
	relay=$!
fi
lock= targets=
release() {
	if [ -n \"$lock\" ]; then
		rm -f \"$lock\"
		rmdir \"${lock%/*}\" 2>/dev/null
	fi
	lock= targets=
}
while IFS= read -r line; do
	set -- $line
	case ${1-} in
	arm)
		shift
		release
		for id in \"$@\"; do
			case $id in '' | *[!0-9a-f]*) continue ;; esac
			targets=\"$targets $id\"
		done
		if [ -n \"$targets\" ]; then
			set -- $targets
			if mkdir -p \"$locks/$1\" && : >\"$locks/$1/$$\"; then
				lock=\"$locks/$1/$$\"
			fi
		fi
		;;
	disarm) release ;;
	esac
done
if [ -n \"$relay\" ]; then
	kill \"$relay\"
	rm -f \"$sock\"
fi
if [ -z \"$targets\" ] || [ -z \"$docker\" ]; then exit 0; fi
# Without a lock file other editors cannot be seen, so this one counts as the last.
if [ -n \"$lock\" ]; then
	dir=${lock%/*}
	rm -f \"$lock\"
	set +f
	for peer in \"$dir\"/*; do
		[ -e \"$peer\" ] || continue
		if kill -0 \"${peer##*/}\" 2>/dev/null; then exit 0; fi
		rm -f \"$peer\"
	done
	rmdir \"$dir\" 2>/dev/null
fi
\"$docker\" stop $targets
")

;;@doc
;; What to do with the container when the editor exits, following the
;; `shutdownAction` property: "none", "stopContainer" or "stopCompose".
;;
;; * configuration : hash? -- the `configuration` object reported by `up`
;;
;; As in VS Code, the default is "stopCompose" for Docker Compose configurations
;; and "stopContainer" for everything else.
(define (shutdown-action configuration)
  (let ([explicit (if (and (hash? configuration) (hash-contains? configuration 'shutdownAction))
                      (hash-ref configuration 'shutdownAction)
                      #f)])
    (cond
      [(member explicit (list "none" "stopContainer" "stopCompose")) explicit]
      [(and (hash? configuration) (hash-contains? configuration 'dockerComposeFile)) "stopCompose"]
      [else "stopContainer"])))

(define (hex-char? c)
  (or (and (char>=? c #\0) (char<=? c #\9)) (and (char>=? c #\a) (char<=? c #\f))))

;;@doc
;; Whether `id` looks like a Docker container id. Only such ids are ever sent to
;; the helper.
(define (valid-container-id? id)
  (and (string? id)
       (> (string-length id) 0)
       (let loop ([chars (string->list id)])
         (cond
           [(empty? chars) #t]
           [(hex-char? (car chars)) (loop (cdr chars))]
           [else #f]))))

;;@doc
;; The `arm` message for the given container ids, or #false if none is valid.
(define (arm-line ids)
  (let ([valid (filter valid-container-id? ids)])
    (if (empty? valid) #f (string-append "arm " (string-join valid " ")))))

;;@doc
;; Start a helper. Returns its handle, or #false if it could not start.
;;
;; * docker : (or string? #f) -- absolute path to the Docker CLI
;; * locks  : string?         -- directory for the shared lock files
;; * relay  : (or hash? #f)   -- SSH relay with 'socket, 'agent and 'socat, or #f
(define (start-helper docker locks relay)
  (spawn/background "sh"
                    (list "-c"
                          helper-script
                          "devcontainer.hx-helper"
                          (or docker "")
                          locks
                          (if relay (hash-ref relay 'socket) "")
                          (if relay (hash-ref relay 'agent) "")
                          (if relay (hash-ref relay 'socat) ""))))

;;@doc
;; Ask the helper to stop `ids` when the editor exits, replacing any earlier
;; request. Returns #false if there was nothing valid to arm.
(define (helper-arm! helper ids)
  (let ([line (arm-line ids)])
    (if (and helper line) (background-send! helper line) #f)))

;;@doc
;; Ask the helper not to stop anything when the editor exits.
(define (helper-disarm! helper)
  (if helper (background-send! helper "disarm") #f))

;;@doc
;; Close the helper's stdin, exactly as happens when the editor exits.
(define (helper-close! helper)
  (if helper (background-close! helper) #f))
