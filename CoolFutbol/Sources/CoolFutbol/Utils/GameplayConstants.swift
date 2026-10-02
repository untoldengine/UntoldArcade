//
//  GameplayConstants.swift
//  CoolFutbol
//
//  Copyright (C) Untold Engine Studios
//  Licensed under the GNU LGPL v3.0 or later.
//  See the LICENSE file or <https://www.gnu.org/licenses/> for details.
//

import Foundation
import simd

/// Centralized gameplay constants to avoid magic numbers scattered across systems
struct GameplayConstants {
    
    // MARK: - Ball Constants
    struct Ball {
        static let possessionDistance: Float = 1.3     // Was 1.5 - tighter possession range
        static let kickDistance: Float = 0.7           // Was 0.8 - kick ball closer to feet
        static let controlTakeoverDistance: Float = 1.2
        static let snapRadius: Float = 1.5
        static let snapOffset: Float = 0.5             // Was 0.6 - ball snaps closer
        static let speed: Float = 1.0
        static let linearDragCoefficient = simd_float2(0.7, 0.0)
        // Increased angular drag from 0.01 to 0.5 to stop spin rolling after ball stops
        // This prevents the ball from continuing to roll on the ground after velocity reaches threshold
        static let angularDragCoefficient = simd_float2(0.2, 0.0)
        static let velocityThreshold: Float = 0.1
    }
    
    // MARK: - Movement Constants
    struct Movement {
        static let baseSpeed: Float = 7.0              // Was 5.0 - faster base speed for arcade feel
        static let sprintMultiplier: Float = 2.2       // Was 1.6 - dramatic sprint boost
        static let acceleration: Float = 25.0          // Was 12.0 - instant response (arcade snappy)
        static let deceleration: Float = 20.0          // Was 16.0 - quick stops
        static let inputSmoothing: Float = 10.0
        static let possessionTurnRate: Float = 12.0    // Was 8.0 - tighter turns with ball
        static let freeTurnRate: Float = 18.0          // Was 14.0 - faster turns without ball
        static let controlSideBias: Float = 0.4
        static let directionChangeBrake: Float = 60.0  // Was 80.0 - less brake, more agile
        static let lateralDamping: Float = 5.0         // Was 1.0 - much stronger to prevent slide on turns
        static let targetDirectionResponse: Float = 14.0
    }
    
    // MARK: - Combat Constants
    struct Combat {
        static let tackleRange: Float = 1.2
        static let stealCooldown: Float = 1.8
        static let stealOffset: Float = 0.4
        static let detectionRange: Float = 10.0
        // How often (seconds) to re-evaluate which home player is closest to the
        // ball while the opponent has possession, so control can auto-switch to
        // the nearest defender instead of being stuck on whoever last had the ball.
        static let controlSwitchInterval: Float = 0.5
        // Distance multiplier applied to the already-controlled player so a
        // marginally closer teammate doesn't cause control to flicker every check.
        static let controlSwitchHysteresis: Float = 0.8
        // Debounce (seconds) for the manual "switch to next defender" input —
        // keys are level-triggered (true while held), so this is what prevents
        // a single press/hold from cycling through every player in one frame.
        static let manualSwitchCooldown: Float = 0.3
    }
    
    // MARK: - Shooting Constants
    struct Shooting {
        static let shootPower: Float = 30.0
        static let shootAccuracy: Float = 0.8
        static let shootCooldown: Float = 2.0
        static let shootingRange: Float = 1.2
        
        // Aim assist - blend between player facing and goal direction
        static let aimAssistStrength: Float = 0.7  // 0=no assist, 1=full auto-aim
        
        // Power scaling based on distance
        static let minPower: Float = 15.0          // Close range power
        static let maxPower: Float = 40.0          // Long range power
        static let optimalShootDistance: Float = 15.0  // Distance for max power
        
        // Accuracy spread (arcade feel)
        static let accuracySpreadDegrees: Float = 5.0  // Random deviation in degrees
    }
    
    // MARK: - Passing Constants
    struct Passing {
        static let passForce: Float = 20.0
        static let passAccuracy: Float = 0.85
        static let passCooldown: Float = 0.5
        static let passRange: Float = 1.2           // Max distance to pass - auto-approach if farther
        static let minForce: Float = 8.0
        static let leadTimeMultiplier: Float = 0.3  // How far ahead to lead moving receivers
        static let minLeadSpeed: Float = 2.0        // Only apply lead if receiver moving >= this speed
        static let distanceForceDivisor: Float = 5.0    // Normalizer for distance-based force scaling
        static let maxDistanceForceFactor: Float = 2.5  // Cap on force multiplier for long passes
        static let minReceiverDistance: Float = 0.1     // Skip receiver if closer than this (epsilon guard)
        static let speedDistanceRatio: Float = 2.0      // Estimated pass speed per unit of distance
    }
    
