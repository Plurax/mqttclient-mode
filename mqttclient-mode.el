;;; mqttclient-mode.el --- An interactive MQTT client for Emacs
;;
;; Public domain.

;; Author: Christoph Uhlich <christoph@familie-uhlich.de>
;; Created: 17 Nov 2019
;; Keywords: mqtt
;; Package-Version: 0.1

;; This file is not part of GNU Emacs.
;; This file is public domain software. Do what you want.

;;; Commentary:
;;
;; This is a tool to manually explore and test MQTT services.
;; Runs queries from a plain-text query sheet.
;; It is inspired by the two projects restclient from Pavel Kurnosov, and
;; mqtt-client from Andreas Müller.

;;; Code:
;;
(require 'outline)
(require 'subr-x)
(require 'dash)


(defgroup mqtt nil
  "MQTT support."
  :group 'tools)

(defconst mqtt-pub-bin "mosquitto_pub")
(defconst mqtt-sub-bin "mosquitto_sub")

(defcustom mqtt-host "localhost"
  "MQTT server host name."
  :group 'mqtt
  :type 'string)

(defcustom mqtt-port 8883
  "Port number of MQTT server."
  :group 'mqtt
  :type 'integer)

(defcustom mqtt-username nil
  "User name for MQTT server."
  :group 'mqtt
  :type '(choice string (const nil)))

(defcustom mqtt-password nil
  "Password for MQTT server."
  :group 'mqtt
  :type '(choice string (const nil)))


(defcustom mqtt-subscribe-qos-level 0
  "Topic to publish to."
  :group 'mqtt
  :type 'integer)

(defcustom mqtt-subscribe-topic "#"
  "Topic to subscribe."
  :group 'mqtt
  :type 'string)

(defcustom mqtt-publish-topic "/test"
  "Topic to subscribe."
  :group 'mqtt
  :type 'string)

(defcustom mqtt-publish-qos-level 0
  "Topic to publish to."
  :group 'mqtt
  :type 'integer)

(defcustom mqtt-timestamp-format "[%y-%m-%d %H:%M:%S]\n"
  "Format for timestamps for incoming messages.

Used as input for 'format-time-string'."
  :group 'mqtt
  :type 'string)

(defcustom mqtt-message-receive-functions '()
  "List of functions to run when a new message is received.

The message is passed as first argument (message is passed as
argument).

Note: if both the mqtt-client and mqtt-consumer is active, each
function will be run twice (which may be desirable if client and
consumer are active for different topics, or undesirable).

Example: `(add-to-list 'mqtt-message-receive-functions (lambda (msg) (alert msg)))`"
  :group 'mqtt
  :type '(repeat function))

(defcustom mqttclient-log-request t
  "Log mqtt publish to *Messages*."
  :group 'mqttclient
  :type 'boolean)


(defgroup mqttclient-faces nil
  "Faces used in Mqttclient Mode"
  :group 'mqttclient
  :group 'faces)

(defface mqttclient-variable-name-face
  '((t (:inherit font-lock-preprocessor-face)))
  "Face for variable name."
  :group 'mqttclient-faces)

(defface mqttclient-variable-string-face
  '((t (:inherit font-lock-string-face)))
  "Face for variable value (string)."
  :group 'mqttclient-faces)

(defface mqttclient-variable-elisp-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs lisp)."
  :group 'mqttclient-faces)

(defface mqttclient-variable-multiline-face
  '((t (:inherit font-lock-doc-face)))
  "Face for multi-line variable value marker."
  :group 'mqttclient-faces)

(defface mqttclient-variable-usage-face
  '((t (:inherit mqttclient-variable-name-face)))
  "Face for variable usage (only used when headers/body is represented as a single variable, not highlighted when variable appears in the middle of other text)."
  :group 'mqttclient-faces)

(defface mqttclient-method-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for HTTP method."
  :group 'mqttclient-faces)

(defface mqttclient-topic-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs lisp)."
  :group 'mqttclient-faces)

(defface mqttclient-header-name-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for HTTP header name."
  :group 'mqttclient-faces)

(defface mqttclient-header-value-face
  '((t (:inherit font-lock-string-face)))
  "Face for HTTP header value."
  :group 'mqttclient-faces)


(defvar mqttclient-response-received-hook nil
  "Hook run after data is loaded into response buffer.")

(defcustom mqttclient-vars-max-passes 10
  "Maximum number of recursive variable references. This is to prevent hanging if two variables reference each other directly or indirectly."
  :group 'mqttclient
  :type 'integer)

(defconst mqttclient-comment-separator "#")
(defconst mqttclient-comment-start-regexp (concat "^" mqttclient-comment-separator))
(defconst mqttclient-comment-not-regexp (concat "^[^" mqttclient-comment-separator "]"))
(defconst mqttclient-empty-line-regexp "^\\s-*$")

(defconst mqttclient-method-topic-regexp
  "^\\(SUB\\|PUB\\) \\(.*\\)$")

(defconst mqttclient-subscribe-topic-regex
  "^\\([^ ]*\\) \\(.*\\)$")

(defconst mqttclient-header-regexp
  "^\\([^](),/:;@[\\{}= \t]+\\): \\(.*\\)$")

(defconst mqttclient-use-var-regexp
  "^\\(:[^: \n]+\\)$")

(defconst mqttclient-var-regexp
  (concat "^\\(:[^:= ]+\\)[ \t]*\\(:?\\)=[ \t]*\\(<<[ \t]*\n\\(\\(.*\n\\)*?\\)" mqttclient-comment-separator "\\|\\([^<].*\\)$\\)"))

(defconst mqttclient-svar-regexp
  "^\\(:[^:= ]+\\)[ \t]*=[ \t]*\\(.+?\\)$")

(defconst mqttclient-evar-regexp
  "^\\(:[^: ]+\\)[ \t]*:=[ \t]*\\(.+?\\)$")

(defconst mqttclient-mvar-regexp
  "^\\(:[^: ]+\\)[ \t]*:?=[ \t]*\\(<<\\)[ \t]*$")

(defconst mqttclient-file-regexp
  "^<[ \t]*\\([^<>\n\r]+\\)[ \t]*$")

(defconst mqttclient-content-type-regexp
  "^Content-[Tt]ype: \\(\\w+\\)/\\(?:[^\\+\r\n]*\\+\\)*\\([^;\r\n]+\\)")


(defun mqttclient-current-min ()
  (save-excursion
    (beginning-of-line)
    (if (looking-at mqttclient-comment-start-regexp)
        (if (re-search-forward mqttclient-comment-not-regexp (point-max) t)
            (point-at-bol) (point-max))
      (if (re-search-backward mqttclient-comment-start-regexp (point-min) t)
          (point-at-bol 2)
        (point-min)))))

(defun mqttclient-current-max ()
  (save-excursion
    (if (re-search-forward mqttclient-comment-start-regexp (point-max) t)
        (max (- (point-at-bol) 1) 1)
      (progn (goto-char (point-max))
             (if (looking-at "^$") (- (point) 1) (point))))))

(defun mqttclient-replace-all-in-string (replacements string)
  (if replacements
      (let ((current string)
            (pass mqttclient-vars-max-passes)
            (continue t))
        (while (and continue (> pass 0))
          (setq pass (- pass 1))
          (setq current (replace-regexp-in-string (regexp-opt (mapcar 'car replacements))
                                                  (lambda (key)
                                                    (setq continue t)
                                                    (cdr (assoc key replacements)))
                                                  current t t)))
        current)
    string))

(defun mqttclient-chop (text)
  (if text (replace-regexp-in-string "\n$" "" text) nil))

(defun mqttclient-find-vars-before-point ()
  (let ((vars nil)
        (bound (point)))
    (save-excursion
      (goto-char (point-min))
      (while (search-forward-regexp mqttclient-var-regexp bound t)
        (let ((name (match-string-no-properties 1))
              (should-eval (> (length (match-string 2)) 0))
              (value (or (mqttclient-chop (match-string-no-properties 4)) (match-string-no-properties 3))))
          (setq vars (cons (cons name (if should-eval (mqttclient-eval-var value) value)) vars))))
      vars)))

(defun mqttclient-eval-var (string)
  (with-output-to-string (princ (eval (read string)))))

(defun mqttclient-parse-body (entity vars)
  (if (= 0 (or (string-match mqttclient-file-regexp entity) 1))
      (mqttclient-read-file (match-string 1 entity))
    (mqttclient-replace-all-in-string vars entity)))

(defun mqttclient-parse-current (execute)
  (save-excursion
    (goto-char (mqttclient-current-min))
    (when (re-search-forward mqttclient-method-topic-regexp (point-max) t)
      (let ((method (match-string-no-properties 1))
            (topic (match-string-no-properties 2))
            (vars (mqttclient-find-vars-before-point))
            (mqtt-client-id (cdr (assoc ":mqtt-client-id" (mqttclient-find-vars-before-point))))
            (mqtt-host (cdr (assoc ":mqtt-host" (mqttclient-find-vars-before-point))))
            (mqtt-tls-version (cdr (assoc ":mqtt-tls-version" (mqttclient-find-vars-before-point))))
            (mqtt-username (cdr (assoc ":mqtt-username" (mqttclient-find-vars-before-point))))
            (mqtt-port (string-to-number (cdr (assoc ":mqtt-port" (mqttclient-find-vars-before-point)))))
            (mqtt-password (cdr (assoc ":mqtt-password" (mqttclient-find-vars-before-point))))
            (mqtt-ca-path (cdr (assoc ":mqtt-ca-path" (mqttclient-find-vars-before-point)))))
        (forward-line)
        (when (looking-at mqttclient-empty-line-regexp)
          (forward-line))
        (if (equal method "PUB") 
            (let* ((cmax (mqttclient-current-max))
                   (entity (mqttclient-parse-body (buffer-substring (min (point) cmax) cmax) vars))
                   (topic (mqttclient-replace-all-in-string vars topic)))
              (mqtt-publish-message mqtt-host mqtt-username mqtt-password entity topic execute mqtt-client-id mqtt-tls-version mqtt-ca-path mqtt-port))
          (mqtt-start-consumer mqtt-host mqtt-username mqtt-password (mqttclient-replace-all-in-string vars topic) execute mqtt-tls-version mqtt-ca-path mqtt-port))))))

(defun mqtt-start-consumer (mqtt-host mqtt-username mqtt-password topic execute &optional t-version ca-path mqtt-port)
  "Start MQTT consumer.

The consumer subscribes to the topic set from the buffer and shows incoming
messages."
  (interactive)
  (let ((command (-flatten `(,mqtt-sub-bin
                             "-v",
                              "-h" ,mqtt-host
                              ,(if (and mqtt-username mqtt-password)
                                   `("-u" ,mqtt-username
                                     "-P" ,mqtt-password))
                              "-p" ,(int-to-string mqtt-port)
                              "-t" ,topic
                              ,(if (not (not t-version))
                                   `("--tls-version" ,t-version))
                              "-q" ,(int-to-string mqtt-publish-qos-level)
                              ,(if (not (not ca-path))
                                   `("--capath" ,ca-path)))))
                 (name (concat "mqtt:" mqtt-host))
                 (buffer (concat "*mqtt:" mqtt-host "*")))
    (when (get-process name) (delete-process (get-process name))
          (let ((thisbuffer (buffer-name)))
            (switch-to-buffer buffer)
            (erase-buffer)
            (switch-to-buffer thisbuffer)))
    (if execute
        (let ((process
               (make-process
                :name name
                :buffer buffer
                :command command
                :filter 'mqtt-consumer-filter
                :sentinel 'mqttclient-pub-sub-sentinel)))
          (set-process-query-on-exit-flag process nil)
          (with-current-buffer (process-buffer process)
            (display-buffer (current-buffer))
            (setq-local header-line-format (format "server: %s:%d subscribe topic: '%s'" mqtt-host mqtt-port topic))))
      (kill-new (mapconcat 'identity command " ")))))

(defun mqtt-consumer-filter (proc string)
  "Input filter for mqtt-consumer (filters STRING messages from PROC)."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((moving (= (point) (process-mark proc)))
            (inhibit-read-only t))
        (save-excursion
          ;; Insert the text, advancing the process marker.
          (goto-char (process-mark proc))
          
          (let ((regx mqttclient-subscribe-topic-regex))
            (string-match regx string)
            (insert (concat (propertize (format-time-string mqtt-timestamp-format) 'face 'font-lock-comment-face)
                            (propertize (match-string 1 string) 'face 'mqttclient-method-face)
                            " "
                            (match-string 2 string)
                            "\n")))
          (set-marker (process-mark proc) (point)))
        (when moving
          (goto-char (process-mark proc))
          (when (get-buffer-window)
            (set-window-point (get-buffer-window) (process-mark proc))))))
    (run-hook-with-args 'mqtt-message-receive-functions string)))

(defun string-trim-final-newline (string)
  (let ((len (length string)))
    (cond
      ((and (> len 0) (eql (aref string (- len 1)) ?\n))
       (substring string 0 (- len 1)))
      (t string))))

(defun mqttclient-pub-sub-sentinel (process event)
             (print
               (format "Process: %s '%s', returning '%i'" (process-name process) (string-trim-final-newline event) (process-exit-status process))))

(defun mqtt-publish-message (mqtt-host mqtt-username mqtt-password message topic execute &optional c-id t-version ca-path mqtt-port)
  "Publish given MESSAGE to given TOPIC."
  (let* ((command (-flatten `(,mqtt-pub-bin
                              "-h" ,mqtt-host
                              ,(if (and mqtt-username mqtt-password)
                                   `("-u" ,mqtt-username
                                     "-P" ,mqtt-password))
                              "-p" ,(int-to-string mqtt-port)
                              ,(if (not (not c-id))
                                   `("-i" ,c-id))
                              "-t" ,topic
                              ,(if (not (not t-version))
                                   `("--tls-version" ,t-version))
                              "-q" ,(int-to-string mqtt-publish-qos-level)
                              ,(if (not (not ca-path))
                                   `("--capath" ,ca-path))
                              "-m", (format "%s" message)))))
         (if execute
        (let* ((pub-proc (make-process
                          :name "mqtt-publisher"
                          :command command
                          :sentinel 'mqttclient-pub-sub-sentinel))))
      (kill-new (mapconcat 'identity command " ")))))

;;;###autoload
(defun mqttclient-copy-command ()
  "Formats the request as a mosquitto command and copies the command to the clipboard."
  (interactive)
  (mqttclient-parse-current nil)
  (message "Shell command copied to killring."))

;;;###autoload
(defun mqttclient-pub-current (&optional raw)
  "Publish current payload.
Optional argument STAY-IN-WINDOW do not move focus to response buffer if t."
  (interactive)
  (mqttclient-parse-current t))


(defun mqttclient-jump-next ()
  "Jump to next request in buffer."
  (interactive)
  (let ((last-min nil))
    (while (not (eq last-min (goto-char (mqttclient-current-min))))
      (goto-char (mqttclient-current-min))
      (setq last-min (point))))
  (goto-char (+ (mqttclient-current-max) 1))
  (goto-char (mqttclient-current-min)))

(defun mqttclient-jump-prev ()
  "Jump to previous request in buffer."
  (interactive)
  (let* ((current-min (mqttclient-current-min))
         (end-of-entity
          (save-excursion
            (progn (goto-char (mqttclient-current-min))
                   (while (and (or (looking-at "^\s*\\(#.*\\)?$")
                                   (eq (point) current-min))
                               (not (eq (point) (point-min))))
                     (forward-line -1)
                     (beginning-of-line))
                   (point)))))
    (unless (eq (point-min) end-of-entity)
      (goto-char end-of-entity)
      (goto-char (mqttclient-current-min)))))

(defun mqttclient-mark-current ()
  "Mark current request."
  (interactive)
  (goto-char (mqttclient-current-min))
  (set-mark-command nil)
  (goto-char (mqttclient-current-max))
  (backward-char 1)
  (setq deactivate-mark nil))

(defun mqttclient-narrow-to-current ()
  "Narrow to region of current request"
  (interactive)
  (narrow-to-region (mqttclient-current-min) (mqttclient-current-max)))

(defun mqttclient-toggle-body-visibility ()
  (interactive)
  ;; If we are not on the HTTP call line, don't do anything
  (let ((at-header (save-excursion
                     (beginning-of-line)
                     (looking-at mqttclient-method-topic-regexp))))
    (when at-header
      (save-excursion
        (end-of-line)
        ;; If the overlays at this point have 'invisible set, toggling
        ;; must make the region visible. Else it must hide the region
        
        ;; This part of code is from org-hide-block-toggle method of
        ;; Org mode
        (let ((overlays (overlays-at (point))))
          (if (memq t (mapcar
                       (lambda (o)
                         (eq (overlay-get o 'invisible) 'outline))
                       overlays))
              (outline-flag-region (point) (mqttclient-current-max) nil)
            (outline-flag-region (point) (mqttclient-current-max) t)))) t)))

(defun mqttclient-toggle-body-visibility-or-indent ()
  (interactive)
  (unless (mqttclient-toggle-body-visibility)
    (indent-for-tab-command)))

;;;###autoload
(defun mqttclient-insert-defaults ()
    "Inserts the default values into the current buffer."
    (interactive)
    (setq last-point (mark-marker))
    (beginning-of-buffer)
    (insert "# Initial setup\n\
:mqtt-host := \"\"\n\
:mqtt-ca-path := \"/etc/ssl/certs\"\n\
:mqtt-tls-version := \"tlsv1.2\"\n\
:mqtt-client-id := \"\"\n\
:mqtt-username := \"\"\n\
:mqtt-password := \"\"\n\
:mqtt-port := 8883\n\
#SUB #")
    (goto-char last-point))


(defconst mqttclient-mode-keywords
  (list (list mqttclient-method-topic-regexp '(1 'mqttclient-method-face) '(2 'mqttclient-topic-face))
        (list mqttclient-svar-regexp '(1 'mqttclient-variable-name-face) '(2 'mqttclient-variable-string-face))
        (list mqttclient-evar-regexp '(1 'mqttclient-variable-name-face) '(2 'mqttclient-variable-elisp-face t))
        (list mqttclient-mvar-regexp '(1 'mqttclient-variable-name-face) '(2 'mqttclient-variable-multiline-face t))
        (list mqttclient-use-var-regexp '(1 'mqttclient-variable-usage-face))
        (list mqttclient-file-regexp '(0 'mqttclient-file-upload-face))
        (list mqttclient-header-regexp '(1 'mqttclient-header-name-face t) '(2 'mqttclient-header-value-face t))
        ))

(defconst mqttclient-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\# "<" table)
    (modify-syntax-entry ?\n ">#" table)
    table))

(defvar mqttclient-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'mqttclient-pub-current)
    (define-key map (kbd "C-c C-n") 'mqttclient-jump-next)
    (define-key map (kbd "C-c C-p") 'mqttclient-jump-prev)
    (define-key map (kbd "C-c C-.") 'mqttclient-mark-current)
    (define-key map (kbd "C-c C-u") 'mqttclient-copy-command)
    (define-key map (kbd "C-c C-d") 'mqttclient-insert-defaults)
    map)
  "Keymap for mqttclient-mode.")



(define-minor-mode mqttclient-outline-mode
  "Minor mode to allow show/hide of request bodies by TAB."
      :init-value nil
      :lighter nil
      :keymap '(("\t" . mqttclient-toggle-body-visibility-or-indent)
                ("\C-c\C-a" . mqttclient-toggle-body-visibility-or-indent))
      :group 'mqttclient)

;;;###autoload
(define-derived-mode mqttclient-mode fundamental-mode "MQTT Client"
  "Turn on mqttclient mode."
  (set (make-local-variable 'comment-start) "# ")
  (set (make-local-variable 'comment-start-skip) "# *")
  (set (make-local-variable 'comment-column) 48)

  (set (make-local-variable 'font-lock-defaults) '(mqttclient-mode-keywords))
  ;; We use outline-mode's method outline-flag-region to hide/show the
  ;; body. As a part of it, it sets 'invisibility text property to
  ;; 'outline. To get ellipsis, we need 'outline to be in
  ;; buffer-invisibility-spec
  (add-to-invisibility-spec '(outline . t)))

(add-hook 'mqttclient-mode-hook 'mqttclient-outline-mode)

(provide 'mqttclient-mode)

(eval-after-load 'helm
  '(ignore-errors (require 'mqttclient-helm)))

;;; mqttclient-mode.el ends here
