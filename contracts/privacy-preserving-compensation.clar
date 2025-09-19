;; privacy-preserving-compensation
;; Automated compensation for anonymized health data contributions to research

;; Error constants
(define-constant ERR-NOT-AUTHORIZED u200)
(define-constant ERR-INSUFFICIENT-FUNDS u201)
(define-constant ERR-INVALID-PROJECT u202)
(define-constant ERR-ALREADY-CLAIMED u203)
(define-constant ERR-INVALID-AMOUNT u204)
(define-constant ERR-PROJECT-NOT-ACTIVE u205)
(define-constant ERR-COMPENSATION-CALCULATION-FAILED u206)
(define-constant ERR-WITHDRAWAL-FAILED u207)
(define-constant ERR-INVALID-PARTICIPANT u208)

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-COMPENSATION u10000) ;; 0.01 STX minimum
(define-constant MAX-COMPENSATION u100000000) ;; 100 STX maximum
(define-constant PLATFORM-FEE-PERCENTAGE u5) ;; 5% platform fee
(define-constant BASE-QUALITY-MULTIPLIER u100)
(define-constant RARITY-BONUS-MULTIPLIER u150)
(define-constant RESEARCH-IMPACT-MULTIPLIER u200)
(define-constant LOYALTY-BONUS-THRESHOLD u30) ;; 30 days

;; Compensation tiers based on data quality
(define-constant TIER-BRONZE-THRESHOLD u50)
(define-constant TIER-SILVER-THRESHOLD u75)
(define-constant TIER-GOLD-THRESHOLD u90)
(define-constant TIER-BRONZE-RATE u1000)
(define-constant TIER-SILVER-RATE u2000)
(define-constant TIER-GOLD-RATE u5000)
(define-constant TIER-PLATINUM-RATE u10000)

;; Data variables
(define-data-var next-project-id uint u1)
(define-data-var next-compensation-id uint u1)
(define-data-var total-research-projects uint u0)
(define-data-var total-compensations-paid uint u0)
(define-data-var platform-revenue uint u0)

;; Research projects mapping
(define-map research-projects
  { project-id: uint }
  {
    title: (string-ascii 100),
    description: (string-ascii 500),
    researcher: principal,
    funding-amount: uint,
    remaining-budget: uint,
    compensation-rate: uint,
    target-participants: uint,
    current-participants: uint,
    project-status: uint, ;; 1=active, 2=paused, 3=completed, 4=cancelled
    creation-block: uint,
    end-block: uint,
    data-requirements: (list 5 (string-ascii 20)),
    quality-threshold: uint
  }
)

;; Participant data contributions
(define-map participant-contributions
  { project-id: uint, participant: principal }
  {
    total-submissions: uint,
    quality-score-sum: uint,
    average-quality: uint,
    first-contribution-block: uint,
    last-contribution-block: uint,
    total-earned: uint,
    compensation-tier: uint,
    is-eligible: bool
  }
)

;; Individual compensation records
(define-map compensation-records
  { compensation-id: uint }
  {
    project-id: uint,
    participant: principal,
    submission-id: uint,
    base-amount: uint,
    quality-bonus: uint,
    rarity-bonus: uint,
    loyalty-bonus: uint,
    total-amount: uint,
    platform-fee: uint,
    net-amount: uint,
    calculation-block: uint,
    payment-status: uint, ;; 1=calculated, 2=paid, 3=failed
    payment-block: uint
  }
)

;; Project funding escrow
(define-map project-escrow
  { project-id: uint }
  {
    deposited-amount: uint,
    reserved-amount: uint,
    paid-amount: uint,
    refundable-amount: uint,
    last-update-block: uint
  }
)

;; Participant earnings summary
(define-map participant-earnings
  { participant: principal }
  {
    total-earned: uint,
    total-projects: uint,
    pending-withdrawals: uint,
    withdrawn-amount: uint,
    current-tier: uint,
    reputation-score: uint,
    join-block: uint
  }
)