    // MARK: - Receiving Constants
    struct Receiving {
        static let maxSpeed: Float = 15.0
        static let receiveCooldown: Float = 2.0
        static let receiveReactionDelay: Float = 0.2  // Reduced from 0.5s for snappier feel
        static let maxReceivingTime: Float = 3.0      // Timeout for receiving attempt
        static let interceptionSpeedBoost: Float = 1.2 // Speed multiplier when intercepting pass
    }
    
    // MARK: - Dribbling Constants
    struct Dribbling {
        static let baseKickSpeed: Float = 8.0
        static let possessionRadius: Float = 1.5
        static let catchUpBoostMultiplier: Float = 1.3
        static let dribbleOffset: Float = 0.8          // Ball distance in front of player during soft-attach
        static let attachLerpSpeed: Float = 15.0       // How fast the ball lerps to the attach target
    }
    
    // MARK: - State Timing Constants
    struct StateTiming {
        static let shootRecoveryDuration: Float = 1.0
        static let passRecoveryDuration: Float = 0.5
        static let settlingDuration: Float = 0.4
    }
    
    // MARK: - NPC Constants
    struct NPC {
        static let decisionCooldown: Float = 2.0
        static let chaseSpeed: Float = 4.0
        static let chaseSpeedFast: Float = 4.5
        static let chaseTurnSpeed: Float = 45.0
        static let chaseTurnSpeedFast: Float = 50.0
        static let targetRefreshInterval: Float = 1.5
        static let approachSpeedMultiplier: Float = 1.5
        // Radius within which a marking defender leaves formation and presses their mark.
        // The presser (NPC assigned to ball carrier) always chases regardless of this value.
        static let alertRange: Float = 20.0
        static let avoidanceRadius: Float = 1.5
        // Minimum dot product between NPC facing and goal direction before a
        // dribble kick is allowed. 0.5 ≈ 60°, 0.7 ≈ 45°, 0.0 = always kick.
        static let kickAlignmentThreshold: Float = 0.5
        // Minimum findBestReceiver score for an NPC to commit to a pass.
        // Filters out passes to heavily marked or poorly positioned teammates.
        static let minPassScore: Float = 0.25
    }
    
    // MARK: - AI Decision Constants
    struct AIDecision {
        static let pressureThreshold: Float = 0.6
        static let distanceThreshold: Float = 6.0
    }
    
    // MARK: - Formation Constants
    struct Formation {
        static let updateInterval: Float = 1.0
        static let arrivalThreshold: Float = 0.8
        static let formationSpeed: Float = 5.0
        static let slowingRadius: Float = 1.0
        static let formationTurnSpeed: Float = 40.0
        static let fieldMargin: Float = 1.0
        // Distance multiplier applied to a player who was assigned to a role last
        // interval. Values below 1.0 make them appear "closer" in the greedy sort,
        // so they hold their assignment unless someone else is substantially nearer.
        // 0.75 = keep your role unless another player is at least 25% closer.
        static let assignmentHysteresisFactor: Float = 0.75
        // Distance multiplier applied when a player's natural role (PlayerRoleComponent)
        // matches a cell's role. 0.5 = they appear twice as close, strongly preferring
        // their natural position without locking them to it.
        static let naturalRoleMatchFactor: Float = 0.5
        // Fraction of the lateral (z) offset compressed toward the center lane when
        // a player's intent is .narrowCentralSpace. 0 = no change, 1 = fully central.
        static let centralNarrowingFactor: Float = 0.5
        // Units behind the ball (along the attacking axis) that a player with
        // .coverBehindBall intent targets, ensuring they stay on the safe side.
        static let coverBehindBallDrop: Float = 5.0
        // How far (in world units) from the center line each player must stay during
        // kickoff. Keeps midfielders and the forward in their own half until play starts.
        static let kickoffHalflineBuffer: Float = 0.5
        static let defenderFreedomRadius: Float  = 6.0
        static let midfielderFreedomRadius: Float = 10.0
        static let forwardFreedomRadius: Float   = 14.0
        static let defaultFreedomRadius: Float   = 8.0
        static let attackingForwardShift: Float = 3.0
        static let defendingBackShift: Float = 3.0
        static let attackingCompactness: Float = 1.1
        static let attackingWidth: Float = 1.15
        static let defendingCompactness: Float = 0.85
        static let defendingWidth: Float = 0.85
    }
    
    // MARK: - Team Tactics Constants
    struct TeamTactics {
        // How long a team presses after losing possession before dropping into
        // defensive shape. Formation stays in attacking position during this window.
        static let pressDuration: Float = 4.0
    }

    // MARK: - Support Positioning Constants
    struct SupportPositioning {
        // Intent-driven positioning allows multiple roles to move simultaneously
        // (e.g. two supporters + one depth runner), so raise the cap to 3.
        static let maxOpenSpacePlayers: Int = 3
        static let supportRadius: Float = 5.0
        static let minMovementThreshold: Float = 2.0
        static let evaluationInterval: Float = 0.5
        static let weightDefenderDist: Float = 1.0
        static let weightPassingLane: Float = 1.5
        static let weightGoalProximity: Float = 0.8
        static let weightRoleZone: Float = 0.5
        static let weightSpacing: Float = 0.7
        static let maxDefenderDist: Float = 8.0
        static let laneWidth: Float = 2.0
        static let minTeammateSpacing: Float = 5.0
        static let maxGoalDist: Float = 30.0
        static let weightCarrierAngle: Float = 0.9
    }

