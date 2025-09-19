;; wearable-data-aggregation
;; Secure integration of fitness trackers and health monitoring devices for the Health Data Marketplace

;; Error constants
(define-constant ERR-NOT-AUTHORIZED u100)
(define-constant ERR-DEVICE-NOT-FOUND u101)
(define-constant ERR-INVALID-DATA u102)
(define-constant ERR-DEVICE-ALREADY-REGISTERED u103)
(define-constant ERR-INSUFFICIENT-STAKE u104)
(define-constant ERR-INVALID-DEVICE-TYPE u105)
(define-constant ERR-DATA-SUBMISSION-FAILED u106)
(define-constant ERR-PRIVACY-SETTINGS-NOT-FOUND u107)

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-STAKE-AMOUNT u1000000) ;; 1 STX minimum stake
(define-constant MAX-DEVICES-PER-USER u10)
(define-constant DATA-RETENTION-BLOCKS u144000) ;; ~100 days at 10 min blocks

;; Device types
(define-constant DEVICE-TYPE-FITNESS-TRACKER u1)
(define-constant DEVICE-TYPE-SMARTWATCH u2)
(define-constant DEVICE-TYPE-HEART-MONITOR u3)
(define-constant DEVICE-TYPE-SLEEP-TRACKER u4)
(define-constant DEVICE-TYPE-BLOOD-OXYGEN u5)

;; Data maps and vars
(define-data-var next-device-id uint u1)
(define-data-var total-devices-registered uint u0)
(define-data-var total-data-submissions uint u0)

;; Device registration map
(define-map devices
  { device-id: uint }
  {
    owner: principal,
    device-type: uint,
    device-hash: (buff 32),
    registration-block: uint,
    is-active: bool,
    stake-amount: uint,
    total-submissions: uint,
    last-submission-block: uint,
    reputation-score: uint
  }
)

;; User device mapping
(define-map user-devices
  { user: principal }
  { device-count: uint, device-ids: (list 10 uint) }
)

;; Health data submissions
(define-map health-data
  { submission-id: uint }
  {
    device-id: uint,
    data-hash: (buff 32),
    submission-block: uint,
    data-type: (string-ascii 20),
    quality-score: uint,
    privacy-level: uint,
    is-validated: bool
  }
)

;; Privacy settings per user
(define-map privacy-settings
  { user: principal }
  {
    data-sharing-enabled: bool,
    anonymization-level: uint,
    research-participation: bool,
    compensation-opt-in: bool,
    data-retention-period: uint
  }
)

;; Device authentication mapping
(define-map device-auth
  { device-hash: (buff 32) }
  {
    device-id: uint,
    auth-key: (buff 33),
    last-auth-block: uint,
    auth-failures: uint
  }
)

;; Data validation results
(define-map validation-results
  { submission-id: uint }
  {
    validator: principal,
    validation-block: uint,
    is-valid: bool,
    quality-metrics: (list 5 uint),
    validation-notes: (string-ascii 100)
  }
)

;; Private functions

;; Generate device hash from device info
(define-private (generate-device-hash (device-info (string-ascii 100)))
  (keccak256 (concat (unwrap-panic (to-consensus-buff? device-info)) (unwrap-panic (to-consensus-buff? stacks-block-height))))
)

;; Validate device type
(define-private (is-valid-device-type (device-type uint))
  (and (>= device-type DEVICE-TYPE-FITNESS-TRACKER) 
       (<= device-type DEVICE-TYPE-BLOOD-OXYGEN))
)

;; Calculate quality score based on data consistency
(define-private (calculate-quality-score (device-id uint) (current-data (buff 32)))
  (let ((device-info (unwrap! (map-get? devices { device-id: device-id }) u0)))
    (if (> (get total-submissions device-info) u5)
        (+ u70 (mod (len current-data) u30)) ;; Score between 70-100
        u50) ;; New devices start with base score
  )
)