;; Data quality metrics tracking
(define-map quality-metrics
  { participant: principal, metric-type: (string-ascii 20) }
  {
    metric-value: uint,
    sample-count: uint,
    last-updated: uint,
    percentile-rank: uint
  }
)

;; Research impact multipliers
(define-map impact-multipliers
  { project-id: uint }
  {
    base-multiplier: uint,
    publication-bonus: uint,
    breakthrough-bonus: uint,
    social-impact-score: uint,
    citations-count: uint
  }
)

;; Private functions

;; Calculate base compensation based on quality tier
(define-private (calculate-tier-rate (quality-score uint))
  (if (>= quality-score TIER-GOLD-THRESHOLD)
      TIER-PLATINUM-RATE
      (if (>= quality-score TIER-SILVER-THRESHOLD)
          TIER-GOLD-RATE
          (if (>= quality-score TIER-BRONZE-THRESHOLD)
              TIER-SILVER-RATE
              TIER-BRONZE-RATE)))
)

;; Calculate quality bonus multiplier
(define-private (calculate-quality-bonus (quality-score uint))
  (if (> quality-score u80)
      (+ BASE-QUALITY-MULTIPLIER (* (- quality-score u80) u10))
      BASE-QUALITY-MULTIPLIER)
)

;; Calculate rarity bonus based on data uniqueness
(define-private (calculate-rarity-bonus (participant principal) (data-type (string-ascii 20)))
  (let ((quality-metric (default-to { metric-value: u50, sample-count: u100, last-updated: u0, percentile-rank: u50 }
                                    (map-get? quality-metrics { participant: participant, metric-type: data-type }))))
    (if (< (get percentile-rank quality-metric) u20) ;; Top 20% rarity
        RARITY-BONUS-MULTIPLIER
        u100)
  )
)

;; Calculate loyalty bonus for long-term participants
(define-private (calculate-loyalty-bonus (first-contribution-block uint))
  (let ((participation-duration (- stacks-block-height first-contribution-block)))
    (if (> participation-duration (* LOYALTY-BONUS-THRESHOLD u144)) ;; ~30 days in blocks
        u120 ;; 20% bonus
        u100) ;; No bonus
  )
)

;; Calculate platform fee
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount PLATFORM-FEE-PERCENTAGE) u100)
)

;; Update participant tier based on performance
(define-private (update-participant-tier (participant principal) (new-quality-score uint))
  (let ((earnings-info (default-to 
                       { total-earned: u0, total-projects: u0, pending-withdrawals: u0, 
                         withdrawn-amount: u0, current-tier: u1, reputation-score: u50, join-block: stacks-block-height }
                       (map-get? participant-earnings { participant: participant }))))
    (let ((new-tier (if (>= new-quality-score TIER-GOLD-THRESHOLD) u4
                       (if (>= new-quality-score TIER-SILVER-THRESHOLD) u3
                          (if (>= new-quality-score TIER-BRONZE-THRESHOLD) u2 u1)))))
      (map-set participant-earnings
        { participant: participant }
        (merge earnings-info { current-tier: new-tier })
      )
      true
    )
  )
)

;; Verify project is active and funded
(define-private (is-project-active (project-id uint))
  (let ((project-info (unwrap! (map-get? research-projects { project-id: project-id }) false)))
    (and (is-eq (get project-status project-info) u1)
         (> (get remaining-budget project-info) u0)
         (<= stacks-block-height (get end-block project-info)))
  )
)

;; Public functions