    // MARK: - Goal Constants
    struct Goal {
        static let triggerRadius: Float = 3.0
    }
    
    // MARK: - Field Bounds Constants
    struct FieldBounds {
        static let resetMargin: Float = 0.3
    }
    
    // MARK: - Animation Constants
    struct Animation {
        static let minPlaybackSpeed: Float = 0.8
        static let maxPlaybackSpeed: Float = 1.4
        static let speedRange: Float = 0.6
    }
    
    // MARK: - Steering Constants
    struct Steering {
        static let pursuitTurnSpeed: Float = 8.0
        static let pursuitTurnSpeedFast: Float = 10.0
    }
    
    // MARK: - Pass Scoring Weights
    struct PassScoring {
        // Predictive interception-based scoring
        static let interceptionTimeWeight: Float = 0.4   // How quickly receiver can intercept
        static let defenderProximityWeight: Float = 0.3  // How close defenders are to interception point
        static let receiverSpeedWeight: Float = 0.2      // Favor faster receivers
        static let alignmentWeight: Float = 0.1          // Passer's facing direction

        // Constraints
        static let maxPressureDistance: Float = 6.0
        static let fallbackPressure: Float = 999.0
        static let maxInterceptionTime: Float = 3.0      // Don't pick receivers who take too long

        // Pass lane blocking — perpendicular radius around the pass line that a
        // defender must be within to be considered blocking the lane.
        static let laneBlockRadius: Float = 1.5
        // Bonus added to a receiver's score when their tactical intent signals they
        // are already moving into position. Keeps the raw score in [0, 1+bonus] so
        // a well-positioned supporter can beat a marginally faster stationary player.
        static let supportIntentBonus: Float = 0.25   // checking into a passing lane
        static let depthRunIntentBonus: Float = 0.15  // making a forward run
    }
    
    // MARK: - AI Assist Constants (for young players 3-5 years old)
    struct AIAssist {
        // Difficulty presets (0.0 = no assist, 1.0 = full AI)
        static let easyAssistLevel: Float = 0.7          // 70% AI, 30% manual
        static let mediumAssistLevel: Float = 0.5        // 50% AI, 50% manual
        static let hardAssistLevel: Float = 0.3          // 30% AI, 70% manual
        static let manualMode: Float = 0.0               // No AI assist

        // Direction assist blending
        static let goalDirectionWeight: Float = 0.7      // How strongly to pull toward attacking goal
        static let defenderAvoidWeight: Float = 0.3      // How strongly to push away from nearest defender
        static let defenderMinDistance: Float = 0.1      // Minimum distance to register a defender (epsilon guard)

        // Auto-pass decision
        static let maxPassDistance: Float = 12.0         // Max distance from ball for auto-pass to trigger
        static let minDribbleDurationBeforePass: Float = 0.8  // Seconds dribbling required before auto-pass is allowed
        static let autoPassCooldown: Float = 1.0         // Seconds between auto-pass attempts
        static let maxTeammatePassDistance: Float = 15.0 // Max range when searching for a teammate to pass to
        static let minTeammateProximity: Float = 0.5     // Skip teammates closer than this (too close to be useful)
        static let passChanceMultiplier: Float = 1.5     // Scales assist level when computing pass probability

        // Auto-shoot decision
        static let maxShootProbability: Float = 0.95     // Hard cap on auto-shoot probability regardless of assist level
        static let maxPassProbability: Float = 0.85      // Hard cap on auto-pass probability regardless of assist level
    }

    // MARK: - Camera Constants
    struct Camera {
        // Fixed eye offset from the tracked ground point (ball, height-flattened).
        // x=0 keeps the camera's local right axis aligned to world X (the pitch's
        // goal-to-goal axis), so deadZoneExtents.x maps directly onto pitch length —
        // this is what makes the "pan along the pitch" behavior predictable.
        static let offset = simd_float3(0.0, 26.0, -22.0)
        // Dead-zone half-extents in the camera's local axes (x=right, y=up, z=forward).
        // The ball can move freely inside this box before the camera reacts.
        static let deadZoneExtents = simd_float3(10.0, 6.0, 8.0)
        // Exponential catch-up rate used by cameraFollowDeadZone (t = smoothFactor * deltaTime).
        static let smoothFactor: Float = 3.0
        // Fixed height used for the camera's tracking target instead of the ball's
        // actual y, so bounces/shots don't make the camera bob vertically.
        static let trackingGroundY: Float = 0.5
        // Extra room (beyond the pitch's goal-to-goal half-length) the camera may
        // pan before being clamped, so a ball parked in a corner can't push the
        // camera arbitrarily far off the pitch.
        static let panMargin: Float = 4.0
    }
}