;; Update reputation based on validation results
(define-private (update-device-reputation (device-id uint) (validation-success bool))
  (match (map-get? devices { device-id: device-id })
    device-info
    (let ((current-reputation (get reputation-score device-info)))
      (let ((new-reputation 
             (if validation-success
                 (if (< (+ current-reputation u5) u100) (+ current-reputation u5) u100)
                 (if (> (- current-reputation u10) u0) (- current-reputation u10) u0))))
        (map-set devices 
          { device-id: device-id }
          (merge device-info { reputation-score: new-reputation })
        )
        true
      )
    )
    false
  )
)

;; Verify device authentication
(define-private (verify-device-auth (device-hash (buff 32)) (auth-signature (buff 65)))
  ;; Simplified authentication check - in production would verify cryptographic signature
  (is-some (map-get? device-auth { device-hash: device-hash }))
)

;; Public functions

;; Register a new wearable device
(define-public (register-device (device-info (string-ascii 100)) (device-type uint) (stake-amount uint))
  (let (
    (device-id (var-get next-device-id))
    (device-hash (generate-device-hash device-info))
    (user-device-info (default-to { device-count: u0, device-ids: (list) } 
                                   (map-get? user-devices { user: tx-sender })))
  )
    (asserts! (is-valid-device-type device-type) (err ERR-INVALID-DEVICE-TYPE))
    (asserts! (>= stake-amount MIN-STAKE-AMOUNT) (err ERR-INSUFFICIENT-STAKE))
    (asserts! (< (get device-count user-device-info) MAX-DEVICES-PER-USER) (err ERR-DEVICE-ALREADY-REGISTERED))
    (asserts! (is-none (map-get? device-auth { device-hash: device-hash })) (err ERR-DEVICE-ALREADY-REGISTERED))
    
    ;; Transfer stake amount (simplified - in production would use escrow)
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    
    ;; Register device
    (map-set devices
      { device-id: device-id }
      {
        owner: tx-sender,
        device-type: device-type,
        device-hash: device-hash,
        registration-block: stacks-block-height,
        is-active: true,
        stake-amount: stake-amount,
        total-submissions: u0,
        last-submission-block: u0,
        reputation-score: u50
      }
    )
    
    ;; Update device authentication with simplified key generation
    (map-set device-auth
      { device-hash: device-hash }
      {
        device-id: device-id,
        auth-key: (keccak256 (concat device-hash (unwrap-panic (to-consensus-buff? stacks-block-height)))),
        last-auth-block: stacks-block-height,
        auth-failures: u0
      }
    )
    
    ;; Update user device mapping
    (map-set user-devices
      { user: tx-sender }
      {
        device-count: (+ (get device-count user-device-info) u1),
        device-ids: (unwrap-panic (as-max-len? (append (get device-ids user-device-info) device-id) u10))
      }
    )
    
    ;; Update global counters
    (var-set next-device-id (+ device-id u1))
    (var-set total-devices-registered (+ (var-get total-devices-registered) u1))
    
    (ok device-id)
  )
)

;; Submit health data from registered device
(define-public (submit-health-data (device-id uint) (data-hash (buff 32)) (data-type (string-ascii 20)) (auth-signature (buff 65)))
  (let (
    (device-info (unwrap! (map-get? devices { device-id: device-id }) (err ERR-DEVICE-NOT-FOUND)))
    (submission-id (var-get total-data-submissions))
    (privacy-config (default-to 
                    { data-sharing-enabled: true, anonymization-level: u3, research-participation: true, 
                      compensation-opt-in: true, data-retention-period: DATA-RETENTION-BLOCKS }
                    (map-get? privacy-settings { user: (get owner device-info) })))
  )
    (asserts! (is-eq tx-sender (get owner device-info)) (err ERR-NOT-AUTHORIZED))
    (asserts! (get is-active device-info) (err ERR-DEVICE-NOT-FOUND))
    (asserts! (verify-device-auth (get device-hash device-info) auth-signature) (err ERR-NOT-AUTHORIZED))
    (asserts! (get data-sharing-enabled privacy-config) (err ERR-NOT-AUTHORIZED))
    
    ;; Calculate data quality score
    (let ((quality-score (calculate-quality-score device-id data-hash)))
      
      ;; Store health data submission
      (map-set health-data
        { submission-id: submission-id }
        {
          device-id: device-id,
          data-hash: data-hash,
          submission-block: stacks-block-height,
          data-type: data-type,
          quality-score: quality-score,
          privacy-level: (get anonymization-level privacy-config),
          is-validated: false
        }
      )
      
      ;; Update device statistics
      (map-set devices
        { device-id: device-id }
        (merge device-info 
          {
            total-submissions: (+ (get total-submissions device-info) u1),
            last-submission-block: stacks-block-height
          }
        )
      )
      
      ;; Update global counter
      (var-set total-data-submissions (+ submission-id u1))
      
      (ok submission-id)
    )
  )
)