;; Register a new research project
(define-public (register-research-project 
  (title (string-ascii 100))
  (description (string-ascii 500))
  (funding-amount uint)
  (compensation-rate uint)
  (target-participants uint)
  (duration-blocks uint)
  (data-requirements (list 5 (string-ascii 20)))
  (quality-threshold uint))
  (let ((project-id (var-get next-project-id)))
    (asserts! (>= funding-amount (* MIN-COMPENSATION target-participants)) (err ERR-INSUFFICIENT-FUNDS))
    (asserts! (<= compensation-rate MAX-COMPENSATION) (err ERR-INVALID-AMOUNT))
    (asserts! (> target-participants u0) (err ERR-INVALID-PROJECT))
    (asserts! (and (>= quality-threshold u0) (<= quality-threshold u100)) (err ERR-INVALID-PROJECT))
    
    ;; Transfer funding to escrow
    (try! (stx-transfer? funding-amount tx-sender (as-contract tx-sender)))
    
    ;; Register research project
    (map-set research-projects
      { project-id: project-id }
      {
        title: title,
        description: description,
        researcher: tx-sender,
        funding-amount: funding-amount,
        remaining-budget: funding-amount,
        compensation-rate: compensation-rate,
        target-participants: target-participants,
        current-participants: u0,
        project-status: u1,
        creation-block: stacks-block-height,
        end-block: (+ stacks-block-height duration-blocks),
        data-requirements: data-requirements,
        quality-threshold: quality-threshold
      }
    )
    
    ;; Set up project escrow
    (map-set project-escrow
      { project-id: project-id }
      {
        deposited-amount: funding-amount,
        reserved-amount: u0,
        paid-amount: u0,
        refundable-amount: funding-amount,
        last-update-block: stacks-block-height
      }
    )
    
    ;; Initialize impact multipliers
    (map-set impact-multipliers
      { project-id: project-id }
      {
        base-multiplier: u100,
        publication-bonus: u0,
        breakthrough-bonus: u0,
        social-impact-score: u0,
        citations-count: u0
      }
    )
    
    ;; Update global counters
    (var-set next-project-id (+ project-id u1))
    (var-set total-research-projects (+ (var-get total-research-projects) u1))
    
    (ok project-id)
  )
)

;; Calculate comprehensive compensation for data contribution
(define-public (calculate-reward 
  (project-id uint)
  (participant principal)
  (submission-id uint)
  (quality-score uint)
  (data-type (string-ascii 20)))
  (let (
    (project-info (unwrap! (map-get? research-projects { project-id: project-id }) (err ERR-INVALID-PROJECT)))
    (participant-info (default-to 
                      { total-submissions: u0, quality-score-sum: u0, average-quality: u0,
                        first-contribution-block: stacks-block-height, last-contribution-block: stacks-block-height,
                        total-earned: u0, compensation-tier: u1, is-eligible: true }
                      (map-get? participant-contributions { project-id: project-id, participant: participant })))
    (compensation-id (var-get next-compensation-id))
  )
    (asserts! (is-project-active project-id) (err ERR-PROJECT-NOT-ACTIVE))
    (asserts! (>= quality-score (get quality-threshold project-info)) (err ERR-INVALID-PARTICIPANT))
    (asserts! (get is-eligible participant-info) (err ERR-INVALID-PARTICIPANT))
    
    ;; Calculate compensation components
    (let (
      (base-rate (calculate-tier-rate quality-score))
      (quality-bonus (calculate-quality-bonus quality-score))
      (rarity-bonus (calculate-rarity-bonus participant data-type))
      (loyalty-bonus (calculate-loyalty-bonus (get first-contribution-block participant-info)))
      (base-amount (get compensation-rate project-info))
    )
      (let (
        (quality-adjusted (* base-amount (/ quality-bonus u100)))
        (rarity-adjusted (* quality-adjusted (/ rarity-bonus u100)))
        (loyalty-adjusted (* rarity-adjusted (/ loyalty-bonus u100)))
        (total-before-fee loyalty-adjusted)
        (platform-fee (calculate-platform-fee total-before-fee))
        (net-amount (- total-before-fee platform-fee))
      )
        (asserts! (<= total-before-fee (get remaining-budget project-info)) (err ERR-INSUFFICIENT-FUNDS))
        (asserts! (>= net-amount MIN-COMPENSATION) (err ERR-INVALID-AMOUNT))
        
        ;; Record compensation calculation
        (map-set compensation-records
          { compensation-id: compensation-id }
          {
            project-id: project-id,
            participant: participant,
            submission-id: submission-id,
            base-amount: base-amount,
            quality-bonus: (- quality-adjusted base-amount),
            rarity-bonus: (- rarity-adjusted quality-adjusted),
            loyalty-bonus: (- loyalty-adjusted rarity-adjusted),
            total-amount: total-before-fee,
            platform-fee: platform-fee,
            net-amount: net-amount,
            calculation-block: stacks-block-height,
            payment-status: u1,
            payment-block: u0
          }
        )
        
        ;; Update participant contribution tracking
        (map-set participant-contributions
          { project-id: project-id, participant: participant }
          {
            total-submissions: (+ (get total-submissions participant-info) u1),
            quality-score-sum: (+ (get quality-score-sum participant-info) quality-score),
            average-quality: (/ (+ (get quality-score-sum participant-info) quality-score) 
                               (+ (get total-submissions participant-info) u1)),
            first-contribution-block: (get first-contribution-block participant-info),
            last-contribution-block: stacks-block-height,
            total-earned: (+ (get total-earned participant-info) net-amount),
            compensation-tier: (calculate-tier-rate quality-score),
            is-eligible: true
          }
        )
        
        ;; Update project budget
        (map-set research-projects
          { project-id: project-id }
          (merge project-info { remaining-budget: (- (get remaining-budget project-info) total-before-fee) })
        )
        
        ;; Update participant tier
        (update-participant-tier participant quality-score)
        
        ;; Update global counter
        (var-set next-compensation-id (+ compensation-id u1))
        
        (ok { compensation-id: compensation-id, net-amount: net-amount, platform-fee: platform-fee })
      )
    )
  )
)

