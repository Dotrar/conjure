(module conjure.client.common-lisp.slynk
  {autoload {a conjure.aniseed.core
             nvim conjure.aniseed.nvim
             bridge conjure.bridge
             mapping conjure.mapping
             text conjure.text
             log conjure.log
             str conjure.aniseed.string
             config conjure.config
             client conjure.client
             remote conjure.remote.slynk
             output conjure.client.common-lisp.output
             ts conjure.tree-sitter}})

(def buf-suffix ".lisp")
(def context-pattern "%(%s*defpackage%s+(.-)[%s){]")
(def comment-prefix "; ")
(def form-node? ts.node-surrounded-by-form-pair-chars?)

;; ------------ common lisp client
;; Can parse simple forms
;; and return the result.
;; will also display the stdout
;; in the log, when present.

(config.merge
  {:client
   {:common_lisp
    {:slynk
     {:connection {:default_host "127.0.0.1"
                   :default_port "4005"}
      :mapping {:connect "cc"
                :disconnect "cd"}}}}})

(defonce- state (client.new-state
                  #(do
                     {:conn nil
                      :eval-id 0})))

(defn- with-conn-or-warn [f opts]
  (let [conn (state :conn)]
    (if conn
      (f conn)
      (log.append "; No connection"))))

(defn- connected? []
  (if (state :conn)
    true
    false))

(defn- display-conn-status [status]
  (with-conn-or-warn
    (fn [conn]
      (log.append
        [(.. "; Slynk " conn.host ":" conn.port " (" status ")")]
        {:break? true}))))

(defn disconnect []
  (with-conn-or-warn
    (fn [conn]
      (conn.destroy)
      (display-conn-status :disconnected)
      (a.assoc (state) :conn nil))))


(defn- remote-execute [slyfn msg context cb]
  (with-conn-or-warn
    (fn [conn]
      (let [eval-id (a.get (a.update (state) :eval-id a.inc) :eval-id)]
        ;; TODO: the 'eval-id' at the end is indicating the expression given
        ;; this is so the results that return can be married up to the
        ;; expression that is sent, asynchronously.
        (remote.send
          conn
          (str.join
            ["(:emacs-rex (slynk:"
             slyfn
             " " 
             (output.wrap-message msg)
             ") " 
             (output.wrap-message-or-nil (or context nil))
             " t "
             eval-id
             ")"]) 
          cb)))))

;; functions we can send to SLYNK:
(defn eval-and-grab-output [msg context cb]
   (remote-execute :eval-and-grab-output msg context cb))
(defn connection-info []
   (remote-execute :connection-info))
; -----------------------------------

(defn connect [opts]
  (let [opts (or opts {})
        host (or opts.host (config.get-in [:client :common_lisp :slynk :connection :default_host]))
        port (or opts.port (config.get-in [:client :common_lisp :slynk :connection :default_port]))]

    (when (state :conn)
      (disconnect))

    (a.assoc
      (state) :conn
      (remote.connect
        {:host host
         :port port

         :on-failure
         (fn [err]
           (display-conn-status err)
           (disconnect))

         :on-success
         (fn []
           (display-conn-status :connected))

         :on-error
         (fn [err]
           (if err
             (display-conn-status err)
             (disconnect)))})))
  (connection-info))


(defn- try-ensure-conn []
  (when (not (connected?))
    (connect {:silent? true})))



(defn eval-str [opts]
  (try-ensure-conn)

  (when (not (a.empty? opts.code))
    (eval-and-grab-output
      opts.code
      (when (not (a.empty? opts.context))
        opts.context)
      (fn [msg]
        (let [(stdout result) (output.parse-result msg)]
          (output.display-stdout stdout)
          (when (not= nil result)
            (when opts.on-result
              (opts.on-result result))

            (when (not opts.passive?)
              (log.append (text.split-lines result)))))))))

(defn doc-str [opts]
  (try-ensure-conn)
  (eval-str (a.update opts :code #(.. "(describe #'" $1 ")"))))

(defn eval-file [opts]
  (try-ensure-conn)
  (eval-str
    (a.assoc opts :code (.. "(load \"" opts.file-path "\")"))))

(defn on-filetype []
  (mapping.buf :n :CommonLispDisconnect
               (config.get-in [:client :common_lisp :slynk :mapping :disconnect])
               :conjure.client.common-lisp.slynk :disconnect)
  (mapping.buf :n :CommonLispConnect
               (config.get-in [:client :common_lisp :slynk :mapping :connect])
               :conjure.client.common-lisp.slynk :connect))

(defn on-load []
  (connect {}))

(defn on-exit []
  (disconnect))