;; Update privacy settings for user
(define-public (update-privacy-settings 
  (data-sharing bool) 
  (anonymization-level uint) 
  (research-participation bool)
  (compensation-opt-in bool)
  (retention-period uint))
  (begin
    (asserts! (<= anonymization-level u5) (err ERR-INVALID-DATA))
    (asserts! (<= retention-period (* DATA-RETENTION-BLOCKS u5)) (err ERR-INVALID-DATA))
    
    (map-set privacy-settings
      { user: tx-sender }
      {
        data-sharing-enabled: data-sharing,
        anonymization-level: anonymization-level,
        research-participation: research-participation,
        compensation-opt-in: compensation-opt-in,
        data-retention-period: retention-period
      }
    )
    (ok true)
  )
)

;; Validate submitted health data (called by authorized validators)
(define-public (validate-data-integrity (submission-id uint) (is-valid bool) (quality-metrics (list 5 uint)))
  (let (
    (submission-info (unwrap! (map-get? health-data { submission-id: submission-id }) (err ERR-INVALID-DATA)))
  )
    ;; In production, would check if caller is authorized validator
    (asserts! (is-eq tx-sender CONTRACT-OWNER) (err ERR-NOT-AUTHORIZED))
    
    ;; Update validation results
    (map-set validation-results
      { submission-id: submission-id }
      {
        validator: tx-sender,
        validation-block: stacks-block-height,
        is-valid: is-valid,
        quality-metrics: quality-metrics,
        validation-notes: "Automated validation completed"
      }
    )
    
    ;; Mark data as validated
    (map-set health-data
      { submission-id: submission-id }
      (merge submission-info { is-validated: true })
    )
    
    ;; Update device reputation
    (update-device-reputation (get device-id submission-info) is-valid)
    
    (ok true)
  )
)

;; Deactivate device (emergency function)
(define-public (deactivate-device (device-id uint))
  (let ((device-info (unwrap! (map-get? devices { device-id: device-id }) (err ERR-DEVICE-NOT-FOUND))))
    (asserts! (or (is-eq tx-sender (get owner device-info)) (is-eq tx-sender CONTRACT-OWNER)) (err ERR-NOT-AUTHORIZED))
    
    (map-set devices
      { device-id: device-id }
      (merge device-info { is-active: false })
    )
    (ok true)
  )
)

;; Read-only functions

(define-read-only (get-device-info (device-id uint))
  (map-get? devices { device-id: device-id })
)

(define-read-only (get-user-devices (user principal))
  (map-get? user-devices { user: user })
)

(define-read-only (get-health-data (submission-id uint))
  (map-get? health-data { submission-id: submission-id })
)

(define-read-only (get-privacy-settings (user principal))
  (map-get? privacy-settings { user: user })
)

(define-read-only (get-validation-result (submission-id uint))
  (map-get? validation-results { submission-id: submission-id })
)

(define-read-only (get-platform-stats)
  {
    total-devices: (var-get total-devices-registered),
    total-submissions: (var-get total-data-submissions),
    next-device-id: (var-get next-device-id)
  }
)