;; Process payment for calculated compensation
(define-public (process-payment (compensation-id uint))
  (let ((compensation-info (unwrap! (map-get? compensation-records { compensation-id: compensation-id }) (err ERR-INVALID-AMOUNT))))
    (asserts! (is-eq (get payment-status compensation-info) u1) (err ERR-ALREADY-CLAIMED))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) (err ERR-NOT-AUTHORIZED)) ;; In production, would be automated
    
    ;; Transfer payment to participant
    (try! (as-contract (stx-transfer? (get net-amount compensation-info) tx-sender (get participant compensation-info))))
    
    ;; Update payment status
    (map-set compensation-records
      { compensation-id: compensation-id }
      (merge compensation-info { payment-status: u2, payment-block: stacks-block-height })
    )
    
    ;; Update participant earnings
    (let ((earnings-info (default-to 
                         { total-earned: u0, total-projects: u0, pending-withdrawals: u0,
                           withdrawn-amount: u0, current-tier: u1, reputation-score: u50, join-block: stacks-block-height }
                         (map-get? participant-earnings { participant: (get participant compensation-info) }))))
      (map-set participant-earnings
        { participant: (get participant compensation-info) }
        (merge earnings-info 
          {
            total-earned: (+ (get total-earned earnings-info) (get net-amount compensation-info)),
            withdrawn-amount: (+ (get withdrawn-amount earnings-info) (get net-amount compensation-info))
          }
        )
      )
    )
    
    ;; Update platform revenue
    (var-set platform-revenue (+ (var-get platform-revenue) (get platform-fee compensation-info)))
    (var-set total-compensations-paid (+ (var-get total-compensations-paid) u1))
    
    (ok true)
  )
)

;; Allocate additional funding to research project
(define-public (allocate-research-funds (project-id uint) (additional-amount uint))
  (let ((project-info (unwrap! (map-get? research-projects { project-id: project-id }) (err ERR-INVALID-PROJECT))))
    (asserts! (is-eq tx-sender (get researcher project-info)) (err ERR-NOT-AUTHORIZED))
    (asserts! (> additional-amount u0) (err ERR-INVALID-AMOUNT))
    
    ;; Transfer additional funds
    (try! (stx-transfer? additional-amount tx-sender (as-contract tx-sender)))
    
    ;; Update project funding
    (map-set research-projects
      { project-id: project-id }
      (merge project-info 
        {
          funding-amount: (+ (get funding-amount project-info) additional-amount),
          remaining-budget: (+ (get remaining-budget project-info) additional-amount)
        }
      )
    )
    
    ;; Update escrow
    (let ((escrow-info (unwrap! (map-get? project-escrow { project-id: project-id }) (err ERR-INVALID-PROJECT))))
      (map-set project-escrow
        { project-id: project-id }
        (merge escrow-info
          {
            deposited-amount: (+ (get deposited-amount escrow-info) additional-amount),
            refundable-amount: (+ (get refundable-amount escrow-info) additional-amount),
            last-update-block: stacks-block-height
          }
        )
      )
    )
    
    (ok true)
  )
)

;; Update research impact multipliers (called by authorized evaluators)
(define-public (update-research-impact 
  (project-id uint)
  (publication-bonus uint)
  (breakthrough-bonus uint)
  (social-impact-score uint)
  (citations-count uint))
  (let ((impact-info (unwrap! (map-get? impact-multipliers { project-id: project-id }) (err ERR-INVALID-PROJECT))))
    ;; In production, would verify caller is authorized research evaluator
    (asserts! (is-eq tx-sender CONTRACT-OWNER) (err ERR-NOT-AUTHORIZED))
    
    (map-set impact-multipliers
      { project-id: project-id }
      {
        base-multiplier: (get base-multiplier impact-info),
        publication-bonus: publication-bonus,
        breakthrough-bonus: breakthrough-bonus,
        social-impact-score: social-impact-score,
        citations-count: citations-count
      }
    )
    (ok true)
  )
)

;; Emergency pause project
(define-public (pause-project (project-id uint))
  (let ((project-info (unwrap! (map-get? research-projects { project-id: project-id }) (err ERR-INVALID-PROJECT))))
    (asserts! (or (is-eq tx-sender (get researcher project-info)) (is-eq tx-sender CONTRACT-OWNER)) (err ERR-NOT-AUTHORIZED))
    
    (map-set research-projects
      { project-id: project-id }
      (merge project-info { project-status: u2 })
    )
    (ok true)
  )
)

;; Read-only functions

(define-read-only (get-research-project (project-id uint))
  (map-get? research-projects { project-id: project-id })
)

(define-read-only (get-participant-contributions (project-id uint) (participant principal))
  (map-get? participant-contributions { project-id: project-id, participant: participant })
)

(define-read-only (get-compensation-record (compensation-id uint))
  (map-get? compensation-records { compensation-id: compensation-id })
)

(define-read-only (get-participant-earnings (participant principal))
  (map-get? participant-earnings { participant: participant })
)

(define-read-only (get-project-escrow (project-id uint))
  (map-get? project-escrow { project-id: project-id })
)

(define-read-only (get-platform-statistics)
  {
    total-projects: (var-get total-research-projects),
    total-compensations: (var-get total-compensations-paid),
    platform-revenue: (var-get platform-revenue),
    next-project-id: (var-get next-project-id)
  }
)

(define-read-only (estimate-compensation 
  (project-id uint)
  (quality-score uint)
  (participant principal)
  (data-type (string-ascii 20)))
  (let ((project-info (unwrap! (map-get? research-projects { project-id: project-id }) (err ERR-INVALID-PROJECT))))
    (let (
      (base-amount (get compensation-rate project-info))
      (quality-bonus (calculate-quality-bonus quality-score))
      (rarity-bonus (calculate-rarity-bonus participant data-type))
      (loyalty-bonus u100) ;; Default for estimation
    )
      (let (
        (total-before-fee (* base-amount (/ (* (* quality-bonus rarity-bonus) loyalty-bonus) u1000000)))
        (platform-fee (calculate-platform-fee total-before-fee))
        (net-amount (- total-before-fee platform-fee))
      )
        (ok { estimated-gross: total-before-fee, platform-fee: platform-fee, estimated-net: net-amount })
      )
    )
  )
)
